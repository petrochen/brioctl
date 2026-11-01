import Foundation
import SwiftUI

/// Where the debounced save for `brioctl watch` stands.
public enum AutoSaveStatus: Equatable {
    case idle
    /// A change was written; the save follows when the changes stop.
    case pending
    /// The settings file now has what the camera has (shown for a few seconds).
    case saved
}

/// The state of the chosen camera as the CLI reports it, and every change to it. All CLI calls go through here.
@MainActor
public final class CameraStore: ObservableObject {
    public static let sliderDelay: TimeInterval = 0.15
    /// How long the changes must stop before they are saved for `brioctl watch`.
    public static let autoSaveDelay: TimeInterval = 1.0
    static let selectedKey = "selectedCamera"

    @Published public private(set) var cameras: [CameraInfo] = []
    @Published public private(set) var selectedCamera: CameraInfo?
    @Published public private(set) var state: CameraState?
    @Published public private(set) var profiles: Profiles?
    /// Per setting: what the CLI said when the last change failed.
    @Published public private(set) var errors: [String: String] = [:]
    /// An error that belongs to no setting.
    @Published public private(set) var banner: String?
    /// A short confirmation ("Saved warm").
    @Published public private(set) var notice: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var autoSaveStatus: AutoSaveStatus = .idle
    /// What the user has set and the CLI has not confirmed yet.
    @Published public private(set) var pending: [String: SettingValue] = [:]
    @Published public private(set) var cliVersion: String?
    @Published public var collapsed: Set<String> {
        didSet { defaults.set(Array(collapsed).sorted(), forKey: "collapsedSections") }
    }

    private let runner: CLIRunning
    private let defaults: UserDefaults
    private var queued: [String: String] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var autoSaveTask: Task<Void, Never>?
    private var autoSaveTarget: AutoSaveTarget?
    private var savedHintTask: Task<Void, Never>?

    private struct AutoSaveTarget {
        var camera: CameraInfo?
        /// The --camera value of the camera that was written, kept in case another one is chosen before the save.
        var argument: String?
    }

    /// Asks before something that interrupts the camera; the app shows an alert. Arguments: title, text, button.
    public var confirm: (String, String, String) -> Bool = { _, _, _ in true }
    /// Keeps the file `brioctl watch` re-applies in step with the camera: after each successful change of the app's own,
    /// `brioctl save` runs once the changes pause for `autoSaveDelay` seconds. Asked with the camera that was written,
    /// when the change is made and again when the save is due. The app model answers from the installed LaunchAgents;
    /// without one nothing is saved.
    public var autoSaveEnabled: (CameraInfo?) -> Bool = { _ in false }
    public var autoSaveDelay: TimeInterval = CameraStore.autoSaveDelay

