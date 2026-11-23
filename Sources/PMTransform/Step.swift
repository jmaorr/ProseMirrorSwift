// Port of prosemirror-transform/src/step.ts, replace_step.ts, mark_step.ts, attr_step.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import PMModel

/// A step object represents an atomic change.
open class Step {
    public init() {}

    open func apply(_ doc: Node) -> StepResult { fatalError("abstract") }
    open func getMap() -> StepMap { .empty }
    open func invert(_ doc: Node) -> Step { fatalError("abstract") }
    open func map(_ mapping: Mappable) -> Step? { fatalError("abstract") }
    open func merge(_ other: Step) -> Step? { nil }
    open func toJSON() -> JSONValue { fatalError("abstract") }

    nonisolated(unsafe) private static var stepsByID: [String: (Schema, JSONValue) throws -> Step] = builtinSteps()

    private static func builtinSteps() -> [String: (Schema, JSONValue) throws -> Step] { [
        "replace": ReplaceStep.decode,
        "replaceAround": ReplaceAroundStep.decode,
        "addMark": AddMarkStep.decode,
        "removeMark": RemoveMarkStep.decode,
        "addNodeMark": AddNodeMarkStep.decode,
        "removeNodeMark": RemoveNodeMarkStep.decode,
        "attr": AttrStep.decode,
        "docAttr": DocAttrStep.decode,
    ] }

    public static func fromJSON(_ schema: Schema, _ json: JSONValue) throws -> Step {
        guard let id = json["stepType"]?.stringValue, !id.isEmpty else { throw PMError.range("Invalid input for Step.fromJSON") }
        guard let fn = stepsByID[id] else { throw PMError.range("No step type \(id) defined") }
        return try fn(schema, json)
    }

    /// Register a custom step type for JSON deserialization.
    public static func jsonID(_ id: String, _ fromJSON: @escaping (Schema, JSONValue) throws -> Step) throws {
        if stepsByID[id] != nil { throw PMError.range("Duplicate use of step JSON ID \(id)") }
        stepsByID[id] = fromJSON
    }
}

/// The result of applying a step: a new document or a failure message.
public struct StepResult {
    public let doc: Node?
    public let failed: String?

    public static func ok(_ doc: Node) -> StepResult { StepResult(doc: doc, failed: nil) }
    public static func fail(_ message: String) -> StepResult { StepResult(doc: nil, failed: message) }

    public static func fromReplace(_ doc: Node, _ from: Int, _ to: Int, _ slice: Slice) -> StepResult {
        do {
            return .ok(try doc.replace(from, to, slice))
        } catch {
            return .fail("\(error)")
        }
    }
}

private func num(_ i: Int) -> JSONValue { .number(Double(i)) }

/// A position from step JSON: a number (as JS checks), and also finite and within JS's safe
/// integers, so converting it can't trap and arithmetic on it can't overflow.
private func requireInt(_ json: JSONValue, _ key: String, _ msg: String) throws -> Int {
    guard let n = json[key]?.numberValue, let i = JSONValue.safeInt(n) else { throw PMError.range(msg) }
    return i
}

// MARK: - ReplaceStep

public final class ReplaceStep: Step {
    public let from: Int
    public let to: Int
    public let slice: Slice
    public let structure: Bool

    /// JS `ReplaceStep.MAP_BIAS`.
    nonisolated(unsafe) public static var mapBias = 1

    public init(_ from: Int, _ to: Int, _ slice: Slice, structure: Bool = false) {
        self.from = from
        self.to = to
        self.slice = slice
        self.structure = structure
    }

    public override func apply(_ doc: Node) -> StepResult {
        if structure && contentBetween(doc, from, to) { return .fail("Structure replace would overwrite content") }
        return .fromReplace(doc, from, to, slice)
    }

    public override func getMap() -> StepMap { StepMap([from, to - from, slice.size]) }

    public override func invert(_ doc: Node) -> Step {
        ReplaceStep(from, from + slice.size, doc.slice(from, to))
    }

