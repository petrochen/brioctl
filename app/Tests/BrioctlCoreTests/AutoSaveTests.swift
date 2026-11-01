import XCTest
@testable import BrioctlCore

private func makeDefaults() -> UserDefaults {
    let suite = "com.github.petrochen.brioctl.app.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

private func saves(_ stub: StubRunner) -> [[String]] { stub.writes.filter { $0.last == "save" } }

/// The debounced `save` that keeps the file of `brioctl watch` in step with changes made in the app.
@MainActor
final class AutoSaveStoreTests: XCTestCase {
    private func makeStore(enabled: Bool = true, delay: TimeInterval = 0.3, list: String = "list-one-camera",
                           answering: ((StubRunner, [String]) -> CLIResult?)? = nil) async throws -> (CameraStore, StubRunner) {
        let base = try StubRunner.serving(list: list)
        let stub = StubRunner { args in answering?(base, args) ?? base.answer(args) }
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        store.autoSaveEnabled = { _ in enabled }
        store.autoSaveDelay = delay
        await store.refresh()
        stub.calls = []
        return (store, stub)
    }

    func testABurstOfChangesIsSavedOnceAfterTheLastOne() async throws {
        let (store, stub) = try await makeStore(delay: 0.5)
        for v in [120.0, 130, 140] {
            await store.write([("zoom", SettingValue.format(v))])
            XCTAssertTrue(saves(stub).isEmpty, "nothing is saved while the changes go on")
            XCTAssertEqual(store.autoSaveStatus, .pending)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let done = await eventually { store.autoSaveStatus == .saved }
        XCTAssertTrue(done)
        XCTAssertEqual(stub.writes, [["zoom", "120"], ["zoom", "130"], ["zoom", "140"], ["save"]])
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(saves(stub).count, 1, "one save for the whole burst")
    }

    func testTheFirstSaveWaitsForTheDelay() async throws {
        let (store, stub) = try await makeStore(delay: 0.4)
        await store.write([("fov", "65")])
        XCTAssertTrue(saves(stub).isEmpty)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(saves(stub).isEmpty, "still inside the debounce")
        let done = await eventually { store.autoSaveStatus == .saved }
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub), [["save"]])
    }

    func testNothingIsSavedWhenAutoApplyIsOff() async throws {
        let (store, stub) = try await makeStore(enabled: false, delay: 0.05)
        await store.write([("zoom", "120")])
        await store.apply(profile: "warmer")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(saves(stub).isEmpty)
        XCTAssertEqual(store.autoSaveStatus, .idle)
        XCTAssertNil(store.banner)
    }

    func testTheDefaultIsNotToSave() async throws {
        let stub = try StubRunner.serving()
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        store.autoSaveDelay = 0.05
        await store.refresh()
        await store.write([("zoom", "120")])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(saves(stub).isEmpty)
    }

    func testAPresetOrSavedFileIsSavedToo() async throws {
        let (store, stub) = try await makeStore(delay: 0.1)
        await store.apply(profile: "warmer")
        let done = await eventually { store.autoSaveStatus == .saved }
        XCTAssertTrue(done)
        XCTAssertEqual(stub.writes, [["apply", "warmer"], ["save"]])
    }

    func testAFailedChangeIsNotSaved() async throws {
        let (store, stub) = try await makeStore(delay: 0.05) { _, args in
            args.first == "zoom" ? CLIResult(status: 1, stderr: "zoom: out of range\n") : nil
        }
        await store.write([("zoom", "999")])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(saves(stub).isEmpty)
        XCTAssertEqual(store.autoSaveStatus, .idle)
    }

    func testAFailedSaveIsReported() async throws {
        let (store, stub) = try await makeStore(delay: 0.05) { _, args in
            args.last == "save" ? CLIResult(status: 1, stderr: "cannot write settings\n") : nil
        }
        await store.write([("zoom", "120")])
        let done = await eventually { store.banner != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(store.banner, "Could not save the settings for auto-apply: cannot write settings")
        XCTAssertEqual(store.autoSaveStatus, .idle)
        XCTAssertEqual(saves(stub).count, 1)
    }

    func testTheSaveGoesToTheCameraThatWasChanged() async throws {
        let (store, stub) = try await makeStore(delay: 0.3, list: "list-four-cameras")
        await store.write([("zoom", "150")])
        await store.selectCamera(store.cameras[2])
        await store.write([("zoom", "160")])
        let done = await eventually { saves(stub).count == 2 && store.autoSaveStatus == .saved }
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub), [["--camera", "1", "save"], ["--camera", "3", "save"]])
    }

    func testSavingByHandSupersedesTheWait() async throws {
        let (store, stub) = try await makeStore(delay: 0.2)
        await store.write([("zoom", "120")])
        let saved = await store.saveCurrent(as: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.autoSaveStatus, .idle)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(saves(stub), [["save"]], "only the explicit save")
    }

    func testSavingUnderANameNeverTouchesTheWait() async throws {
        let (store, stub) = try await makeStore(delay: 0.2)
        await store.write([("zoom", "120")])
        _ = await store.saveCurrent(as: "evening")
        let done = await eventually { store.autoSaveStatus == .saved }
        XCTAssertTrue(done)
        XCTAssertEqual(stub.writes, [["zoom", "120"], ["save", "evening"], ["save"]])
    }

    func testTheAgentRemovedDuringTheWaitStopsTheSave() async throws {
        let (store, stub) = try await makeStore(delay: 0.3)
        var agentInstalled = true
        store.autoSaveEnabled = { _ in agentInstalled }
        await store.write([("zoom", "120")])
        agentInstalled = false
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(saves(stub).isEmpty)
        XCTAssertEqual(store.autoSaveStatus, .idle)
    }

    func testTheNewSettingsFileShowsUpInTheSavedList() async throws {
        let (store, stub) = try await makeStore(delay: 0.05) { _, args in
            args == ["profiles", "--json"]
                ? CLIResult(status: 0, stdout: Data(#"{"presets":[],"saved":[],"dir":"/x"}"#.utf8)) : nil
        }
        XCTAssertEqual(store.profiles?.saved, [])
        await store.write([("zoom", "120")])
        let done = await eventually { store.autoSaveStatus == .saved }
        XCTAssertTrue(done)
        XCTAssertTrue(stub.calls.contains(["profiles", "--json"]), "the list is read again after the first save")
    }
}

/// Which installed agents are fed, with the LaunchAgents of a temporary directory.
@MainActor
final class AutoSaveModelTests: XCTestCase {
    private var root: URL!
    private var agents: URL { root.appendingPathComponent("agents") }
    private let appCLI = "/Applications/brioctl.app/Contents/Resources/brioctl"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brioctl-autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeModel(list: String = "list-one-camera", stub custom: StubRunner? = nil) async throws -> (AppModel, StubRunner) {
        let stub = try custom ?? StubRunner.serving(list: list)
        let suite = "com.github.petrochen.brioctl.app.tests.\(UUID().uuidString)"
        let env = AppEnvironment(processEnvironment: [
            "BRIOCTL_APP_CLI": "/nonexistent/brioctl", "BRIOCTL_APP_AGENTS_DIR": agents.path,
            "BRIOCTL_APP_DEFAULTS_SUITE": suite,
        ], bundle: Bundle(for: AutoSaveModelTests.self), home: root)
        let model = AppModel(environment: env, runner: stub, launchctl: RecordingLaunchctl())
        model.store.autoSaveDelay = 0.1
        await model.store.refresh()
        stub.calls = []
        return (model, stub)
    }

    private func installAgent(_ label: String, arguments: [String]) throws {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true], format: .xml, options: 0)
        try data.write(to: agents.appendingPathComponent("\(label).plist"))
    }

    private func settle(_ model: AppModel) async -> Bool { await eventually { model.store.autoSaveStatus == .saved } }

    func testNothingIsSavedWithoutAnAgent() async throws {
        let (model, stub) = try await makeModel()
        await model.store.write([("zoom", "120")])
        await model.store.apply(profile: "warmer")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(saves(stub).isEmpty)
        XCTAssertEqual(model.store.autoSaveStatus, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path), "the agents directory was not even created")
    }

    func testOtherPlistsInTheDirectoryDoNotCount() async throws {
        try installAgent(AgentLabel.login, arguments: ["/usr/bin/open", "/Applications/brioctl.app"])
        try installAgent("com.example.other", arguments: ["/usr/bin/true"])
        let (model, stub) = try await makeModel()
        await model.store.write([("zoom", "120")])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(saves(stub).isEmpty, "launch at login is not an agent that re-applies settings")
    }

    func testTheAppsOwnAgentIsFed() async throws {
        try installAgent(AgentLabel.watch, arguments: [appCLI, "watch"])
        let (model, stub) = try await makeModel()
        await model.store.write([("zoom", "120")])
        let done = await settle(model)
        XCTAssertTrue(done)
        XCTAssertEqual(stub.writes, [["zoom", "120"], ["save"]])
    }

    func testAnAgentFromMakeAgentIsFed() async throws {
        try installAgent(AgentLabel.watch, arguments: ["/Users/me/bin/brioctl", "watch"])
        let (model, stub) = try await makeModel()
        await model.store.write([("zoom", "120")])
        let done = await settle(model)
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub), [["save"]])
    }

    func testTheHomebrewAgentIsFed() async throws {
        try installAgent(AgentLabel.homebrew, arguments: ["/opt/homebrew/opt/brioctl/bin/brioctl", "watch"])
        let (model, stub) = try await makeModel()
        await model.store.write([("zoom", "120")])
        let done = await settle(model)
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub), [["save"]])
    }

    func testAnUnreadablePlistStillCountsAsAnAgent() async throws {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: agents.appendingPathComponent("\(AgentLabel.watch).plist"))
        let (model, stub) = try await makeModel()
        await model.store.write([("zoom", "120")])
        let done = await settle(model)
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub), [["save"]])
    }

    func testTheAgentIsLookedUpWhenTheChangeIsMade() async throws {
        let (model, stub) = try await makeModel()
        await model.store.write([("zoom", "120")])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(saves(stub).isEmpty)

        try installAgent(AgentLabel.homebrew, arguments: ["/opt/homebrew/opt/brioctl/bin/brioctl", "watch"])
        await model.store.write([("zoom", "130")])
        let done = await settle(model)
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub).count, 1)

        try FileManager.default.removeItem(at: agents.appendingPathComponent("\(AgentLabel.homebrew).plist"))
        stub.calls = []
        await model.store.write([("zoom", "140")])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(saves(stub).isEmpty, "the agent is gone: back to saving by hand")
    }

    func testAnAgentForAnotherCameraIsNotFed() async throws {
        try installAgent(AgentLabel.watch, arguments: [appCLI, "--camera", "2", "watch"])
        let (model, stub) = try await makeModel(list: "list-four-cameras")
        XCTAssertEqual(model.store.selectedCamera?.index, 1)
        await model.store.write([("zoom", "120")])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(saves(stub).isEmpty, "camera 1 is not the one the agent follows; its file stays as it is")

        await model.store.selectCamera(model.store.cameras[1])
        await model.store.write([("zoom", "130")])
        let done = await settle(model)
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub), [["--camera", "2", "save"]])
    }

    func testAnAgentWithoutACameraNeverFollowsAStandardOne() async throws {
        try installAgent(AgentLabel.homebrew, arguments: ["/opt/homebrew/opt/brioctl/bin/brioctl", "watch"])
        let (model, stub) = try await makeModel(list: "list-four-cameras")
        await model.store.selectCamera(model.store.cameras[1])  // Generic UVC, support "standard"
        await model.store.write([("zoom", "120")])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(saves(stub).isEmpty)

        await model.store.selectCamera(model.store.cameras[0])  // MX Brio
        await model.store.write([("zoom", "130")])
        let done = await settle(model)
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub), [["--camera", "1", "save"]])
    }

    func testTheAgentTheAppInstallsFollowsALoneStandardCamera() async throws {
        let json = #"{"cameras":[{"index":1,"vid":"1234","pid":"5678","name":"Generic UVC","model":null,"support":"standard","serial":"ABC123","location":"0x100000"}]}"#
        let base = try StubRunner.serving()
        let stub = StubRunner { args in
            args == ["list", "--json"] ? CLIResult(status: 0, stdout: Data(json.utf8)) : base.answer(args)
        }
        let (model, _) = try await makeModel(stub: stub)
        await model.setAutoApply(true)
        XCTAssertNil(model.settingsError)
        let data = try Data(contentsOf: agents.appendingPathComponent("\(AgentLabel.watch).plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(Array(args.dropFirst()), ["--camera", "ABC123", "watch"], "without --camera it would wait for the MX Brio")

        stub.calls = []
        await model.store.write([("zoom", "120")])
        let done = await settle(model)
        XCTAssertTrue(done)
        XCTAssertEqual(saves(stub), [["save"]], "one camera: no --camera needed for the save")
    }

    func testRememberCurrentSettingsStillWorksWithoutAnAgent() async throws {
        let (model, stub) = try await makeModel()
        await model.rememberCurrentSettings()
        XCTAssertEqual(stub.calls.first, ["save"])
        XCTAssertNil(model.settingsError)
        XCTAssertEqual(model.store.notice, "Saved as the settings to re-apply")
    }
}

final class AutoApplyAgentTests: XCTestCase {
    private func camera(_ index: Int, support: String, serial: String? = nil) -> CameraInfo {
        CameraInfo(index: index, vid: "046d", pid: "0944", name: nil, model: nil, support: support, serial: serial,
                   location: "0x\(index)00000")
    }

    func testTheCameraArgumentOfAnAgent() {
        XCTAssertNil(LaunchAgentManager.cameraArgument(in: ["/x/brioctl", "watch"]))
        XCTAssertEqual(LaunchAgentManager.cameraArgument(in: ["/x/brioctl", "--camera", "SER1", "watch"]), "SER1")
        XCTAssertEqual(LaunchAgentManager.cameraArgument(in: ["/x/brioctl", "--camera=2", "watch"]), "2")
        XCTAssertNil(LaunchAgentManager.cameraArgument(in: ["/x/brioctl", "watch", "--camera"]), "no value")
    }

    func testWhoFollowsWhat() {
        let full = camera(1, support: "full", serial: "AAA"), standard = camera(2, support: "standard", serial: "BBB")
        XCTAssertFalse(AutoApplyAgent.none.follows(full))
        let any = AutoApplyAgent(installed: true, camera: nil)
        XCTAssertTrue(any.follows(full))
        XCTAssertTrue(any.follows(camera(3, support: "experimental")))
        XCTAssertFalse(any.follows(standard))
        XCTAssertFalse(any.follows(nil))
        let chosen = AutoApplyAgent(installed: true, camera: "BBB")
        XCTAssertTrue(chosen.follows(standard))
        XCTAssertFalse(chosen.follows(full))
        XCTAssertTrue(AutoApplyAgent(installed: true, camera: "1").follows(full), "by index")
    }
}

/// The real CLI source against an emulated camera: the settings file really changes.
@MainActor
final class AutoSaveEndToEndTests: XCTestCase {
    private var fake: FakeCLI!

    override func setUpWithError() throws { fake = try FakeCLI() }
    override func tearDownWithError() throws { fake?.cleanUp() }

    private var agents: URL { fake.home.appendingPathComponent("agents") }
    private var settingsFile: URL { fake.home.appendingPathComponent(".config/brioctl/settings") }

    private func makeModel() -> AppModel {
        let suite = "com.github.petrochen.brioctl.app.tests.\(UUID().uuidString)"
        let env = AppEnvironment(processEnvironment: fake.environment.merging([
            "BRIOCTL_APP_CLI": fake.executable.path, "BRIOCTL_APP_AGENTS_DIR": agents.path,
            "BRIOCTL_APP_DEFAULTS_SUITE": suite]) { $1 }, bundle: Bundle(for: AutoSaveEndToEndTests.self), home: fake.home)
        let model = AppModel(environment: env, launchctl: RecordingLaunchctl())
        model.store.autoSaveDelay = 0.1
        return model
    }

    func testChangesFromEveryEntryPointReachTheSettingsFile() async throws {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Label": AgentLabel.homebrew, "ProgramArguments": ["/opt/homebrew/opt/brioctl/bin/brioctl", "watch"]],
            format: .xml, options: 0)
        try plist.write(to: agents.appendingPathComponent("\(AgentLabel.homebrew).plist"))
        let model = makeModel()
        await model.store.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsFile.path))

        await model.store.write([("fov", "65")])
        var done = await eventually { model.store.autoSaveStatus == .saved }
        XCTAssertTrue(done)
        var saved = try String(contentsOf: settingsFile)
        XCTAssertTrue(saved.contains("fov 65"), saved)
        XCTAssertTrue(model.store.profiles?.saved.contains("settings") == true)

        await model.handle(url: URL(string: "brioctl://apply?name=warmer")!)
        done = await eventually { (try? String(contentsOf: settingsFile))?.contains("warmth 60") == true }
        XCTAssertTrue(done)

        await model.handle(hotkey: .zoomIn)
        done = await eventually { (try? String(contentsOf: settingsFile))?.contains("zoom 140") == true }
        saved = (try? String(contentsOf: settingsFile)) ?? "no file"
        XCTAssertTrue(done, saved)
        XCTAssertTrue(saved.contains("fov 65"), "the earlier change is still there")
    }

    func testWithoutAnAgentTheSettingsFileIsLeftAlone() async throws {
        let model = makeModel()
        await model.store.refresh()
        await model.store.write([("fov", "65"), ("zoom", "150")])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsFile.path), "nothing is saved behind the user's back")
        XCTAssertEqual(model.store.autoSaveStatus, .idle)
        let fov = await fake.get("fov")
        XCTAssertEqual(fov, "65", "the change itself went through")

        await model.rememberCurrentSettings()
        let saved = try String(contentsOf: settingsFile)
        XCTAssertTrue(saved.contains("fov 65"), saved)
    }
}
