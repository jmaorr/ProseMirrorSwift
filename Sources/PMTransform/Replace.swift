// Port of prosemirror-transform/src/replace.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import PMModel

/// "Fit" a slice into a given position in the document, producing a step
/// that inserts it. Returns nil if there's no meaningful way to insert it.
public func replaceStep(_ doc: Node, _ from: Int, _ to: Int? = nil, _ slice: Slice = .empty) throws -> Step? {
    let to = to ?? from
    if from == to && slice.size == 0 { return nil }
    let rFrom = doc.resolve(from), rTo = doc.resolve(to)
    if fitsTrivially(rFrom, rTo, slice) { return ReplaceStep(from, to, slice) }
    return try Fitter(rFrom, rTo, slice).fit()
}

private func fitsTrivially(_ rFrom: ResolvedPos, _ rTo: ResolvedPos, _ slice: Slice) -> Bool {
    slice.openStart == 0 && slice.openEnd == 0 && rFrom.start() == rTo.start() &&
        rFrom.parent.canReplace(rFrom.index(), rTo.index(), slice.content)
}

private struct Fittable {
    let sliceDepth: Int
    let frontierDepth: Int
    let parent: Node?
    var inject: Fragment? = nil
    var wrap: [NodeType]? = nil
}

private struct FrontierEntry {
    let type: NodeType
    // May be null in JS (`matchType(type)!` is only a type assertion); dereferencing throws.
    var match: ContentMatch?
}

/// JS dereferences of null values throw TypeError; mirror that instead of trapping.
func unwrap<T>(_ value: T?, _ what: String = "value") throws -> T {
    guard let value else { throw PMError.generic("Cannot read properties of null (\(what))") }
    return value
}

private final class Fitter {
    var frontier: [FrontierEntry] = []
    var placed: Fragment = .empty
    let rFrom: ResolvedPos
    let rTo: ResolvedPos
    var unplaced: Slice

    init(_ rFrom: ResolvedPos, _ rTo: ResolvedPos, _ unplaced: Slice) {
        self.rFrom = rFrom
        self.rTo = rTo
        self.unplaced = unplaced
        for i in 0...rFrom.depth {
            let node = rFrom.node(i)
            frontier.append(FrontierEntry(type: node.type, match: node.contentMatchAt(rFrom.indexAfter(i))))
        }
        var i = rFrom.depth
        while i > 0 {
            placed = Fragment.from(rFrom.node(i).copy(placed))
            i -= 1
        }
    }

    var depth: Int { frontier.count - 1 }

    func fit() throws -> Step? {
        while unplaced.size > 0 {
            if let fit = try findFittable() {
                try placeNodes(fit)
            } else if try !openMore() {
                try dropNode()
            }
        }
        let moveInline = try mustMoveInline(), placedSize = placed.size - depth - rFrom.depth
        let from = rFrom
        guard let to = try close(moveInline < 0 ? rTo : from.doc.resolve(moveInline)) else { return nil }

        var content = placed, openStart = from.depth, openEnd = to.depth
        while openStart > 0 && openEnd > 0 && content.childCount == 1 {
            content = try unwrap(content.firstChild).content
            openStart -= 1
            openEnd -= 1
        }
        let slice = Slice(content, openStart, openEnd)
        if moveInline > -1 {
            return ReplaceAroundStep(from.pos, moveInline, rTo.pos, rTo.end(), slice, placedSize)
        }
        if slice.size > 0 || from.pos != rTo.pos {
            return ReplaceStep(from.pos, to.pos, slice)
        }
        return nil
    }

