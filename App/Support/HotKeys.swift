import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts via Carbon's RegisterEventHotKey — still the only API that works without
/// Accessibility permission.
@MainActor
final class HotKeys {
    struct Shortcut: Identifiable {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let display: String
        let title: String
    }

    static let shared = HotKeys()

    static let addRegion = Shortcut(id: 1, keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥T", title: String(localized: "Add Lens"))
    static let toggleOriginal = Shortcut(id: 2, keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥O", title: String(localized: "Show Original"))
    static let pause = Shortcut(id: 3, keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥P", title: String(localized: "Pause"))
    static let refresh = Shortcut(id: 4, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥R", title: String(localized: "Translate Again"))
    static let all = [addRegion, toggleOriginal, pause, refresh]

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(_ s: Shortcut, handler: @escaping () -> Void) {
        installIfNeeded()
        handlers[s.id] = handler
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D57_5941), id: s.id) // 'MWYA'
        if RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
