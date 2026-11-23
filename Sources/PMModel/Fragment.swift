// Port of prosemirror-model/src/fragment.ts and diff.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

/// A fragment represents a node's collection of child nodes. Persistent:
/// never mutate.
public final class Fragment: CustomStringConvertible {
    public let content: [Node]
    public let size: Int

    init(_ content: [Node], size: Int? = nil) {
        self.content = content
        self.size = size ?? content.reduce(0) { $0 + $1.nodeSize }
    }

    public static let empty = Fragment([], size: 0)

    /// Invoke a callback for all descendant nodes between the given two
    /// positions (relative to start of this fragment). Return false from the
    /// callback to skip a node's children.
    public func nodesBetween(_ from: Int, _ to: Int, nodeStart: Int = 0, parent: Node? = nil,
                             _ f: (Node, Int, Node?, Int) -> Bool) {
        var i = 0, pos = 0
        while pos < to {
            let child = content[i]
            let end = pos + child.nodeSize
            if end > from && f(child, nodeStart + pos, parent, i) && child.content.size > 0 {
                let start = pos + 1
                child.nodesBetween(max(0, from - start), min(child.content.size, to - start), startPos: nodeStart + start, f)
            }
            pos = end
            i += 1
        }
    }

    public func descendants(_ f: (Node, Int, Node?, Int) -> Bool) {
        nodesBetween(0, size, f)
    }

    public func textBetween(_ from: Int, _ to: Int, blockSeparator: String? = nil, leafText: String? = nil,
                            leafTextFn: ((Node) -> String)? = nil) -> String {
        var text = ""
        var first = true
        nodesBetween(from, to) { node, pos, _, _ in
            let nodeText: String
            if let t = node as? TextNode {
                nodeText = t.slice(max(from, pos) - pos, to - pos)
            } else if !node.isLeaf {
                nodeText = ""
            } else if let leafTextFn {
                nodeText = leafTextFn(node)
            } else if let leafText, !leafText.isEmpty {
                nodeText = leafText
            } else if let specFn = node.type.spec.leafText {
                nodeText = specFn(node)
            } else {
                nodeText = ""
            }
            if node.isBlock && (node.isLeaf && !nodeText.isEmpty || node.isTextblock), let blockSeparator, !blockSeparator.isEmpty {
                if first { first = false } else { text += blockSeparator }
            }
            text += nodeText
            return true
        }
        return text
    }

    /// Create a new fragment containing the combined content of this fragment
    /// and the other.
    public func append(_ other: Fragment) -> Fragment {
        if other.size == 0 { return self }
        if size == 0 { return other }
        let last = lastChild!, first = other.firstChild!
        var content = self.content
        var i = 0
        if let lastText = last as? TextNode, let firstText = first as? TextNode, last.sameMarkup(first) {
            content[content.count - 1] = lastText.withUnits(lastText.units + firstText.units)
            i = 1
        }
        while i < other.content.count { content.append(other.content[i]); i += 1 }
        return Fragment(content, size: size + other.size)
    }

    /// Cut out the sub-fragment between the two given positions.
    public func cut(_ from: Int, _ to: Int? = nil) -> Fragment {
        let to = to ?? size
        if from == 0 && to == size { return self }
        var result: [Node] = []
        var size = 0
        if to > from {
            var i = 0, pos = 0
            while pos < to {
                var child = content[i]
                let end = pos + child.nodeSize
                if end > from {
                    if pos < from || end > to {
                        if let t = child as? TextNode {
                            child = t.cutText(max(0, from - pos), min(t.units.count, to - pos))
                        } else {
                            child = child.cut(max(0, from - pos - 1), min(child.content.size, to - pos - 1))
                        }
                    }
                    result.append(child)
                    size += child.nodeSize
                }
                pos = end
                i += 1
            }
        }
        return Fragment(result, size: size)
    }

    public func cutByIndex(_ from: Int, _ to: Int) -> Fragment {
        if from == to { return .empty }
        if from == 0 && to == content.count { return self }
        return Fragment(Array(content[from..<to]))
    }

    public func replaceChild(_ index: Int, _ node: Node) -> Fragment {
        let current = content[index]
        if current === node { return self }
        var copy = content
        let size = self.size + node.nodeSize - current.nodeSize
        copy[index] = node
        return Fragment(copy, size: size)
    }

    public func addToStart(_ node: Node) -> Fragment { Fragment([node] + content, size: size + node.nodeSize) }
    public func addToEnd(_ node: Node) -> Fragment { Fragment(content + [node], size: size + node.nodeSize) }

    public func eq(_ other: Fragment) -> Bool {
        if content.count != other.content.count { return false }
        for i in 0..<content.count where !content[i].eq(other.content[i]) { return false }
        return true
    }

    public var firstChild: Node? { content.first }
    public var lastChild: Node? { content.last }
    public var childCount: Int { content.count }

    public func child(_ index: Int) -> Node {
        precondition(index >= 0 && index < content.count, "Index \(index) out of range for \(self)")
        return content[index]
    }

    public func maybeChild(_ index: Int) -> Node? {
        index >= 0 && index < content.count ? content[index] : nil
    }

    public func forEach(_ f: (Node, Int, Int) -> Void) {
        var p = 0
        for (i, child) in content.enumerated() {
            f(child, p, i)
            p += child.nodeSize
        }
    }

    public func findDiffStart(_ other: Fragment, pos: Int = 0) -> Int? {
        PMModel.findDiffStart(self, other, pos)
    }