    func findFittable() throws -> Fittable? {
        var startDepth = unplaced.openStart
        do {
            var cur = unplaced.content, openEnd = unplaced.openEnd
            var d = 0
            while d < startDepth {
                let node = try unwrap(cur.firstChild)
                if cur.childCount > 1 { openEnd = 0 }
                if node.type.spec.isolating && openEnd <= d {
                    startDepth = d
                    break
                }
                cur = node.content
                d += 1
            }
        }
        for pass in 1...2 {
            var sliceDepth = pass == 1 ? startDepth : unplaced.openStart
            while sliceDepth >= 0 {
                let fragment: Fragment
                var parent: Node? = nil
                if sliceDepth > 0 {
                    parent = try contentAt(unplaced.content, sliceDepth - 1).firstChild
                    fragment = try unwrap(parent).content
                } else {
                    fragment = unplaced.content
                }
                let first = fragment.firstChild
                var frontierDepth = depth
                while frontierDepth >= 0 {
                    let type = frontier[frontierDepth].type, match = try unwrap(frontier[frontierDepth].match)
                    if pass == 1 {
                        if let first {
                            if match.matchType(first.type) != nil {
                                return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent)
                            }
                            if let inject = match.fillBefore(Fragment.from(first), toEnd: false) {
                                return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent, inject: inject)
                            }
                        } else if let parent, type.compatibleContent(parent.type) {
                            return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent)
                        }
                    } else if pass == 2, let first, let wrap = match.findWrapping(first.type) {
                        return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent, wrap: wrap)
                    }
                    if let parent, match.matchType(parent.type) != nil { break }
                    frontierDepth -= 1
                }
                sliceDepth -= 1
            }
        }
        return nil
    }

    func openMore() throws -> Bool {
        let content = unplaced.content, openStart = unplaced.openStart
        var openEnd = unplaced.openEnd
        if maxOpen(content, -1) <= openStart { return false }
        if unplaced.size > 1 && maxOpen(content, 1) > openEnd { openEnd += 1 }
        unplaced = Slice(content, openStart + 1, openEnd)
        return true
    }

    func dropNode() throws {
        let content = unplaced.content, openStart = unplaced.openStart, openEnd = unplaced.openEnd
        let inner = try contentAt(content, openStart)
        if inner.childCount <= 1 && openStart > 0 {
            let openAtEnd = content.size - openStart <= openStart + inner.size
            unplaced = Slice(try dropFromFragment(content, openStart - 1, 1), openStart - 1, openAtEnd ? openStart - 1 : openEnd)
        } else {
            unplaced = Slice(try dropFromFragment(content, openStart, 1), openStart, openEnd)
        }
    }

    func placeNodes(_ fit: Fittable) throws {
        let sliceDepth = fit.sliceDepth, frontierDepth = fit.frontierDepth, parent = fit.parent
        while depth > frontierDepth { try closeFrontierNode() }
        if let wrap = fit.wrap { for w in wrap { try openFrontierNode(w) } }

        let slice = unplaced, fragment = parent?.content ?? slice.content
        let openStart = slice.openStart - sliceDepth
        var taken = 0
        var add: [Node] = []
        var match = try unwrap(frontier[frontierDepth].match)
        let type = frontier[frontierDepth].type
        if let inject = fit.inject {
            for i in 0..<inject.childCount { add.append(inject.child(i)) }
            match = try unwrap(match.matchFragment(inject))
        }
        var openEndCount = (fragment.size + sliceDepth) - (slice.content.size - slice.openEnd)
        while taken < fragment.childCount {
            let next = fragment.child(taken)
            guard let matches = match.matchType(next.type) else { break }
            taken += 1
            if taken > 1 || openStart == 0 || next.content.size > 0 {
                match = matches
                add.append(try closeNodeStart(next.mark(type.allowedMarks(next.marks)), taken == 1 ? openStart : 0,
                                          taken == fragment.childCount ? openEndCount : -1))
            }
        }
        let toEnd = taken == fragment.childCount
        if !toEnd { openEndCount = -1 }

        placed = try addToFragment(placed, frontierDepth, Fragment.from(add))
        frontier[frontierDepth].match = match

        if toEnd && openEndCount < 0, let parent, parent.type === frontier[depth].type, frontier.count > 1 {
            try closeFrontierNode()
        }

        var cur = fragment
        for _ in 0..<max(0, openEndCount) {
            let node = try unwrap(cur.lastChild)
            frontier.append(FrontierEntry(type: node.type, match: try node.checkedContentMatchAt(node.childCount)))
            cur = node.content
        }

        unplaced = !toEnd ? Slice(try dropFromFragment(slice.content, sliceDepth, taken), slice.openStart, slice.openEnd)
            : sliceDepth == 0 ? .empty
            : Slice(try dropFromFragment(slice.content, sliceDepth - 1, 1), sliceDepth - 1, openEndCount < 0 ? slice.openEnd : sliceDepth - 1)
    }

    func mustMoveInline() throws -> Int {
        if !rTo.parent.isTextblock { return -1 }
        let top = frontier[depth]
        if !top.type.isTextblock { return -1 }
        if try contentAfterFits(rTo, rTo.depth, top.type, unwrap(top.match), false) == nil { return -1 }
        if rTo.depth == depth, let level = try findCloseLevel(rTo), level.depth == depth { return -1 }
        var d = rTo.depth
        var after = rTo.after(d)
        while d > 1 {
            d -= 1
            if after != rTo.end(d) { break }
            after += 1
        }
        return after
    }

    func findCloseLevel(_ rTo: ResolvedPos) throws -> (depth: Int, fit: Fragment, move: ResolvedPos)? {
        var i = min(depth, rTo.depth)
        scan: while i >= 0 {
            defer { i -= 1 }
            let match = try unwrap(frontier[i].match), type = frontier[i].type
            let dropInner = i < rTo.depth && rTo.end(i + 1) == rTo.pos + (rTo.depth - (i + 1))
            guard let fit = contentAfterFits(rTo, i, type, match, dropInner) else { continue }
            var d = i - 1
            while d >= 0 {
                let m = try unwrap(frontier[d].match), t = frontier[d].type
                guard let matches = contentAfterFits(rTo, d, t, m, true), matches.childCount == 0 else { continue scan }
                d -= 1
            }
            return (i, fit, dropInner ? rTo.doc.resolve(rTo.after(i + 1)) : rTo)
        }
        return nil
    }

    func close(_ rTo: ResolvedPos) throws -> ResolvedPos? {
        guard let close = try findCloseLevel(rTo) else { return nil }
        while depth > close.depth { try closeFrontierNode() }
        if close.fit.childCount > 0 { placed = try addToFragment(placed, close.depth, close.fit) }
        let to = close.move
        var d = close.depth + 1
        while d <= to.depth {
            let node = to.node(d)
            let add = try unwrap(node.type.contentMatch.fillBefore(node.content, toEnd: true, startIndex: to.index(d)))
            try openFrontierNode(node.type, node.attrs, add)
            d += 1
        }
        return to
    }

    func openFrontierNode(_ type: NodeType, _ attrs: Attrs? = nil, _ content: Fragment? = nil) throws {
        frontier[depth].match = try unwrap(frontier[depth].match).matchType(type)
        placed = try addToFragment(placed, depth, Fragment.from(try type.create(attrs, content)))
        frontier.append(FrontierEntry(type: type, match: type.contentMatch))
    }

    func closeFrontierNode() throws {
        let open = frontier.removeLast()
        let add = try unwrap(try unwrap(open.match).fillBefore(.empty, toEnd: true))
        if add.childCount > 0 { placed = try addToFragment(placed, frontier.count, add) }
    }
}

