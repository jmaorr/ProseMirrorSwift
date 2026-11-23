// Port of prosemirror-state/src/selection.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import PMModel
import PMTransform

public struct SelectionRange {
    public let from: ResolvedPos
    public let to: ResolvedPos
    public init(_ from: ResolvedPos, _ to: ResolvedPos) {
        self.from = from
        self.to = to
    }
}

/// Superclass for editor selections.
open class Selection {
    public let anchorPos: ResolvedPos
    public let headPos: ResolvedPos
    public let ranges: [SelectionRange]

    public init(_ anchor: ResolvedPos, _ head: ResolvedPos, ranges: [SelectionRange]? = nil) {
        anchorPos = anchor
        headPos = head
        self.ranges = ranges ?? [SelectionRange(anchor.min(head), anchor.max(head))]
    }

    public var anchor: Int { anchorPos.pos }
    public var head: Int { headPos.pos }
    public var from: Int { fromPos.pos }
    public var to: Int { toPos.pos }
    /// `$from` in JS.
    public var fromPos: ResolvedPos { ranges[0].from }
    /// `$to` in JS.
    public var toPos: ResolvedPos { ranges[0].to }

    public var empty: Bool { ranges.allSatisfy { $0.from.pos == $0.to.pos } }

    /// The cursor position if this is an empty text selection (`$cursor` in JS), nil otherwise.
    open var cursor: ResolvedPos? { nil }

    /// Whether the selection is drawn by the view (false for node selections).
    open var visible: Bool { true }

    open func eq(_ other: Selection) -> Bool { fatalError("abstract") }
    open func map(_ doc: Node, _ mapping: Mappable) -> Selection { fatalError("abstract") }
    open func toJSON() -> JSONValue { fatalError("abstract") }

    open func content() -> Slice {
        fromPos.doc.slice(from, to, includeParents: true)
    }

    /// Replace the selection with a slice or, if no slice is given, delete the selection.
    open func replace(_ tr: Transaction, _ content: Slice = .empty) throws {
        var lastNode = content.content.lastChild
        var lastParent: Node? = nil
        for _ in 0..<content.openEnd {
            lastParent = lastNode
            lastNode = lastNode?.lastChild
        }
        let mapFrom = tr.steps.count
        for (i, range) in ranges.enumerated() {
            let mapping = tr.mapping.slice(mapFrom)
            try tr.replaceRange(mapping.map(range.from.pos), mapping.map(range.to.pos), i > 0 ? .empty : content)
            if i == 0 {
                let inlineEnd = lastNode.map { $0.isInline } ?? (lastParent?.isTextblock ?? false)
                selectionToInsertionEnd(tr, mapFrom, inlineEnd ? -1 : 1)
            }
        }
    }

    open func replaceWith(_ tr: Transaction, _ node: Node) throws {
        let mapFrom = tr.steps.count
        for (i, range) in ranges.enumerated() {
            let mapping = tr.mapping.slice(mapFrom)
            let from = mapping.map(range.from.pos), to = mapping.map(range.to.pos)
            if i > 0 {
                try tr.deleteRange(from, to)
            } else {
                try tr.replaceRangeWith(from, to, node)
                selectionToInsertionEnd(tr, mapFrom, node.isInline ? -1 : 1)
            }
        }
    }

    open func getBookmark() -> SelectionBookmark {
        TextSelection.between(anchorPos, headPos).getBookmark()
    }

    // MARK: Static helpers

    public static func findFrom(_ pos: ResolvedPos, _ dir: Int, textOnly: Bool = false) -> Selection? {
        let inner: Selection? = pos.parent.inlineContent ? TextSelection(pos)
            : findSelectionIn(pos.node(0), pos.parent, pos.pos, pos.index(), dir, textOnly)
        if let inner { return inner }
        var depth = pos.depth - 1
        while depth >= 0 {
            let found = dir < 0
                ? findSelectionIn(pos.node(0), pos.node(depth), pos.before(depth + 1), pos.index(depth), dir, textOnly)
                : findSelectionIn(pos.node(0), pos.node(depth), pos.after(depth + 1), pos.index(depth) + 1, dir, textOnly)
            if let found { return found }
            depth -= 1
        }
        return nil
    }

    public static func near(_ pos: ResolvedPos, _ bias: Int = 1) -> Selection {
        findFrom(pos, bias) ?? findFrom(pos, -bias) ?? AllSelection(pos.node(0))
    }

    public static func atStart(_ doc: Node) -> Selection {
        findSelectionIn(doc, doc, 0, 0, 1) ?? AllSelection(doc)
    }

    public static func atEnd(_ doc: Node) -> Selection {
        findSelectionIn(doc, doc, doc.content.size, doc.childCount, -1) ?? AllSelection(doc)
    }

