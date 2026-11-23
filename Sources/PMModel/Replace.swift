// Port of prosemirror-model/src/replace.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

/// A slice represents a piece cut out of a larger document. It stores not
/// only a fragment, but also the depth up to which nodes on both side are
/// "open" (cut through).
public final class Slice: CustomStringConvertible {
    public let content: Fragment
    public let openStart: Int
    public let openEnd: Int

    public init(_ content: Fragment, _ openStart: Int, _ openEnd: Int) {
        self.content = content
        self.openStart = openStart
        self.openEnd = openEnd
    }

    public static let empty = Slice(.empty, 0, 0)

    public var size: Int { content.size - openStart - openEnd }

    public func insertAt(_ pos: Int, _ fragment: Fragment) -> Slice? {
        guard let content = insertInto(content, pos + openStart, fragment, openStart + 1, openEnd + 1, nil) else { return nil }
        return Slice(content, openStart, openEnd)
    }

    /// Throws (like JS's `RangeError`) when the range isn't flat or isn't inside the slice.
    public func removeBetween(_ from: Int, _ to: Int) throws -> Slice {
        Slice(try removeRange(content, from + openStart, to + openStart), openStart, openEnd)
    }

    public func eq(_ other: Slice) -> Bool {
        content.eq(other.content) && openStart == other.openStart && openEnd == other.openEnd
    }

    public var description: String { "\(content)(\(openStart),\(openEnd))" }

    public func toJSON() -> JSONValue {
        if content.size == 0 { return .null }
        var json = JSONObject()
        json["content"] = content.toJSON() ?? .null
        if openStart > 0 { json["openStart"] = .number(Double(openStart)) }
        if openEnd > 0 { json["openEnd"] = .number(Double(openEnd)) }
        return .object(json)
    }

    public static func fromJSON(_ schema: Schema, _ json: JSONValue?) throws -> Slice {
        try fromJSON(schema, json, depth: 0)
    }

    static func fromJSON(_ schema: Schema, _ json: JSONValue?, depth: Int) throws -> Slice {
        guard let json, json.truthy else { return .empty }
        // JS checks only that the open depths are numbers. Untrusted slices (the pasteboard)
        // can say anything, so also require integers no deeper than the content on that side;
        // anything else would break the size arithmetic and the replace code downstream.
        func open(_ v: JSONValue?) throws -> Int {
            guard let v, v.truthy else { return 0 }
            guard let n = v.numberValue else { throw PMError.range("Invalid input for Slice.fromJSON") }
            guard let i = JSONValue.truncatedInt(n), Double(i) == n, i >= 0 else {
                throw PMError.range("Invalid open depth \(JSONValue.number(n)) for Slice.fromJSON")
            }
            return i
        }
        let openStart = try open(json["openStart"]), openEnd = try open(json["openEnd"])
        let content = try Fragment.fromJSON(schema, json["content"], depth: depth + 1)
        let max = maxOpen(content)
        if openStart > max.openStart || openEnd > max.openEnd {
            throw PMError.range("Slice open depths (\(openStart), \(openEnd)) exceed its content's depth")
        }
        return Slice(content, openStart, openEnd)
    }

    /// Create a slice from a fragment by taking the maximum possible open value on both side.
    public static func maxOpen(_ fragment: Fragment, openIsolating: Bool = true) -> Slice {
        var openStart = 0, openEnd = 0
        var n = fragment.firstChild
        while let node = n, !node.isLeaf, openIsolating || !node.type.spec.isolating { openStart += 1; n = node.firstChild }
        n = fragment.lastChild
        while let node = n, !node.isLeaf, openIsolating || !node.type.spec.isolating { openEnd += 1; n = node.lastChild }
        return Slice(fragment, openStart, openEnd)
    }
}

private func removeRange(_ content: Fragment, _ from: Int, _ to: Int) throws -> Fragment {
    guard from >= 0, from <= to, to <= content.size else { throw PMError.range("Removing range outside of content") }
    let (index, offset) = content.findIndex(from)
    let child = content.maybeChild(index)
    let (indexTo, offsetTo) = content.findIndex(to)
    if offset == from || child!.isText {
        if offsetTo != to && !content.child(indexTo).isText { throw PMError.range("Removing non-flat range") }
        return content.cut(0, from).append(content.cut(to))
    }
    if index != indexTo { throw PMError.range("Removing non-flat range") }
    return content.replaceChild(index, child!.copy(try removeRange(child!.content, from - offset - 1, to - offset - 1)))
}

private func insertInto(_ content: Fragment, _ dist: Int, _ insert: Fragment, _ openStart: Int, _ openEnd: Int, _ parent: Node?) -> Fragment? {
    let (index, offset) = content.findIndex(dist)
    let child = content.maybeChild(index)
    if offset == dist || child!.isText {
        if let parent, openStart <= 0, openEnd <= 0, !parent.canReplace(index, index, insert) { return nil }
        return content.cut(0, dist).append(insert).append(content.cut(dist))
    }
    guard let inner = insertInto(child!.content, dist - offset - 1, insert, index == 0 ? openStart - 1 : 0,
                                 index == content.childCount - 1 ? openEnd - 1 : 0, child) else { return nil }
    return content.replaceChild(index, child!.copy(inner))
}