    public func findDiffEnd(_ other: Fragment, pos: Int? = nil, otherPos: Int? = nil) -> (a: Int, b: Int)? {
        PMModel.findDiffEnd(self, other, pos ?? size, otherPos ?? other.size)
    }

    /// Find the index and inner offset corresponding to a given relative position.
    public func findIndex(_ pos: Int) -> (index: Int, offset: Int) {
        if pos == 0 { return (0, pos) }
        if pos == size { return (content.count, pos) }
        precondition(pos <= size && pos >= 0, "Position \(pos) outside of fragment (\(self))")
        var i = 0, curPos = 0
        while true {
            let cur = child(i)
            let end = curPos + cur.nodeSize
            if end >= pos {
                if end == pos { return (i + 1, end) }
                return (i, curPos)
            }
            curPos = end
            i += 1
        }
    }

    public var description: String { "<" + toStringInner() + ">" }
    func toStringInner() -> String { content.map(\.description).joined(separator: ", ") }

    public func toJSON() -> JSONValue? {
        content.isEmpty ? nil : .array(content.map { $0.toJSON() })
    }

    public static func fromJSON(_ schema: Schema, _ value: JSONValue?) throws -> Fragment {
        try fromJSON(schema, value, depth: 0)
    }

    static func fromJSON(_ schema: Schema, _ value: JSONValue?, depth: Int) throws -> Fragment {
        guard let value, value.truthy else { return .empty }
        guard let arr = value.arrayValue else { throw PMError.range("Invalid input for Fragment.fromJSON") }
        return fromArray(try arr.map { try Node.fromJSON(schema, $0, depth: depth) })
    }

    /// Build a fragment from an array of nodes, joining adjacent text nodes with the same marks.
    public static func fromArray(_ array: [Node]) -> Fragment {
        if array.isEmpty { return .empty }
        var joined: [Node]? = nil
        var size = 0
        for i in 0..<array.count {
            let node = array[i]
            size += node.nodeSize
            if i > 0, let t = node as? TextNode, array[i - 1].sameMarkup(node) {
                if joined == nil { joined = Array(array[0..<i]) }
                let prev = joined![joined!.count - 1] as! TextNode
                joined![joined!.count - 1] = t.withUnits(prev.units + t.units)
            } else if joined != nil {
                joined!.append(node)
            }
        }
        return Fragment(joined ?? array, size: size)
    }

    public static func from(_ nodes: [Node]) -> Fragment { fromArray(nodes) }
    public static func from(_ node: Node) -> Fragment { Fragment([node], size: node.nodeSize) }
    public static func from(_ fragment: Fragment?) -> Fragment { fragment ?? .empty }
}

// MARK: - diff.ts

private func surrogateLow(_ ch: UInt16) -> Bool { ch >= 0xDC00 && ch < 0xE000 }
private func surrogateHigh(_ ch: UInt16) -> Bool { ch >= 0xD800 && ch < 0xDC00 }

func findDiffStart(_ a: Fragment, _ b: Fragment, _ pos: Int) -> Int? {
    var pos = pos
    var i = 0
    while true {
        if i == a.childCount || i == b.childCount {
            return a.childCount == b.childCount ? nil : pos
        }
        let childA = a.child(i), childB = b.child(i)
        defer { i += 1 }
        if childA === childB { pos += childA.nodeSize; continue }
        if !childA.sameMarkup(childB) { return pos }
        if let tA = (childA as? TextNode)?.units, let tB = (childB as? TextNode)?.units, tA != tB {
            var j = 0
            while j < tA.count && j < tB.count && tA[j] == tB[j] { j += 1; pos += 1 }
            if j > 0 && j < tA.count && j < tB.count && surrogateHigh(tA[j - 1]) && surrogateLow(tA[j]) { pos -= 1 }
            return pos
        }
        if childA.content.size > 0 || childB.content.size > 0 {
            if let inner = findDiffStart(childA.content, childB.content, pos + 1) { return inner }
        }
        pos += childA.nodeSize
    }
}

func findDiffEnd(_ a: Fragment, _ b: Fragment, _ posA: Int, _ posB: Int) -> (a: Int, b: Int)? {
    var posA = posA, posB = posB
    var iA = a.childCount, iB = b.childCount
    while true {
        if iA == 0 || iB == 0 {
            return iA == iB ? nil : (posA, posB)
        }
        iA -= 1; iB -= 1
        let childA = a.child(iA), childB = b.child(iB), size = childA.nodeSize
        if childA === childB {
            posA -= size; posB -= size
            continue
        }
        if !childA.sameMarkup(childB) { return (posA, posB) }
        if let tA = (childA as? TextNode)?.units, let tB = (childB as? TextNode)?.units, tA != tB {
            var ia = tA.count, ib = tB.count
            while ia > 0 && ib > 0 && tA[ia - 1] == tB[ib - 1] { ia -= 1; ib -= 1; posA -= 1; posB -= 1 }
            if ia > 0 && ib > 0 && ia < tA.count && surrogateHigh(tA[ia - 1]) && surrogateLow(tA[ia]) {
                posA += 1; posB += 1
            }
            return (posA, posB)
        }
        if childA.content.size > 0 || childB.content.size > 0 {
            if let inner = findDiffEnd(childA.content, childB.content, posA - 1, posB - 1) { return inner }
        }
        posA -= size; posB -= size
    }
}
