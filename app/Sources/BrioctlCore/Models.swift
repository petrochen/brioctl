import Foundation

public struct ModelError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - brioctl list --json

public struct CameraInfo: Equatable, Hashable, Identifiable {
    public let index: Int
    public let vid: String
    public let pid: String
    public let name: String?
    public let model: String?
    public let support: String
    public let serial: String?
    public let location: String

    public var id: Int { index }

    public init(index: Int, vid: String, pid: String, name: String?, model: String?, support: String, serial: String?,
                location: String) {
        self.index = index
        self.vid = vid
        self.pid = pid
        self.name = name
        self.model = model
        self.support = support
        self.serial = serial
        self.location = location
    }

    public init(json: JSON) throws {
        guard let index = json["index"]?.int, let vid = json["vid"]?.string, let pid = json["pid"]?.string else {
            throw ModelError("a camera without index, vid or pid")
        }
        self.init(index: index, vid: vid, pid: pid, name: json["name"]?.string, model: json["model"]?.string,
                  support: json["support"]?.string ?? "standard", serial: json["serial"]?.string,
                  location: json["location"]?.string ?? "")
    }

    public var displayName: String { name ?? model ?? "\(vid):\(pid)" }

    /// Does the id (an index, a serial number or a location) name this camera?
    public func matches(id: String) -> Bool {
        let s = id.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        if s == String(index) { return true }
        if let serial, !serial.isEmpty, serial.caseInsensitiveCompare(s) == .orderedSame { return true }
        return !location.isEmpty && location.caseInsensitiveCompare(s) == .orderedSame
    }

    /// What goes after --camera: the serial number when it names exactly one of these cameras (an index changes when
    /// another camera is plugged in), the index otherwise.
    public func cliID(among all: [CameraInfo]) -> String {
        if let serial, !serial.isEmpty, all.filter({ $0.serial == serial }).count == 1 { return serial }
        return String(index)
    }

    public static func decodeList(_ data: Data) throws -> [CameraInfo] {
        let root = try JSON.parse(data)
        guard let cameras = root["cameras"]?.array else { throw ModelError("no \"cameras\" in the list") }
        return try cameras.map(CameraInfo.init(json:))
    }
}

// MARK: - brioctl --json

public struct DeviceInfo: Equatable {
    public let model: String?
    public let firmware: String?
    public let serial: String?
    public let name: String?
    public let vid: String
    public let pid: String
    public let support: String
    public let index: Int
    public let location: String

    public init(json: JSON) throws {
        guard let vid = json["vid"]?.string, let pid = json["pid"]?.string else { throw ModelError("device without vid or pid") }
        self.vid = vid
        self.pid = pid
        model = json["model"]?.string
        firmware = json["firmware"]?.string
        serial = json["serial"]?.string
        name = json["name"]?.string
        support = json["support"]?.string ?? "standard"
        index = json["index"]?.int ?? 0
        location = json["location"]?.string ?? ""
    }

    public var displayName: String { name ?? model ?? "\(vid):\(pid)" }
}

public struct VideoStatus: Equatable {
    public let on: Bool
    public let width: Int
    public let height: Int
}

public struct RightSightStatus: Equatable {
    public let stored: Bool
    public let enabled: Bool?
    public let speed: String?
    public let framing: String?
}

public struct CameraStatus: Equatable {
    public let video: VideoStatus?
    public let led: Bool?
    public let deskView: Bool?
    public let rightSight: RightSightStatus?

    public init(json: JSON?) {
        if let v = json?["video"], let on = v["on"]?.bool {
            video = VideoStatus(on: on, width: v["width"]?.int ?? 0, height: v["height"]?.int ?? 0)
        } else {
            video = nil
        }
        led = json?["led"]?.bool
        deskView = json?["desk_view"]?.bool
        if let r = json?["rightsight"], r.members != nil {
            rightSight = RightSightStatus(stored: r["stored"]?.bool ?? false, enabled: r["enabled"]?.bool,
                                          speed: r["speed"]?.string, framing: r["framing"]?.string)
        } else {
            rightSight = nil
        }
    }

