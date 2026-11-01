import Foundation

/// The brioctl:// URL scheme, for Shortcuts ("Open URL"), scripts (`open "brioctl://set?fov=78"`) and links.
///
///     brioctl://set?fov=78&zoom=115     change settings
///     brioctl://apply?name=warmer       apply a preset or a saved file
///     brioctl://camera?id=2             choose the camera (index, serial number or location)
public enum URLCommand: Equatable {
    case set([(name: String, value: String)])
    case apply(name: String)
    case camera(id: String)

    public static func == (a: URLCommand, b: URLCommand) -> Bool {
        switch (a, b) {
        case (.set(let x), .set(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.name == $1.name && $0.value == $1.value }
        case (.apply(let x), .apply(let y)): return x == y
        case (.camera(let x), .camera(let y)): return x == y
        default: return false
        }
    }
}

public enum URLCommandError: Error, Equatable, CustomStringConvertible {
    case wrongScheme
    case unknownAction(String)
    case missing(String)
    case nothingToDo

    public var description: String {
        switch self {
        case .wrongScheme: return "not a brioctl:// URL"
        case .unknownAction(let a): return "unknown action \u{201C}\(a)\u{201D} (use set, apply or camera)"
        case .missing(let key): return "missing \u{201C}\(key)\u{201D}"
        case .nothingToDo: return "no settings in the URL"
        }
    }
}

public enum URLCommands {
    public static let scheme = "brioctl"

    public static func parse(_ url: URL) -> Result<URLCommand, URLCommandError> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.wrongScheme) }
        // brioctl://set?... has the action as the host; brioctl:///set?... as the path.
        var action = parts.host ?? ""
        if action.isEmpty { action = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        action = action.lowercased()
        let items = parts.queryItems ?? []
        func value(_ key: String) -> String? { items.last(where: { $0.name == key })?.value }

        switch action {
        case "set":
            // Later duplicates win; the order of first appearance stays.
            var order: [String] = []
            var values: [String: String] = [:]
            for item in items {
                guard let v = item.value else { continue }
                if values[item.name] == nil { order.append(item.name) }
                values[item.name] = v
            }
            let pairs = order.map { (name: $0, value: values[$0]!) }
            return pairs.isEmpty ? .failure(.nothingToDo) : .success(.set(pairs))
        case "apply":
            guard let name = value("name"), !name.isEmpty else { return .failure(.missing("name")) }
            return .success(.apply(name: name))
        case "camera":
            guard let id = value("id"), !id.isEmpty else { return .failure(.missing("id")) }
            return .success(.camera(id: id))
        default:
            return .failure(.unknownAction(action))
        }
    }

    // MARK: validation against what the camera has

    public struct SetPlan: Equatable {
        public var pairs: [(name: String, value: String)]
        /// Keys the camera does not have (or values that cannot be one): left out.
        public var ignored: [String]

        public static func == (a: SetPlan, b: SetPlan) -> Bool {
            a.ignored == b.ignored && a.pairs.count == b.pairs.count
                && zip(a.pairs, b.pairs).allSatisfy { $0.name == $1.name && $0.value == $1.value }
        }
    }

    /// Keeps the names the current JSON lists (and micgain when the camera has a microphone). Unknown keys are ignored.
    /// The value has to look like a value brioctl takes: a word or a number, no more.
    public static func plan(set pairs: [(name: String, value: String)], for state: CameraState) -> SetPlan {
        var kept: [(name: String, value: String)] = []
        var ignored: [String] = []
        for p in pairs {
            if state.has(p.name), isPlainValue(p.value) { kept.append(p) } else { ignored.append(p.name) }
        }
        return SetPlan(pairs: kept, ignored: ignored)
    }

    static func isPlainValue(_ v: String) -> Bool {
        guard !v.isEmpty, v.count <= 32, !v.hasPrefix("--") else { return false }
        return v.unicodeScalars.allSatisfy { plainCharacters.contains($0) }
    }

    private static let plainCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: ".+-_")
        return set
    }()

    /// A name brioctl may be given: a preset or a saved file it listed. Anything else could be a path.
    public static func isKnownProfile(_ name: String, in profiles: Profiles?) -> Bool {
        profiles?.isKnown(name) ?? false
    }

    public static func camera(matching id: String, in cameras: [CameraInfo]) -> CameraInfo? {
        cameras.first { $0.matches(id: id) }
    }
}