    nonisolated(unsafe) private static var classesById: [String: (Node, JSONValue) throws -> Selection] = [
        "text": TextSelection.decode,
        "node": NodeSelection.decode,
        "all": { doc, _ in AllSelection(doc) },
    ]

    public static func fromJSON(_ doc: Node, _ json: JSONValue) throws -> Selection {
        guard let type = json["type"]?.stringValue else { throw PMError.range("Invalid input for Selection.fromJSON") }
        guard let cls = classesById[type] else { throw PMError.range("No selection type \(type) defined") }
        return try cls(doc, json)
    }

    public static func jsonID(_ id: String, _ fromJSON: @escaping (Node, JSONValue) throws -> Selection) throws {
        if classesById[id] != nil { throw PMError.range("Duplicate use of selection JSON ID \(id)") }
        classesById[id] = fromJSON
    }
}

/// A lightweight, document-independent representation of a selection.
public protocol SelectionBookmark {
    func map(_ mapping: Mappable) -> SelectionBookmark
    func resolve(_ doc: Node) -> Selection
}

/// A text selection represents a classical editor selection, with a head and an anchor.
open class TextSelection: Selection {
    public init(_ anchor: ResolvedPos, _ head: ResolvedPos? = nil) {
        super.init(anchor, head ?? anchor)
    }

    open override var cursor: ResolvedPos? { anchorPos.pos == headPos.pos ? headPos : nil }

    open override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let head = doc.resolve(mapping.map(self.head))
        if !head.parent.inlineContent { return Selection.near(head) }
        let anchor = doc.resolve(mapping.map(self.anchor))
        return TextSelection(anchor.parent.inlineContent ? anchor : head, head)
    }

    open override func replace(_ tr: Transaction, _ content: Slice = .empty) throws {
        try super.replace(tr, content)
        if content === Slice.empty {
            if let marks = fromPos.marksAcross(toPos) { tr.ensureMarks(marks) }
        }
    }

    open override func eq(_ other: Selection) -> Bool {
        guard let other = other as? TextSelection else { return false }
        return other.anchor == anchor && other.head == head
    }

    open override func getBookmark() -> SelectionBookmark { TextBookmark(anchor: anchor, head: head) }

    open override func toJSON() -> JSONValue {
        .object(JSONObject([("type", "text"), ("anchor", .number(Double(anchor))), ("head", .number(Double(head)))]))
    }

    static func decode(_ doc: Node, _ json: JSONValue) throws -> Selection {
        guard let a = json["anchor"]?.numberValue.flatMap(JSONValue.truncatedInt),
              let h = json["head"]?.numberValue.flatMap(JSONValue.truncatedInt) else {
            throw PMError.range("Invalid input for TextSelection.fromJSON")
        }
        return TextSelection(try doc.resolveChecked(a), try doc.resolveChecked(h))
    }

    public static func create(_ doc: Node, _ anchor: Int, _ head: Int? = nil) -> TextSelection {
        let rAnchor = doc.resolve(anchor)
        return TextSelection(rAnchor, head == nil || head == anchor ? rAnchor : doc.resolve(head!))
    }

    /// Return a text selection that spans the given positions or, if they
    /// aren't text positions, find a text selection near them.
    public static func between(_ anchor: ResolvedPos, _ head: ResolvedPos, _ bias: Int? = nil) -> Selection {
        var anchor = anchor, head = head
        let dPos = anchor.pos - head.pos
        var bias = bias ?? 0
        if bias == 0 || dPos != 0 { bias = dPos >= 0 ? 1 : -1 }
        if !head.parent.inlineContent {
            if let found = Selection.findFrom(head, bias, textOnly: true) ?? Selection.findFrom(head, -bias, textOnly: true) {
                head = found.headPos
            } else {
                return Selection.near(head, bias)
            }
        }
        if !anchor.parent.inlineContent {
            if dPos == 0 {
                anchor = head
            } else {
                anchor = (Selection.findFrom(anchor, -bias, textOnly: true) ?? Selection.findFrom(anchor, bias, textOnly: true))!.anchorPos
                if (anchor.pos < head.pos) != (dPos < 0) { anchor = head }
            }
        }
        return TextSelection(anchor, head)
    }
}

struct TextBookmark: SelectionBookmark {
    let anchor: Int
    let head: Int
    func map(_ mapping: Mappable) -> SelectionBookmark { TextBookmark(anchor: mapping.map(anchor), head: mapping.map(head)) }
    func resolve(_ doc: Node) -> Selection { TextSelection.between(doc.resolve(anchor), doc.resolve(head)) }
}