    /// The status line under the camera name; nil when the camera does not say anything.
    public var summary: String? {
        var parts: [String] = []
        if let video {
            parts.append(video.on ? (video.width > 0 ? "Video on, \(video.width)\u{00D7}\(video.height)" : "Video on") : "Video off")
        }
        if deskView == true { parts.append("showing the desk") }
        if rightSight?.enabled == true { parts.append("RightSight on") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

public enum SettingKind: String, Equatable {
    case choice, bool, number
}

/// A value as the CLI reports it: named values are strings, plain numbers are numbers, an unreadable one is null.
public enum SettingValue: Equatable {
    case text(String)
    case number(Double)
    case none

    public init(json: JSON?) {
        switch json {
        case .string(let s)?: self = .text(s)
        case .number(let d)?: self = .number(d)
        case .bool(let b)?: self = .text(b ? "on" : "off")
        default: self = .none
        }
    }

    public var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var double: Double? {
        switch self {
        case .number(let d): return d
        case .text(let s): return Double(s)
        case .none: return nil
        }
    }

    /// The form brioctl accepts on its command line.
    public var argument: String? {
        switch self {
        case .text(let s): return s
        case .number(let d): return SettingValue.format(d)
        case .none: return nil
        }
    }

    /// 115, not 115.0; at most four decimals otherwise.
    public static func format(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e12 { return String(Int(d)) }
        var s = String(format: "%.4f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

public struct Setting: Equatable, Identifiable {
    public let name: String
    public let value: SettingValue
    public let defaultValue: SettingValue
    public let auto: Bool
    public let group: String
    public let writable: Bool
    public let kind: SettingKind
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let choices: [String]
    public let help: String

    public var id: String { name }

    public init(name: String, value: SettingValue, defaultValue: SettingValue = .none, auto: Bool = false,
                group: String, writable: Bool = true, kind: SettingKind, min: Double? = nil, max: Double? = nil,
                step: Double? = nil, choices: [String] = [], help: String = "") {
        self.name = name
        self.value = value
        self.defaultValue = defaultValue
        self.auto = auto
        self.group = group
        self.writable = writable
        self.kind = kind
        self.min = min
        self.max = max
        self.step = step
        self.choices = choices
        self.help = help
    }

    public init(name: String, json: JSON) throws {
        guard let kindName = json["kind"]?.string, let kind = SettingKind(rawValue: kindName) else {
            throw ModelError("\(name): unknown kind")
        }
        self.init(name: name, value: SettingValue(json: json["value"]), defaultValue: SettingValue(json: json["default"]),
                  auto: json["auto"]?.bool ?? false, group: json["group"]?.string ?? "Other",
                  writable: json["writable"]?.bool ?? false, kind: kind, min: json["min"]?.double,
                  max: json["max"]?.double, step: json["step"]?.double,
                  choices: json["choices"]?.array?.compactMap { $0.string } ?? [], help: json["help"]?.string ?? "")
    }
}

/// The sections of the settings list, in the order of the CLI help; groups the app does not know come last.
public struct SettingsSection: Equatable, Identifiable {
    public let group: String
    public let settings: [Setting]
    public var id: String { group }
}

public struct CameraState: Equatable {
    public static let groupOrder = ["Logitech", "Framing", "Exposure and image", "Found in the firmware"]

    public let device: DeviceInfo
    public let status: CameraStatus
    public let settings: [Setting]
    public let micgain: Double?

    public init(device: DeviceInfo, status: CameraStatus, settings: [Setting], micgain: Double?) {
        self.device = device
        self.status = status
        self.settings = settings
        self.micgain = micgain
    }

    public static func decode(_ data: Data) throws -> CameraState {
        let root = try JSON.parse(data)
        guard let dev = root["device"] else { throw ModelError("no \"device\" in the output") }
        guard let members = root["settings"]?.members else { throw ModelError("no \"settings\" in the output") }
        return CameraState(device: try DeviceInfo(json: dev), status: CameraStatus(json: root["status"]),
                           settings: try members.map { try Setting(name: $0.key, json: $0.value) },
                           micgain: root["micgain"]?.double)
    }

    public func setting(_ name: String) -> Setting? { settings.first { $0.name == name } }

    public func has(_ name: String) -> Bool { name == "micgain" ? micgain != nil : setting(name) != nil }

    public var sections: [SettingsSection] {
        var order = CameraState.groupOrder
        for s in settings where !order.contains(s.group) { order.append(s.group) }
        return order.compactMap { g in
            let list = settings.filter { $0.group == g }
            return list.isEmpty ? nil : SettingsSection(group: g, settings: list)
        }
    }
}

// MARK: - brioctl profiles --json

public struct Preset: Equatable, Identifiable {
    public let name: String
    public let settings: [(name: String, value: String)]
    public var id: String { name }

    public static func == (a: Preset, b: Preset) -> Bool {
        a.name == b.name && a.settings.count == b.settings.count
            && zip(a.settings, b.settings).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    public init(name: String, settings: [(name: String, value: String)]) {
        self.name = name
        self.settings = settings
    }

    /// "warmth 60"
    public var summary: String { settings.map { "\($0.name) \($0.value)" }.joined(separator: ", ") }
}

public struct Profiles: Equatable {
    public let presets: [Preset]
    public let saved: [String]
    public let dir: String?

    public init(presets: [Preset], saved: [String], dir: String?) {
        self.presets = presets
        self.saved = saved
        self.dir = dir
    }

    public static func decode(_ data: Data) throws -> Profiles {
        let root = try JSON.parse(data)
        guard let presets = root["presets"]?.array else { throw ModelError("no \"presets\" in the output") }
        return Profiles(
            presets: presets.compactMap { p in
                guard let name = p["name"]?.string else { return nil }
                let pairs = (p["settings"]?.members ?? []).compactMap { m -> (name: String, value: String)? in
                    guard let v = m.value.string ?? m.value.double.map(SettingValue.format) else { return nil }
                    return (m.key, v)
                }
                return Preset(name: name, settings: pairs)
            },
            saved: root["saved"]?.array?.compactMap { $0.string } ?? [],
            dir: root["dir"]?.string)
    }

    public func isKnown(_ name: String) -> Bool {
        presets.contains { $0.name == name } || saved.contains(name)
    }

    /// Letters, digits, space, dot, dash, underscore; not empty, not hidden, not a preset (brioctl refuses those), no
    /// slash (a name with a slash is a path to brioctl).
    public func validateNewName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter a name." }
        if name.count > 40 { return "Use at most 40 characters." }
        if name.hasPrefix(".") || name.hasPrefix("-") { return "The name cannot start with \u{201C}\(name.first!)\u{201D}." }
        if name.unicodeScalars.contains(where: { !Profiles.allowedNameCharacters.contains($0) }) {
            return "Use letters, digits, spaces, dots, dashes and underscores."
        }
        if presets.contains(where: { $0.name == name }) { return "\(name) is a built-in preset, choose another name." }
        return nil
    }

    private static let allowedNameCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: " ._-")
        return set
    }()
}
