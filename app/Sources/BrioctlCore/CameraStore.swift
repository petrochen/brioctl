import Foundation
import SwiftUI

/// The state of the chosen camera as the CLI reports it, and every change to it. All CLI calls go through here.
@MainActor
public final class CameraStore: ObservableObject {
    public static let sliderDelay: TimeInterval = 0.15
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
    /// Asks before something that interrupts the camera; the app shows an alert. Arguments: title, text, button.
    public var confirm: (String, String, String) -> Bool = { _, _, _ in true }

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
        await reloadProfiles()
        show(notice: name.map { "Saved \u{201C}\($0.trimmingCharacters(in: .whitespaces))\u{201D}" } ?? "Saved as the settings to re-apply")
        return true
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
