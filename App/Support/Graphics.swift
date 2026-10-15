import AppKit
import CoreGraphics
import MwoyeaCore

extension RGBAImage {
    /// Renders (part of) a CGImage into straight RGBA8.
    init?(cgImage: CGImage, crop: PixelRect? = nil) {
        let full = PixelRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let r = (crop ?? full).clamped(width: cgImage.width, height: cgImage.height)
        guard !r.isEmpty, let source = r == full ? cgImage : cgImage.cropping(to: r.cgRect) else { return nil }
        var px = [UInt8](repeating: 0, count: r.width * r.height * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: r.width, height: r.height, bitsPerComponent: 8,
                                      bytesPerRow: r.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
            return true
        }
        guard ok else { return nil }
        // Screen pixels are opaque, so premultiplied == straight here.
        self.init(width: r.width, height: r.height, pixels: px)
    }

    var cgImage: CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension RGBA {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

/// Converts between Quartz global coordinates (top-left origin, y down) and AppKit (bottom-left origin, y up).
enum ScreenGeometry {
    /// Height of the primary display, which anchors both coordinate systems.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func appKitRect(fromQuartz r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func quartzRect(fromAppKit r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The screen showing most of `quartzRect`.
    static func screen(for quartzRect: CGRect) -> NSScreen? {
        let r = appKitRect(fromQuartz: quartzRect)
        return NSScreen.screens.max { a, b in
            area(a.frame.intersection(r)) < area(b.frame.intersection(r))
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}

/// Snapshot of other apps' on-screen windows, front to back.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    /// Quartz global coordinates.
    let bounds: CGRect
    let isOnScreen: Bool

    static func onScreen() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return parse(CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    static func window(id: CGWindowID) -> WindowInfo? {
        parse(CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []).first
    }

    /// Windows stacked above `id` (front to back).
    static func windows(above id: CGWindowID) -> [WindowInfo] {
        parse(CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], id) as? [[String: Any]] ?? [])
    }

    private static func parse(_ list: [[String: Any]]) -> [WindowInfo] {
        let me = getpid()
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (d[kCGWindowLayer as String] as? Int) == 0,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b as CFDictionary),
                  bounds.width > 40, bounds.height > 40
            else { return nil }
            return WindowInfo(id: id, pid: pid,
                              appName: d[kCGWindowOwnerName as String] as? String ?? "",
                              title: d[kCGWindowName as String] as? String ?? "",
                              bounds: bounds,
                              isOnScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
}
