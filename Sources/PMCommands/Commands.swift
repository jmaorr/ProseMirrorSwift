// Port of prosemirror-commands/src/commands.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import Foundation
import PMModel
import PMTransform
import PMState

public let deleteSelection: Command = { state, dispatch, _ in
    if state.selection.empty { return false }
    return CommandErrors.run {
        if let dispatch { dispatch(try state.tr.deleteSelection().scrollIntoView()) }
        return true
    }
}

private func atBlockStart(_ state: EditorState, _ view: EditorView?) -> ResolvedPos? {
    guard let cursor = state.selection.cursor else { return nil }
    if view != nil ? !view!.endOfTextblock("backward", state) : cursor.parentOffset > 0 { return nil }
    return cursor
}

public let joinBackward: Command = { state, dispatch, view in
    guard let cursor = atBlockStart(state, view) else { return false }
    return CommandErrors.run {
        guard let cut = findCutBefore(cursor) else {
            guard let range = cursor.blockRange(), let target = liftTarget(range) else { return false }
            if let dispatch { dispatch(try state.tr.lift(range, target).scrollIntoView()) }
            return true
        }
        let before = cut.nodeBefore!
        if try deleteBarrier(state, cut, dispatch, -1) { return true }

        if cursor.parent.content.size == 0 && (textblockAt(before, .end) || NodeSelection.isSelectable(before)) {
            var depth = cursor.depth
            while true {
                if let delStep = try replaceStep(state.doc, cursor.before(depth), cursor.after(depth), .empty) as? ReplaceStep,
                   delStep.slice.size < delStep.to - delStep.from {
                    if let dispatch {
                        let tr = try state.tr.step(delStep)
                        tr.setSelection(textblockAt(before, .end)
                            ? Selection.findFrom(tr.doc.resolve(tr.mapping.map(cut.pos, assoc: -1)), -1)!
                            : NodeSelection.create(tr.doc, cut.pos - before.nodeSize))
                        dispatch(tr.scrollIntoView())
                    }
                    return true
                }
                if depth == 1 || cursor.node(depth - 1).childCount > 1 { break }
                depth -= 1
            }
        }

        if before.isAtom && cut.depth == cursor.depth - 1 {
            if let dispatch { dispatch(try state.tr.delete(cut.pos - before.nodeSize, cut.pos).scrollIntoView()) }
            return true
        }
        return false
    }
}

public let joinTextblockBackward: Command = { state, dispatch, view in
    guard let cursor = atBlockStart(state, view), let cut = findCutBefore(cursor) else { return false }
    return CommandErrors.run { try joinTextblocksAround(state, cut, dispatch) }
}

public let joinTextblockForward: Command = { state, dispatch, view in
    guard let cursor = atBlockEnd(state, view), let cut = findCutAfter(cursor) else { return false }
    return CommandErrors.run { try joinTextblocksAround(state, cut, dispatch) }
}

private func joinTextblocksAround(_ state: EditorState, _ cut: ResolvedPos, _ dispatch: Dispatch?) throws -> Bool {
    var beforeText = cut.nodeBefore!, beforePos = cut.pos - 1
    while !beforeText.isTextblock {
        if beforeText.type.spec.isolating { return false }
        guard let child = beforeText.lastChild else { return false }
        beforeText = child
        beforePos -= 1
    }
    var afterText = cut.nodeAfter!, afterPos = cut.pos + 1
    while !afterText.isTextblock {
        if afterText.type.spec.isolating { return false }
        guard let child = afterText.firstChild else { return false }
        afterText = child
        afterPos += 1
    }
    guard let step = try replaceStep(state.doc, beforePos, afterPos, .empty) else { return false }
    let stepFrom = (step as? ReplaceStep)?.from ?? (step as? ReplaceAroundStep)?.from
    if stepFrom != beforePos { return false }
    if let rs = step as? ReplaceStep, rs.slice.size >= afterPos - beforePos { return false }
    if let dispatch {
        let tr = try state.tr.step(step)
        tr.setSelection(TextSelection.create(tr.doc, beforePos))
        dispatch(tr.scrollIntoView())
    }
    return true
}

private enum Side { case start, end }

