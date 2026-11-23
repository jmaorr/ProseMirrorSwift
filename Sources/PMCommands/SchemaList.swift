// Port of the command part of prosemirror-schema-list/src/schema-list.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import PMModel
import PMTransform
import PMState

/// Returns a command function that wraps the selection in a list with the given type and attributes.
public func wrapInList(_ listType: NodeType, _ attrs: Attrs? = nil) -> Command {
    return { state, dispatch, _ in
        let sel = state.selection
        guard let range = sel.fromPos.blockRange(sel.toPos) else { return false }
        return CommandErrors.run {
            let tr = dispatch != nil ? state.tr : nil
            if try !wrapRangeInList(tr, range, listType, attrs) { return false }
            if let dispatch { dispatch(tr!.scrollIntoView()) }
            return true
        }
    }
}

/// Try to wrap the given node range in a list of the given type.
public func wrapRangeInList(_ tr: Transaction?, _ range: NodeRange, _ listType: NodeType, _ attrs: Attrs? = nil) throws -> Bool {
    var range = range
    var doJoin = false, outerRange = range
    let doc = range.from.doc
    if range.depth >= 2 && range.from.node(range.depth - 1).type.compatibleContent(listType) && range.startIndex == 0 {
        if range.from.index(range.depth - 1) == 0 { return false }
        let insert = doc.resolve(range.start - 2)
        outerRange = NodeRange(insert, insert, range.depth)
        if range.endIndex < range.parent.childCount {
            range = NodeRange(range.from, doc.resolve(range.to.end(range.depth)), range.depth)
        }
        doJoin = true
    }
    guard let wrap = findWrapping(outerRange, listType, attrs, innerRange: range) else { return false }
    if let tr { try doWrapInList(tr, range, wrap, doJoin, listType) }
    return true
}

private func doWrapInList(_ tr: Transaction, _ range: NodeRange, _ wrappers: [NodeTypeWithAttrs], _ joinBefore: Bool, _ listType: NodeType) throws {
    var content = Fragment.empty
    for w in wrappers.reversed() { content = Fragment.from(try w.type.create(w.attrs, content)) }
    try tr.step(ReplaceAroundStep(range.start - (joinBefore ? 2 : 0), range.end, range.start, range.end,
                                  Slice(content, 0, 0), wrappers.count, structure: true))
    var found = 0
    for (i, w) in wrappers.enumerated() where w.type === listType { found = i + 1 }
    let splitDepth = wrappers.count - found
    var splitPos = range.start + wrappers.count - (joinBefore ? 2 : 0)
    let parent = range.parent
    var first = true
    for i in range.startIndex..<max(range.startIndex, range.endIndex) {
        if !first && canSplit(tr.doc, splitPos, splitDepth) {
            try tr.split(splitPos, splitDepth)
            splitPos += 2 * splitDepth
        }
        splitPos += parent.child(i).nodeSize
        first = false
    }
}

/// Build a command that splits a non-empty textblock at the top level of a list item.
public func splitListItem(_ itemType: NodeType, _ itemAttrs: Attrs? = nil) -> Command {
    return { state, dispatch, _ in
        let sel = state.selection, from = sel.fromPos, to = sel.toPos
        if let node = (sel as? NodeSelection)?.node, node.isBlock { return false }
        if from.depth < 2 || !from.sameParent(to) { return false }
        let grandParent = from.node(-1)
        if grandParent.type !== itemType { return false }
        return CommandErrors.run {
            if from.parent.content.size == 0 && from.node(-1).childCount == from.indexAfter(-1) {
                if from.depth == 3 || from.node(-3).type !== itemType || from.index(-2) != from.node(-2).childCount - 1 { return false }
                if let dispatch {
                    var wrap = Fragment.empty
                    let depthBefore = from.index(-1) > 0 ? 1 : from.index(-2) > 0 ? 2 : 3
                    var d = from.depth - depthBefore
                    while d >= from.depth - 3 {
                        wrap = Fragment.from(from.node(d).copy(wrap))
                        d -= 1
                    }
                    let depthAfter = from.indexAfter(-1) < from.node(-2).childCount ? 1
                        : from.indexAfter(-2) < from.node(-3).childCount ? 2 : 3
                    wrap = wrap.append(itemType.createAndFill().map { Fragment.from($0) } ?? .empty)
                    let start = from.before(from.depth - (depthBefore - 1))
                    let tr = try state.tr.replace(start, from.after(-depthAfter), Slice(wrap, 4 - depthBefore, 0))
                    var sel = -1
                    tr.doc.nodesBetween(start, tr.doc.content.size) { node, pos, _, _ in
                        if sel > -1 { return false }
                        if node.isTextblock && node.content.size == 0 { sel = pos + 1 }
                        return true
                    }
                    if sel > -1 { tr.setSelection(Selection.near(tr.doc.resolve(sel))) }
                    dispatch(tr.scrollIntoView())
                }
                return true
            }
            let nextType = to.pos == from.end() ? grandParent.contentMatchAt(0).defaultType : nil
            let tr = try state.tr.delete(from.pos, to.pos)
            let types: [NodeTypeWithAttrs?]? = nextType.map { [itemAttrs != nil ? NodeTypeWithAttrs(itemType, itemAttrs) : nil, NodeTypeWithAttrs($0)] }
            if !canSplit(tr.doc, from.pos, 2, types) { return false }
            if let dispatch { dispatch(try tr.split(from.pos, 2, types).scrollIntoView()) }
            return true
        }
    }
}