func replace(_ from: ResolvedPos, _ to: ResolvedPos, _ slice: Slice) throws -> Node {
    if slice.openStart > from.depth { throw PMError.replace("Inserted content deeper than insertion position") }
    if from.depth - slice.openStart != to.depth - slice.openEnd { throw PMError.replace("Inconsistent open depths") }
    return try replaceOuter(from, to, slice, 0)
}

private func replaceOuter(_ from: ResolvedPos, _ to: ResolvedPos, _ slice: Slice, _ depth: Int) throws -> Node {
    let index = from.index(depth), node = from.node(depth)
    if index == to.index(depth) && depth < from.depth - slice.openStart {
        let inner = try replaceOuter(from, to, slice, depth + 1)
        return node.copy(node.content.replaceChild(index, inner))
    } else if slice.content.size == 0 {
        return try close(node, try replaceTwoWay(from, to, depth))
    } else if slice.openStart == 0 && slice.openEnd == 0 && from.depth == depth && to.depth == depth {
        let parent = from.parent, content = parent.content
        return try close(parent, content.cut(0, from.parentOffset).append(slice.content).append(content.cut(to.parentOffset)))
    } else {
        let (start, end) = prepareSliceForReplace(slice, from)
        return try close(node, try replaceThreeWay(from, start, end, to, depth))
    }
}

private func checkJoin(_ main: Node, _ sub: Node) throws {
    if !sub.type.compatibleContent(main.type) {
        throw PMError.replace("Cannot join \(sub.type.name) onto \(main.type.name)")
    }
}

private func joinable(_ before: ResolvedPos, _ after: ResolvedPos, _ depth: Int) throws -> Node {
    let node = before.node(depth)
    try checkJoin(node, after.node(depth))
    return node
}

private func addNode(_ child: Node, _ target: inout [Node]) {
    let last = target.count - 1
    if last >= 0, let t = child as? TextNode, child.sameMarkup(target[last]), let prev = target[last] as? TextNode {
        target[last] = t.withUnits(prev.units + t.units)
    } else {
        target.append(child)
    }
}

private func addRange(_ start: ResolvedPos?, _ end: ResolvedPos?, _ depth: Int, _ target: inout [Node]) {
    let node = (end ?? start)!.node(depth)
    var startIndex = 0
    let endIndex = end?.index(depth) ?? node.childCount
    if let start {
        startIndex = start.index(depth)
        if start.depth > depth {
            startIndex += 1
        } else if start.textOffset > 0 {
            addNode(start.nodeAfter!, &target)
            startIndex += 1
        }
    }
    var i = startIndex
    while i < endIndex { addNode(node.child(i), &target); i += 1 }
    if let end, end.depth == depth, end.textOffset > 0 {
        addNode(end.nodeBefore!, &target)
    }
}

private func close(_ node: Node, _ content: Fragment) throws -> Node {
    if !node.type.validContent(content) { throw PMError.replace("Invalid content for node \(node.type.name)") }
    return node.copy(content)
}

private func replaceThreeWay(_ from: ResolvedPos, _ start: ResolvedPos, _ end: ResolvedPos, _ to: ResolvedPos, _ depth: Int) throws -> Fragment {
    let openStart = from.depth > depth ? try joinable(from, start, depth + 1) : nil
    let openEnd = to.depth > depth ? try joinable(end, to, depth + 1) : nil

    var content: [Node] = []
    addRange(nil, from, depth, &content)
    if let openStart, let openEnd, start.index(depth) == end.index(depth) {
        try checkJoin(openStart, openEnd)
        addNode(try close(openStart, try replaceThreeWay(from, start, end, to, depth + 1)), &content)
    } else {
        if let openStart { addNode(try close(openStart, try replaceTwoWay(from, start, depth + 1)), &content) }
        addRange(start, end, depth, &content)
        if let openEnd { addNode(try close(openEnd, try replaceTwoWay(end, to, depth + 1)), &content) }
    }
    addRange(to, nil, depth, &content)
    return Fragment(content)
}

private func replaceTwoWay(_ from: ResolvedPos, _ to: ResolvedPos, _ depth: Int) throws -> Fragment {
    var content: [Node] = []
    addRange(nil, from, depth, &content)
    if from.depth > depth {
        let type = try joinable(from, to, depth + 1)
        addNode(try close(type, try replaceTwoWay(from, to, depth + 1)), &content)
    }
    addRange(to, nil, depth, &content)
    return Fragment(content)
}

private func prepareSliceForReplace(_ slice: Slice, _ along: ResolvedPos) -> (ResolvedPos, ResolvedPos) {
    let extra = along.depth - slice.openStart
    let parent = along.node(extra)
    var node = parent.copy(slice.content)
    var i = extra - 1
    while i >= 0 {
        node = along.node(i).copy(Fragment.from(node))
        i -= 1
    }
    return (node.resolveNoCache(slice.openStart + extra), node.resolveNoCache(node.content.size - slice.openEnd - extra))
}
