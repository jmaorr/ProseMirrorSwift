// Port of prosemirror-model/src/mark.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

public typealias Attrs = JSONObject

/// A mark is a piece of information that can be attached to a node, such as
/// it being emphasized, in code font, or a link.
public final class Mark: CustomStringConvertible {
    public let type: MarkType
    public let attrs: Attrs

    init(type: MarkType, attrs: Attrs) {
        self.type = type
        self.attrs = attrs
    }

    /// Given a set of marks, create a new set which contains this one as well,
    /// in the right position.
    public func addToSet(_ set: [Mark]) -> [Mark] {
        var copy: [Mark]? = nil
        var placed = false
        for i in 0..<set.count {
            let other = set[i]
            if eq(other) { return set }
            if type.excludes(other.type) {
                if copy == nil { copy = Array(set[0..<i]) }
            } else if other.type.excludes(type) {
                return set
            } else {
                if !placed && other.type.rank > type.rank {
                    if copy == nil { copy = Array(set[0..<i]) }
                    copy!.append(self)
                    placed = true
                }
                if copy != nil { copy!.append(other) }
            }
        }
        var result = copy ?? set
        if !placed { result.append(self) }
        return result
    }

    /// Remove this mark from the given set.
    public func removeFromSet(_ set: [Mark]) -> [Mark] {
        for i in 0..<set.count where eq(set[i]) {
            return Array(set[0..<i]) + Array(set[(i + 1)...])
        }
        return set
    }

    public func isInSet(_ set: [Mark]) -> Bool {
        set.contains { eq($0) }
    }

    /// Same type and attributes.
    public func eq(_ other: Mark) -> Bool {
        self === other || (type === other.type && attrs == other.attrs)
    }

    public func toJSON() -> JSONValue {
        var obj = JSONObject()
        obj["type"] = .string(type.name)
        if !attrs.isEmpty { obj["attrs"] = .object(attrs) }
        return .object(obj)
    }

    public static func fromJSON(_ schema: Schema, _ json: JSONValue) throws -> Mark {
        guard case .object = json else { throw PMError.range("Invalid input for Mark.fromJSON") }
        if let attrs = json["attrs"], attrs.nestingExceeds(JSONValue.maxNestingDepth) {
            throw PMError.range("Mark attrs nested too deeply")
        }
        guard let name = json["type"]?.stringValue, let type = schema.marks[name] else {
            throw PMError.range("There is no mark type \(json["type"].map { "\($0)" } ?? "undefined") in this schema")
        }
        let mark = try type.create(json["attrs"]?.objectValue)
        try type.checkAttrs(mark.attrs)
        return mark
    }

    public static func sameSet(_ a: [Mark], _ b: [Mark]) -> Bool {
        if a.count != b.count { return false }
        for i in 0..<a.count where !a[i].eq(b[i]) { return false }
        return true
    }

    /// Create a properly sorted mark set.
    public static func setFrom(_ marks: [Mark]?) -> [Mark] {
        guard let marks, !marks.isEmpty else { return none }
        if marks.count == 1 { return marks }
        // Stable sort by rank, as JS Array.prototype.sort is stable.
        return marks.enumerated().sorted { a, b in
            a.element.type.rank != b.element.type.rank ? a.element.type.rank < b.element.type.rank : a.offset < b.offset
        }.map(\.element)
    }

    public static let none: [Mark] = []

    public var description: String {
        attrs.isEmpty ? type.name : "\(type.name)\(JSONValue.object(attrs))"
    }
}
