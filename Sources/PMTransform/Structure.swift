// Port of prosemirror-transform/src/structure.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import PMModel

private func canCut(_ node: Node, _ start: Int, _ end: Int) -> Bool {
    (start == 0 || node.canReplace(start, node.childCount)) && (end == node.childCount || node.canReplace(0, end))
}

/// Try to find a target depth to which the content in the given range can be lifted.
public func liftTarget(_ range: NodeRange) -> Int? {
    let parent = range.parent
    let content = parent.content.cutByIndex(range.startIndex, range.endIndex)
    var depth = range.depth, contentBefore = 0, contentAfter = 0
    while true {
        let node = range.from.node(depth)
        let index = range.from.index(depth) + contentBefore, endIndex = range.to.indexAfter(depth) - contentAfter
        if depth < range.depth && node.canReplace(index, endIndex, content) { return depth }
        if depth == 0 || node.type.spec.isolating || !canCut(node, index, endIndex) { break }
        if index > 0 { contentBefore = 1 }
        if endIndex < node.childCount { contentAfter = 1 }
        depth -= 1
    }
    return nil
}

func lift(_ tr: Transform, _ range: NodeRange, _ target: Int) throws {
    let rFrom = range.from, rTo = range.to, depth = range.depth
    let gapStart = rFrom.before(depth + 1), gapEnd = rTo.after(depth + 1)
    var start = gapStart, end = gapEnd

    var before = Fragment.empty, openStart = 0
    var d = depth, splitting = false
    while d > target {
        if splitting || rFrom.index(d) > 0 {
            splitting = true
            before = Fragment.from(rFrom.node(d).copy(before))
            openStart += 1
        } else {
            start -= 1
        }
        d -= 1
    }
    var after = Fragment.empty, openEnd = 0
    d = depth
    splitting = false
    while d > target {
        if splitting || rTo.after(d + 1) < rTo.end(d) {
            splitting = true
            after = Fragment.from(rTo.node(d).copy(after))
            openEnd += 1
        } else {
            end += 1
        }
        d -= 1
    }
    try tr.step(ReplaceAroundStep(start, end, gapStart, gapEnd, Slice(before.append(after), openStart, openEnd),
                                  before.size - openStart, structure: true))
}

/// Try to find a valid way to wrap the content in the given range in a node of the given type.
public func findWrapping(_ range: NodeRange, _ nodeType: NodeType, _ attrs: Attrs? = nil, innerRange: NodeRange? = nil) -> [NodeTypeWithAttrs]? {
    guard let around = findWrappingOutside(range, nodeType), let inner = findWrappingInside(innerRange ?? range, nodeType) else { return nil }
    return around.map { NodeTypeWithAttrs($0, nil) } + [NodeTypeWithAttrs(nodeType, attrs)] + inner.map { NodeTypeWithAttrs($0, nil) }
}

private func findWrappingOutside(_ range: NodeRange, _ type: NodeType) -> [NodeType]? {
    let parent = range.parent, startIndex = range.startIndex, endIndex = range.endIndex
    guard let around = parent.contentMatchAt(startIndex).findWrapping(type) else { return nil }
    let outer = around.first ?? type
    return parent.canReplaceWith(startIndex, endIndex, outer) ? around : nil
}

private func findWrappingInside(_ range: NodeRange, _ type: NodeType) -> [NodeType]? {
    let parent = range.parent, startIndex = range.startIndex, endIndex = range.endIndex
    let inner = parent.child(startIndex)
    guard let inside = type.contentMatch.findWrapping(inner.type) else { return nil }
    let lastType = inside.last ?? type
    var innerMatch: ContentMatch? = lastType.contentMatch
    var i = startIndex
    while let m = innerMatch, i < endIndex {
        innerMatch = m.matchType(parent.child(i).type)
        i += 1
    }
    guard let m = innerMatch, m.validEnd else { return nil }
    return inside
}

func wrap(_ tr: Transform, _ range: NodeRange, _ wrappers: [NodeTypeWithAttrs]) throws {
    var content = Fragment.empty
    for w in wrappers.reversed() {
        if content.size > 0 {
            guard let match = w.type.contentMatch.matchFragment(content), match.validEnd else {
                throw PMError.range("Wrapper type given to Transform.wrap does not form valid content of its parent wrapper")
            }
        }
        content = Fragment.from(try w.type.create(w.attrs, content))
    }
    let start = range.start, end = range.end
    try tr.step(ReplaceAroundStep(start, end, start, end, Slice(content, 0, 0), wrappers.count, structure: true))
}

