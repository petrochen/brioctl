import XCTest
@testable import BrioctlCore

private func makeDefaults() -> UserDefaults {
    let suite = "com.github.petrochen.brioctl.app.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

@MainActor
final class StoreWithStubTests: XCTestCase {
    func testRefreshReadsListStateProfilesAndVersion() async throws {
        let stub = try StubRunner.serving()
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        XCTAssertEqual(stub.calls, [["list", "--json"], ["--json"], ["profiles", "--json"], ["--version"]])
        XCTAssertEqual(store.cameras.count, 1)
        XCTAssertEqual(store.state?.device.displayName, "MX Brio")
        XCTAssertEqual(store.profiles?.saved, ["desk", "settings"])
        XCTAssertEqual(store.cliVersion, "1.1.0")
        XCTAssertNil(store.banner)
        XCTAssertNil(store.cameraArgument, "one camera: no --camera")
    }

    func testSeveralCamerasUseTheCameraArgument() async throws {
        let stub = try StubRunner.serving(list: "list-four-cameras")
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        XCTAssertEqual(store.cameras.count, 4)
        XCTAssertEqual(store.selectedCamera?.index, 1)
        XCTAssertEqual(store.cameraArgument, "1")
        XCTAssertEqual(stub.calls[1], ["--camera", "1", "--json"])

        await store.selectCamera(store.cameras[2])
        XCTAssertEqual(stub.calls.last, ["--camera", "3", "--json"])
        await store.write([("zoom", "150"), ("pan", "5")])
        XCTAssertEqual(stub.writes.last, ["--camera", "3", "zoom", "150", "pan", "5"])
    }

    func testTheChosenCameraIsRememberedAndFoundAgain() async throws {
        let defaults = makeDefaults()
        let first = CameraStore(runner: try StubRunner.serving(list: "list-four-cameras"), defaults: defaults)
        await first.refresh()
        await first.selectCamera(first.cameras[1])
        let second = CameraStore(runner: try StubRunner.serving(list: "list-four-cameras"), defaults: defaults)
        await second.refresh()
        XCTAssertEqual(second.selectedCamera?.index, 2)
    }

    func testNoCameraAndBrokenCLI() async throws {
        let none = StubRunner { _ in CLIResult(status: 0, stdout: Data(#"{"cameras":[]}"#.utf8)) }
        let store = CameraStore(runner: none, defaults: makeDefaults())
        await store.refresh()
        XCTAssertTrue(store.cameras.isEmpty)
        XCTAssertNil(store.state)
        XCTAssertNil(store.banner)

        let broken = StubRunner { _ in CLIResult(status: -1, failure: "cannot start /x/brioctl: no such file") }
        let store2 = CameraStore(runner: broken, defaults: makeDefaults())
        await store2.refresh()
        XCTAssertEqual(store2.banner, "cannot start /x/brioctl: no such file")

        let garbage = StubRunner { _ in CLIResult(status: 0, stdout: Data("hello".utf8)) }
        let store3 = CameraStore(runner: garbage, defaults: makeDefaults())
        await store3.refresh()
        XCTAssertNotNil(store3.banner)
    }

    func testAStateWithAnUnreadableControlIsStillShown() async throws {
        let list = try Fixture.data("list-one-camera"), state = try Fixture.data("state-mxbrio")
        let stub = StubRunner { args in
            if args == ["list", "--json"] { return CLIResult(status: 0, stdout: list) }
            if args == ["--json"] { return CLIResult(status: 1, stdout: state, stderr: "zoom: could not read\n") }
            return CLIResult(status: 0)
        }
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        XCTAssertNotNil(store.state)
        XCTAssertNil(store.banner)
    }

    func testSlidersWaitForThePauseAndWriteTheLastValueOnce() async throws {
        let stub = try StubRunner.serving()
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        stub.calls = []
        for v in [120.0, 130, 140] {
            store.change("zoom", to: SettingValue.format(v), shown: .number(v), delay: 1)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(store.pending["zoom"], .number(140), "the slider shows what the user did meanwhile")
        XCTAssertTrue(stub.writes.isEmpty, "nothing is written while the slider moves")
        let done = await eventually { store.pending.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(stub.writes, [["zoom", "140"]])
        XCTAssertEqual(stub.calls.last, ["--json"], "the view is read again after the write")
    }

    func testReleasingTheSliderWritesAtOnce() async throws {
        let stub = try StubRunner.serving()
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        stub.calls = []
        store.change("warmth", to: "70", shown: .number(70), delay: 5)
        await store.flush("warmth")
        XCTAssertEqual(stub.writes, [["warmth", "70"]])
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testChoicesWriteWithoutWaiting() async throws {
        let stub = try StubRunner.serving()
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        stub.calls = []
        store.change("fov", to: "65", shown: .text("65"))
        let done = await eventually { !stub.writes.isEmpty && store.pending.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(stub.writes, [["fov", "65"]])
    }

    func testAFailedWriteIsShownUnderTheSetting() async throws {
        let list = try Fixture.data("list-one-camera"), state = try Fixture.data("state-mxbrio")
        let stub = StubRunner { args in
            if args == ["list", "--json"] { return CLIResult(status: 0, stdout: list) }
            if args.last == "--json" { return CLIResult(status: 0, stdout: state) }
            if args.first == "exposure" { return CLIResult(status: 1, stderr: "exposure: set automatically right now (...)\n") }
            if args.first == "fov" { return CLIResult(status: 1, stderr: "something else went wrong\n") }
            return CLIResult(status: 0, stdout: Data("{\"presets\":[],\"saved\":[]}".utf8))
        }
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        let ok = await store.write([("exposure", "100")])
        XCTAssertFalse(ok)
        XCTAssertEqual(store.errors["exposure"], "set automatically right now (...)")
        XCTAssertNil(store.banner)
        XCTAssertNil(store.pending["exposure"])

        await store.write([("fov", "65")])
        XCTAssertNil(store.errors["fov"])
        XCTAssertEqual(store.banner, "something else went wrong")

        // a new change of the same setting clears its error
        store.change("exposure", to: "120", shown: .number(120), delay: 5)
        XCTAssertNil(store.errors["exposure"])
    }

    func testTheMicToggleAsksFirst() async throws {
        let stub = try StubRunner.serving()
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        stub.calls = []
        var asked: [String] = []
        store.confirm = { title, text, button in
            asked.append(title + "|" + button)
            XCTAssertTrue(text.contains("restarts"))
            return false
        }
        store.changeMic(to: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(asked, ["Turn the camera microphone off?|Turn off"])
        XCTAssertTrue(stub.calls.isEmpty, "declined: nothing is written")
        XCTAssertTrue(store.pending.isEmpty)

        store.confirm = { _, _, _ in true }
        store.changeMic(to: false)
        let done = await eventually { !stub.writes.isEmpty && store.pending.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(stub.writes, [["mic", "off"]])
    }

    func testApplyAndSaveCallTheCLI() async throws {
        let stub = try StubRunner.serving()
        let store = CameraStore(runner: stub, defaults: makeDefaults())
        await store.refresh()
        stub.calls = []
        await store.apply(profile: "warmer")
        XCTAssertEqual(stub.calls, [["apply", "warmer"], ["--json"]])
        stub.calls = []
        let saved = await store.saveCurrent(as: " evening ")
        XCTAssertTrue(saved)
        XCTAssertEqual(stub.calls.first, ["save", "evening"])
        stub.calls = []
        let bad = await store.saveCurrent(as: "warmer")
        XCTAssertFalse(bad)
        XCTAssertTrue(stub.calls.isEmpty, "a preset name is refused before brioctl is asked")
        XCTAssertNotNil(store.banner)
        stub.calls = []
        _ = await store.saveCurrent(as: nil)
        XCTAssertEqual(stub.calls.first, ["save"])
    }

    func testCollapsedSectionsArePersisted() {
        let defaults = makeDefaults()
        let store = CameraStore(runner: StubRunner(), defaults: defaults)
        XCTAssertEqual(store.collapsed, ["Exposure and image", "Found in the firmware"])
        store.collapsed.remove("Exposure and image")
        XCTAssertEqual(CameraStore(runner: StubRunner(), defaults: defaults).collapsed, ["Found in the firmware"])
    }
}

/// The real CLI source against an emulated camera.
@MainActor
final class EndToEndWithFakeCLITests: XCTestCase {
    private var fake: FakeCLI!

    override func setUpWithError() throws { fake = try FakeCLI() }
    override func tearDownWithError() throws { fake?.cleanUp() }

    private func makeModel(launchctl: LaunchctlRunning = RecordingLaunchctl(), agents: URL? = nil) -> AppModel {
        let suite = "com.github.petrochen.brioctl.app.tests.\(UUID().uuidString)"
        let env = AppEnvironment(processEnvironment: fake.environment.merging([
            "BRIOCTL_APP_CLI": fake.executable.path,
            "BRIOCTL_APP_AGENTS_DIR": (agents ?? fake.home.appendingPathComponent("agents")).path,
            "BRIOCTL_APP_DEFAULTS_SUITE": suite,
        ]) { $1 }, bundle: Bundle(for: EndToEndWithFakeCLITests.self), home: fake.home)
        return AppModel(environment: env, launchctl: launchctl)
    }

    func testReadsTheEmulatedCamera() async throws {
        let model = makeModel()
        await model.store.refresh()
        let state = try XCTUnwrap(model.store.state)
        XCTAssertEqual(state.device.displayName, "MX Brio")
        XCTAssertEqual(state.setting("fov")?.value, .text("78"))
        XCTAssertEqual(state.sections.map(\.group), CameraState.groupOrder)
        XCTAssertEqual(model.store.cliVersion?.isEmpty, false)
        XCTAssertEqual(model.store.profiles?.presets.count, 7)
        XCTAssertEqual(model.store.profiles?.dir, fake.home.path + "/.config/brioctl")
    }

    func testChangesReachTheCamera() async throws {
        let model = makeModel()
        await model.store.refresh()
        await model.store.write([("fov", "65"), ("zoom", "150")])
        let fov = await fake.get("fov"), zoom = await fake.get("zoom")
        XCTAssertEqual([fov, zoom], ["65", "150"])
        XCTAssertEqual(model.store.state?.setting("fov")?.value, .text("65"))
        XCTAssertEqual(model.store.state?.setting("zoom")?.value, .number(150))
    }

    func testARefusedValueComesBackAsAnInlineError() async throws {
        let model = makeModel()
        await model.store.refresh()
        await model.store.write([("fov", "55")])
        XCTAssertTrue(model.store.errors["fov"]?.hasPrefix("bad value 55") == true, model.store.errors["fov"] ?? "no error")
        XCTAssertEqual(model.store.state?.setting("fov")?.value, .text("78"), "the camera still has its value")
        await model.store.write([("exposure", "100")])
        XCTAssertTrue(model.store.errors["exposure"]?.contains("set automatically") == true)
    }

    func testMicGainAndPresetsAndSavedFiles() async throws {
        let model = makeModel()
        await model.store.refresh()
        await model.store.write([("micgain", "0.5")])
        XCTAssertEqual(model.store.state?.micgain, 0.5)
        await model.store.apply(profile: "warmer")
        let warmth = await fake.get("warmth")
        XCTAssertEqual(warmth, "60")
        let saved = await model.store.saveCurrent(as: "evening")
        XCTAssertTrue(saved)
        XCTAssertEqual(model.store.profiles?.saved, ["evening"])
        await model.store.write([("warmth", "30")])
        await model.store.apply(profile: "evening")
        let again = await fake.get("warmth")
        XCTAssertEqual(again, "60")
    }

    func testURLCommandsAgainstTheEmulatedCamera() async throws {
        let model = makeModel()
        await model.handle(url: URL(string: "brioctl://set?fov=65&zoom=115&bogus=1")!)
        let fov = await fake.get("fov"), zoom = await fake.get("zoom")
        XCTAssertEqual([fov, zoom], ["65", "115"])
        XCTAssertNil(model.store.banner, "the unknown key was ignored, not reported to brioctl")

        await model.handle(url: URL(string: "brioctl://apply?name=cooler")!)
        let cooler = await fake.get("warmth")
        XCTAssertEqual(cooler, "40")

        await model.handle(url: URL(string: "brioctl://apply?name=../../etc/hosts")!)
        XCTAssertNotNil(model.store.banner)
        await model.handle(url: URL(string: "brioctl://factory-reset")!)
        XCTAssertEqual(model.store.banner, "Ignored the URL: unknown action \u{201C}factory-reset\u{201D} (use set, apply or camera)")
        let unchanged = await fake.get("fov")
        XCTAssertEqual(unchanged, "65")
    }

    func testHotkeysAgainstTheEmulatedCamera() async throws {
        let model = makeModel()
        await model.handle(hotkey: .fov90)
        var fov = await fake.get("fov")
        XCTAssertEqual(fov, "90")
        await model.handle(hotkey: .zoomReset)
        var zoom = await fake.get("zoom")
        XCTAssertEqual(zoom, "100")
        await model.handle(hotkey: .zoomIn)
        zoom = await fake.get("zoom")
        XCTAssertEqual(zoom, "125")
        await model.handle(hotkey: .zoomIn)
        await model.handle(hotkey: .zoomOut)
        zoom = await fake.get("zoom")
        XCTAssertEqual(zoom, "125")
        await model.handle(hotkey: .fov65)
        fov = await fake.get("fov")
        XCTAssertEqual(fov, "65")
    }

    func testSeveralCamerasAndChoosingOneByURL() async throws {
        fake.cleanUp()
        fake = try FakeCLI(snapshots: ["mxbrio-1.1.394.snap", "generic-uvc.snap", "brio500-sim.snap"])
        let model = makeModel()
        await model.store.refresh()
        XCTAssertEqual(model.store.cameras.map(\.displayName), ["MX Brio", "Generic UVC", "Brio 500"])
        XCTAssertEqual(model.store.selectedCamera?.index, 1)

        await model.handle(url: URL(string: "brioctl://camera?id=2")!)
        XCTAssertEqual(model.store.selectedCamera?.displayName, "Generic UVC")
        XCTAssertNil(model.store.state?.setting("fov"))
        // fov does not exist on camera 2: ignored. zoom is written to camera 2 only.
        await model.handle(url: URL(string: "brioctl://set?fov=65&zoom=200")!)
        let zoom2 = await fake.get("zoom", camera: "2"), zoom1 = await fake.get("zoom", camera: "1")
        XCTAssertEqual(zoom2, "200")
        XCTAssertEqual(zoom1, "115")
        let fov1 = await fake.get("fov", camera: "1")
        XCTAssertEqual(fov1, "78")

        await model.handle(url: URL(string: "brioctl://camera?id=9")!)
        XCTAssertNotNil(model.store.banner)
        XCTAssertEqual(model.store.selectedCamera?.index, 2)
    }

    func testHotkeysAreOffByDefaultAndRemembered() throws {
        let suite = "com.github.petrochen.brioctl.app.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        func model() -> AppModel {
            AppModel(environment: AppEnvironment(processEnvironment: fake.environment.merging([
                "BRIOCTL_APP_CLI": fake.executable.path, "BRIOCTL_APP_DEFAULTS_SUITE": suite,
                "BRIOCTL_APP_AGENTS_DIR": fake.home.appendingPathComponent("agents").path]) { $1 },
                bundle: Bundle(for: EndToEndWithFakeCLITests.self), home: fake.home), launchctl: RecordingLaunchctl())
        }
        let first = model()
        XCTAssertFalse(first.hotkeysEnabled)
        first.hotkeysEnabled = true
        XCTAssertTrue(model().hotkeysEnabled, "remembered")
        first.hotkeysEnabled = false  // unregisters the keys again
        XCTAssertFalse(model().hotkeysEnabled)
        XCTAssertNil(first.hotkeyProblem)
    }

    func testAutoApplyUsesTheInjectedDirectoryOnly() async throws {
        let launchctl = RecordingLaunchctl()
        let agents = fake.home.appendingPathComponent("agents")
        let model = makeModel(launchctl: launchctl, agents: agents)
        await model.store.refresh()
        model.refreshAgents()
        XCTAssertEqual(model.watchState, .off)

        await model.setAutoApply(true)
        XCTAssertNil(model.settingsError)
        XCTAssertEqual(model.watchState, .app(usesThisCopy: true))
        let saved = try String(contentsOf: fake.home.appendingPathComponent(".config/brioctl/settings"))
        XCTAssertTrue(saved.contains("fov 78"), "the current settings were saved first")
        let plist = try Data(contentsOf: agents.appendingPathComponent("com.github.petrochen.brioctl.plist"))
        let args = (try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any])["ProgramArguments"] as! [String]
        XCTAssertEqual(args, [fake.executable.path, "watch"])
        XCTAssertEqual(launchctl.events.last, "bootstrap com.github.petrochen.brioctl.plist")

        await model.setAutoApply(false)
        XCTAssertEqual(model.watchState, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.appendingPathComponent("com.github.petrochen.brioctl.plist").path))
    }

    func testAForeignAgentStaysAndTheAppSaysSo() async throws {
        let agents = fake.home.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("com.github.petrochen.brioctl.plist")
        let foreign = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.github.petrochen.brioctl", "ProgramArguments": ["/Users/me/bin/brioctl", "watch"]],
            format: .xml, options: 0)
        try foreign.write(to: plist)
        let launchctl = RecordingLaunchctl()
        let model = makeModel(launchctl: launchctl, agents: agents)
        await model.store.refresh()
        model.refreshAgents()
        XCTAssertEqual(model.watchState, .other(.makeAgent(program: "/Users/me/bin/brioctl")))
        await model.setAutoApply(true)
        XCTAssertNotNil(model.settingsError)
        await model.setAutoApply(false)
        XCTAssertEqual(try Data(contentsOf: plist), foreign)
        XCTAssertEqual(launchctl.events, [])
    }
}