private func textblockAt(_ node: Node, _ side: Side, only: Bool = false) -> Bool {
    var scan: Node? = node
    while let s = scan {
        if s.isTextblock { return true }
        if only && s.childCount != 1 { return false }
        scan = side == .start ? s.firstChild : s.lastChild
    }
    return false
}

public let selectNodeBackward: Command = { state, dispatch, view in
    let head = state.selection.headPos
    var cut: ResolvedPos? = head
    if !state.selection.empty { return false }
    if head.parent.isTextblock {
        if view != nil ? !view!.endOfTextblock("backward", state) : head.parentOffset > 0 { return false }
        cut = findCutBefore(head)
    }
    guard let cut, let node = cut.nodeBefore, NodeSelection.isSelectable(node) else { return false }
    if let dispatch { dispatch(state.tr.setSelection(NodeSelection.create(state.doc, cut.pos - node.nodeSize)).scrollIntoView()) }
    return true
}

private func findCutBefore(_ pos: ResolvedPos) -> ResolvedPos? {
    if !pos.parent.type.spec.isolating {
        var i = pos.depth - 1
        while i >= 0 {
            if pos.index(i) > 0 { return pos.doc.resolve(pos.before(i + 1)) }
            if pos.node(i).type.spec.isolating { break }
            i -= 1
        }
    }
    return nil
}

private func atBlockEnd(_ state: EditorState, _ view: EditorView?) -> ResolvedPos? {
    guard let cursor = state.selection.cursor else { return nil }
    if view != nil ? !view!.endOfTextblock("forward", state) : cursor.parentOffset < cursor.parent.content.size { return nil }
    return cursor
}

public let joinForward: Command = { state, dispatch, view in
    guard let cursor = atBlockEnd(state, view), let cut = findCutAfter(cursor) else { return false }
    return CommandErrors.run {
        let after = cut.nodeAfter!
        if try deleteBarrier(state, cut, dispatch, 1) { return true }
        if cursor.parent.content.size == 0 && (textblockAt(after, .start) || NodeSelection.isSelectable(after)) {
            if let delStep = try replaceStep(state.doc, cursor.before(), cursor.after(), .empty) as? ReplaceStep,
               delStep.slice.size < delStep.to - delStep.from {
                if let dispatch {
                    let tr = try state.tr.step(delStep)
                    tr.setSelection(textblockAt(after, .start) ? Selection.findFrom(tr.doc.resolve(tr.mapping.map(cut.pos)), 1)!
                        : NodeSelection.create(tr.doc, tr.mapping.map(cut.pos)))
                    dispatch(tr.scrollIntoView())
                }
                return true
            }
        }
        if after.isAtom && cut.depth == cursor.depth - 1 {
            if let dispatch { dispatch(try state.tr.delete(cut.pos, cut.pos + after.nodeSize).scrollIntoView()) }
            return true
        }
        return false
    }
}

public let selectNodeForward: Command = { state, dispatch, view in
    let head = state.selection.headPos
    var cut: ResolvedPos? = head
    if !state.selection.empty { return false }
    if head.parent.isTextblock {
        if view != nil ? !view!.endOfTextblock("forward", state) : head.parentOffset < head.parent.content.size { return false }
        cut = findCutAfter(head)
    }
    guard let cut, let node = cut.nodeAfter, NodeSelection.isSelectable(node) else { return false }
    if let dispatch { dispatch(state.tr.setSelection(NodeSelection.create(state.doc, cut.pos)).scrollIntoView()) }
    return true
}

private func findCutAfter(_ pos: ResolvedPos) -> ResolvedPos? {
    if !pos.parent.type.spec.isolating {
        var i = pos.depth - 1
        while i >= 0 {
            let parent = pos.node(i)
            if pos.index(i) + 1 < parent.childCount { return pos.doc.resolve(pos.after(i + 1)) }
            if parent.type.spec.isolating { break }
            i -= 1
        }
    }
    return nil
}