func setBlockType(_ tr: Transform, _ from: Int, _ to: Int, _ type: NodeType, _ attrs: (Node) -> Attrs?) throws {
    if !type.isTextblock { throw PMError.range("Type given to setBlockType should be a textblock") }
    let mapFrom = tr.steps.count
    var error: Error? = nil
    tr.doc.nodesBetween(from, to) { node, pos, _, _ in
        if error != nil { return false }
        let attrsHere = attrs(node)
        if node.isTextblock && !node.hasMarkup(type, attrsHere) &&
            canChangeType(tr.doc, tr.mapping.slice(mapFrom).map(pos), type) {
            do {
                var convertNewlines: Bool? = nil
                if let lb = type.schema.linebreakReplacement {
                    let pre = type.whitespace == "pre", supportLinebreak = type.contentMatch.matchType(lb) != nil
                    if pre && !supportLinebreak { convertNewlines = false }
                    else if !pre && supportLinebreak { convertNewlines = true }
                }
                if convertNewlines == false { try replaceLinebreaks(tr, node, pos, mapFrom) }
                try clearIncompatible(tr, tr.mapping.slice(mapFrom).map(pos, assoc: 1), type, type.contentMatch, convertNewlines == nil)
                let mapping = tr.mapping.slice(mapFrom)
                let startM = mapping.map(pos, assoc: 1), endM = mapping.map(pos + node.nodeSize, assoc: 1)
                try tr.step(ReplaceAroundStep(startM, endM, startM + 1, endM - 1,
                                              Slice(Fragment.from(try type.create(attrsHere, nil, node.marks)), 0, 0), 1, structure: true))
                if convertNewlines == true { try replaceNewlines(tr, node, pos, mapFrom) }
            } catch let e {
                error = e
            }
            return false
        }
        return true
    }
    if let error { throw error }
}

private func replaceNewlines(_ tr: Transform, _ node: Node, _ pos: Int, _ mapFrom: Int) throws {
    var offsets: [(Int, TextNode)] = []
    node.forEach { child, offset, _ in if let t = child as? TextNode { offsets.append((offset, t)) } }
    for (offset, child) in offsets {
        for (index, _) in newlineMatches(child.units) {
            let start = tr.mapping.slice(mapFrom).map(pos + 1 + offset + index)
            try tr.replaceWith(start, start + 1, try node.type.schema.linebreakReplacement!.create())
        }
    }
}

private func replaceLinebreaks(_ tr: Transform, _ node: Node, _ pos: Int, _ mapFrom: Int) throws {
    var offsets: [Int] = []
    node.forEach { child, offset, _ in if child.type === child.type.schema.linebreakReplacement { offsets.append(offset) } }
    for offset in offsets {
        let start = tr.mapping.slice(mapFrom).map(pos + 1 + offset)
        try tr.replaceWith(start, start + 1, node.type.schema.text("\n"))
    }
}

private func canChangeType(_ doc: Node, _ pos: Int, _ type: NodeType) -> Bool {
    let rpos = doc.resolve(pos), index = rpos.index()
    return rpos.parent.canReplaceWith(index, index + 1, type)
}

func setNodeMarkup(_ tr: Transform, _ pos: Int, _ type: NodeType?, _ attrs: Attrs?, _ marks: [Mark]?) throws {
    guard let node = tr.doc.nodeAt(pos) else { throw PMError.range("No node at given position") }
    let type = type ?? node.type
    let newNode = try type.create(attrs, nil, marks ?? node.marks)
    if node.isLeaf {
        try tr.replaceWith(pos, pos + node.nodeSize, newNode)
        return
    }
    if !type.validContent(node.content) { throw PMError.range("Invalid content for node type \(type.name)") }
    try tr.step(ReplaceAroundStep(pos, pos + node.nodeSize, pos + 1, pos + node.nodeSize - 1,
                                  Slice(Fragment.from(newNode), 0, 0), 1, structure: true))
}

