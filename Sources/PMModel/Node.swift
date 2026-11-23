// Port of prosemirror-model/src/node.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

/// A node in a ProseMirror document. Persistent: never mutate.
///
/// Positions count UTF-16 code units in text, exactly like JS ProseMirror.
public class Node: CustomStringConvertible {
    public let type: NodeType
    public let attrs: Attrs
    public let content: Fragment
    public let marks: [Mark]
    // Small ring buffer of recently resolved positions (JS uses a WeakMap).
    var resolveCache: [ResolvedPos] = []
    var resolveCacheIndex = 0

    init(type: NodeType, attrs: Attrs, content: Fragment = .empty, marks: [Mark] = Mark.none) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.marks = marks
    }

    public var children: [Node] { content.content }

    /// Text content for text nodes, nil otherwise.
    public var text: String? { nil }

    public var nodeSize: Int { isLeaf ? 1 : 2 + content.size }
    public var childCount: Int { content.childCount }
    public func child(_ index: Int) -> Node { content.child(index) }
    public func maybeChild(_ index: Int) -> Node? { content.maybeChild(index) }
    public func forEach(_ f: (Node, Int, Int) -> Void) { content.forEach(f) }

    /// Calls `f` for all descendants between `from` and `to`. Return false to skip children.
    public func nodesBetween(_ from: Int, _ to: Int, startPos: Int = 0, _ f: (Node, Int, Node?, Int) -> Bool) {
        content.nodesBetween(from, to, nodeStart: startPos, parent: self, f)
    }

    public func descendants(_ f: (Node, Int, Node?, Int) -> Bool) {
        nodesBetween(0, content.size, f)
    }

    public var textContent: String {
        if isLeaf, let fn = type.spec.leafText { return fn(self) }
        return textBetween(0, content.size, blockSeparator: "")
    }

    public func textBetween(_ from: Int, _ to: Int, blockSeparator: String? = nil, leafText: String? = nil) -> String {
        content.textBetween(from, to, blockSeparator: blockSeparator, leafText: leafText)
    }

    public var firstChild: Node? { content.firstChild }
    public var lastChild: Node? { content.lastChild }

    public func eq(_ other: Node) -> Bool {
        self === other || (sameMarkup(other) && content.eq(other.content))
    }

    public func sameMarkup(_ other: Node) -> Bool {
        hasMarkup(other.type, other.attrs, other.marks)
    }

    public func hasMarkup(_ type: NodeType, _ attrs: Attrs? = nil, _ marks: [Mark]? = nil) -> Bool {
        self.type === type && self.attrs == (attrs ?? type.defaultAttrs ?? Attrs()) && Mark.sameSet(self.marks, marks ?? Mark.none)
    }

    /// Create a new node with the same markup as this node, containing the given content.
    public func copy(_ content: Fragment? = nil) -> Node {
        let content = content ?? .empty
        if content === self.content { return self }
        return Node(type: type, attrs: attrs, content: content, marks: marks)
    }

    public func mark(_ marks: [Mark]) -> Node {
        Node(type: type, attrs: attrs, content: content, marks: marks)
    }

    public func cut(_ from: Int, _ to: Int? = nil) -> Node {
        let to = to ?? content.size
        if from == 0 && to == content.size { return self }
        return copy(content.cut(from, to))
    }

    public func slice(_ from: Int, _ to: Int? = nil, includeParents: Bool = false) -> Slice {
        let to = to ?? content.size
        if from == to { return .empty }
        let rFrom = resolve(from), rTo = resolve(to)
        let depth = includeParents ? 0 : rFrom.sharedDepth(to)
        let start = rFrom.start(depth), node = rFrom.node(depth)
        let content = node.content.cut(rFrom.pos - start, rTo.pos - start)
        return Slice(content, rFrom.depth - depth, rTo.depth - depth)
    }

    /// Replace the part of the document between the given positions with the given slice.
    public func replace(_ from: Int, _ to: Int, _ slice: Slice) throws -> Node {
        try PMModel.replace(resolve(from), resolve(to), slice)
    }

    public func nodeAt(_ pos: Int) -> Node? {
        var node: Node = self
        var pos = pos
        while true {
            let (index, offset) = node.content.findIndex(pos)
            guard let child = node.maybeChild(index) else { return nil }
            if offset == pos || child.isText { return child }
            pos -= offset + 1
            node = child
        }
    }

    public func childAfter(_ pos: Int) -> (node: Node?, index: Int, offset: Int) {
        let (index, offset) = content.findIndex(pos)
        return (content.maybeChild(index), index, offset)
    }

    public func childBefore(_ pos: Int) -> (node: Node?, index: Int, offset: Int) {
        if pos == 0 { return (nil, 0, 0) }
        let (index, offset) = content.findIndex(pos)
        if offset < pos { return (content.child(index), index, offset) }
        let node = content.child(index - 1)
        return (node, index - 1, offset - node.nodeSize)
    }

    public func resolve(_ pos: Int) -> ResolvedPos { ResolvedPos.resolveCached(self, pos) }
    public func resolveNoCache(_ pos: Int) -> ResolvedPos { ResolvedPos.resolve(self, pos) }

    /// `resolve`, throwing (JS's `RangeError`) instead of trapping when `pos` is outside the
    /// document: for positions from untrusted JSON.
    public func resolveChecked(_ pos: Int) throws -> ResolvedPos {
        guard pos >= 0 && pos <= content.size else { throw PMError.range("Position \(pos) out of range") }
        return resolve(pos)
    }

    public func rangeHasMark(_ from: Int, _ to: Int, _ type: MarkType) -> Bool {
        var found = false
        if to > from {
            nodesBetween(from, to) { node, _, _, _ in
                if type.isInSet(node.marks) != nil { found = true }
                return !found
            }
        }
        return found
    }

    public func rangeHasMark(_ from: Int, _ to: Int, _ mark: Mark) -> Bool {
        var found = false
        if to > from {
            nodesBetween(from, to) { node, _, _, _ in
                if mark.isInSet(node.marks) { found = true }
                return !found
            }
        }
        return found
    }

    public var isBlock: Bool { type.isBlock }
    public var isTextblock: Bool { type.isTextblock }
    public var inlineContent: Bool { type.inlineContent }
    public var isInline: Bool { type.isInline }
    public var isText: Bool { type.isText }
    public var isLeaf: Bool { type.isLeaf }
    public var isAtom: Bool { type.isAtom }

    public var description: String {
        if let fn = type.spec.toDebugString { return fn(self) }
        var name = type.name
        if content.size > 0 { name += "(" + content.toStringInner() + ")" }
        return wrapMarks(marks, name)
    }

    /// Like `contentMatchAt`, but throws (as JS does) instead of trapping when the content is invalid.
    public func checkedContentMatchAt(_ index: Int) throws -> ContentMatch {
        guard let match = type.contentMatch.matchFragment(content, start: 0, end: index) else {
            throw PMError.generic("Called contentMatchAt on a node with invalid content")
        }
        return match
    }

    public func contentMatchAt(_ index: Int) -> ContentMatch {
        guard let match = type.contentMatch.matchFragment(content, start: 0, end: index) else {
            preconditionFailure("Called contentMatchAt on a node with invalid content")
        }
        return match
    }

    public func canReplace(_ from: Int, _ to: Int, _ replacement: Fragment = .empty, start: Int = 0, end: Int? = nil) -> Bool {
        let end = end ?? replacement.childCount
        let one = contentMatchAt(from).matchFragment(replacement, start: start, end: end)
        guard let two = one?.matchFragment(content, start: to), two.validEnd else { return false }
        for i in start..<max(start, end) where !type.allowsMarks(replacement.child(i).marks) { return false }
        return true
    }

    public func canReplaceWith(_ from: Int, _ to: Int, _ type: NodeType, _ marks: [Mark]? = nil) -> Bool {
        if let marks, !self.type.allowsMarks(marks) { return false }
        guard let start = contentMatchAt(from).matchType(type), let end = start.matchFragment(content, start: to) else { return false }
        return end.validEnd
    }

    public func canAppend(_ other: Node) -> Bool {
        if other.content.size > 0 { return canReplace(childCount, childCount, other.content) }
        return type.compatibleContent(other.type)
    }

    /// Check whether this node and its descendants conform to the schema; throws otherwise.
    public func check() throws {
        try type.checkContent(content)
        try type.checkAttrs(attrs)
        var copy = Mark.none
        for mark in marks {
            try mark.type.checkAttrs(mark.attrs)
            copy = mark.addToSet(copy)
        }
        if !Mark.sameSet(copy, marks) {
            throw PMError.range("Invalid collection of marks for node \(type.name): \(marks.map(\.type.name).joined(separator: ","))")
        }
        for child in content.content { try child.check() }
    }

    public func toJSON() -> JSONValue {
        var obj = JSONObject()
        obj["type"] = .string(type.name)
        if !attrs.isEmpty { obj["attrs"] = .object(attrs) }
        if content.size > 0, let c = content.toJSON() { obj["content"] = c }
        if !marks.isEmpty { obj["marks"] = .array(marks.map { $0.toJSON() }) }
        return .object(obj)
    }

    public static func fromJSON(_ schema: Schema, _ json: JSONValue) throws -> Node {
        try fromJSON(schema, json, depth: 0)
    }

    /// `depth` counts enclosing nodes, so hostile JSON nested thousands deep throws instead of
    /// overflowing the stack.
    static func fromJSON(_ schema: Schema, _ json: JSONValue, depth: Int) throws -> Node {
        guard case .object = json else { throw PMError.range("Invalid input for Node.fromJSON") }
        if depth > JSONValue.maxNestingDepth { throw PMError.range("Node JSON nested too deeply") }
        if let attrs = json["attrs"], attrs.nestingExceeds(JSONValue.maxNestingDepth) {
            throw PMError.range("Node attrs nested too deeply")
        }
        var marks: [Mark]? = nil
        if let m = json["marks"], m.truthy {
            guard let arr = m.arrayValue else { throw PMError.range("Invalid mark data for Node.fromJSON") }
            marks = try arr.map { try schema.markFromJSON($0) }
        }
        if json["type"]?.stringValue == "text" {
            guard let text = json["text"]?.stringValue else { throw PMError.range("Invalid text node in JSON") }
            if text.isEmpty { throw PMError.range("Empty text nodes are not allowed") }
            return schema.text(text, marks)
        }
        let content = try Fragment.fromJSON(schema, json["content"], depth: depth + 1)
        let typeName: String
        switch json["type"] {
        case .string(let s)?: typeName = s
        case nil: typeName = "undefined"
        case let v?: typeName = v.description
        }
        let node = try schema.nodeType(typeName).create(json["attrs"]?.objectValue, content, marks)
        try node.type.checkAttrs(node.attrs)
        return node
    }
}

