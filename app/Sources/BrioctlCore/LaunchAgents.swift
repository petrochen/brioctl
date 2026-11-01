import Foundation

public enum AgentLabel {
    /// The `brioctl watch` agent: the same label as `make agent` in the repository.
    public static let watch = "com.github.petrochen.brioctl"
    /// The agent of the Homebrew formula (`brew services`).
    public static let homebrew = "homebrew.mxcl.brioctl"
    /// This app, started at login.
    public static let login = "com.github.petrochen.brioctl.app"
}

public enum LaunchAgentError: Error, CustomStringConvertible, Equatable {
    case foreignAgent
    case notInAppBundle
    case launchctl(String)
    case io(String)

    public var description: String {
        switch self {
        case .foreignAgent: return "The agent was installed by make agent or Homebrew; remove it there."
        case .notInAppBundle: return "Only the packaged app (brioctl.app) can start itself at login."
        case .launchctl(let m): return "launchctl: \(m)"
        case .io(let m): return m
        }
    }
}

/// What `launchctl` is asked to do. Tests use a recording stand-in; nothing in the tests may reach the real launchd.
public protocol LaunchctlRunning {
    func bootstrap(plist: URL) throws
    /// Unloads the job; a job that is not loaded is not an error.
    func bootout(label: String)
    func isLoaded(label: String) -> Bool
}

public struct SystemLaunchctl: LaunchctlRunning {
    public init() {}

    private var domain: String { "gui/\(getuid())" }

    @discardableResult
    private func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func bootstrap(plist: URL) throws {
        let r = launchctl(["bootstrap", domain, plist.path])
        if r.status != 0 { throw LaunchAgentError.launchctl(r.output.isEmpty ? "exit \(r.status)" : r.output) }
    }

    public func bootout(label: String) { launchctl(["bootout", "\(domain)/\(label)"]) }

    public func isLoaded(label: String) -> Bool { launchctl(["print", "\(domain)/\(label)"]).status == 0 }
}

public enum WatchAgentState: Equatable {
    /// Nothing installed.
    case off
    /// Installed by this app. `usesThisCopy` is false when the plist runs the CLI of another copy of the app.
    case app(usesThisCopy: Bool)
    /// Installed by `make agent` (another program, same label), by Homebrew, or a plist that cannot be read: not ours,
    /// never changed or removed by the app.
    case other(OtherSource)

    public enum OtherSource: Equatable {
        case makeAgent(program: String)
        case homebrew
        case unreadable
    }
}

public final class LaunchAgentManager {
    public let directory: URL
    private let launchctl: LaunchctlRunning
    /// The brioctl the agent will run: Contents/Resources/brioctl of this app.
    public let cliPath: String
    public let appPath: String
    public let logPath: String
    private let fm = FileManager.default

    public init(directory: URL, launchctl: LaunchctlRunning, cliPath: String, appPath: String, logPath: String) {
        self.directory = directory
        self.launchctl = launchctl
        self.cliPath = cliPath
        self.appPath = appPath
        self.logPath = logPath
    }

    public func plistURL(_ label: String) -> URL { directory.appendingPathComponent("\(label).plist") }

    // MARK: plist contents

    public func watchPlist(camera: String?) -> Data {
        var args = [cliPath]
        if let camera, !camera.isEmpty { args += ["--camera", camera] }
        args.append("watch")
        return Self.serialize([
            "Label": AgentLabel.watch,
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ])
    }

    public func loginPlist() -> Data {
        Self.serialize([
            "Label": AgentLabel.login,
            "ProgramArguments": ["/usr/bin/open", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ])
    }

    static func serialize(_ dict: [String: Any]) -> Data {
        // A dictionary of strings, arrays and booleans always serializes.
        (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return obj
    }

    /// The program a plist starts.
    static func program(of plist: [String: Any]) -> String? {
        if let args = plist["ProgramArguments"] as? [String], let first = args.first { return first }
        return plist["Program"] as? String
    }

    // MARK: auto-apply (brioctl watch)

    private func isAppCLI(_ program: String) -> Bool {
        program == cliPath || program.hasSuffix(".app/Contents/Resources/brioctl")
    }

    public func watchState() -> WatchAgentState {
        let url = plistURL(AgentLabel.watch)
        if fm.fileExists(atPath: url.path) {
            guard let plist = Self.read(url), let program = Self.program(of: plist) else { return .other(.unreadable) }
            return isAppCLI(program) ? .app(usesThisCopy: program == cliPath) : .other(.makeAgent(program: program))
        }
        if fm.fileExists(atPath: plistURL(AgentLabel.homebrew).path) { return .other(.homebrew) }
        return .off
    }

    /// Is the agent loaded in launchd right now?
    public func watchIsRunning() -> Bool { launchctl.isLoaded(label: AgentLabel.watch) }

    /// Writes the plist and loads it. Replaces an agent this app installed earlier; refuses to touch any other.
    public func installWatch(camera: String?) throws {
        if case .other = watchState() { throw LaunchAgentError.foreignAgent }
        let url = plistURL(AgentLabel.watch)
        let previous = try? Data(contentsOf: url)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try watchPlist(camera: camera).write(to: url, options: .atomic)
        } catch {
            throw LaunchAgentError.io("cannot write \(url.path): \(error.localizedDescription)")
        }
        launchctl.bootout(label: AgentLabel.watch)  // an older copy of this agent may be loaded
        do {
            try launchctl.bootstrap(plist: url)
        } catch {
            if let previous { try? previous.write(to: url, options: .atomic) } else { try? fm.removeItem(at: url) }
            throw error
        }
    }

    /// Unloads the agent and removes its plist, if this app installed it.
    public func removeWatch() throws {
        switch watchState() {
        case .other: throw LaunchAgentError.foreignAgent
        case .off: return
        case .app: break
        }
        launchctl.bootout(label: AgentLabel.watch)
        do { try fm.removeItem(at: plistURL(AgentLabel.watch)) } catch {
            throw LaunchAgentError.io("cannot remove \(plistURL(AgentLabel.watch).path): \(error.localizedDescription)")
        }
    }

    // MARK: launch at login

    public func loginItemEnabled() -> Bool { fm.fileExists(atPath: plistURL(AgentLabel.login).path) }

    /// launchd reads the plist at the next login, so nothing is loaded now (that would start a second copy).
    public func setLoginItem(enabled: Bool) throws {
        let url = plistURL(AgentLabel.login)
        if enabled {
            guard appPath.hasSuffix(".app") else { throw LaunchAgentError.notInAppBundle }
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try loginPlist().write(to: url, options: .atomic)
            } catch {
                throw LaunchAgentError.io("cannot write \(url.path): \(error.localizedDescription)")
            }
        } else if fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) } catch {
                throw LaunchAgentError.io("cannot remove \(url.path): \(error.localizedDescription)")
            }
        }
    }
}
