import SwiftUI

/// Hotkeys, launch at login, automatic re-apply, the settings folder and About.
struct SettingsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hotkeys
            Divider()
            loginItem
            Divider()
            autoApply
            if let error = model.settingsError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button("Open settings folder") { model.openSettingsFolder() }
            Divider()
            about
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hotkeys: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Global hotkeys", isOn: $model.hotkeysEnabled).toggleStyle(.switch)
            Text(HotkeyAction.allCases.map { "\($0.shortcut)  \($0.title)" }.joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let problem = model.hotkeyProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var loginItem: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) }))
                .toggleStyle(.switch)
                .disabled(!model.canStartAtLogin)
            Text(model.canStartAtLogin
                 ? "Writes ~/Library/LaunchAgents/\(AgentLabel.login).plist."
                 : "Available in the packaged app (brioctl.app).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var isOurs: Bool {
        if case .app = model.watchState { return true }
        return false
    }

    private var autoApply: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.watchState {
            case .off, .app:
                Toggle("Re-apply settings automatically", isOn: Binding(
                    get: { isOurs },
                    set: { on in Task { await model.setAutoApply(on) } }))
                    .toggleStyle(.switch)
                    .disabled(model.store.state == nil && !isOurs)
            case .other:
                Toggle("Re-apply settings automatically", isOn: .constant(true)).toggleStyle(.switch).disabled(true)
            }
            Text(autoApplyCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if case .app(let usesThisCopy) = model.watchState {
                HStack {
                    Button("Remember current settings") { Task { await model.rememberCurrentSettings() } }
                    if !usesThisCopy {
                        Button("Use this copy of the app") { Task { await model.setAutoApply(true) } }
                    }
                }
            }
        }
    }

    private var autoApplyCaption: String {
        switch model.watchState {
        case .off:
            return "Saves the current settings and starts brioctl watch, which applies them when the camera is connected and when video starts."
        case .app(let usesThisCopy):
            let running = model.watchRunning ? "Running." : "Installed, not running."
            let copy = usesThisCopy ? "" : " It runs the brioctl of another copy of the app."
            return "\(running)\(copy) It applies the saved \u{201C}settings\u{201D} file; changes made here are kept only after \u{201C}Remember current settings\u{201D}."
        case .other(.homebrew):
            return "Installed by Homebrew. Manage it with brew services."
        case .other(.makeAgent(let program)):
            return "Installed by make agent / Homebrew (runs \(program)). Remove it there (make unagent)."
        case .other(.unreadable):
            return "An agent with this label is installed by make agent / Homebrew; the app leaves it alone."
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("brioctl app \(model.appVersion) \u{00B7} brioctl \(model.store.cliVersion ?? "?")").font(.callout)
            Link("github.com/petrochen/brioctl", destination: URL(string: "https://github.com/petrochen/brioctl")!)
                .font(.caption)
            Text("URLs: brioctl://set?fov=78&zoom=115, brioctl://apply?name=warmer, brioctl://camera?id=2")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
