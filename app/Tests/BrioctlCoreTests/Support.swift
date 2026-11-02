import Foundation
import XCTest
@testable import BrioctlCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(name).json is missing")
        }
        return try Data(contentsOf: url)
    }

    static func state(_ name: String) throws -> CameraState { try CameraState.decode(try data(name)) }
    static func cameras(_ name: String) throws -> [CameraInfo] { try CameraInfo.decodeList(try data(name)) }
    static func profiles() throws -> Profiles { try Profiles.decode(try data("profiles")) }
}

/// A scripted CLI: records every call and answers from a closure.
///
/// `run` is nonisolated and async, so a debounced save of the store appends to `calls` from a pool thread while the test
/// reads `writes` on another one. Every access to the mutable state goes through `lock`; `answer` is copied out before it
/// is called, so a closure may use the stub (or another one) without deadlocking.
final class StubRunner: CLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var responder: ([String]) -> CLIResult

    init(_ answer: @escaping ([String]) -> CLIResult = { _ in CLIResult(status: 0) }) { responder = answer }

    var calls: [[String]] {
        get { lock.withLock { recorded } }
        set { lock.withLock { recorded = newValue } }
    }

    var answer: ([String]) -> CLIResult {
        get { lock.withLock { responder } }
        set { lock.withLock { responder = newValue } }
    }

    func run(_ arguments: [String]) async -> CLIResult {
        let respond = lock.withLock { () -> ([String]) -> CLIResult in
            recorded.append(arguments)
            return responder
        }
        return respond(arguments)
    }

    var writes: [[String]] {
        calls.filter { c in !c.contains("--json") && !c.contains("--version") && c != ["list", "--json"] }
    }

    /// The usual answers: the fixtures for the reads, success for everything else.
    static func serving(list: String = "list-one-camera", state: String = "state-mxbrio") throws -> StubRunner {
        let list = try Fixture.data(list), state = try Fixture.data(state), profiles = try Fixture.data("profiles")
        return StubRunner { args in
            if args == ["list", "--json"] { return CLIResult(status: 0, stdout: list) }
            if args == ["profiles", "--json"] { return CLIResult(status: 0, stdout: profiles) }
            if args == ["--version"] { return CLIResult(status: 0, stdout: Data("brioctl 1.1.0\n".utf8)) }
            if args.last == "--json" { return CLIResult(status: 0, stdout: state) }
            return CLIResult(status: 0)
        }
    }
}

/// The real CLI source built with -DBRIOCTL_FAKE (tests/brioctl-fake): a camera read from a snapshot, no USB.
/// Nothing in the tests may run the real brioctl.
struct FakeCLI {
    let executable: URL
    let home: URL
    let snapshots: [URL]
    let environment: [String: String]

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// - Parameter snapshots: names of files in the repository's tests/ directory
    init(snapshots names: [String] = ["mxbrio-1.1.394.snap"]) throws {
        let exe = Self.root.appendingPathComponent("tests/brioctl-fake")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw XCTSkip("build it first: make -C \(Self.root.path) tests/brioctl-fake")
        }
        // Only the fake build says this when BRIOCTL_FAKE is not set.
        let probe = Process()
        probe.executableURL = exe
        probe.arguments = ["show"]
        probe.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = pipe
        try probe.run()
        let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        guard said.contains("BRIOCTL_FAKE is not set") else {
            throw XCTSkip("\(exe.path) is not the fake build; refusing to run it")
        }
        executable = exe
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brioctl-app-test-\(UUID().uuidString)")
        home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var copies: [URL] = []
        for (i, name) in names.enumerated() {
            let copy = dir.appendingPathComponent("camera\(i + 1).snap")
            try FileManager.default.copyItem(at: Self.root.appendingPathComponent("tests/\(name)"), to: copy)
            copies.append(copy)
        }
        snapshots = copies
        environment = ["BRIOCTL_FAKE": copies.map(\.path).joined(separator: ":"), "HOME": home.path,
                       "PATH": "/usr/bin:/bin"]
    }

    var runner: ProcessCLIRunner { ProcessCLIRunner(executable: executable, environment: environment) }

    func cleanUp() { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

    /// brioctl get NAME, straight from the fake.
    func get(_ name: String, camera: String? = nil) async -> String {
        let r = await runner.run((camera.map { ["--camera", $0] } ?? []) + ["get", name])
        return r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func eventually(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

func pairs(_ p: [(name: String, value: String)]) -> [String] { p.map { "\($0.name)=\($0.value)" } }
