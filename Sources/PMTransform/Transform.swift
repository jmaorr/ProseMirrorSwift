// Port of prosemirror-transform/src/transform.ts and mark.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import PMModel

/// A node type plus optional attributes, as used by `wrap`, `split` and `findWrapping`.
public struct NodeTypeWithAttrs {
    public let type: NodeType
    public let attrs: Attrs?
    public init(_ type: NodeType, _ attrs: Attrs? = nil) {
        self.type = type
        self.attrs = attrs
    }
}

/// Abstraction to build up and track an array of steps representing a
/// document transformation. Methods throw `PMError.transform` when a step
/// fails, like JS `TransformError`.
open class Transform {
    public private(set) var steps: [Step] = []
    public private(set) var docs: [Node] = []
    public let mapping = Mapping()
    public private(set) var doc: Node

    public init(_ doc: Node) { self.doc = doc }

    public var before: Node { docs.first ?? doc }

    @discardableResult
    public func step(_ step: Step) throws -> Self {
        let result = maybeStep(step)
        if let failed = result.failed { throw PMError.transform(failed) }
        return self
    }

    @discardableResult
    public func maybeStep(_ step: Step) -> StepResult {
        let result = step.apply(doc)
        if result.failed == nil { addStep(step, result.doc!) }
        return result
    }

    public var docChanged: Bool { !steps.isEmpty }

    public func changedRange() -> (from: Int, to: Int)? {
        var from = 1_000_000_000, to = -1_000_000_000
        for (i, map) in mapping.maps.enumerated() {
            if i > 0 {
                from = map.map(from, assoc: 1)
                to = map.map(to, assoc: -1)
            }
            map.forEach { _, _, fromB, toB in
                from = Swift.min(from, fromB)
                to = Swift.max(to, toB)
            }
        }
        return from == 1_000_000_000 ? nil : (from, to)
    }

    open func addStep(_ step: Step, _ doc: Node) {
        docs.append(self.doc)
        steps.append(step)
        mapping.appendMap(step.getMap())
        self.doc = doc
    }

    @discardableResult
    public func replace(_ from: Int, _ to: Int? = nil, _ slice: Slice = .empty) throws -> Self {
        if let step = try replaceStep(doc, from, to ?? from, slice) { try self.step(step) }
        return self
    }

    @discardableResult
    public func replaceWith(_ from: Int, _ to: Int, _ content: Fragment) throws -> Self {
        try replace(from, to, Slice(content, 0, 0))
    }

    @discardableResult
    public func replaceWith(_ from: Int, _ to: Int, _ node: Node) throws -> Self {
        try replace(from, to, Slice(Fragment.from(node), 0, 0))
    }

    @discardableResult
    public func replaceWith(_ from: Int, _ to: Int, _ nodes: [Node]) throws -> Self {
        try replace(from, to, Slice(Fragment.from(nodes), 0, 0))
    }

    @discardableResult
    public func delete(_ from: Int, _ to: Int) throws -> Self { try replace(from, to, .empty) }

    @discardableResult
    public func insert(_ pos: Int, _ content: Fragment) throws -> Self { try replaceWith(pos, pos, content) }

    @discardableResult
    public func insert(_ pos: Int, _ node: Node) throws -> Self { try replaceWith(pos, pos, node) }

    @discardableResult
    public func replaceRange(_ from: Int, _ to: Int, _ slice: Slice) throws -> Self {
        try PMTransform.replaceRange(self, from, to, slice)
        return self
    }

    @discardableResult
    public func replaceRangeWith(_ from: Int, _ to: Int, _ node: Node) throws -> Self {
        try PMTransform.replaceRangeWith(self, from, to, node)
        return self
    }

    @discardableResult
    public func deleteRange(_ from: Int, _ to: Int) throws -> Self {
        try PMTransform.deleteRange(self, from, to)
        return self
    }

    @discardableResult
    public func lift(_ range: NodeRange, _ target: Int) throws -> Self {
        try PMTransform.lift(self, range, target)
        return self
    }

    @discardableResult
    public func join(_ pos: Int, _ depth: Int = 1) throws -> Self {
        try PMTransform.join(self, pos, depth)
        return self
    }