/// Check whether splitting at the given position is allowed.
public func canSplit(_ doc: Node, _ pos: Int, _ depth: Int = 1, _ typesAfter: [NodeTypeWithAttrs?]? = nil) -> Bool {
    let rpos = doc.resolve(pos), base = rpos.depth - depth
    let innerType: NodeType = (typesAfter?.last ?? nil)?.type ?? rpos.parent.type
    if base < 0 || rpos.parent.type.spec.isolating ||
        !rpos.parent.canReplace(rpos.index(), rpos.parent.childCount) ||
        !innerType.validContent(rpos.parent.content.cutByIndex(rpos.index(), rpos.parent.childCount)) {
        return false
    }
    var d = rpos.depth - 1, i = depth - 2
    while d > base {
        let node = rpos.node(d), index = rpos.index(d)
        if node.type.spec.isolating { return false }
        var rest = node.content.cutByIndex(index, node.childCount)
        if let typesAfter, i + 1 >= 0, i + 1 < typesAfter.count, let overrideChild = typesAfter[i + 1] {
            guard let created = try? overrideChild.type.create(overrideChild.attrs) else { return false }
            rest = rest.replaceChild(0, created)
        }
        let afterType: NodeType
        if let typesAfter, i >= 0, i < typesAfter.count, let t = typesAfter[i] { afterType = t.type } else { afterType = node.type }
        if !node.canReplace(index + 1, node.childCount) || !afterType.validContent(rest) { return false }
        d -= 1
        i -= 1
    }
    let index = rpos.indexAfter(base)
    let baseType = typesAfter?.first ?? nil
    return rpos.node(base).canReplaceWith(index, index, baseType?.type ?? rpos.node(base + 1).type)
}

func split(_ tr: Transform, _ pos: Int, _ depth: Int, _ typesAfter: [NodeTypeWithAttrs?]?) throws {
    let rpos = tr.doc.resolve(pos)
    var before = Fragment.empty, after = Fragment.empty
    var d = rpos.depth, i = depth - 1
    let e = rpos.depth - depth
    while d > e {
        before = Fragment.from(rpos.node(d).copy(before))
        if let typesAfter, i >= 0, i < typesAfter.count, let typeAfter = typesAfter[i] {
            after = Fragment.from(try typeAfter.type.create(typeAfter.attrs, after))
        } else {
            after = Fragment.from(rpos.node(d).copy(after))
        }
        d -= 1
        i -= 1
    }
    try tr.step(ReplaceStep(pos, pos, Slice(before.append(after), depth, depth), structure: true))
}

/// Test whether the blocks before and after a given position can be joined.
public func canJoin(_ doc: Node, _ pos: Int) -> Bool {
    let rpos = doc.resolve(pos), index = rpos.index()
    return joinable(rpos.nodeBefore, rpos.nodeAfter) && rpos.parent.canReplace(index, index + 1)
}

private func canAppendWithSubstitutedLinebreaks(_ a: Node, _ b: Node) -> Bool {
    // (JS evaluates `a.type.compatibleContent(b.type)` here for empty `b` and discards it.)
    var match: ContentMatch? = a.contentMatchAt(a.childCount)
    let linebreakReplacement = a.type.schema.linebreakReplacement
    for i in 0..<b.childCount {
        let child = b.child(i)
        let type = child.type === linebreakReplacement ? a.type.schema.nodes["text"]! : child.type
        match = match!.matchType(type)
        if match == nil { return false }
        if !a.type.allowsMarks(child.marks) { return false }
    }
    return match!.validEnd
}

private func joinable(_ a: Node?, _ b: Node?) -> Bool {
    guard let a, let b else { return false }
    return !a.isLeaf && canAppendWithSubstitutedLinebreaks(a, b)
}

/// Find an ancestor of the given position that can be joined to the block before (or after) it.
public func joinPoint(_ doc: Node, _ pos: Int, _ dir: Int = -1) -> Int? {
    let rpos = doc.resolve(pos)
    var pos = pos
    var d = rpos.depth
    while true {
        var before: Node?, after: Node?
        var index = rpos.index(d)
        if d == rpos.depth {
            before = rpos.nodeBefore
            after = rpos.nodeAfter
        } else if dir > 0 {
            before = rpos.node(d + 1)
            index += 1
            after = rpos.node(d).maybeChild(index)
        } else {
            before = rpos.node(d).maybeChild(index - 1)
            after = rpos.node(d + 1)
        }
        if let b = before, !b.isTextblock, joinable(b, after), rpos.node(d).canReplace(index, index + 1) { return pos }
        if d == 0 { break }
        pos = dir < 0 ? rpos.before(d) : rpos.after(d)
        d -= 1
    }
    return nil
}