    public override func map(_ mapping: Mappable) -> Step? {
        let to = mapping.mapResult(self.to, assoc: -1)
        let from = self.from == self.to && ReplaceStep.mapBias < 0 ? to : mapping.mapResult(self.from, assoc: 1)
        if from.deletedAcross && to.deletedAcross { return nil }
        return ReplaceStep(from.pos, Swift.max(from.pos, to.pos), slice, structure: structure)
    }

    public override func merge(_ other: Step) -> Step? {
        guard let other = other as? ReplaceStep, !other.structure, !structure else { return nil }
        if from + slice.size == other.from && slice.openEnd == 0 && other.slice.openStart == 0 {
            let slice = self.slice.size + other.slice.size == 0 ? Slice.empty
                : Slice(self.slice.content.append(other.slice.content), self.slice.openStart, other.slice.openEnd)
            return ReplaceStep(from, to + (other.to - other.from), slice, structure: structure)
        } else if other.to == from && slice.openStart == 0 && other.slice.openEnd == 0 {
            let slice = self.slice.size + other.slice.size == 0 ? Slice.empty
                : Slice(other.slice.content.append(self.slice.content), other.slice.openStart, self.slice.openEnd)
            return ReplaceStep(other.from, to, slice, structure: structure)
        }
        return nil
    }

    public override func toJSON() -> JSONValue {
        var json = JSONObject([("stepType", "replace"), ("from", num(from)), ("to", num(to))])
        if slice.size > 0 { json["slice"] = slice.toJSON() }
        if structure { json["structure"] = true }
        return .object(json)
    }

    static func decode(_ schema: Schema, _ json: JSONValue) throws -> Step {
        let msg = "Invalid input for ReplaceStep.fromJSON"
        return ReplaceStep(try requireInt(json, "from", msg), try requireInt(json, "to", msg),
                           try Slice.fromJSON(schema, json["slice"]), structure: json["structure"]?.truthy ?? false)
    }
}

// MARK: - ReplaceAroundStep

public final class ReplaceAroundStep: Step {
    public let from: Int
    public let to: Int
    public let gapFrom: Int
    public let gapTo: Int
    public let slice: Slice
    public let insert: Int
    public let structure: Bool

    public init(_ from: Int, _ to: Int, _ gapFrom: Int, _ gapTo: Int, _ slice: Slice, _ insert: Int, structure: Bool = false) {
        self.from = from
        self.to = to
        self.gapFrom = gapFrom
        self.gapTo = gapTo
        self.slice = slice
        self.insert = insert
        self.structure = structure
    }

    public override func apply(_ doc: Node) -> StepResult {
        if structure && (contentBetween(doc, from, gapFrom) || contentBetween(doc, gapTo, to)) {
            return .fail("Structure gap-replace would overwrite content")
        }
        let gap = doc.slice(gapFrom, gapTo)
        if gap.openStart > 0 || gap.openEnd > 0 { return .fail("Gap is not a flat range") }
        guard let inserted = slice.insertAt(insert, gap.content) else { return .fail("Content does not fit in gap") }
        return .fromReplace(doc, from, to, inserted)
    }

    public override func getMap() -> StepMap {
        StepMap([from, gapFrom - from, insert, gapTo, to - gapTo, slice.size - insert])
    }

    public override func invert(_ doc: Node) -> Step {
        let gap = gapTo - gapFrom
        // Only meaningful for the document the step applied to, where the gap is a flat range.
        guard let removed = try? doc.slice(from, to).removeBetween(gapFrom - from, gapTo - from) else {
            preconditionFailure("ReplaceAroundStep.invert called with a document the step doesn't apply to")
        }
        return ReplaceAroundStep(from, from + slice.size + gap, from + insert, from + insert + gap,
                                 removed, gapFrom - from, structure: structure)
    }

    public override func map(_ mapping: Mappable) -> Step? {
        let from = mapping.mapResult(self.from, assoc: 1), to = mapping.mapResult(self.to, assoc: -1)
        let gapFrom = self.from == self.gapFrom ? from.pos : mapping.map(self.gapFrom, assoc: -1)
        let gapTo = self.to == self.gapTo ? to.pos : mapping.map(self.gapTo, assoc: 1)
        if (from.deletedAcross && to.deletedAcross) || gapFrom < from.pos || gapTo > to.pos { return nil }
        return ReplaceAroundStep(from.pos, to.pos, gapFrom, gapTo, slice, insert, structure: structure)
    }