    @discardableResult
    public func wrap(_ range: NodeRange, _ wrappers: [NodeTypeWithAttrs]) throws -> Self {
        try PMTransform.wrap(self, range, wrappers)
        return self
    }

    @discardableResult
    public func setBlockType(_ from: Int, _ to: Int? = nil, _ type: NodeType, _ attrs: Attrs? = nil) throws -> Self {
        try PMTransform.setBlockType(self, from, to ?? from, type, { _ in attrs })
        return self
    }

    @discardableResult
    public func setBlockType(_ from: Int, _ to: Int? = nil, _ type: NodeType, attrsFor: @escaping (Node) -> Attrs?) throws -> Self {
        try PMTransform.setBlockType(self, from, to ?? from, type, attrsFor)
        return self
    }

    @discardableResult
    public func setNodeMarkup(_ pos: Int, _ type: NodeType? = nil, _ attrs: Attrs? = nil, _ marks: [Mark]? = nil) throws -> Self {
        try PMTransform.setNodeMarkup(self, pos, type, attrs, marks)
        return self
    }

    @discardableResult
    public func setNodeAttribute(_ pos: Int, _ attr: String, _ value: JSONValue) throws -> Self {
        try step(AttrStep(pos, attr, value))
    }

    @discardableResult
    public func setDocAttribute(_ attr: String, _ value: JSONValue) throws -> Self {
        try step(DocAttrStep(attr, value))
    }

    @discardableResult
    public func addNodeMark(_ pos: Int, _ mark: Mark) throws -> Self {
        try step(AddNodeMarkStep(pos, mark))
    }

    @discardableResult
    public func removeNodeMark(_ pos: Int, _ mark: Mark) throws -> Self {
        guard let node = doc.nodeAt(pos) else { throw PMError.range("No node at position \(pos)") }
        if mark.isInSet(node.marks) { try step(RemoveNodeMarkStep(pos, mark)) }
        return self
    }

    @discardableResult
    public func removeNodeMark(_ pos: Int, _ markType: MarkType) throws -> Self {
        guard let node = doc.nodeAt(pos) else { throw PMError.range("No node at position \(pos)") }
        var set = node.marks
        var steps: [Step] = []
        while let found = markType.isInSet(set) {
            steps.append(RemoveNodeMarkStep(pos, found))
            set = found.removeFromSet(set)
        }
        for s in steps.reversed() { try step(s) }
        return self
    }

    @discardableResult
    public func split(_ pos: Int, _ depth: Int = 1, _ typesAfter: [NodeTypeWithAttrs?]? = nil) throws -> Self {
        try PMTransform.split(self, pos, depth, typesAfter)
        return self
    }

    @discardableResult
    public func addMark(_ from: Int, _ to: Int, _ mark: Mark) throws -> Self {
        try PMTransform.addMark(self, from, to, mark)
        return self
    }

    /// Remove marks from inline nodes between `from` and `to`. `mark` may be a
    /// specific mark, a mark type, or nil (all marks).
    @discardableResult
    public func removeMark(_ from: Int, _ to: Int, _ mark: Mark?) throws -> Self {
        try PMTransform.removeMark(self, from, to, mark.map(MarkMatch.mark) ?? .all)
        return self
    }

    @discardableResult
    public func removeMark(_ from: Int, _ to: Int, _ type: MarkType) throws -> Self {
        try PMTransform.removeMark(self, from, to, .type(type))
        return self
    }

    @discardableResult
    public func clearIncompatible(_ pos: Int, _ parentType: NodeType, _ match: ContentMatch? = nil) throws -> Self {
        try PMTransform.clearIncompatible(self, pos, parentType, match ?? parentType.contentMatch)
        return self
    }
}

// MARK: - mark.ts

