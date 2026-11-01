import XCTest
@testable import BrioctlCore

final class RecordingLaunchctl: LaunchctlRunning {
    var events: [String] = []
    var bootstrapFails: String?
    var loaded: Set<String> = []

    func bootstrap(plist: URL) throws {
        events.append("bootstrap \(plist.lastPathComponent)")
        if let bootstrapFails { throw LaunchAgentError.launchctl(bootstrapFails) }
        loaded.insert(plist.deletingPathExtension().lastPathComponent)
    }

    func bootout(label: String) {
        events.append("bootout \(label)")
        loaded.remove(label)
    }

    func isLoaded(label: String) -> Bool { loaded.contains(label) }
}

final class LaunchAgentTests: XCTestCase {
    private var dir: URL!
    private var launchctl: RecordingLaunchctl!
    private let cli = "/Applications/brioctl.app/Contents/Resources/brioctl"
    private let app = "/Applications/brioctl.app"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("brioctl-agents-\(UUID().uuidString)")
        launchctl = RecordingLaunchctl()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func manager(cli: String? = nil, app: String? = nil) -> LaunchAgentManager {
        LaunchAgentManager(directory: dir, launchctl: launchctl, cliPath: cli ?? self.cli, appPath: app ?? self.app,
                           logPath: "/Users/example/Library/Logs/brioctl.log")
    }

