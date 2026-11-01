import Foundation

// A small JSON reader that keeps the order of object members. brioctl --json lists the settings in the order the CLI
// shows them, and JSONDecoder / JSONSerialization lose that order.

public struct JSONMember: Equatable {
    public let key: String
    public let value: JSON
}

public enum JSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([JSONMember])
}

public struct JSONParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let offset: Int
    public var description: String { "invalid JSON at byte \(offset): \(message)" }
}

extension JSON {
    public static func parse(_ data: Data) throws -> JSON {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    /// The first member of that key, if this is an object.
    public subscript(key: String) -> JSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var members: [JSONMember]? {
        if case .object(let m) = self { return m }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var double: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    public var int: Int? {
        guard case .number(let d) = self, d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var pos = 0
    var depth = 0
    static let maxDepth = 64

    init(bytes: [UInt8]) { self.bytes = bytes }

    func fail(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: pos) }

    mutating func skipSpace() {
        while pos < bytes.count, bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09 {
            pos += 1
        }
    }

    mutating func parseDocument() throws -> JSON {
        skipSpace()
        let v = try parseValue()
        skipSpace()
        if pos != bytes.count { throw fail("unexpected data after the value") }
        return v
    }

    mutating func parseValue() throws -> JSON {
        skipSpace()
        guard pos < bytes.count else { throw fail("unexpected end") }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        let w = Array(word.utf8)
        guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else { throw fail("expected \(word)") }
        pos += w.count
    }

    mutating func parseObject() throws -> JSON {
        depth += 1
        defer { depth -= 1 }
        if depth > JSONParser.maxDepth { throw fail("nested too deeply") }
        pos += 1  // {
        var members: [JSONMember] = []
        skipSpace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
        while true {
            skipSpace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw fail("expected a member name") }
            let key = try parseString()
            skipSpace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            pos += 1
            members.append(JSONMember(key: key, value: try parseValue()))
            skipSpace()
            guard pos < bytes.count else { throw fail("unexpected end") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
            throw fail("expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> JSON {
        depth += 1
        defer { depth -= 1 }
        if depth > JSONParser.maxDepth { throw fail("nested too deeply") }
        pos += 1  // [
        var items: [JSON] = []
        skipSpace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
        while true {
            items.append(try parseValue())
            skipSpace()
            guard pos < bytes.count else { throw fail("unexpected end") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
            throw fail("expected ',' or ']'")
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw fail("short \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[pos]
            let d: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A")) + 10
            default: throw fail("bad \\u escape")
            }
            v = v << 4 | d
            pos += 1
        }
        return v
    }

    mutating func parseString() throws -> String {
        pos += 1  // opening quote
        var out: [UInt8] = []
        while true {
            guard pos < bytes.count else { throw fail("unterminated string") }
            let c = bytes[pos]
            pos += 1
            if c == UInt8(ascii: "\"") { break }
            if c != UInt8(ascii: "\\") { out.append(c); continue }
            guard pos < bytes.count else { throw fail("unterminated string") }
            let e = bytes[pos]
            pos += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var code = try parseHex4()
                if (0xD800..<0xDC00).contains(code) {  // high surrogate: a low one must follow
                    guard pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") else {
                        throw fail("lone surrogate")
                    }
                    pos += 2
                    let low = try parseHex4()
                    guard (0xDC00..<0xE000).contains(low) else { throw fail("bad surrogate pair") }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(code) else { throw fail("bad code point") }
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: throw fail("bad escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func parseNumber() throws -> JSON {
        let start = pos
        while pos < bytes.count {
            let c = bytes[pos]
            let isNumberChar = (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-")
                || c == UInt8(ascii: "+") || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
            if !isNumberChar { break }
            pos += 1
        }
        guard pos > start, let d = Double(String(decoding: bytes[start..<pos], as: UTF8.self)) else {
            pos = start
            throw fail("unexpected character")
        }
        return .number(d)
    }
}