func addMark(_ tr: Transform, _ from: Int, _ to: Int, _ mark: Mark) throws {
    var removed: [Step] = [], added: [Step] = []
    var removing: RemoveMarkStep? = nil, adding: AddMarkStep? = nil
    tr.doc.nodesBetween(from, to) { node, pos, parent, _ in
        if !node.isInline { return true }
        let marks = node.marks
        if !mark.isInSet(marks) && parent!.type.allowsMarkType(mark.type) {
            let start = max(pos, from), end = min(pos + node.nodeSize, to)
            let newSet = mark.addToSet(marks)
            for m in marks where !m.isInSet(newSet) {
                if let r = removing, r.to == start, r.mark.eq(m) {
                    r.to = end
                } else {
                    let r = RemoveMarkStep(start, end, m)
                    removing = r
                    removed.append(r)
                }
            }
            if let a = adding, a.to == start {
                a.to = end
            } else {
                let a = AddMarkStep(start, end, mark)
                adding = a
                added.append(a)
            }
        }
        return true
    }
    for s in removed { try tr.step(s) }
    for s in added { try tr.step(s) }
}

enum MarkMatch {
    case mark(Mark)
    case type(MarkType)
    case all
}

func removeMark(_ tr: Transform, _ from: Int, _ to: Int, _ mark: MarkMatch) throws {
    final class Matched {
        let style: Mark
        let from: Int
        var to: Int
        var step: Int
        init(_ style: Mark, _ from: Int, _ to: Int, _ step: Int) { self.style = style; self.from = from; self.to = to; self.step = step }
    }
    var matched: [Matched] = []
    var step = 0
    tr.doc.nodesBetween(from, to) { node, pos, _, _ in
        if !node.isInline { return true }
        step += 1
        var toRemove: [Mark]? = nil
        switch mark {
        case .type(let type):
            var set = node.marks
            while let found = type.isInSet(set) {
                toRemove = (toRemove ?? []) + [found]
                set = found.removeFromSet(set)
            }
        case .mark(let m):
            if m.isInSet(node.marks) { toRemove = [m] }
        case .all:
            toRemove = node.marks
        }
        if let toRemove, !toRemove.isEmpty {
            let end = min(pos + node.nodeSize, to)
            for style in toRemove {
                var found: Matched? = nil
                for m in matched where m.step == step - 1 && style.eq(m.style) { found = m }
                if let found {
                    found.to = end
                    found.step = step
                } else {
                    matched.append(Matched(style, max(pos, from), end, step))
                }
            }
        }
        return true
    }
    for m in matched { try tr.step(RemoveMarkStep(m.from, m.to, m.style)) }
}

/// Matches `/\r?\n|\r/g` over UTF-16 units; returns (index, length) pairs.
func newlineMatches(_ units: [UInt16]) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    var i = 0
    while i < units.count {
        if units[i] == 13 {
            if i + 1 < units.count && units[i + 1] == 10 { result.append((i, 2)); i += 2; continue }
            result.append((i, 1))
        } else if units[i] == 10 {
            result.append((i, 1))
        }
        i += 1
    }
    return result
}

func clearIncompatible(_ tr: Transform, _ pos: Int, _ parentType: NodeType, _ match: ContentMatch, _ clearNewlines: Bool = true) throws {
    var match = match
    let node = tr.doc.nodeAt(pos)!
    var replSteps: [Step] = []
    var cur = pos + 1
    for i in 0..<node.childCount {
        let child = node.child(i), end = cur + child.nodeSize
        if let allowed = match.matchType(child.type) {
            match = allowed
            for m in child.marks where !parentType.allowsMarkType(m.type) {
                try tr.step(RemoveMarkStep(cur, end, m))
            }
            if clearNewlines, let text = child as? TextNode, parentType.whitespace != "pre" {
                var slice: Slice? = nil
                for (index, length) in newlineMatches(text.units) {
                    if slice == nil {
                        slice = Slice(Fragment.from(parentType.schema.text(" ", parentType.allowedMarks(child.marks))), 0, 0)
                    }
                    replSteps.append(ReplaceStep(cur + index, cur + index + length, slice!))
                }
            }
        } else {
            replSteps.append(ReplaceStep(cur, end, .empty))
        }
        cur = end
    }
    if !match.validEnd {
        let fill = try unwrap(match.fillBefore(.empty, toEnd: true))
        try tr.replace(cur, cur, Slice(fill, 0, 0))
    }
    for s in replSteps.reversed() { try tr.step(s) }
}
