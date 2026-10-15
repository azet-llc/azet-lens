import CoreMedia
import CoreVideo
import Foundation
import MwoyeaCore
import ScreenCaptureKit
import os

/// Streams one screen rectangle with ScreenCaptureKit. Mwoyea's own windows (the overlays) are excluded,
/// so it always sees the original content underneath. ScreenCaptureKit only delivers frames when pixels
/// change, so a static region costs nothing.
final class RegionCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case displayNotFound
        var errorDescription: String? { String(localized: "Can’t find the display this lens is on.") }
    }

    var onFrame: (@Sendable (CapturedFrame) -> Void)?
    var onStop: (@Sendable (Error?) -> Void)?

    private let queue = DispatchQueue(label: "dev.midagedev.mwoyea.capture", qos: .userInitiated)
    private let log = Logger(subsystem: "dev.midagedev.mwoyea", category: "capture")
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var scale: CGFloat = 2
    /// The rect the stream is known to deliver; nil while a reconfiguration is in flight (frames are ambiguous then).
    private let configured = OSAllocatedUnfairLock<CGRect?>(initialState: nil)

    /// `rect` is in global Quartz points and must lie on one display.
    func start(rect: CGRect, fps: Double) async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.max(by: { overlap($0.frame, rect) < overlap($1.frame, rect) }),
              overlap(display.frame, rect) > 0 else { throw CaptureError.displayNotFound }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        scale = CGFloat(filter.pointPixelScale)

        let config = configuration(rect: rect, display: display.frame, fps: fps)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.filter = filter
        displayFrame = display.frame
        await settle(rect: rect, config: config)
    }

    private var displayFrame: CGRect = .zero

    /// Moves/resizes the captured rect without restarting (same display).
    func update(rect: CGRect, fps: Double) async throws {
        // Moving onto another display needs a new filter; within one display, reconfigure in place.
        guard let stream, displayFrame.contains(CGPoint(x: rect.midX, y: rect.midY)) else {
            try await start(rect: rect, fps: fps)
            return
        }
        configured.withLock { $0 = nil }
        let config = configuration(rect: rect, display: displayFrame, fps: fps)
        try await stream.updateConfiguration(config)
        await settle(rect: rect, config: config)
    }

    /// Marks `rect` as what the stream now shows and delivers one fresh frame of it. ScreenCaptureKit only sends
    /// frames when pixels change, so without this a lens moved over static content would never see what it uncovered.
    private func settle(rect: CGRect, config: SCStreamConfiguration) async {
        configured.withLock { $0 = rect }
        guard let filter, let buffer = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config),
              let pb = buffer.imageBuffer, configured.withLock({ $0 }) == rect,
              let frame = Self.makeFrame(pb, rect: rect, scale: scale) else { return }
        onFrame?(frame)
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        configured.withLock { $0 = nil }
        try? await s.stopCapture()
    }

    private func configuration(rect: CGRect, display: CGRect, fps: Double) -> SCStreamConfiguration {
        let local = rect.intersection(display).offsetBy(dx: -display.minX, dy: -display.minY)
        let c = SCStreamConfiguration()
        c.sourceRect = local
        c.width = max(2, Int((local.width * scale).rounded()))
        c.height = max(2, Int((local.height * scale).rounded()))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.showsCursor = false
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(30, fps))))
        c.queueDepth = 4
        c.captureResolution = .best
        return c
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        guard let rect = configured.withLock({ $0 }), let frame = Self.makeFrame(pixelBuffer, rect: rect, scale: scale) else { return }
        onFrame?(frame)
    }

    /// Copies the (pooled, soon reused) pixel buffer into an owned CGImage and a downsampled gray image.
    static func makeFrame(_ pb: CVPixelBuffer, rect: CGRect, scale: CGFloat) -> CapturedFrame? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let step = scale >= 2 ? 4 : 2
        let gray = GrayImage(bgra: base, width: w, height: h, bytesPerRow: bpr, step: step)
        let data = Data(bytes: base, count: bpr * h) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return CapturedFrame(image: image, gray: gray, grayStep: step, scale: scale, rect: rect, time: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("stream stopped: \(error.localizedDescription)")
        if self.stream === stream { self.stream = nil }
        onStop?(error)
    }
}
