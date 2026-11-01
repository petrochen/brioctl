import Foundation
import os

public let appBundleID = "com.github.petrochen.brioctl.app"

let log = Logger(subsystem: appBundleID, category: "app")

/// Everything the app takes from outside, in one place, so that tests and the headless smoke test can redirect it.
///
///     BRIOCTL_APP_CLI             path of the brioctl to run instead of Contents/Resources/brioctl
///     BRIOCTL_APP_AGENTS_DIR      directory of the LaunchAgent plists instead of ~/Library/LaunchAgents; launchd is
///                                 then never asked to load or unload anything (the labels are those of real agents)
///     BRIOCTL_APP_DEFAULTS_SUITE  UserDefaults suite instead of the app's own domain
///     BRIOCTL_FAKE                not read here: the CLI inherits it (a fake brioctl build reads a camera snapshot)
public struct AppEnvironment {
    public static let cliKey = "BRIOCTL_APP_CLI"
    public static let agentsKey = "BRIOCTL_APP_AGENTS_DIR"
    public static let suiteKey = "BRIOCTL_APP_DEFAULTS_SUITE"

    public var cliURL: URL?
    public var agentsDirectory: URL
    public var logPath: String
    public var appBundlePath: String
    public var defaults: UserDefaults
    public var processEnvironment: [String: String]
    public var usesCLIOverride: Bool
    /// BRIOCTL_APP_AGENTS_DIR is set: a development run, which must never reach the real launchd.
    public var usesAgentsOverride: Bool

    public init(processEnvironment env: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        processEnvironment = env
        if let path = env[Self.cliKey], !path.isEmpty {
            cliURL = URL(fileURLWithPath: path)
            usesCLIOverride = true
        } else {
            cliURL = bundle.resourceURL?.appendingPathComponent("brioctl")
            usesCLIOverride = false
        }
        if let dir = env[Self.agentsKey], !dir.isEmpty {
            agentsDirectory = URL(fileURLWithPath: dir, isDirectory: true)
            usesAgentsOverride = true
        } else {
            agentsDirectory = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            usesAgentsOverride = false
        }
        logPath = home.appendingPathComponent("Library/Logs/brioctl.log").path
        appBundlePath = bundle.bundleURL.path
        if let suite = env[Self.suiteKey], !suite.isEmpty, let d = UserDefaults(suiteName: suite) {
            defaults = d
        } else {
            defaults = .standard
        }
    }

    public var cliExists: Bool {
        guard let cliURL else { return false }
        return FileManager.default.isExecutableFile(atPath: cliURL.path)
    }

    public var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}
