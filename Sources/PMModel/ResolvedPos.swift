// Port of prosemirror-model/src/resolvedpos.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

/// A position in a document resolved to its context (parents, indices, offsets).
public final class ResolvedPos: CustomStringConvertible {
    public let pos: Int
    let path: [(node: Node, index: Int, offset: Int)]
    public let parentOffset: Int
    public let depth: Int

    init(pos: Int, path: [(node: Node, index: Int, offset: Int)], parentOffset: Int) {
        self.pos = pos
        self.path = path
        self.parentOffset = parentOffset
        depth = path.count - 1
    }

    func resolveDepth(_ val: Int?) -> Int {
        guard let val else { return depth }
        return val < 0 ? depth + val : val
    }

    public var parent: Node { node(depth) }
    public var doc: Node { node(0) }

    public func node(_ depth: Int? = nil) -> Node { path[resolveDepth(depth)].node }
    public func index(_ depth: Int? = nil) -> Int { path[resolveDepth(depth)].index }

    public func indexAfter(_ depth: Int? = nil) -> Int {
        let depth = resolveDepth(depth)
        return index(depth) + (depth == self.depth && textOffset == 0 ? 0 : 1)
    }

    public func start(_ depth: Int? = nil) -> Int {
        let depth = resolveDepth(depth)
        return depth == 0 ? 0 : path[depth - 1].offset + 1
    }

    public func end(_ depth: Int? = nil) -> Int {
        let depth = resolveDepth(depth)
        return start(depth) + node(depth).content.size
    }

    public func before(_ depth: Int? = nil) -> Int {
        let depth = resolveDepth(depth)
        precondition(depth != 0, "There is no position before the top-level node")
        return depth == self.depth + 1 ? pos : path[depth - 1].offset
    }

    public func after(_ depth: Int? = nil) -> Int {
        let depth = resolveDepth(depth)
        precondition(depth != 0, "There is no position after the top-level node")
        return depth == self.depth + 1 ? pos : path[depth - 1].offset + path[depth].node.nodeSize
    }

    public var textOffset: Int { pos - path[path.count - 1].offset }

    public var nodeAfter: Node? {
        let parent = self.parent, index = self.index(depth)
        if index == parent.childCount { return nil }
        let dOff = pos - path[path.count - 1].offset
        let child = parent.child(index)
        return dOff > 0 ? child.cut(dOff) : child
    }

    public var nodeBefore: Node? {
        let index = self.index(depth)
        let dOff = pos - path[path.count - 1].offset
        if dOff > 0 { return parent.child(index).cut(0, dOff) }
        return index == 0 ? nil : parent.child(index - 1)
    }

    public func posAtIndex(_ index: Int, _ depth: Int? = nil) -> Int {
        let depth = resolveDepth(depth)
        let node = path[depth].node
        var pos = depth == 0 ? 0 : path[depth - 1].offset + 1
        for i in 0..<index { pos += node.child(i).nodeSize }
        return pos
    }

    /// The marks at this position, factoring in surrounding marks' `inclusive` property.
    public func marks() -> [Mark] {
        let parent = self.parent, index = self.index()
        if parent.content.size == 0 { return Mark.none }
        if textOffset > 0 { return parent.child(index).marks }
        var main = parent.maybeChild(index - 1), other = parent.maybeChild(index)
        if main == nil { swap(&main, &other) }
        var marks = main!.marks
        var i = 0
        while i < marks.count {
            if marks[i].type.spec.inclusive == false && (other == nil || !marks[i].isInSet(other!.marks)) {
                marks = marks[i].removeFromSet(marks)
            } else {
                i += 1
            }
        }
        return marks
    }

    /// The marks after the current position, if any, except those that are
    /// non-inclusive and not present at position `end`.
    public func marksAcross(_ end: ResolvedPos) -> [Mark]? {
        guard let after = parent.maybeChild(index()), after.isInline else { return nil }
        var marks = after.marks
        let next = end.parent.maybeChild(end.index())
        var i = 0
        while i < marks.count {
            if marks[i].type.spec.inclusive == false && (next == nil || !marks[i].isInSet(next!.marks)) {
                marks = marks[i].removeFromSet(marks)
            } else {
                i += 1
            }
        }
        return marks
    }

    public func sharedDepth(_ pos: Int) -> Int {
        var depth = self.depth
        while depth > 0 {
            if start(depth) <= pos && end(depth) >= pos { return depth }
            depth -= 1
        }
        return 0
    }

    public func blockRange(_ other: ResolvedPos? = nil, _ pred: ((Node) -> Bool)? = nil) -> NodeRange? {
        let other = other ?? self
        if other.pos < pos { return other.blockRange(self) }
        var d = depth - (parent.inlineContent || pos == other.pos ? 1 : 0)
        while d >= 0 {
            if other.pos <= end(d) && (pred == nil || pred!(node(d))) { return NodeRange(self, other, d) }
            d -= 1
        }
        return nil
    }

    public func sameParent(_ other: ResolvedPos) -> Bool {
        pos - parentOffset == other.pos - other.parentOffset
    }

    public func max(_ other: ResolvedPos) -> ResolvedPos { other.pos > pos ? other : self }
    public func min(_ other: ResolvedPos) -> ResolvedPos { other.pos < pos ? other : self }

    public var description: String {
        var str = ""
        if depth >= 1 {
            for i in 1...depth { str += (str.isEmpty ? "" : "/") + node(i).type.name + "_" + String(index(i - 1)) }
        }
        return str + ":" + String(parentOffset)
    }

    static func resolve(_ doc: Node, _ pos: Int) -> ResolvedPos {
        precondition(pos >= 0 && pos <= doc.content.size, "Position \(pos) out of range")
        var path: [(node: Node, index: Int, offset: Int)] = []
        var start = 0, parentOffset = pos
        var node = doc
        while true {
            let (index, offset) = node.content.findIndex(parentOffset)
            let rem = parentOffset - offset
            path.append((node, index, start + offset))
            if rem == 0 { break }
            node = node.child(index)
            if node.isText { break }
            parentOffset = rem - 1
            start += offset + 1
        }
        return ResolvedPos(pos: pos, path: path, parentOffset: parentOffset)
    }

    static let resolveCacheSize = 12

    static func resolveCached(_ doc: Node, _ pos: Int) -> ResolvedPos {
        for elt in doc.resolveCache where elt.pos == pos { return elt }
        let result = resolve(doc, pos)
        if doc.resolveCache.count < resolveCacheSize {
            doc.resolveCache.append(result)
        } else {
            doc.resolveCache[doc.resolveCacheIndex] = result
        }
        doc.resolveCacheIndex = (doc.resolveCacheIndex + 1) % resolveCacheSize
        return result
    }
}

/// A range of content along a flat sequence of nodes at some depth.
public final class NodeRange {
    public let from: ResolvedPos
    public let to: ResolvedPos
    public let depth: Int

    public init(_ from: ResolvedPos, _ to: ResolvedPos, _ depth: Int) {
        self.from = from
        self.to = to
        self.depth = depth
    }

    public var start: Int { from.before(depth + 1) }
    public var end: Int { to.after(depth + 1) }
    public var parent: Node { from.node(depth) }
    public var startIndex: Int { from.index(depth) }
    public var endIndex: Int { to.indexAfter(depth) }
}
