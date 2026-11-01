import Foundation

/// Which control draws a setting. Decided from the JSON alone: kind, choices, range.
public enum ControlStyle: Equatable {
    /// A choice with at most four choices.
    case segmented([String])
    /// A choice with more.
    case popup([String])
    case toggle
    case slider(min: Double, max: Double, step: Double)
    /// Nothing to put in a control: show the value as text (no range, no choices).
    case valueOnly
}

public enum ControlMapping {
    public static let segmentedLimit = 4

    public static func style(for setting: Setting) -> ControlStyle {
        switch setting.kind {
        case .bool:
            return .toggle
        case .choice:
            if setting.choices.isEmpty { return .valueOnly }
            return setting.choices.count <= segmentedLimit ? .segmented(setting.choices) : .popup(setting.choices)
        case .number:
            guard let lo = setting.min, let hi = setting.max, hi > lo else { return .valueOnly }
            let step = (setting.step ?? 1) > 0 ? (setting.step ?? 1) : 1
            return .slider(min: lo, max: hi, step: step)
        }
    }

    /// Why a control is disabled, nil when it can be changed.
    public static func disabledHint(for setting: Setting) -> String? {
        if setting.writable { return nil }
        return setting.auto ? "set automatically" : "read-only"
    }

    /// The text next to a slider, or the whole row of a value-only setting.
    public static func valueText(for setting: Setting) -> String {
        switch setting.value {
        case .text(let s): return s
        case .number(let d): return SettingValue.format(d)
        case .none: return "\u{2014}"
        }
    }

    /// The setting's help without the list of choices after the last colon ("field of view in degrees: 90, 78, 65").
    /// Help that says more than the list ("on, off (camera restarts on change)") stays whole.
    public static func caption(for setting: Setting) -> String {
        let help = setting.help
        guard setting.kind != .number, let colon = help.lastIndex(of: ":") else { return help }
        let items = help[help.index(after: colon)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let known = setting.kind == .bool ? ["on", "off"] : setting.choices
        return !items.isEmpty && items.allSatisfy({ known.contains($0) }) ? String(help[..<colon]) : help
    }

    /// The value a slider sends: snapped to the step and the range.
    public static func snapped(_ v: Double, min lo: Double, max hi: Double, step: Double) -> Double {
        let n = ((v - lo) / step).rounded()
        return Swift.min(hi, Swift.max(lo, lo + n * step))
    }

    /// What to send for a slider position: the number as the CLI parses it.
    public static func argument(forNumber v: Double) -> String { SettingValue.format(v) }

    // MARK: micgain

    public static let micGainRange: ClosedRange<Double> = 0...1
    public static let micGainStep = 0.01

    public static func micGainArgument(_ v: Double) -> String { String(format: "%.2f", v) }
}