/// A node selection is a selection that points at a single node.
open class NodeSelection: Selection {
    public let node: Node

    public init(_ pos: ResolvedPos) {
        let node = pos.nodeAfter!
        let end = pos.node(0).resolve(pos.pos + node.nodeSize)
        self.node = node
        super.init(pos, end)
    }

    open override var visible: Bool { false }

    open override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let result = mapping.mapResult(anchor)
        let pos = doc.resolve(result.pos)
        if result.deleted { return Selection.near(pos) }
        return NodeSelection(pos)
    }

    open override func content() -> Slice { Slice(Fragment.from(node), 0, 0) }

    open override func eq(_ other: Selection) -> Bool {
        guard let other = other as? NodeSelection else { return false }
        return other.anchor == anchor
    }

    open override func toJSON() -> JSONValue {
        .object(JSONObject([("type", "node"), ("anchor", .number(Double(anchor)))]))
    }

    open override func getBookmark() -> SelectionBookmark { NodeBookmark(anchor: anchor) }

    static func decode(_ doc: Node, _ json: JSONValue) throws -> Selection {
        guard let a = json["anchor"]?.numberValue.flatMap(JSONValue.truncatedInt) else {
            throw PMError.range("Invalid input for NodeSelection.fromJSON")
        }
        let pos = try doc.resolveChecked(a)
        guard pos.nodeAfter != nil else { throw PMError.range("Invalid input for NodeSelection.fromJSON") }
        return NodeSelection(pos)
    }

    public static func create(_ doc: Node, _ from: Int) -> NodeSelection { NodeSelection(doc.resolve(from)) }

    public static func isSelectable(_ node: Node) -> Bool {
        !node.isText && node.type.spec.selectable != false
    }
}

struct NodeBookmark: SelectionBookmark {
    let anchor: Int
    func map(_ mapping: Mappable) -> SelectionBookmark {
        let r = mapping.mapResult(anchor)
        return r.deleted ? TextBookmark(anchor: r.pos, head: r.pos) : NodeBookmark(anchor: r.pos)
    }
    func resolve(_ doc: Node) -> Selection {
        let pos = doc.resolve(anchor)
        if let node = pos.nodeAfter, NodeSelection.isSelectable(node) { return NodeSelection(pos) }
        return Selection.near(pos)
    }
}

/// A selection type that represents selecting the whole document.
open class AllSelection: Selection {
    public init(_ doc: Node) {
        super.init(doc.resolve(0), doc.resolve(doc.content.size))
    }

    open override func replace(_ tr: Transaction, _ content: Slice = .empty) throws {
        if content === Slice.empty {
            try tr.delete(0, tr.doc.content.size)
            let sel = Selection.atStart(tr.doc)
            if !sel.eq(tr.selection) { tr.setSelection(sel) }
        } else {
            try super.replace(tr, content)
        }
    }

    open override func toJSON() -> JSONValue { .object(JSONObject([("type", "all")])) }
    open override func map(_ doc: Node, _ mapping: Mappable) -> Selection { AllSelection(doc) }
    open override func eq(_ other: Selection) -> Bool { other is AllSelection }
    open override func getBookmark() -> SelectionBookmark { AllBookmark() }
}

struct AllBookmark: SelectionBookmark {
    func map(_ mapping: Mappable) -> SelectionBookmark { self }
    func resolve(_ doc: Node) -> Selection { AllSelection(doc) }
}

private func findSelectionIn(_ doc: Node, _ node: Node, _ pos: Int, _ index: Int, _ dir: Int, _ text: Bool = false) -> Selection? {
    if node.inlineContent { return TextSelection.create(doc, pos) }
    var pos = pos
    var i = index - (dir > 0 ? 0 : 1)
    while dir > 0 ? i < node.childCount : i >= 0 {
        let child = node.child(i)
        if !child.isAtom {
            if let inner = findSelectionIn(doc, child, pos + dir, dir < 0 ? child.childCount : 0, dir, text) { return inner }
        } else if !text && NodeSelection.isSelectable(child) {
            return NodeSelection.create(doc, pos - (dir < 0 ? child.nodeSize : 0))
        }
        pos += child.nodeSize * dir
        i += dir
    }
    return nil
}

func selectionToInsertionEnd(_ tr: Transaction, _ startLen: Int, _ bias: Int) {
    let last = tr.steps.count - 1
    if last < startLen { return }
    let step = tr.steps[last]
    if !(step is ReplaceStep || step is ReplaceAroundStep) { return }
    let map = tr.mapping.maps[last]
    var end: Int? = nil
    map.forEach { _, _, _, newTo in if end == nil { end = newTo } }
    tr.setSelection(Selection.near(tr.doc.resolve(end!), bias))
}
