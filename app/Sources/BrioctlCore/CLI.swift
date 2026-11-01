import Foundation

/// Builds the argument arrays of the bundled brioctl. Nothing here runs anything. No shell is involved anywhere, so a
/// value is one argument whatever characters it has.
public enum CLIArguments {
    /// `--camera ID` goes first when a camera is chosen.
    private static func prefix(_ camera: String?) -> [String] {
        guard let camera, !camera.isEmpty else { return [] }
        return ["--camera", camera]
    }

    public static func list() -> [String] { ["list", "--json"] }

    public static func state(camera: String?) -> [String] { prefix(camera) + ["--json"] }

    public static func profiles() -> [String] { ["profiles", "--json"] }

    public static func version() -> [String] { ["--version"] }

    /// `brioctl [--camera ID] NAME VALUE [NAME VALUE ...]`
    public static func set(camera: String?, _ pairs: [(name: String, value: String)]) -> [String] {
        prefix(camera) + pairs.flatMap { [$0.name, $0.value] }
    }

    /// `brioctl [--camera ID] save [NAME]`
    public static func save(camera: String?, name: String? = nil) -> [String] {
        prefix(camera) + ["save"] + (name.map { [$0] } ?? [])
    }

    /// `brioctl [--camera ID] apply NAME|PRESET`
    public static func apply(camera: String?, name: String) -> [String] { prefix(camera) + ["apply", name] }
}

public struct CLIResult: Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    /// Set when the program could not be started or was killed after the timeout.
    public var failure: String?

    public init(status: Int32, stdout: Data = Data(), stderr: String = "", failure: String? = nil) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.failure = failure
    }

    public var ok: Bool { status == 0 && failure == nil }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }

    /// A line for the user: what the CLI said on stderr, else on stdout, else the exit status.
    public var message: String {
        if let failure { return failure }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty, status != 0 { return out }
        return "brioctl exited with status \(status)"
    }
}

public protocol CLIRunning: AnyObject {
    func run(_ arguments: [String]) async -> CLIResult
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Runs the CLI one command at a time (two commands must never talk to the camera together).
public final class ProcessCLIRunner: CLIRunning, @unchecked Sendable {
    public let executable: URL
    public let environment: [String: String]
    public let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.github.petrochen.brioctl.app.cli")

    public init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                timeout: TimeInterval = 20) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    public func run(_ arguments: [String]) async -> CLIResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.runBlocking(arguments)) }
        }
    }

    func runBlocking(_ arguments: [String]) -> CLIResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return CLIResult(status: -1, failure: "cannot start \(executable.path): \(error.localizedDescription)")
        }
        // Read both pipes while the process runs, or a full pipe would stop it.
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outBox.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        group.wait()
        let status = process.isRunning ? -1 : process.terminationStatus
        return CLIResult(status: status, stdout: outBox.data, stderr: String(decoding: errBox.data, as: UTF8.self),
                         failure: timedOut ? "brioctl did not answer within \(Int(timeout)) s" : nil)
    }
}

/// Splits the stderr of a write into lines for the settings they name ("fov: bad value 55 (...)") and the rest.
public enum CLIErrors {
    public static func attribute(_ stderr: String, names: [String]) -> (perSetting: [String: String], other: [String]) {
        var per: [String: String] = [:]
        var other: [String] = []
        for raw in stderr.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":"), names.contains(String(line[..<colon])) {
                let name = String(line[..<colon])
                let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                per[name] = per[name].map { $0 + "; " + text } ?? text
            } else {
                other.append(line)
            }
        }
        return (per, other)
    }
}
