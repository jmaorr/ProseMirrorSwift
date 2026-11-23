// A JSON value with order-preserving objects.
//
// ProseMirror attributes are arbitrary JSON, and schema specs rely on key order
// (node/mark order, attribute order), so objects remember insertion order.
// Equality on objects ignores order, matching how ProseMirror compares attrs.

public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    /// The number truncated toward zero, or nil when it isn't finite or doesn't fit in an
    /// `Int` (untrusted JSON can say `1e400` or `9e18`, which `Int(_:)` traps on).
    public var intValue: Int? { if case .number(let n) = self { return JSONValue.truncatedInt(n) }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// `n` truncated toward zero, or nil when it isn't finite or doesn't fit in an `Int`.
    public static func truncatedInt(_ n: Double) -> Int? { Int(exactly: n.rounded(.towardZero)) }

    /// `n` as a position or count from untrusted input: an integer-valued (after truncation)
    /// number within ±2^53 (JS's safe integers), so later arithmetic on it can't overflow.
    public static func safeInt(_ n: Double) -> Int? {
        guard let i = truncatedInt(n), abs(i) <= 9_007_199_254_740_992 else { return nil }
        return i
    }

    /// JS truthiness, for porting `if (spec.foo)` checks.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// Name of the JS `typeof` result, used for attribute validation.
    public var jsTypeName: String {
        switch self {
        case .null, .array, .object: return "object"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o = JSONObject()
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

public struct JSONObject: Hashable, Sendable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}
    public init(_ pairs: [(String, JSONValue)]) { for (k, v) in pairs { self[k] = v } }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var i = 0
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], storage[keys[i]]!)
        }
    }

    public static func == (a: JSONObject, b: JSONObject) -> Bool { a.storage == b.storage }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let description: String
}

extension JSONValue {
    /// The deepest nesting `parse` and the model's `fromJSON` functions accept.
    public static let maxNestingDepth = 512

    /// Whether arrays/objects nest deeper than `limit` (checked without unbounded recursion).
    public func nestingExceeds(_ limit: Int) -> Bool {
        switch self {
        case .array(let a):
            if limit <= 0 { return true }
            return a.contains { $0.nestingExceeds(limit - 1) }
        case .object(let o):
            if limit <= 0 { return true }
            return o.contains { $0.value.nestingExceeds(limit - 1) }
        default: return false
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var p = JSONParser(bytes: Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        if p.i != p.bytes.count { throw JSONParseError(description: "trailing characters at \(p.i)") }
        return v
    }
}

private struct JSONParser {
    /// Deepest array/object nesting accepted, so hostile input can't overflow the stack.
    static let maxDepth = JSONValue.maxNestingDepth

    let bytes: [UInt8]
    var i = 0
    var depth = 0

    mutating func skipWS() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    func fail(_ msg: String) -> JSONParseError { JSONParseError(description: "\(msg) at \(i)") }

    mutating func value() throws -> JSONValue {
        guard i < bytes.count else { throw fail("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"):
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else { throw fail("nested too deeply") }
            i += 1
            var o = JSONObject()
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let k = try string()
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
                i += 1
                skipWS()
                o[k] = try value()
                skipWS()
                guard i < bytes.count else { throw fail("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                throw fail("expected , or }")
            }
        case UInt8(ascii: "["):
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else { throw fail("nested too deeply") }
            i += 1
            var a: [JSONValue] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                skipWS()
                a.append(try value())
                skipWS()
                guard i < bytes.count else { throw fail("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                throw fail("expected , or ]")
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default:
            return .number(try number())
        }
    }

    mutating func literal(_ s: String) throws {
        let u = Array(s.utf8)
        guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw fail("bad literal") }
        i += u.count
    }

    mutating func number() throws -> Double {
        let start = i
        while i < bytes.count {
            let c = bytes[i]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
                || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { i += 1 } else { break }
        }
        guard let d = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else { throw fail("bad number") }
        return d
    }

    mutating func string() throws -> String {
        i += 1 // opening quote
        var units: [UInt16] = []
        var chunkStart = i
        func flush(_ end: Int) {
            if end > chunkStart { units.append(contentsOf: String(decoding: bytes[chunkStart..<end], as: UTF8.self).utf16) }
        }
        while true {
            guard i < bytes.count else { throw fail("unterminated string") }
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { flush(i); i += 1; break }
            if c == UInt8(ascii: "\\") {
                flush(i)
                i += 1
                guard i < bytes.count else { throw fail("bad escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): units.append(0x22)
                case UInt8(ascii: "\\"): units.append(0x5C)
                case UInt8(ascii: "/"): units.append(0x2F)
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"):
                    guard i + 4 <= bytes.count, let v = UInt16(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
                    else { throw fail("bad \\u escape") }
                    units.append(v)
                    i += 4
                default: throw fail("bad escape")
                }
                chunkStart = i
                continue
            }
            i += 1
        }
        return String(decoding: units, as: UTF16.self)
    }
}

// MARK: - Serialization (JSON.stringify-compatible for the values we produce)

extension JSONValue: CustomStringConvertible {
    public var description: String { serialized() }

    public func serialized(sortedKeys: Bool = false) -> String {
        var out = ""
        write(to: &out, sortedKeys: sortedKeys)
        return out
    }

    private func write(to out: inout String, sortedKeys: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSONValue.formatNumber(n)
        case .string(let s): JSONValue.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (idx, v) in a.enumerated() {
                if idx > 0 { out += "," }
                v.write(to: &out, sortedKeys: sortedKeys)
            }
            out += "]"
        case .object(let o):
            out += "{"
            let keys = sortedKeys ? o.keys.sorted() : o.keys
            for (idx, k) in keys.enumerated() {
                if idx > 0 { out += "," }
                JSONValue.writeString(k, to: &out)
                out += ":"
                o[k]!.write(to: &out, sortedKeys: sortedKeys)
            }
            out += "}"
        }
    }

    static func formatNumber(_ n: Double) -> String {
        if !n.isFinite { return "null" }
        // JS prints integers below 1e21 in full: exact below 2^53, and past that its shortest
        // round-trip digits padded with zeros (Int64 would trap at 2^63, and print digits JS doesn't).
        if n == n.rounded(), abs(n) < 1e21 {
            if abs(n) < 9_007_199_254_740_992 { return String(Int64(n)) }
            return paddedShortestDigits(n)
        }
        return "\(n)"
    }

    /// JS's `Number.prototype.toString` for an integer-valued double in [2^53, 1e21): the
    /// shortest round-trip digits (which Swift's description also gives), then zeros.
    private static func paddedShortestDigits(_ n: Double) -> String {
        let text = "\(abs(n))" // e.g. "9.223372036854778e+18" or "1e+20"
        let parts = text.split(separator: "e")
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(mantissa[0])
        var fraction = mantissa.count > 1 ? String(mantissa[1]) : ""
        if fraction == "0" { fraction = "" }
        let digits = whole + fraction
        let zeros = exponent - fraction.count
        let body = zeros >= 0 ? digits + String(repeating: "0", count: zeros) : String(digits.dropLast(-zeros))
        return (n < 0 ? "-" : "") + body
    }

    static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += "\\u" + String(repeating: "0", count: 4 - String(u.value, radix: 16).count) + String(u.value, radix: 16)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}