    public override func toJSON() -> JSONValue {
        var json = JSONObject([("stepType", "replaceAround"), ("from", num(from)), ("to", num(to)),
                               ("gapFrom", num(gapFrom)), ("gapTo", num(gapTo)), ("insert", num(insert))])
        if slice.size > 0 { json["slice"] = slice.toJSON() }
        if structure { json["structure"] = true }
        return .object(json)
    }

    static func decode(_ schema: Schema, _ json: JSONValue) throws -> Step {
        let msg = "Invalid input for ReplaceAroundStep.fromJSON"
        return ReplaceAroundStep(try requireInt(json, "from", msg), try requireInt(json, "to", msg),
                                 try requireInt(json, "gapFrom", msg), try requireInt(json, "gapTo", msg),
                                 try Slice.fromJSON(schema, json["slice"]), try requireInt(json, "insert", msg),
                                 structure: json["structure"]?.truthy ?? false)
    }
}

func contentBetween(_ doc: Node, _ from: Int, _ to: Int) -> Bool {
    let rFrom = doc.resolve(from)
    var dist = to - from, depth = rFrom.depth
    while dist > 0 && depth > 0 && rFrom.indexAfter(depth) == rFrom.node(depth).childCount {
        depth -= 1
        dist -= 1
    }
    if dist > 0 {
        var next = rFrom.node(depth).maybeChild(rFrom.indexAfter(depth))
        while dist > 0 {
            guard let n = next, !n.isLeaf else { return true }
            next = n.firstChild
            dist -= 1
        }
    }
    return false
}

// MARK: - Mark steps

private func mapFragment(_ fragment: Fragment, _ f: (Node, Node, Int) -> Node, _ parent: Node) -> Fragment {
    var mapped: [Node] = []
    for i in 0..<fragment.childCount {
        var child = fragment.child(i)
        if child.content.size > 0 { child = child.copy(mapFragment(child.content, f, child)) }
        if child.isInline { child = f(child, parent, i) }
        mapped.append(child)
    }
    return Fragment.fromArray(mapped)
}

public final class AddMarkStep: Step {
    public internal(set) var from: Int
    public internal(set) var to: Int
    public let mark: Mark

    public init(_ from: Int, _ to: Int, _ mark: Mark) {
        self.from = from
        self.to = to
        self.mark = mark
    }

    public override func apply(_ doc: Node) -> StepResult {
        let oldSlice = doc.slice(from, to), rFrom = doc.resolve(from)
        let parent = rFrom.node(rFrom.sharedDepth(to))
        let slice = Slice(mapFragment(oldSlice.content, { node, parent, _ in
            if !node.isAtom || !parent.type.allowsMarkType(self.mark.type) { return node }
            return node.mark(self.mark.addToSet(node.marks))
        }, parent), oldSlice.openStart, oldSlice.openEnd)
        return .fromReplace(doc, from, to, slice)
    }

    public override func invert(_ doc: Node) -> Step { RemoveMarkStep(from, to, mark) }

    public override func map(_ mapping: Mappable) -> Step? {
        let from = mapping.mapResult(self.from, assoc: 1), to = mapping.mapResult(self.to, assoc: -1)
        if from.deleted && to.deleted || from.pos >= to.pos { return nil }
        return AddMarkStep(from.pos, to.pos, mark)
    }

    public override func merge(_ other: Step) -> Step? {
        if let other = other as? AddMarkStep, other.mark.eq(mark), from <= other.to, to >= other.from {
            return AddMarkStep(Swift.min(from, other.from), Swift.max(to, other.to), mark)
        }
        return nil
    }

    public override func toJSON() -> JSONValue {
        .object(JSONObject([("stepType", "addMark"), ("mark", mark.toJSON()), ("from", num(from)), ("to", num(to))]))
    }

    static func decode(_ schema: Schema, _ json: JSONValue) throws -> Step {
        let msg = "Invalid input for AddMarkStep.fromJSON"
        return AddMarkStep(try requireInt(json, "from", msg), try requireInt(json, "to", msg), try schema.markFromJSON(json["mark"] ?? .null))
    }
}

