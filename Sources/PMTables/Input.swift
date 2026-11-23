// Port of the key handling in prosemirror-tables/src/input.ts
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel
import PMState
import PMKeymap

/// The table plugin's keys: arrows move between cells at cell edges, Shift-arrows extend a
/// cell selection, Backspace/Delete empty selected cells.
public func tableKeymap() -> [String: Command] {
    [
        "ArrowLeft": arrow("horiz", -1),
        "ArrowRight": arrow("horiz", 1),
        "ArrowUp": arrow("vert", -1),
        "ArrowDown": arrow("vert", 1),
        "Shift-ArrowLeft": shiftArrow("horiz", -1),
        "Shift-ArrowRight": shiftArrow("horiz", 1),
        "Shift-ArrowUp": shiftArrow("vert", -1),
        "Shift-ArrowDown": shiftArrow("vert", 1),
        "Backspace": deleteCellSelection,
        "Mod-Backspace": deleteCellSelection,
        "Delete": deleteCellSelection,
        "Mod-Delete": deleteCellSelection,
    ]
}

private let tableKeyHandler = keydownHandler(tableKeymap())

func tableHandleKeyDown(_ view: EditorView, _ event: KeyEvent) -> Bool { tableKeyHandler(view, event) }

private func maybeSetSelection(_ state: EditorState, _ dispatch: Dispatch?, _ selection: Selection) -> Bool {
    if selection.eq(state.selection) { return false }
    dispatch?(state.tr.setSelection(selection).scrollIntoView())
    return true
}

private func arrow(_ axis: String, _ dir: Int) -> Command {
    return { state, dispatch, view in
        guard let view else { return false }
        let sel = state.selection
        if let sel = sel as? CellSelection { return maybeSetSelection(state, dispatch, Selection.near(sel.headCell, dir)) }
        if axis != "horiz" && !sel.empty { return false }
        guard let end = atEndOfCell(view, axis, dir) else { return false }
        if axis == "horiz" {
            return maybeSetSelection(state, dispatch, Selection.near(state.doc.resolve(sel.head + dir), dir))
        }
        return CommandErrors.run {
            let cell = state.doc.resolve(end)
            let newSel: Selection
            if let next = try nextCell(cell, axis: axis, dir: dir) {
                newSel = Selection.near(next, 1)
            } else if dir < 0 {
                newSel = Selection.near(state.doc.resolve(cell.before(-1)), -1)
            } else {
                newSel = Selection.near(state.doc.resolve(cell.after(-1)), 1)
            }
            return maybeSetSelection(state, dispatch, newSel)
        }
    }
}

private func shiftArrow(_ axis: String, _ dir: Int) -> Command {
    return { state, dispatch, view in
        guard let view else { return false }
        return CommandErrors.run {
            let cellSel: CellSelection
            if let sel = state.selection as? CellSelection {
                cellSel = sel
            } else {
                guard let end = atEndOfCell(view, axis, dir) else { return false }
                cellSel = try CellSelection(state.doc.resolve(end))
            }
            guard let head = try nextCell(cellSel.headCell, axis: axis, dir: dir) else { return false }
            return maybeSetSelection(state, dispatch, try CellSelection(cellSel.anchorCell, head))
        }
    }
}

/// The position before the cell when the caret is at that cell's edge in the given
/// direction (as the view sees it), or nil.
public func atEndOfCell(_ view: EditorView, _ axis: String, _ dir: Int) -> Int? {
    guard let sel = view.state.selection as? TextSelection else { return nil }
    let head = sel.headPos
    var d = head.depth - 1
    while d >= 0 {
        let parent = head.node(d)
        if (dir < 0 ? head.index(d) : head.indexAfter(d)) != (dir < 0 ? 0 : parent.childCount) { return nil }
        if parent.isCellNode {
            let cellPos = head.before(d)
            let dirStr = axis == "vert" ? (dir > 0 ? "down" : "up") : (dir > 0 ? "right" : "left")
            return view.endOfTextblock(dirStr, nil) ? cellPos : nil
        }
        d -= 1
    }
    return nil
}