    private func write(_ label: String, program: String?, args: [String] = ["watch"]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var plist: [String: Any] = ["Label": label, "RunAtLoad": true]
        if let program { plist["ProgramArguments"] = [program] + args }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("\(label).plist"))
    }

    private func contents(_ label: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent("\(label).plist")) }

    // MARK: plists

    func testWatchPlistRunsTheBundledCLI() throws {
        let plist = try PropertyListSerialization.propertyList(from: manager().watchPlist(camera: nil), format: nil)
            as! [String: Any]
        XCTAssertEqual(plist["Label"] as? String, "com.github.petrochen.brioctl")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [cli, "watch"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["StandardOutPath"] as? String, "/Users/example/Library/Logs/brioctl.log")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/Users/example/Library/Logs/brioctl.log")

        let two = try PropertyListSerialization.propertyList(from: manager().watchPlist(camera: "ABC123"), format: nil)
            as! [String: Any]
        XCTAssertEqual(two["ProgramArguments"] as? [String], [cli, "--camera", "ABC123", "watch"])
    }

    func testLoginPlistOpensTheApp() throws {
        let plist = try PropertyListSerialization.propertyList(from: manager().loginPlist(), format: nil) as! [String: Any]
        XCTAssertEqual(plist["Label"] as? String, "com.github.petrochen.brioctl.app")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", app])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertNil(plist["KeepAlive"], "it only opens the app once")
    }

    // MARK: auto-apply

    func testInstallAndRemoveInATempDirectory() throws {
        let m = manager()
        XCTAssertEqual(m.watchState(), .off)
        try m.installWatch(camera: nil)
        XCTAssertEqual(m.watchState(), .app(usesThisCopy: true))
        XCTAssertTrue(m.watchIsRunning())
        XCTAssertEqual(launchctl.events, ["bootout com.github.petrochen.brioctl", "bootstrap com.github.petrochen.brioctl.plist"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("com.github.petrochen.brioctl.plist").path))

        try m.installWatch(camera: "2")  // installing again replaces our own agent
        XCTAssertEqual(m.watchState(), .app(usesThisCopy: true))

        launchctl.events = []
        try m.removeWatch()
        XCTAssertEqual(m.watchState(), .off)
        XCTAssertEqual(launchctl.events, ["bootout com.github.petrochen.brioctl"])
        XCTAssertNil(contents(AgentLabel.watch))
        XCTAssertFalse(m.watchIsRunning())
        XCTAssertNoThrow(try m.removeWatch(), "removing what is not there is fine")
    }

    func testAgentOfAnotherCopyOfTheAppIsOurs() throws {
        try write(AgentLabel.watch, program: "/Users/me/Downloads/brioctl.app/Contents/Resources/brioctl")
        XCTAssertEqual(manager().watchState(), .app(usesThisCopy: false))
        try manager().installWatch(camera: nil)  // rewritten for this copy
        XCTAssertEqual(manager().watchState(), .app(usesThisCopy: true))
    }

    func testAPlistThatRunsAnotherProgramIsNeverTouched() throws {
        try write(AgentLabel.watch, program: "/Users/me/bin/brioctl")
        let before = try XCTUnwrap(contents(AgentLabel.watch))
        let m = manager()
        XCTAssertEqual(m.watchState(), .other(.makeAgent(program: "/Users/me/bin/brioctl")))
        XCTAssertThrowsError(try m.installWatch(camera: nil)) { XCTAssertEqual($0 as? LaunchAgentError, .foreignAgent) }
        XCTAssertThrowsError(try m.removeWatch()) { XCTAssertEqual($0 as? LaunchAgentError, .foreignAgent) }
        XCTAssertEqual(contents(AgentLabel.watch), before)
        XCTAssertEqual(launchctl.events, [], "launchctl was not even asked")
    }

    func testHomebrewAgentIsLeftAlone() throws {
        try write(AgentLabel.homebrew, program: "/opt/homebrew/opt/brioctl/bin/brioctl")
        let m = manager()
        XCTAssertEqual(m.watchState(), .other(.homebrew))
        XCTAssertThrowsError(try m.installWatch(camera: nil))
        XCTAssertThrowsError(try m.removeWatch())
        XCTAssertNil(contents(AgentLabel.watch), "no second agent next to Homebrew's")
        XCTAssertNotNil(contents(AgentLabel.homebrew))
        XCTAssertEqual(launchctl.events, [])
    }

    func testAnUnreadablePlistIsForeign() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = Data("not a plist".utf8)
        try garbage.write(to: dir.appendingPathComponent("com.github.petrochen.brioctl.plist"))
        let m = manager()
        XCTAssertEqual(m.watchState(), .other(.unreadable))
        XCTAssertThrowsError(try m.removeWatch())
        XCTAssertThrowsError(try m.installWatch(camera: nil))
        XCTAssertEqual(contents(AgentLabel.watch), garbage)
    }

    func testFailedBootstrapLeavesNothingBehind() throws {
        launchctl.bootstrapFails = "Bootstrap failed: 5: Input/output error"
        let m = manager()
        XCTAssertThrowsError(try m.installWatch(camera: nil)) {
            XCTAssertEqual($0 as? LaunchAgentError, .launchctl("Bootstrap failed: 5: Input/output error"))
        }
        XCTAssertNil(contents(AgentLabel.watch))
        XCTAssertEqual(m.watchState(), .off)

        // and an older agent of ours comes back as it was
        launchctl.bootstrapFails = nil
        try m.installWatch(camera: nil)
        let old = try XCTUnwrap(contents(AgentLabel.watch))
        launchctl.bootstrapFails = "boom"
        XCTAssertThrowsError(try m.installWatch(camera: "2"))
        XCTAssertEqual(contents(AgentLabel.watch), old)
    }

    // MARK: launch at login

    func testLaunchAtLoginWritesOnlyItsOwnPlist() throws {
        let m = manager()
        XCTAssertFalse(m.loginItemEnabled())
        try m.setLoginItem(enabled: true)
        XCTAssertTrue(m.loginItemEnabled())
        XCTAssertNotNil(contents(AgentLabel.login))
        XCTAssertEqual(launchctl.events, [], "launchd reads it at the next login; nothing is loaded now")
        try m.setLoginItem(enabled: false)
        XCTAssertFalse(m.loginItemEnabled())
        XCTAssertNoThrow(try m.setLoginItem(enabled: false))
    }

    func testLaunchAtLoginNeedsAnAppBundle() throws {
        let m = manager(app: "/Users/me/src/brioctl/app/.build/debug")
        XCTAssertThrowsError(try m.setLoginItem(enabled: true)) { XCTAssertEqual($0 as? LaunchAgentError, .notInAppBundle) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testTheEnvironmentRedirectsEverything() {
        let env = AppEnvironment(processEnvironment: [
            "BRIOCTL_APP_CLI": "/tmp/fake/brioctl-fake", "BRIOCTL_APP_AGENTS_DIR": "/tmp/agents",
            "BRIOCTL_APP_DEFAULTS_SUITE": "com.example.brioctl-test", "BRIOCTL_FAKE": "/tmp/x.snap",
        ], bundle: Bundle(for: LaunchAgentTests.self), home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(env.cliURL?.path, "/tmp/fake/brioctl-fake")
        XCTAssertTrue(env.usesCLIOverride)
        XCTAssertEqual(env.agentsDirectory.path, "/tmp/agents")
        XCTAssertEqual(env.logPath, "/Users/example/Library/Logs/brioctl.log")
        XCTAssertEqual(env.processEnvironment["BRIOCTL_FAKE"], "/tmp/x.snap", "the CLI inherits it")
        env.defaults.removePersistentDomain(forName: "com.example.brioctl-test")

        let plain = AppEnvironment(processEnvironment: [:], bundle: Bundle(for: LaunchAgentTests.self),
                                   home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertFalse(plain.usesCLIOverride)
        XCTAssertEqual(plain.agentsDirectory.path, "/Users/example/Library/LaunchAgents")
        XCTAssertEqual(plain.cliURL?.lastPathComponent, "brioctl")
    }
}