public final class RemoveMarkStep: Step {
    public internal(set) var from: Int
    public internal(set) var to: Int
    public let mark: Mark

    public init(_ from: Int, _ to: Int, _ mark: Mark) {
        self.from = from
        self.to = to
        self.mark = mark
    }

    public override func apply(_ doc: Node) -> StepResult {
        let oldSlice = doc.slice(from, to)
        let slice = Slice(mapFragment(oldSlice.content, { node, _, _ in
            node.mark(self.mark.removeFromSet(node.marks))
        }, doc), oldSlice.openStart, oldSlice.openEnd)
        return .fromReplace(doc, from, to, slice)
    }

    public override func invert(_ doc: Node) -> Step { AddMarkStep(from, to, mark) }

    public override func map(_ mapping: Mappable) -> Step? {
        let from = mapping.mapResult(self.from, assoc: 1), to = mapping.mapResult(self.to, assoc: -1)
        if from.deleted && to.deleted || from.pos >= to.pos { return nil }
        return RemoveMarkStep(from.pos, to.pos, mark)
    }

    public override func merge(_ other: Step) -> Step? {
        if let other = other as? RemoveMarkStep, other.mark.eq(mark), from <= other.to, to >= other.from {
            return RemoveMarkStep(Swift.min(from, other.from), Swift.max(to, other.to), mark)
        }
        return nil
    }

    public override func toJSON() -> JSONValue {
        .object(JSONObject([("stepType", "removeMark"), ("mark", mark.toJSON()), ("from", num(from)), ("to", num(to))]))
    }

    static func decode(_ schema: Schema, _ json: JSONValue) throws -> Step {
        let msg = "Invalid input for RemoveMarkStep.fromJSON"
        return RemoveMarkStep(try requireInt(json, "from", msg), try requireInt(json, "to", msg), try schema.markFromJSON(json["mark"] ?? .null))
    }
}

/// Recreate a node with new attrs/marks, the way `node.type.create(attrs, null, marks)` does in JS.
func recreate(_ node: Node, attrs: Attrs?, marks: [Mark]) -> Node? {
    try? node.type.create(attrs, nil, marks)
}

public final class AddNodeMarkStep: Step {
    public let pos: Int
    public let mark: Mark

    public init(_ pos: Int, _ mark: Mark) {
        self.pos = pos
        self.mark = mark
    }

    public override func apply(_ doc: Node) -> StepResult {
        guard let node = doc.nodeAt(pos) else { return .fail("No node at mark step's position") }
        guard let updated = recreate(node, attrs: node.attrs, marks: mark.addToSet(node.marks)) else {
            return .fail("NodeType.create can't construct text nodes")
        }
        return .fromReplace(doc, pos, pos + 1, Slice(Fragment.from(updated), 0, node.isLeaf ? 0 : 1))
    }

    public override func invert(_ doc: Node) -> Step {
        if let node = doc.nodeAt(pos) {
            let newSet = mark.addToSet(node.marks)
            if newSet.count == node.marks.count {
                for m in node.marks where !m.isInSet(newSet) { return AddNodeMarkStep(pos, m) }
                return AddNodeMarkStep(pos, mark)
            }
        }
        return RemoveNodeMarkStep(pos, mark)
    }

    public override func map(_ mapping: Mappable) -> Step? {
        let pos = mapping.mapResult(self.pos, assoc: 1)
        return pos.deletedAfter ? nil : AddNodeMarkStep(pos.pos, mark)
    }

    public override func toJSON() -> JSONValue {
        .object(JSONObject([("stepType", "addNodeMark"), ("pos", num(pos)), ("mark", mark.toJSON())]))
    }

    static func decode(_ schema: Schema, _ json: JSONValue) throws -> Step {
        AddNodeMarkStep(try requireInt(json, "pos", "Invalid input for AddNodeMarkStep.fromJSON"), try schema.markFromJSON(json["mark"] ?? .null))
    }
}

public final class RemoveNodeMarkStep: Step {
    public let pos: Int
    public let mark: Mark

    public init(_ pos: Int, _ mark: Mark) {
        self.pos = pos
        self.mark = mark
    }