public let joinUp: Command = { state, dispatch, _ in
    let sel = state.selection
    let point: Int
    if let nodeSel = sel as? NodeSelection {
        if nodeSel.node.isTextblock || !canJoin(state.doc, sel.from) { return false }
        point = sel.from
    } else {
        guard let p = joinPoint(state.doc, sel.from, -1) else { return false }
        point = p
    }
    return CommandErrors.run {
        if let dispatch {
            let tr = try state.tr.join(point)
            if sel is NodeSelection {
                tr.setSelection(NodeSelection.create(tr.doc, point - state.doc.resolve(point).nodeBefore!.nodeSize))
            }
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

public let joinDown: Command = { state, dispatch, _ in
    let sel = state.selection
    let point: Int
    if let nodeSel = sel as? NodeSelection {
        if nodeSel.node.isTextblock || !canJoin(state.doc, sel.to) { return false }
        point = sel.to
    } else {
        guard let p = joinPoint(state.doc, sel.to, 1) else { return false }
        point = p
    }
    return CommandErrors.run {
        if let dispatch { dispatch(try state.tr.join(point).scrollIntoView()) }
        return true
    }
}

public let lift: Command = { state, dispatch, _ in
    let sel = state.selection
    guard let range = sel.fromPos.blockRange(sel.toPos), let target = liftTarget(range) else { return false }
    return CommandErrors.run {
        if let dispatch { dispatch(try state.tr.lift(range, target).scrollIntoView()) }
        return true
    }
}

public let newlineInCode: Command = { state, dispatch, _ in
    let head = state.selection.headPos, anchor = state.selection.anchorPos
    if !head.parent.type.spec.code || !head.sameParent(anchor) { return false }
    return CommandErrors.run {
        if let dispatch { dispatch(try state.tr.insertText("\n").scrollIntoView()) }
        return true
    }
}

private func defaultBlockAt(_ match: ContentMatch) -> NodeType? {
    for i in 0..<match.edgeCount {
        let type = match.edge(i).type
        if type.isTextblock && !type.hasRequiredAttrs() { return type }
    }
    return nil
}

public let exitCode: Command = { state, dispatch, _ in
    let head = state.selection.headPos, anchor = state.selection.anchorPos
    if !head.parent.type.spec.code || !head.sameParent(anchor) { return false }
    let above = head.node(-1), after = head.indexAfter(-1)
    guard let type = defaultBlockAt(above.contentMatchAt(after)), above.canReplaceWith(after, after, type) else { return false }
    return CommandErrors.run {
        if let dispatch {
            let pos = head.after()
            let tr = try state.tr.replaceWith(pos, pos, type.createAndFill()!)
            tr.setSelection(Selection.near(tr.doc.resolve(pos), 1))
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

public let createParagraphNear: Command = { state, dispatch, _ in
    let sel = state.selection, from = sel.fromPos, to = sel.toPos
    if sel is AllSelection || from.parent.inlineContent || to.parent.inlineContent { return false }
    guard let type = defaultBlockAt(to.parent.contentMatchAt(to.indexAfter())), type.isTextblock else { return false }
    return CommandErrors.run {
        if let dispatch {
            let side = (from.parentOffset == 0 && to.index() < to.parent.childCount ? from : to).pos
            let tr = try state.tr.insert(side, type.createAndFill()!)
            tr.setSelection(TextSelection.create(tr.doc, side + 1))
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

public let liftEmptyBlock: Command = { state, dispatch, _ in
    guard let cursor = state.selection.cursor, cursor.parent.content.size == 0 else { return false }
    return CommandErrors.run {
        if cursor.depth > 1 && cursor.after() != cursor.end(-1) {
            let before = cursor.before()
            if canSplit(state.doc, before) {
                if let dispatch { dispatch(try state.tr.split(before).scrollIntoView()) }
                return true
            }
        }
        guard let range = cursor.blockRange(), let target = liftTarget(range) else { return false }
        if let dispatch { dispatch(try state.tr.lift(range, target).scrollIntoView()) }
        return true
    }
}

/// Create a variant of splitBlock that uses a custom function to determine the type of the newly split off block.
public func splitBlockAs(_ splitNode: ((Node, Bool, ResolvedPos) -> NodeTypeWithAttrs?)? = nil) -> Command {
    return { state, dispatch, _ in
        CommandErrors.run {
            if let nodeSel = state.selection as? NodeSelection, nodeSel.node.isBlock {
                let from = nodeSel.fromPos
                if from.parentOffset == 0 || !canSplit(state.doc, from.pos) { return false }
                if let dispatch { dispatch(try state.tr.split(from.pos).scrollIntoView()) }
                return true
            }
            if state.selection.fromPos.depth == 0 { return false }
            let tr = state.tr
            if !state.selection.empty && (state.selection is TextSelection || state.selection is AllSelection) {
                try tr.deleteSelection()
            }
            let from = tr.selection.fromPos, mapFrom = tr.steps.count
            var types: [NodeTypeWithAttrs?] = []
            var splitDepth = 0
            var deflt: NodeType? = nil
            var atEnd = false, atStart = false
            var d = from.depth
            while true {
                let node = from.node(d)
                if node.isBlock {
                    // JS: $from.node(-1) at depth 0 is undefined -> TypeError.
                    if d == 0 { throw PMError.generic("Cannot read properties of undefined (reading 'contentMatchAt')") }
                    atEnd = from.end(d) == from.pos + (from.depth - d)
                    atStart = from.start(d) == from.pos - (from.depth - d)
                    deflt = defaultBlockAt(from.node(d - 1).contentMatchAt(from.indexAfter(d - 1)))
                    let splitType = splitNode?(from.parent, atEnd, from)
                    types.insert(splitType ?? (atEnd && deflt != nil ? NodeTypeWithAttrs(deflt!) : nil), at: 0)
                    splitDepth = d
                    break
                } else {
                    if d == 1 { return false }
                    types.insert(nil, at: 0)
                }
                d -= 1
            }
            let splitPos = from.pos
            var can = canSplit(tr.doc, splitPos, types.count, types)
            if !can {
                types[0] = deflt.map { NodeTypeWithAttrs($0) }
                can = canSplit(tr.doc, splitPos, types.count, types)
            }
            if !can { return false }
            try tr.split(splitPos, types.count, types)
            if !atEnd && atStart && from.node(splitDepth).type !== deflt {
                let mapping = tr.mapping.slice(mapFrom)
                let first = mapping.map(from.before(splitDepth)), rFirst = tr.doc.resolve(first)
                if let deflt, from.node(splitDepth - 1).canReplaceWith(rFirst.index(), rFirst.index() + 1, deflt) {
                    try tr.setNodeMarkup(mapping.map(from.before(splitDepth)), deflt)
                }
            }
            if let dispatch { dispatch(tr.scrollIntoView()) }
            return true
        }
    }
}

public let splitBlock: Command = splitBlockAs()

public let splitBlockKeepMarks: Command = { state, dispatch, view in
    splitBlock(state, dispatch.map { dispatch in
        { tr in
            let marks = state.storedMarks ?? (state.selection.toPos.parentOffset > 0 ? state.selection.fromPos.marks() : nil)
            if let marks { tr.ensureMarks(marks) }
            dispatch(tr)
        }
    }, view)
}

public let selectParentNode: Command = { state, dispatch, _ in
    let from = state.selection.fromPos, to = state.selection.to
    let same = from.sharedDepth(to)
    if same == 0 { return false }
    let pos = from.before(same)
    if let dispatch { dispatch(state.tr.setSelection(NodeSelection.create(state.doc, pos))) }
    return true
}

public let selectAll: Command = { state, dispatch, _ in
    if let dispatch { dispatch(state.tr.setSelection(AllSelection(state.doc))) }
    return true
}

private func joinMaybeClear(_ state: EditorState, _ pos: ResolvedPos, _ dispatch: Dispatch?) throws -> Bool {
    let index = pos.index()
    guard let before = pos.nodeBefore, let after = pos.nodeAfter, before.type.compatibleContent(after.type) else { return false }
    if before.content.size == 0 && pos.parent.canReplace(index - 1, index) {
        if let dispatch { dispatch(try state.tr.delete(pos.pos - before.nodeSize, pos.pos).scrollIntoView()) }
        return true
    }
    if !pos.parent.canReplace(index, index + 1) || !(after.isTextblock || canJoin(state.doc, pos.pos)) { return false }
    if let dispatch { dispatch(try state.tr.join(pos.pos).scrollIntoView()) }
    return true
}

private func deleteBarrier(_ state: EditorState, _ cut: ResolvedPos, _ dispatch: Dispatch?, _ dir: Int) throws -> Bool {
    let before = cut.nodeBefore!, after = cut.nodeAfter!
    let isolated = before.type.spec.isolating || after.type.spec.isolating
    if !isolated, try joinMaybeClear(state, cut, dispatch) { return true }

    let canDelAfter = !isolated && cut.parent.canReplace(cut.index(), cut.index() + 1)
    if canDelAfter {
        let match = before.contentMatchAt(before.childCount)
        if let conn = match.findWrapping(after.type), match.matchType(conn.first ?? after.type)!.validEnd {
            if let dispatch {
                let end = cut.pos + after.nodeSize
                var wrap = Fragment.empty
                for t in conn.reversed() { wrap = Fragment.from(try t.create(nil, wrap)) }
                wrap = Fragment.from(before.copy(wrap))
                let tr = try state.tr.step(ReplaceAroundStep(cut.pos - 1, end, cut.pos, end, Slice(wrap, 1, 0), conn.count, structure: true))
                let joinAt = tr.doc.resolve(end + 2 * conn.count)
                if let na = joinAt.nodeAfter, na.type === before.type, canJoin(tr.doc, joinAt.pos) { try tr.join(joinAt.pos) }
                dispatch(tr.scrollIntoView())
            }
            return true
        }
    }

    let selAfter = after.type.spec.isolating || (dir > 0 && isolated) ? nil : Selection.findFrom(cut, 1)
    if let selAfter, let range = selAfter.fromPos.blockRange(selAfter.toPos), let target = liftTarget(range), target >= cut.depth {
        if let dispatch { dispatch(try state.tr.lift(range, target).scrollIntoView()) }
        return true
    }

    if canDelAfter && textblockAt(after, .start, only: true) && textblockAt(before, .end) {
        var at = before
        var wrap: [Node] = []
        while true {
            wrap.append(at)
            if at.isTextblock { break }
            at = at.lastChild!
        }
        var afterText = after, afterDepth = 1
        while !afterText.isTextblock { afterText = afterText.firstChild!; afterDepth += 1 }
        if at.canReplace(at.childCount, at.childCount, afterText.content) {
            if let dispatch {
                var end = Fragment.empty
                for w in wrap.reversed() { end = Fragment.from(w.copy(end)) }
                let tr = try state.tr.step(ReplaceAroundStep(cut.pos - wrap.count, cut.pos + after.nodeSize,
                                                             cut.pos + afterDepth, cut.pos + after.nodeSize - afterDepth,
                                                             Slice(end, wrap.count, 0), 0, structure: true))
                dispatch(tr.scrollIntoView())
            }
            return true
        }
    }
    return false
}

private func selectTextblockSide(_ side: Int) -> Command {
    return { state, dispatch, _ in
        let sel = state.selection, pos = side < 0 ? sel.fromPos : sel.toPos
        var depth = pos.depth
        while pos.node(depth).isInline {
            if depth == 0 { return false }
            depth -= 1
        }
        if !pos.node(depth).isTextblock { return false }
        if let dispatch {
            dispatch(state.tr.setSelection(TextSelection.create(state.doc, side < 0 ? pos.start(depth) : pos.end(depth))))
        }
        return true
    }
}

public let selectTextblockStart = selectTextblockSide(-1)
public let selectTextblockEnd = selectTextblockSide(1)

// MARK: - Parameterized commands

public func wrapIn(_ nodeType: NodeType, _ attrs: Attrs? = nil) -> Command {
    return { state, dispatch, _ in
        let sel = state.selection
        guard let range = sel.fromPos.blockRange(sel.toPos), let wrapping = findWrapping(range, nodeType, attrs) else { return false }
        return CommandErrors.run {
            if let dispatch { dispatch(try state.tr.wrap(range, wrapping).scrollIntoView()) }
            return true
        }
    }
}

public func setBlockType(_ nodeType: NodeType, _ attrs: Attrs? = nil) -> Command {
    return { state, dispatch, _ in
        var applicable = false
        for range in state.selection.ranges where !applicable {
            state.doc.nodesBetween(range.from.pos, range.to.pos) { node, pos, _, _ in
                if applicable { return false }
                if !node.isTextblock || node.hasMarkup(nodeType, attrs) { return true }
                if node.type === nodeType {
                    applicable = true
                } else {
                    let rpos = state.doc.resolve(pos), index = rpos.index()
                    applicable = rpos.parent.canReplaceWith(index, index + 1, nodeType)
                }
                return true
            }
        }
        if !applicable { return false }
        return CommandErrors.run {
            if let dispatch {
                let tr = state.tr
                for range in state.selection.ranges { try tr.setBlockType(range.from.pos, range.to.pos, nodeType, attrs) }
                dispatch(tr.scrollIntoView())
            }
            return true
        }
    }
}

private func markApplies(_ doc: Node, _ ranges: [SelectionRange], _ type: MarkType, _ enterAtoms: Bool) -> Bool {
    for range in ranges {
        let from = range.from, to = range.to
        var can = from.depth == 0 ? doc.inlineContent && doc.type.allowsMarkType(type) : false
        doc.nodesBetween(from.pos, to.pos) { node, pos, _, _ in
            if can || !enterAtoms && node.isAtom && node.isInline && pos >= from.pos && pos + node.nodeSize <= to.pos { return false }
            can = node.inlineContent && node.type.allowsMarkType(type)
            return true
        }
        if can { return true }
    }
    return false
}

private func removeInlineAtoms(_ ranges: [SelectionRange]) -> [SelectionRange] {
    var result: [SelectionRange] = []
    for range in ranges {
        var from = range.from
        let to = range.to
        from.doc.nodesBetween(from.pos, to.pos) { node, pos, _, _ in
            if node.isAtom && node.content.size > 0 && node.isInline && pos >= from.pos && pos + node.nodeSize <= to.pos {
                if pos + 1 > from.pos { result.append(SelectionRange(from, from.doc.resolve(pos + 1))) }
                from = from.doc.resolve(pos + 1 + node.content.size)
                return false
            }
            return true
        }
        if from.pos < to.pos { result.append(SelectionRange(from, to)) }
    }
    return result
}

private func isWhitespace(_ u: UInt16) -> Bool {
    // JS \s
    switch u {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
    default: return false
    }
}

public struct ToggleMarkOptions {
    public var removeWhenPresent = true
    public var enterInlineAtoms = true
    public var includeWhitespace = false
    public init(removeWhenPresent: Bool = true, enterInlineAtoms: Bool = true, includeWhitespace: Bool = false) {
        self.removeWhenPresent = removeWhenPresent
        self.enterInlineAtoms = enterInlineAtoms
        self.includeWhitespace = includeWhitespace
    }
}

/// Create a command function that toggles the given mark with the given attributes.
public func toggleMark(_ markType: MarkType, _ attrs: Attrs? = nil, _ options: ToggleMarkOptions = ToggleMarkOptions()) -> Command {
    let removeWhenPresent = options.removeWhenPresent
    let enterAtoms = options.enterInlineAtoms
    let dropSpace = !options.includeWhitespace
    return { state, dispatch, _ in
        let sel = state.selection
        var ranges = sel.ranges
        let cursor = sel.cursor
        if (sel.empty && cursor == nil) || !markApplies(state.doc, ranges, markType, enterAtoms) { return false }
        return CommandErrors.run {
            guard let dispatch else { return true }
            if let cursor {
                if markType.isInSet(state.storedMarks ?? cursor.marks()) != nil {
                    dispatch(state.tr.removeStoredMark(markType))
                } else {
                    dispatch(state.tr.addStoredMark(try markType.create(attrs)))
                }
            } else {
                let tr = state.tr
                if !enterAtoms { ranges = removeInlineAtoms(ranges) }
                let add: Bool
                if removeWhenPresent {
                    add = !ranges.contains { state.doc.rangeHasMark($0.from.pos, $0.to.pos, markType) }
                } else {
                    add = !ranges.allSatisfy { r in
                        var missing = false
                        tr.doc.nodesBetween(r.from.pos, r.to.pos) { node, pos, parent, _ in
                            if missing { return false }
                            var onlySpace = false
                            if node.isText {
                                let t = node.textBetween(max(0, r.from.pos - pos), min(node.nodeSize, r.to.pos - pos))
                                onlySpace = t.utf16.allSatisfy(isWhitespace)
                            }
                            missing = markType.isInSet(node.marks) == nil && parent != nil && parent!.type.allowsMarkType(markType) && !(node.isText && onlySpace)
                            return true
                        }
                        return !missing
                    }
                }
                for range in ranges {
                    if !add {
                        try tr.removeMark(range.from.pos, range.to.pos, markType)
                    } else {
                        var from = range.from.pos, to = range.to.pos
                        let start = range.from.nodeAfter, end = range.to.nodeBefore
                        var spaceStart = 0, spaceEnd = 0
                        if dropSpace, let t = start as? TextNode { spaceStart = t.units.prefix(while: isWhitespace).count }
                        if dropSpace, let t = end as? TextNode { spaceEnd = t.units.reversed().prefix(while: isWhitespace).count }
                        if from + spaceStart < to { from += spaceStart; to -= spaceEnd }
                        try tr.addMark(from, to, try markType.create(attrs))
                    }
                }
                dispatch(tr.scrollIntoView())
            }
            return true
        }
    }
}

private func wrapDispatchForJoin(_ dispatch: @escaping Dispatch, _ isJoinable: @escaping (Node, Node) -> Bool) -> Dispatch {
    return { tr in
        if !tr.isGeneric { return dispatch(tr) }
        var ranges: [Int] = []
        for map in tr.mapping.maps {
            for j in 0..<ranges.count { ranges[j] = map.map(ranges[j]) }
            map.forEach { _, _, from, to in ranges.append(from); ranges.append(to) }
        }
        var joinable: [Int] = []
        var i = 0
        while i < ranges.count {
            let from = ranges[i], to = ranges[i + 1]
            let rFrom = tr.doc.resolve(from), depth = rFrom.sharedDepth(to), parent = rFrom.node(depth)
            var index = rFrom.indexAfter(depth), pos = rFrom.after(depth + 1)
            while pos <= to {
                guard let after = parent.maybeChild(index) else { break }
                if index > 0 && !joinable.contains(pos) {
                    let before = parent.child(index - 1)
                    if before.type === after.type && isJoinable(before, after) { joinable.append(pos) }
                }
                pos += after.nodeSize
                index += 1
            }
            i += 2
        }
        joinable.sort()
        for p in joinable.reversed() where canJoin(tr.doc, p) { try? tr.join(p) }
        dispatch(tr)
    }
}

public func autoJoin(_ command: @escaping Command, _ isJoinable: @escaping (Node, Node) -> Bool) -> Command {
    return { state, dispatch, view in command(state, dispatch.map { wrapDispatchForJoin($0, isJoinable) }, view) }
}

public func autoJoin(_ command: @escaping Command, _ typeNames: [String]) -> Command {
    autoJoin(command) { node, _ in typeNames.contains(node.type.name) }
}

/// Combine a number of command functions into a single function (which calls them one by one until one returns true).
public func chainCommands(_ commands: Command...) -> Command {
    chainCommands(commands)
}

public func chainCommands(_ commands: [Command]) -> Command {
    return { state, dispatch, view in
        let errors = CommandErrors.errorCount
        for command in commands {
            if command(state, dispatch, view) { return true }
            // A failed command aborts the chain, as an exception would in JS.
            if CommandErrors.errorCount != errors { return false }
        }
        return false
    }
}

private let backspace = chainCommands(deleteSelection, joinBackward, selectNodeBackward)
private let del = chainCommands(deleteSelection, joinForward, selectNodeForward)

public let pcBaseKeymap: [String: Command] = [
    "Enter": chainCommands(newlineInCode, createParagraphNear, liftEmptyBlock, splitBlock),
    "Mod-Enter": exitCode,
    "Backspace": backspace,
    "Mod-Backspace": backspace,
    "Shift-Backspace": backspace,
    "Delete": del,
    "Mod-Delete": del,
    "Mod-a": selectAll,
]

public let macBaseKeymap: [String: Command] = {
    var map: [String: Command] = [
        "Ctrl-h": backspace,
        "Alt-Backspace": backspace,
        "Ctrl-d": del,
        "Ctrl-Alt-Backspace": del,
        "Alt-Delete": del,
        "Alt-d": del,
        "Ctrl-a": selectTextblockStart,
        "Ctrl-e": selectTextblockEnd,
    ]
    for (k, v) in pcBaseKeymap { map[k] = v }
    return map
}()

#if os(macOS) || os(iOS) || os(visionOS)
public let baseKeymap = macBaseKeymap
#else
public let baseKeymap = pcBaseKeymap
#endif
