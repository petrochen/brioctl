import Carbon.HIToolbox
import Foundation

/// The global hotkeys: Control-Option-Command plus a key.
public enum HotkeyAction: Int, CaseIterable, Equatable {
    case fov90 = 1, fov78, fov65, zoomReset, zoomIn, zoomOut

    public static let zoomStep = 25.0

    /// The character after the three modifiers.
    public var key: String {
        switch self {
        case .fov90: return "1"
        case .fov78: return "2"
        case .fov65: return "3"
        case .zoomReset: return "0"
        case .zoomIn: return "="
        case .zoomOut: return "-"
        }
    }

    /// Virtual key codes of the ANSI layout: they name physical keys.
    public var keyCode: UInt32 {
        switch self {
        case .fov90: return UInt32(kVK_ANSI_1)
        case .fov78: return UInt32(kVK_ANSI_2)
        case .fov65: return UInt32(kVK_ANSI_3)
        case .zoomReset: return UInt32(kVK_ANSI_0)
        case .zoomIn: return UInt32(kVK_ANSI_Equal)
        case .zoomOut: return UInt32(kVK_ANSI_Minus)
        }
    }

    public static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    public var shortcut: String { "\u{2303}\u{2325}\u{2318}" + key }

    public var title: String {
        switch self {
        case .fov90: return "fov 90"
        case .fov78: return "fov 78"
        case .fov65: return "fov 65"
        case .zoomReset: return "zoom 100"
        case .zoomIn: return "zoom +25"
        case .zoomOut: return "zoom \u{2212}25"
        }
    }
}

public enum Hotkeys {
    /// What a hotkey writes on this camera, or nil when it has nothing to do: the camera lacks the control, the control
    /// cannot be written now, or the value is already at the end of its range.
    public static func command(for action: HotkeyAction, state: CameraState) -> [(name: String, value: String)]? {
        switch action {
        case .fov90, .fov78, .fov65:
            let value = action == .fov90 ? "90" : action == .fov78 ? "78" : "65"
            guard let fov = state.setting("fov"), fov.writable else { return nil }
            if fov.kind == .choice, !fov.choices.contains(value) { return nil }
            return [("fov", value)]
        case .zoomReset:
            guard let zoom = state.setting("zoom"), zoom.writable, zoom.kind == .number else { return nil }
            if let lo = zoom.min, 100 < lo { return nil }
            if let hi = zoom.max, 100 > hi { return nil }
            return [("zoom", "100")]
        case .zoomIn, .zoomOut:
            guard let zoom = state.setting("zoom"), zoom.writable, zoom.kind == .number, let current = zoom.value.double
            else { return nil }
            let delta = action == .zoomIn ? HotkeyAction.zoomStep : -HotkeyAction.zoomStep
            var target = current + delta
            if let lo = zoom.min { target = Swift.max(lo, target) }
            if let hi = zoom.max { target = Swift.min(hi, target) }
            if let lo = zoom.min, let step = zoom.step, step > 0 {
                target = ControlMapping.snapped(target, min: lo, max: zoom.max ?? target, step: step)
            }
            if target == current { return nil }
            return [("zoom", SettingValue.format(target))]
        }
    }
}

/// Registers the hotkeys with Carbon's RegisterEventHotKey, which needs no Accessibility permission.
public final class HotkeyManager {
    public var onAction: ((HotkeyAction) -> Void)?
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private static var handlerInstalled = false
    private static weak var active: HotkeyManager?
    private static let signature: OSType = 0x6272_696F  // 'brio'

    public init() {}

    public var isRegistered: Bool { !refs.isEmpty }

    /// Registers every hotkey; returns the ones another app already owns (or that failed otherwise).
    @discardableResult
    public func register() -> [HotkeyAction] {
        unregister()
        installHandler()
        HotkeyManager.active = self
        var failed: [HotkeyAction] = []
        for action in HotkeyAction.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(action.rawValue))
            let status = RegisterEventHotKey(action.keyCode, HotkeyAction.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[action] = ref } else { failed.append(action) }
        }
        return failed
    }

    public func unregister() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    deinit { unregister() }

    private func installHandler() {
        guard !HotkeyManager.handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard got == noErr, id.signature == HotkeyManager.signature, let action = HotkeyAction(rawValue: Int(id.id))
            else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { HotkeyManager.active?.onAction?(action) }
            return noErr
        }, 1, &spec, nil, nil)
        HotkeyManager.handlerInstalled = status == noErr
    }
}