    public override func apply(_ doc: Node) -> StepResult {
        guard let node = doc.nodeAt(pos) else { return .fail("No node at mark step's position") }
        guard let updated = recreate(node, attrs: node.attrs, marks: mark.removeFromSet(node.marks)) else {
            return .fail("NodeType.create can't construct text nodes")
        }
        return .fromReplace(doc, pos, pos + 1, Slice(Fragment.from(updated), 0, node.isLeaf ? 0 : 1))
    }

    public override func invert(_ doc: Node) -> Step {
        guard let node = doc.nodeAt(pos), mark.isInSet(node.marks) else { return self }
        return AddNodeMarkStep(pos, mark)
    }

    public override func map(_ mapping: Mappable) -> Step? {
        let pos = mapping.mapResult(self.pos, assoc: 1)
        return pos.deletedAfter ? nil : RemoveNodeMarkStep(pos.pos, mark)
    }

    public override func toJSON() -> JSONValue {
        .object(JSONObject([("stepType", "removeNodeMark"), ("pos", num(pos)), ("mark", mark.toJSON())]))
    }

    static func decode(_ schema: Schema, _ json: JSONValue) throws -> Step {
        RemoveNodeMarkStep(try requireInt(json, "pos", "Invalid input for RemoveNodeMarkStep.fromJSON"), try schema.markFromJSON(json["mark"] ?? .null))
    }
}

// MARK: - Attribute steps

public final class AttrStep: Step {
    public let pos: Int
    public let attr: String
    public let value: JSONValue

    public init(_ pos: Int, _ attr: String, _ value: JSONValue) {
        self.pos = pos
        self.attr = attr
        self.value = value
    }

    public override func apply(_ doc: Node) -> StepResult {
        guard let node = doc.nodeAt(pos) else { return .fail("No node at attribute step's position") }
        var attrs = node.attrs
        attrs[attr] = value
        guard let updated = recreate(node, attrs: attrs, marks: node.marks) else {
            return .fail("NodeType.create can't construct text nodes")
        }
        return .fromReplace(doc, pos, pos + 1, Slice(Fragment.from(updated), 0, node.isLeaf ? 0 : 1))
    }

    public override func invert(_ doc: Node) -> Step {
        AttrStep(pos, attr, doc.nodeAt(pos)!.attrs[attr] ?? .null)
    }

    public override func map(_ mapping: Mappable) -> Step? {
        let pos = mapping.mapResult(self.pos, assoc: 1)
        return pos.deletedAfter ? nil : AttrStep(pos.pos, attr, value)
    }

    public override func toJSON() -> JSONValue {
        .object(JSONObject([("stepType", "attr"), ("pos", num(pos)), ("attr", .string(attr)), ("value", value)]))
    }

    static func decode(_ schema: Schema, _ json: JSONValue) throws -> Step {
        guard let attr = json["attr"]?.stringValue else { throw PMError.range("Invalid input for AttrStep.fromJSON") }
        return AttrStep(try requireInt(json, "pos", "Invalid input for AttrStep.fromJSON"), attr, json["value"] ?? .null)
    }
}

public final class DocAttrStep: Step {
    public let attr: String
    public let value: JSONValue

    public init(_ attr: String, _ value: JSONValue) {
        self.attr = attr
        self.value = value
    }

    public override func apply(_ doc: Node) -> StepResult {
        var attrs = doc.attrs
        attrs[attr] = value
        guard let updated = try? doc.type.create(attrs, doc.content, doc.marks) else { return .fail("Invalid doc attrs") }
        return .ok(updated)
    }

    public override func invert(_ doc: Node) -> Step { DocAttrStep(attr, doc.attrs[attr] ?? .null) }
    public override func map(_ mapping: Mappable) -> Step? { self }

    public override func toJSON() -> JSONValue {
        .object(JSONObject([("stepType", "docAttr"), ("attr", .string(attr)), ("value", value)]))
    }

    static func decode(_ schema: Schema, _ json: JSONValue) throws -> Step {
        guard let attr = json["attr"]?.stringValue else { throw PMError.range("Invalid input for DocAttrStep.fromJSON") }
        return DocAttrStep(attr, json["value"] ?? .null)
    }
}