    public init(runner: CLIRunning, defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: "collapsedSections") ?? ["Exposure and image", "Found in the firmware"])
    }

    // MARK: camera

    /// The value of --camera, only when there is more than one camera to choose from.
    public var cameraArgument: String? {
        guard cameras.count > 1, let selectedCamera else { return nil }
        return selectedCamera.cliID(among: cameras)
    }

    public func selectCamera(_ camera: CameraInfo) async {
        guard camera != selectedCamera else { return }
        defaults.set(camera.cliID(among: cameras), forKey: Self.selectedKey)
        selectedCamera = camera
        state = nil
        errors = [:]
        pending = [:]
        queued = [:]
        await reloadState(clearsBanner: true)
    }

    /// The camera a URL or the picker names; nil if none matches.
    public func camera(matching id: String) -> CameraInfo? { URLCommands.camera(matching: id, in: cameras) }

    // MARK: reading

    public func refresh(clearErrors: Bool = false) async {
        if let task = refreshTask {
            await task.value
            return
        }
        if clearErrors { errors = [:] }
        let task = Task { await self.loadAll() }
        refreshTask = task
        await task.value
    }

    private func loadAll() async {
        isLoading = true
        defer {
            isLoading = false
            refreshTask = nil
        }
        let listed = await runner.run(CLIArguments.list())
        guard listed.ok, let list = try? CameraInfo.decodeList(listed.stdout) else {
            cameras = []
            selectedCamera = nil
            state = nil
            banner = listed.ok ? "brioctl gave a camera list the app cannot read." : listed.message
            return
        }
        cameras = list
        let wanted = selectedCamera.map { $0.cliID(among: list) } ?? defaults.string(forKey: Self.selectedKey)
        let previous = selectedCamera
        selectedCamera = wanted.flatMap { id in list.first { $0.matches(id: id) } } ?? list.first
        if previous?.index != selectedCamera?.index { state = nil }
        if selectedCamera == nil {
            state = nil
            banner = nil
        } else {
            await reloadState(clearsBanner: true)
        }
        await reloadProfiles()
        if cliVersion == nil { await loadVersion() }
        log.notice("state refreshed: \(list.count, privacy: .public) camera(s), settings \(self.state?.settings.count ?? 0, privacy: .public)")
    }

    /// Reads the chosen camera. A successful read clears the banner only when asked to: after a failed write the banner
    /// keeps the CLI's complaint.
    private func reloadState(clearsBanner: Bool = false) async {
        guard selectedCamera != nil else { return }
        let r = await runner.run(CLIArguments.state(camera: cameraArgument))
        // A control that cannot be read makes the exit status 1 but the JSON is still all there.
        if let s = try? CameraState.decode(r.stdout) {
            state = s
            if clearsBanner { banner = nil }
        } else {
            banner = r.message
        }
    }

    private func reloadProfiles() async {
        let r = await runner.run(CLIArguments.profiles())
        if r.ok, let p = try? Profiles.decode(r.stdout) { profiles = p }
    }

    private func loadVersion() async {
        let r = await runner.run(CLIArguments.version())
        guard r.ok else { return }
        let text = r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        cliVersion = text.split(separator: " ").last.map(String.init) ?? text
    }

    // MARK: writing

    /// What a control shows: the value the user just chose, else the camera's.
    public func value(of setting: Setting) -> SettingValue { pending[setting.name] ?? setting.value }

    /// A change from a control. Sliders wait for the user to pause; the rest write at once.
    public func change(_ name: String, to value: String, shown: SettingValue, delay: TimeInterval = 0) {
        pending[name] = shown
        queued[name] = value
        errors[name] = nil
        debounceTasks[name]?.cancel()
        debounceTasks[name] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            await self?.flush(name)
        }
    }

    /// Writes a queued change now (the slider was let go).
    public func flush(_ name: String) async {
        debounceTasks[name]?.cancel()
        debounceTasks[name] = nil
        guard let value = queued.removeValue(forKey: name) else { return }
        await write([(name, value)])
    }

    /// One CLI call with these settings, then the view is read again from --json.
    @discardableResult
    public func write(_ pairs: [(name: String, value: String)]) async -> Bool {
        guard !pairs.isEmpty else { return true }
        let r = await runner.run(CLIArguments.set(camera: cameraArgument, pairs))
        let names = pairs.map(\.name)
        var ok = r.ok
        if !r.ok {
            let (per, other) = CLIErrors.attribute(r.stderr, names: names)
            for (name, text) in per { errors[name] = text }
            if let failure = r.failure {
                banner = failure
            } else if !other.isEmpty {
                banner = other.joined(separator: "\n")
            } else if per.isEmpty {
                banner = r.message
            }
        } else {
            for n in names { errors[n] = nil }
            banner = nil
            scheduleAutoSave()
        }
        await reloadState()
        // The camera's values are shown again, unless the user has moved on since.
        for n in names where queued[n] == nil { pending[n] = nil }
        if state == nil { ok = false }
        return ok
    }

    /// The mic toggle: the camera restarts, so ask first.
    public func changeMic(to on: Bool) {
        let word = on ? "on" : "off"
        guard confirm("Turn the camera microphone \(word)?",
                      "The camera restarts, and an app that is using it may drop the video for a few seconds.",
                      "Turn \(word)") else { return }
        change("mic", to: word, shown: .text(word))
    }

    // MARK: presets and saved settings

    /// Applies a preset or a saved file by name.
    public func apply(profile name: String) async {
        let r = await runner.run(CLIArguments.apply(camera: cameraArgument, name: name))
        if r.ok {
            banner = nil
            show(notice: "Applied \(name)")
            scheduleAutoSave()
        } else {
            banner = r.message
        }
        await reloadState()
    }

    /// Saves the camera's current settings as a named file; nil = the file `watch` reads.
    @discardableResult
    public func saveCurrent(as name: String?) async -> Bool {
        if let name, let problem = profiles?.validateNewName(name) {
            banner = problem
            return false
        }
        let r = await runner.run(CLIArguments.save(camera: cameraArgument, name: name?.trimmingCharacters(in: .whitespaces)))
        guard r.ok else {
            banner = r.message
            return false
        }
        banner = nil
        if name == nil { cancelAutoSave(for: cameraArgument) }  // the file is up to date now
        await reloadProfiles()
        show(notice: name.map { "Saved \u{201C}\($0.trimmingCharacters(in: .whitespaces))\u{201D}" } ?? "Saved as the settings to re-apply")
        return true
    }

    // MARK: saving for brioctl watch

    /// Waits for the changes to pause, then saves. Every change starts the wait again, so a burst of slider moves
    /// ends in one `save`.
    private func scheduleAutoSave() {
        let target = AutoSaveTarget(camera: selectedCamera, argument: cameraArgument)
        guard autoSaveEnabled(target.camera) else { return }
        if let pending = autoSaveTarget, pending.argument != target.argument {
            // The wait belongs to another camera: save that one now, this one starts its own wait.
            autoSaveTask?.cancel()
            autoSaveTarget = nil
            Task { await self.runAutoSave(pending) }
        }
        autoSaveTarget = target
        autoSaveStatus = .pending
        savedHintTask?.cancel()
        autoSaveTask?.cancel()
        let nanoseconds = UInt64(max(autoSaveDelay, 0) * 1_000_000_000)
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            await self?.autoSaveDue()
        }
    }

    private func autoSaveDue() async {
        guard let target = autoSaveTarget else { return }
        autoSaveTarget = nil
        autoSaveTask = nil
        await runAutoSave(target)
    }

    private func runAutoSave(_ target: AutoSaveTarget) async {
        // The agent may have been removed while the changes were pending.
        guard autoSaveEnabled(target.camera) else {
            if autoSaveTarget == nil { autoSaveStatus = .idle }
            return
        }
        let r = await runner.run(CLIArguments.save(camera: target.argument))
        guard r.ok else {
            banner = "Could not save the settings for auto-apply: " + r.message
            if autoSaveTarget == nil { autoSaveStatus = .idle }
            return
        }
        if profiles?.saved.contains("settings") != true { await reloadProfiles() }
        guard autoSaveTarget == nil else { return }  // newer changes wait for their own save
        autoSaveStatus = .saved
        savedHintTask?.cancel()
        savedHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            if self?.autoSaveStatus == .saved { self?.autoSaveStatus = .idle }
        }
    }

    private func cancelAutoSave(for argument: String?) {
        guard let pending = autoSaveTarget, pending.argument == argument else { return }
        autoSaveTask?.cancel()
        autoSaveTask = nil
        autoSaveTarget = nil
        autoSaveStatus = .idle
    }

    public func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    public func show(error text: String) { banner = text }
}
