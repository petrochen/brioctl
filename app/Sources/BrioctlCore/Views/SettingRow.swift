import SwiftUI

/// One setting, drawn by the control its kind and range call for (see ControlMapping).
struct SettingRow: View {
    let setting: Setting
    @ObservedObject var store: CameraStore

    private var style: ControlStyle { ControlMapping.style(for: setting) }
    private var hint: String? { ControlMapping.disabledHint(for: setting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
                .disabled(!setting.writable)
                .opacity(setting.writable ? 1 : 0.55)
            footnote
        }
        .help(setting.help)
        .accessibilityElement(children: .contain)
    }

    private var label: some View {
        Text(setting.name).fontWeight(.medium)
    }

    @ViewBuilder private var control: some View {
        switch style {
        case .toggle:
            HStack {
                label
                Spacer()
                Toggle(setting.name, isOn: toggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        case .segmented(let choices):
            VStack(alignment: .leading, spacing: 4) {
                label
                Picker(setting.name, selection: choiceBinding) {
                    ForEach(withCurrent(choices), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
            }
        case .popup(let choices):
            HStack {
                label
                Spacer()
                Picker(setting.name, selection: choiceBinding) {
                    ForEach(withCurrent(choices), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        case .slider(let lo, let hi, let step):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    label
                    Spacer()
                    Text(ControlMapping.valueText(for: valueSetting))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: sliderBinding(lo: lo, hi: hi, step: step), in: lo...hi) { editing in
                    if !editing { Task { await store.flush(setting.name) } }
                }
                .controlSize(.small)
            }
        case .valueOnly:
            HStack {
                label
                Spacer()
                Text(ControlMapping.valueText(for: valueSetting)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var footnote: some View {
        if let error = store.errors[setting.name] {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else {
            let caption = ControlMapping.caption(for: setting)
            let text = [caption, hint].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            if !text.isEmpty {
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The setting with the value the user has just chosen, for the text next to a slider.
    private var valueSetting: Setting {
        Setting(name: setting.name, value: store.value(of: setting), defaultValue: setting.defaultValue,
                auto: setting.auto, group: setting.group, writable: setting.writable, kind: setting.kind,
                min: setting.min, max: setting.max, step: setting.step, choices: setting.choices, help: setting.help)
    }

    private func withCurrent(_ choices: [String]) -> [String] {
        if let current = store.value(of: setting).text, !choices.contains(current) { return choices + [current] }
        return choices
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { store.value(of: setting).text == "on" },
            set: { on in
                if setting.name == "mic" {
                    store.changeMic(to: on)
                } else {
                    store.change(setting.name, to: on ? "on" : "off", shown: .text(on ? "on" : "off"))
                }
            })
    }

    private var choiceBinding: Binding<String> {
        Binding(
            get: { store.value(of: setting).text ?? "" },
            set: { store.change(setting.name, to: $0, shown: .text($0)) })
    }

    private func sliderBinding(lo: Double, hi: Double, step: Double) -> Binding<Double> {
        Binding(
            get: { store.value(of: setting).double ?? lo },
            set: { v in
                let snapped = ControlMapping.snapped(v, min: lo, max: hi, step: step)
                if snapped == store.value(of: setting).double { return }
                store.change(setting.name, to: ControlMapping.argument(forNumber: snapped), shown: .number(snapped),
                             delay: CameraStore.sliderDelay)
            })
    }
}

/// The microphone input volume (macOS), which brioctl reports next to the settings.
struct MicGainRow: View {
    let current: Double
    @ObservedObject var store: CameraStore

    private var shown: Double { store.pending["micgain"]?.double ?? current }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("micgain").fontWeight(.medium)
                Spacer()
                Text("\(Int((shown * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { shown },
                set: { v in
                    let snapped = ControlMapping.snapped(v, min: 0, max: 1, step: ControlMapping.micGainStep)
                    if snapped == shown { return }
                    store.change("micgain", to: ControlMapping.micGainArgument(snapped), shown: .number(snapped),
                                 delay: CameraStore.sliderDelay)
                }), in: ControlMapping.micGainRange) { editing in
                if !editing { Task { await store.flush("micgain") } }
            }
            .controlSize(.small)
            if let error = store.errors["micgain"] {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("input volume of the camera microphone, 0\u{2013}100%").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