/// A text node. Text is stored as UTF-16 code units so positions and slicing
/// match JS exactly (including split surrogate pairs).
public final class TextNode: Node {
    public let units: [UInt16]

    init(type: NodeType, attrs: Attrs, units: [UInt16], marks: [Mark]) {
        precondition(!units.isEmpty, "Empty text nodes are not allowed")
        self.units = units
        super.init(type: type, attrs: attrs, content: .empty, marks: marks)
    }

    public override var text: String? { String(decoding: units, as: UTF16.self) }
    public var string: String { String(decoding: units, as: UTF16.self) }

    public override var description: String {
        if let fn = type.spec.toDebugString { return fn(self) }
        return wrapMarks(marks, JSONValue.string(string).description)
    }

    public override var textContent: String { string }

    public override func textBetween(_ from: Int, _ to: Int, blockSeparator: String? = nil, leafText: String? = nil) -> String {
        slice(from, to)
    }

    /// JS `text.slice(from, to)` on UTF-16 units.
    func slice(_ from: Int, _ to: Int) -> String {
        let n = units.count
        let a = max(0, min(from, n)), b = max(a, min(to, n))
        return String(decoding: units[a..<b], as: UTF16.self)
    }

    public override var nodeSize: Int { units.count }

    public override func mark(_ marks: [Mark]) -> Node {
        TextNode(type: type, attrs: attrs, units: units, marks: marks)
    }

    public func withText(_ text: String) -> TextNode { withUnits(Array(text.utf16)) }

    public func withUnits(_ units: [UInt16]) -> TextNode {
        if units == self.units { return self }
        return TextNode(type: type, attrs: attrs, units: units, marks: marks)
    }

    public override func cut(_ from: Int, _ to: Int? = nil) -> Node {
        cutText(from, to)
    }

    public func cutText(_ from: Int = 0, _ to: Int? = nil) -> TextNode {
        let to = to ?? units.count
        if from == 0 && to == units.count { return self }
        let a = max(0, min(from, units.count)), b = max(a, min(to, units.count))
        return withUnits(Array(units[a..<b]))
    }

    public override func eq(_ other: Node) -> Bool {
        sameMarkup(other) && units == (other as? TextNode)?.units
    }

    public override func toJSON() -> JSONValue {
        guard case .object(var obj) = super.toJSON() else { fatalError() }
        obj["text"] = .string(string)
        return .object(obj)
    }
}

private func wrapMarks(_ marks: [Mark], _ str: String) -> String {
    var str = str
    for mark in marks.reversed() { str = mark.type.name + "(" + str + ")" }
    return str
}