func join(_ tr: Transform, _ pos: Int, _ depth: Int) throws {
    var convertNewlines: Bool? = nil
    let linebreakReplacement = tr.doc.type.schema.linebreakReplacement
    let rBefore = tr.doc.resolve(pos - depth), beforeType = rBefore.node().type
    if let lb = linebreakReplacement, beforeType.inlineContent {
        let pre = beforeType.whitespace == "pre"
        let supportLinebreak = beforeType.contentMatch.matchType(lb) != nil
        if pre && !supportLinebreak { convertNewlines = false }
        else if !pre && supportLinebreak { convertNewlines = true }
    }
    let mapFrom = tr.steps.count
    if convertNewlines == false {
        let rAfter = tr.doc.resolve(pos + depth)
        if rAfter.depth == 0 { throw PMError.range("There is no position before the top-level node") }
        try replaceLinebreaks(tr, rAfter.node(), rAfter.before(), mapFrom)
    }
    if beforeType.inlineContent {
        try clearIncompatible(tr, pos + depth - 1, beforeType, rBefore.node().contentMatchAt(rBefore.index()), convertNewlines == nil)
    }
    let mapping = tr.mapping.slice(mapFrom), start = mapping.map(pos - depth)
    try tr.step(ReplaceStep(start, mapping.map(pos + depth, assoc: -1), .empty, structure: true))
    if convertNewlines == true {
        let rFull = tr.doc.resolve(start)
        if rFull.depth == 0 { throw PMError.range("There is no position before the top-level node") }
        try replaceNewlines(tr, rFull.node(), rFull.before(), tr.steps.count)
    }
}

/// Try to find a point where a node of the given type can be inserted near `pos`.
public func insertPoint(_ doc: Node, _ pos: Int, _ nodeType: NodeType) -> Int? {
    let rpos = doc.resolve(pos)
    if rpos.parent.canReplaceWith(rpos.index(), rpos.index(), nodeType) { return pos }
    if rpos.parentOffset == 0 {
        var d = rpos.depth - 1
        while d >= 0 {
            let index = rpos.index(d)
            if rpos.node(d).canReplaceWith(index, index, nodeType) { return rpos.before(d + 1) }
            if index > 0 { return nil }
            d -= 1
        }
    }
    if rpos.parentOffset == rpos.parent.content.size {
        var d = rpos.depth - 1
        while d >= 0 {
            let index = rpos.indexAfter(d)
            if rpos.node(d).canReplaceWith(index, index, nodeType) { return rpos.after(d + 1) }
            if index < rpos.node(d).childCount { return nil }
            d -= 1
        }
    }
    return nil
}

/// Finds a position at or around the given position where the given slice can be inserted.
public func dropPoint(_ doc: Node, _ pos: Int, _ slice: Slice) -> Int? {
    let rpos = doc.resolve(pos)
    if slice.content.size == 0 { return pos }
    var content = slice.content
    for _ in 0..<slice.openStart { content = content.firstChild!.content }
    let passes = slice.openStart == 0 && slice.size > 0 ? 2 : 1
    for pass in 1...passes {
        var d = rpos.depth
        while d >= 0 {
            let bias = d == rpos.depth ? 0 : Double(rpos.pos) <= Double(rpos.start(d + 1) + rpos.end(d + 1)) / 2 ? -1 : 1
            let insertPos = rpos.index(d) + (bias > 0 ? 1 : 0)
            let parent = rpos.node(d)
            var fits = false
            if pass == 1 {
                fits = parent.canReplace(insertPos, insertPos, content)
            } else if let wrapping = parent.contentMatchAt(insertPos).findWrapping(content.firstChild!.type), !wrapping.isEmpty {
                fits = parent.canReplaceWith(insertPos, insertPos, wrapping[0])
            }
            if fits { return bias == 0 ? rpos.pos : bias < 0 ? rpos.before(d + 1) : rpos.after(d + 1) }
            d -= 1
        }
    }
    return nil
}