/// Acts like splitListItem, but without resetting the set of active marks at the cursor.
public func splitListItemKeepMarks(_ itemType: NodeType, _ itemAttrs: Attrs? = nil) -> Command {
    let split = splitListItem(itemType, itemAttrs)
    return { state, dispatch, view in
        split(state, dispatch.map { dispatch in
            { tr in
                let marks = state.storedMarks ?? (state.selection.toPos.parentOffset > 0 ? state.selection.fromPos.marks() : nil)
                if let marks { tr.ensureMarks(marks) }
                dispatch(tr)
            }
        }, view)
    }
}

/// Create a command to lift the list item around the selection up into a wrapping list.
public func liftListItem(_ itemType: NodeType) -> Command {
    return { state, dispatch, _ in
        let sel = state.selection
        guard let range = sel.fromPos.blockRange(sel.toPos, { $0.childCount > 0 && $0.firstChild!.type === itemType }) else { return false }
        guard let dispatch else { return true }
        return CommandErrors.run {
            if sel.fromPos.node(range.depth - 1).type === itemType {
                return try liftToOuterList(state, dispatch, itemType, range)
            } else {
                return try liftOutOfList(state, dispatch, range)
            }
        }
    }
}

private func liftToOuterList(_ state: EditorState, _ dispatch: Dispatch, _ itemType: NodeType, _ range: NodeRange) throws -> Bool {
    var range = range
    let tr = state.tr, end = range.end, endOfList = range.to.end(range.depth)
    if end < endOfList {
        try tr.step(ReplaceAroundStep(end - 1, endOfList, end, endOfList,
                                      Slice(Fragment.from(try itemType.create(nil, Fragment.from(range.parent.copy()))), 1, 0), 1, structure: true))
        range = NodeRange(tr.doc.resolve(range.from.pos), tr.doc.resolve(endOfList), range.depth)
    }
    guard let target = liftTarget(range) else { return false }
    try tr.lift(range, target)
    let after = tr.doc.resolve(tr.mapping.map(end, assoc: -1) - 1)
    if canJoin(tr.doc, after.pos) && after.nodeBefore!.type === after.nodeAfter!.type { try tr.join(after.pos) }
    dispatch(tr.scrollIntoView())
    return true
}

private func liftOutOfList(_ state: EditorState, _ dispatch: Dispatch, _ range: NodeRange) throws -> Bool {
    let tr = state.tr, list = range.parent
    var pos = range.end
    var i = range.endIndex - 1
    let e = range.startIndex
    while i > e {
        pos -= list.child(i).nodeSize
        try tr.delete(pos - 1, pos + 1)
        i -= 1
    }
    let rStart = tr.doc.resolve(range.start), item = rStart.nodeAfter!
    if tr.mapping.map(range.end) != range.start + rStart.nodeAfter!.nodeSize { return false }
    let atStart = range.startIndex == 0, atEnd = range.endIndex == list.childCount
    let parent = rStart.node(-1), indexBefore = rStart.index(-1)
    if !parent.canReplace(indexBefore + (atStart ? 0 : 1), indexBefore + 1,
                          item.content.append(atEnd ? .empty : Fragment.from(list))) { return false }
    let start = rStart.pos, end = start + item.nodeSize
    try tr.step(ReplaceAroundStep(start - (atStart ? 1 : 0), end + (atEnd ? 1 : 0), start + 1, end - 1,
                                  Slice((atStart ? Fragment.empty : Fragment.from(list.copy(.empty)))
                                          .append(atEnd ? .empty : Fragment.from(list.copy(.empty))),
                                        atStart ? 0 : 1, atEnd ? 0 : 1), atStart ? 0 : 1))
    dispatch(tr.scrollIntoView())
    return true
}

/// Create a command to sink the list item around the selection down into an inner list.
public func sinkListItem(_ itemType: NodeType) -> Command {
    return { state, dispatch, _ in
        let sel = state.selection
        guard let range = sel.fromPos.blockRange(sel.toPos, { $0.childCount > 0 && $0.firstChild!.type === itemType }) else { return false }
        let startIndex = range.startIndex
        if startIndex == 0 { return false }
        let parent = range.parent, nodeBefore = parent.child(startIndex - 1)
        if nodeBefore.type !== itemType { return false }
        return CommandErrors.run {
            if let dispatch {
                let nestedBefore = nodeBefore.lastChild != nil && nodeBefore.lastChild!.type === parent.type
                let inner = nestedBefore ? Fragment.from(try itemType.create()) : Fragment.empty
                let slice = Slice(Fragment.from(try itemType.create(nil, Fragment.from(try parent.type.create(nil, inner)))),
                                  nestedBefore ? 3 : 1, 0)
                let before = range.start, after = range.end
                dispatch(try state.tr.step(ReplaceAroundStep(before - (nestedBefore ? 3 : 1), after, before, after, slice, 1, structure: true))
                    .scrollIntoView())
            }
            return true
        }
    }
}