private func dropFromFragment(_ fragment: Fragment, _ depth: Int, _ count: Int) throws -> Fragment {
    if depth == 0 { return fragment.cutByIndex(count, fragment.childCount) }
    let first = try unwrap(fragment.firstChild)
    return fragment.replaceChild(0, first.copy(try dropFromFragment(first.content, depth - 1, count)))
}

private func addToFragment(_ fragment: Fragment, _ depth: Int, _ content: Fragment) throws -> Fragment {
    if depth == 0 { return fragment.append(content) }
    let last = try unwrap(fragment.lastChild)
    return fragment.replaceChild(fragment.childCount - 1, last.copy(try addToFragment(last.content, depth - 1, content)))
}

private func contentAt(_ fragment: Fragment, _ depth: Int) throws -> Fragment {
    var fragment = fragment
    for _ in 0..<depth { fragment = try unwrap(fragment.firstChild).content }
    return fragment
}

private func closeNodeStart(_ node: Node, _ openStart: Int, _ openEnd: Int) throws -> Node {
    if openStart <= 0 { return node }
    var frag = node.content
    if openStart > 1 {
        frag = frag.replaceChild(0, try closeNodeStart(try unwrap(frag.firstChild), openStart - 1, frag.childCount == 1 ? openEnd - 1 : 0))
    }
    if openStart > 0 {
        frag = try unwrap(node.type.contentMatch.fillBefore(frag)).append(frag)
        if openEnd <= 0 { frag = frag.append(try unwrap(try unwrap(node.type.contentMatch.matchFragment(frag)).fillBefore(.empty, toEnd: true))) }
    }
    return node.copy(frag)
}

