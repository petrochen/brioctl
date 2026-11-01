import AppKit
import Foundation
import SwiftUI

/// Puts the pieces together: the camera store, the LaunchAgents, the hotkeys and the brioctl:// URLs.
@MainActor
public final class AppModel: ObservableObject {
    public let environment: AppEnvironment
    public let store: CameraStore
    public let agents: LaunchAgentManager
    private let hotkeys = HotkeyManager()
    private var lastMenuRefresh = Date.distantPast

    @Published public private(set) var watchState: WatchAgentState = .off
    @Published public private(set) var watchRunning = false
    @Published public private(set) var loginItem = false
    /// Why the last change of the settings page failed.
    @Published public private(set) var settingsError: String?
    @Published public private(set) var hotkeyProblem: String?
    @Published public var hotkeysEnabled: Bool {
        didSet {
            environment.defaults.set(hotkeysEnabled, forKey: "hotkeysEnabled")
            applyHotkeySetting()
        }
    }

    public init(environment: AppEnvironment = AppEnvironment(), runner: CLIRunning? = nil,
                launchctl: LaunchctlRunning = SystemLaunchctl()) {
        self.environment = environment
        let cli = environment.cliURL ?? URL(fileURLWithPath: "/nonexistent/brioctl")
        store = CameraStore(runner: runner ?? ProcessCLIRunner(executable: cli, environment: environment.processEnvironment),
                            defaults: environment.defaults)
        agents = LaunchAgentManager(directory: environment.agentsDirectory, launchctl: launchctl, cliPath: cli.path,
                                    appPath: environment.appBundlePath, logPath: environment.logPath)
        hotkeysEnabled = environment.defaults.bool(forKey: "hotkeysEnabled")
        store.confirm = { title, text, button in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            Task { await self.handle(hotkey: action) }
        }
    }

    public var appVersion: String { environment.appVersion }

    public var cliMissing: Bool { !environment.cliExists }

    /// The app has started: read the camera, find out what is installed, register the hotkeys.
    public func start() {
        refreshAgents()
        applyHotkeySetting()
        Task { await store.refresh() }
    }

    /// The menu was opened. The first view appearance and the window becoming key both call this; it reads once.
    public func menuOpened() {
        refreshAgents()
        guard Date().timeIntervalSince(lastMenuRefresh) > 0.5 else { return }
        lastMenuRefresh = Date()
        Task { await store.refresh(clearErrors: true) }
    }

    // MARK: LaunchAgents

    public func refreshAgents() {
        watchState = agents.watchState()
        watchRunning = agents.watchIsRunning()
        loginItem = agents.loginItemEnabled()
    }

    /// "Re-apply settings automatically": saves the current settings, then installs the agent that runs `watch`.
    public func setAutoApply(_ on: Bool) async {
        settingsError = nil
        do {
            if on {
                guard await store.saveCurrent(as: nil) else {
                    settingsError = store.banner ?? "Could not save the settings."
                    refreshAgents()
                    return
                }
                try agents.installWatch(camera: store.cameras.count > 1 ? store.cameraArgument : nil)
            } else {
                try agents.removeWatch()
            }
        } catch {
            settingsError = "\(error)"
        }
        refreshAgents()
    }

    /// The agent applies the file named `settings`: save the camera as it is now.
    public func rememberCurrentSettings() async {
        settingsError = nil
        if !(await store.saveCurrent(as: nil)) { settingsError = store.banner }
    }

    public func setLoginItem(_ on: Bool) {
        settingsError = nil
        do { try agents.setLoginItem(enabled: on) } catch { settingsError = "\(error)" }
        refreshAgents()
    }

    public var canStartAtLogin: Bool { environment.appBundlePath.hasSuffix(".app") }

    // MARK: hotkeys

    private func applyHotkeySetting() {
        hotkeyProblem = nil
        if hotkeysEnabled {
            let failed = hotkeys.register()
            if !failed.isEmpty {
                hotkeyProblem = "Another app already uses " + failed.map(\.shortcut).joined(separator: ", ") + "."
            }
        } else {
            hotkeys.unregister()
        }
    }

    /// A hotkey: only acts if the camera has the control.
    public func handle(hotkey action: HotkeyAction) async {
        if store.state == nil || action == .zoomIn || action == .zoomOut {
            await store.refresh()  // a zoom step starts from what the camera has now
        }
        guard let state = store.state, let pairs = Hotkeys.command(for: action, state: state) else {
            log.notice("hotkey \(action.title, privacy: .public): nothing to do")
            return
        }
        await store.write(pairs)
    }

    // MARK: brioctl:// URLs

    public func handle(url: URL) async {
        switch URLCommands.parse(url) {
        case .failure(let error):
            log.notice("ignored URL: \(error.description, privacy: .public)")
            store.show(error: "Ignored the URL: \(error)")
        case .success(let command):
            await run(command)
        }
    }

    public func run(_ command: URLCommand) async {
        await store.refresh()
        switch command {
        case .camera(let id):
            guard let camera = store.camera(matching: id) else {
                store.show(error: "No camera matches \u{201C}\(id)\u{201D}.")
                return
            }
            await store.selectCamera(camera)
        case .apply(let name):
            guard URLCommands.isKnownProfile(name, in: store.profiles) else {
                store.show(error: "No preset or saved file named \u{201C}\(name)\u{201D}.")
                return
            }
            await store.apply(profile: name)
        case .set(let pairs):
            guard let state = store.state else {
                store.show(error: "No camera to change.")
                return
            }
            let plan = URLCommands.plan(set: pairs, for: state)
            if !plan.ignored.isEmpty { log.notice("URL: ignored \(plan.ignored.joined(separator: ","), privacy: .public)") }
            await store.write(plan.pairs)
        }
    }

    // MARK: folder

    public func openSettingsFolder() {
        let path = store.profiles?.dir ?? (NSHomeDirectory() + "/.config/brioctl")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