private func contentAfterFits(_ rTo: ResolvedPos, _ depth: Int, _ type: NodeType, _ match: ContentMatch, _ open: Bool) -> Fragment? {
    let node = rTo.node(depth), index = open ? rTo.indexAfter(depth) : rTo.index(depth)
    if index == node.childCount && !type.compatibleContent(node.type) { return nil }
    guard let fit = match.fillBefore(node.content, toEnd: true, startIndex: index) else { return nil }
    return invalidMarks(type, node.content, index) ? nil : fit
}

private func invalidMarks(_ type: NodeType, _ fragment: Fragment, _ start: Int) -> Bool {
    var i = start
    while i < fragment.childCount {
        if !type.allowsMarks(fragment.child(i).marks) { return true }
        i += 1
    }
    return false
}

private func definesContent(_ type: NodeType) -> Bool {
    type.spec.defining || (type.spec.definingForContent ?? false)
}

private func maxOpen(_ frag: Fragment, _ side: Int) -> Int {
    var frag = frag, count = 0
    while true {
        guard let ch = side < 0 ? frag.firstChild : frag.lastChild, !ch.isAtom else { return count }
        frag = ch.content
        count += 1
    }
}

func replaceRange(_ tr: Transform, _ from: Int, _ to: Int, _ slice: Slice) throws {
    var from = from, to = to
    if slice.size == 0 { try tr.deleteRange(from, to); return }

    let rFrom = tr.doc.resolve(from), rTo = tr.doc.resolve(to)
    if fitsTrivially(rFrom, rTo, slice) { try tr.step(ReplaceStep(from, to, slice)); return }

    var targetDepths = coveredDepths(rFrom, rTo)
    if targetDepths.last == 0 { targetDepths.removeLast() }
    var preferredTarget = -(rFrom.depth + 1)
    targetDepths.insert(preferredTarget, at: 0)
    var d = rFrom.depth, pos = rFrom.pos - 1
    while d > 0 {
        let spec = rFrom.node(d).type.spec
        if spec.defining || (spec.definingAsContext ?? false) || spec.isolating { break }
        if targetDepths.contains(d) { preferredTarget = d }
        else if rFrom.before(d) == pos { targetDepths.insert(-d, at: 1) }
        d -= 1
        pos -= 1
    }
    let preferredTargetIndex = targetDepths.firstIndex(of: preferredTarget)!

    // JS pushes `content.firstChild`, which may be null at the innermost level.
    var leftNodes: [Node?] = []
    var preferredDepth = slice.openStart
    var content = slice.content
    var i = 0
    while true {
        let node = content.firstChild
        leftNodes.append(node)
        if i == slice.openStart { break }
        guard let node else { throw PMError.generic("Cannot read properties of null (reading 'content')") }
        content = node.content
        i += 1
    }

    d = preferredDepth - 1
    while d >= 0 {
        guard let leftNode = leftNodes[d] else { throw PMError.generic("Cannot read properties of null (reading 'type')") }
        let def = definesContent(leftNode.type)
        if def && !leftNode.sameMarkup(rFrom.node(abs(preferredTarget) - 1)) { preferredDepth = d }
        else if def || !leftNode.type.isTextblock { break }
        d -= 1
    }

    var j = slice.openStart
    while j >= 0 {
        let openDepth = (j + preferredDepth + 1) % (slice.openStart + 1)
        if openDepth < leftNodes.count, let insert = leftNodes[openDepth] {
            for k in 0..<targetDepths.count {
                var targetDepth = targetDepths[(k + preferredTargetIndex) % targetDepths.count]
                var expand = true
                if targetDepth < 0 { expand = false; targetDepth = -targetDepth }
                let parent = rFrom.node(targetDepth - 1), index = rFrom.index(targetDepth - 1)
                if parent.canReplaceWith(index, index, insert.type, insert.marks) {
                    try tr.replace(rFrom.before(targetDepth), expand ? rTo.after(targetDepth) : to,
                                   Slice(try closeFragment(slice.content, 0, slice.openStart, openDepth, nil), openDepth, slice.openEnd))
                    return
                }
            }
        }
        j -= 1
    }

    let startSteps = tr.steps.count
    var k = targetDepths.count - 1
    while k >= 0 {
        try tr.replace(from, to, slice)
        if tr.steps.count > startSteps { break }
        let depth = targetDepths[k]
        k -= 1
        if depth < 0 { continue }
        from = rFrom.before(depth)
        to = rTo.after(depth)
    }
}

private func closeFragment(_ fragment: Fragment, _ depth: Int, _ oldOpen: Int, _ newOpen: Int, _ parent: Node?) throws -> Fragment {
    var fragment = fragment
    if depth < oldOpen {
        let first = try unwrap(fragment.firstChild)
        fragment = fragment.replaceChild(0, first.copy(try closeFragment(first.content, depth + 1, oldOpen, newOpen, first)))
    }
    if depth > newOpen {
        let match = try unwrap(parent).checkedContentMatchAt(0)
        let start = try unwrap(match.fillBefore(fragment)).append(fragment)
        fragment = start.append(try unwrap(try unwrap(match.matchFragment(start)).fillBefore(.empty, toEnd: true)))
    }
    return fragment
}

func replaceRangeWith(_ tr: Transform, _ from: Int, _ to: Int, _ node: Node) throws {
    var from = from, to = to
    if !node.isInline && from == to && tr.doc.resolve(from).parent.content.size > 0 {
        if let point = insertPoint(tr.doc, from, node.type) { from = point; to = point }
    }
    try tr.replaceRange(from, to, Slice(Fragment.from(node), 0, 0))
}

func deleteRange(_ tr: Transform, _ from: Int, _ to: Int) throws {
    var from = from, to = to
    var rFrom = tr.doc.resolve(from), rTo = tr.doc.resolve(to)

    if rFrom.parent.isTextblock && rTo.parent.isTextblock && rFrom.start() != rTo.start() &&
        rFrom.parentOffset == 0 && rTo.parentOffset == 0 {
        let shared = rFrom.sharedDepth(to)
        var isolated = false
        var d = rFrom.depth
        while d > shared { if rFrom.node(d).type.spec.isolating { isolated = true }; d -= 1 }
        d = rTo.depth
        while d > shared { if rTo.node(d).type.spec.isolating { isolated = true }; d -= 1 }
        if !isolated {
            d = rFrom.depth
            while d > 0 && from == rFrom.start(d) { from = rFrom.before(d); d -= 1 }
            d = rTo.depth
            while d > 0 && to == rTo.start(d) { to = rTo.before(d); d -= 1 }
            rFrom = tr.doc.resolve(from)
            rTo = tr.doc.resolve(to)
        }
    }

    let covered = coveredDepths(rFrom, rTo)
    for (i, depth) in covered.enumerated() {
        let last = i == covered.count - 1
        if (last && depth == 0) || rFrom.node(depth).type.contentMatch.validEnd {
            try tr.delete(rFrom.start(depth), rTo.end(depth))
            return
        }
        if depth > 0 && (last || rFrom.node(depth - 1).canReplace(rFrom.index(depth - 1), rTo.indexAfter(depth - 1))) {
            try tr.delete(rFrom.before(depth), rTo.after(depth))
            return
        }
    }
    var d = 1
    while d <= rFrom.depth && d <= rTo.depth {
        if from - rFrom.start(d) == rFrom.depth - d && to > rFrom.end(d) && rTo.end(d) - to != rTo.depth - d &&
            rFrom.start(d - 1) == rTo.start(d - 1) && rFrom.node(d - 1).canReplace(rFrom.index(d - 1), rTo.index(d - 1)) {
            try tr.delete(rFrom.before(d), to)
            return
        }
        d += 1
    }
    try tr.delete(from, to)
}

private func coveredDepths(_ rFrom: ResolvedPos, _ rTo: ResolvedPos) -> [Int] {
    var result: [Int] = []
    let minDepth = min(rFrom.depth, rTo.depth)
    var d = minDepth
    while d >= 0 {
        let start = rFrom.start(d)
        if start < rFrom.pos - (rFrom.depth - d) ||
            rTo.end(d) > rTo.pos + (rTo.depth - d) ||
            rFrom.node(d).type.spec.isolating ||
            rTo.node(d).type.spec.isolating { break }
        if start == rTo.start(d) ||
            (d == rFrom.depth && d == rTo.depth && rFrom.parent.inlineContent && rTo.parent.inlineContent &&
             d > 0 && rTo.start(d - 1) == start - 1) {
            result.append(d)
        }
        d -= 1
    }
    return result
}
