// Platform-neutral (no AppKit): the keys also serve iOS.
import Foundation
import PMModel
import PMState
import PMTables

/// Keys for moving around a table while editing a cell, on top of prosemirror-tables' own:
/// Tab / Shift-Tab to the next / previous cell, Escape to select the cell, ⌘A widening from
/// the cell's text to every cell to the whole note, and arrows off the table's top or bottom
/// edge into a new paragraph when there's no text there (`createsParagraphAtEdge`).
public func tableNavigationKeymap(createsParagraphAtEdge: Bool = true) -> [String: Command] {
    var keys: [String: Command] = [
        "Tab": goToNextCell(1),
        "Shift-Tab": goToNextCell(-1),
        "Escape": selectCellAround,
        "Mod-a": selectAllInTable,
    ]
    if createsParagraphAtEdge {
        keys["ArrowDown"] = leaveTableIntoNewParagraph(1)
        keys["ArrowUp"] = leaveTableIntoNewParagraph(-1)
        keys["ArrowRight"] = leaveTableIntoNewParagraph(1, axis: "horiz")
        keys["ArrowLeft"] = leaveTableIntoNewParagraph(-1, axis: "horiz")
    }
    return keys
}

/// The cell (position before it) around a text selection, if the selection is in one cell.
func cellAroundSelection(_ state: EditorState) -> ResolvedPos? {
    guard state.selection is TextSelection, let from = cellAround(state.selection.fromPos),
          let to = cellAround(state.selection.toPos), from.pos == to.pos else { return nil }
    return from
}

/// Escape in a cell: select the cell.
public let selectCellAround: Command = { state, dispatch, _ in
    guard let cell = cellAroundSelection(state), let sel = try? CellSelection(cell) else { return false }
    dispatch?(state.tr.setSelection(sel))
    return true
}

/// ⌘A in a table: the cell's text, then every cell, then (not handled here) the whole note.
public let selectAllInTable: Command = { state, dispatch, _ in
    if let cell = cellAroundSelection(state), let node = cell.nodeAfter {
        let start = Selection.findFrom(state.doc.resolve(cell.pos + 1), 1, textOnly: true)
        let end = Selection.findFrom(state.doc.resolve(cell.pos + node.nodeSize - 1), -1, textOnly: true)
        if let start, let end {
            let whole = TextSelection.between(start.fromPos, end.toPos)
            if !(state.selection.from <= whole.from && state.selection.to >= whole.to) {
                dispatch?(state.tr.setSelection(whole))
                return true
            }
        }
        guard let map = try? TableMap.get(cell.node(-1)), let last = map.map.last, let first = map.map.first,
              let all = try? CellSelection.create(state.doc, cell.start(-1) + first, cell.start(-1) + last) else { return false }
        dispatch?(state.tr.setSelection(all))
        return true
    }
    if let sel = state.selection as? CellSelection {
        guard let map = try? TableMap.get(sel.anchorCell.node(-1)) else { return false }
        let start = sel.anchorCell.start(-1)
        let allSelected = sel.isRowSelection() && sel.isColSelection()
        if !allSelected, let first = map.map.first, let last = map.map.last,
           let all = try? CellSelection.create(state.doc, start + first, start + last) {
            dispatch?(state.tr.setSelection(all))
            return true
        }
        dispatch?(state.tr.setSelection(AllSelection(state.doc)))
        return true
    }
    return false
}

/// Arrow down (1) from the last row, or up (-1) from the first, when there's no text that
/// way: add an empty paragraph there and move into it. Across (`axis` "horiz"), the same from
/// the end of the table's last cell or the start of its first.
public func leaveTableIntoNewParagraph(_ dir: Int, axis: String = "vert") -> Command {
    return { state, dispatch, view in
        guard let view, let cellPos = atEndOfCell(view, axis, dir) else { return false }
        let cell = state.doc.resolve(cellPos)
        if axis == "vert" {
            guard (try? nextCell(cell, axis: "vert", dir: dir)) ?? nil == nil else { return false }
        } else {
            guard let map = try? TableMap.get(cell.node(-1)), cell.pos - cell.start(-1) == (dir > 0 ? map.map.last : map.map.first)
            else { return false }
        }
        let tableDepth = cell.depth - 1
        let parent = cell.node(tableDepth - 1)
        let index = cell.index(tableDepth - 1)
        let neighbour = dir > 0 ? (index + 1 < parent.childCount ? parent.child(index + 1) : nil) : (index > 0 ? parent.child(index - 1) : nil)
        if let neighbour, neighbour.isTextblock || neighbour.inlineContent { return false }
        guard let paragraph = state.schema.nodes["paragraph"]?.createAndFill() else { return false }
        let at = dir > 0 ? cell.after(tableDepth) : cell.before(tableDepth)
        guard let dispatch else { return true }
        guard let tr = try? state.tr.insert(at, paragraph) else { return false }
        _ = tr.setSelection(TextSelection.create(tr.doc, at + 1))
        dispatch(tr.scrollIntoView())
        return true
    }
}

/// A click below a table that ends the note: add an empty paragraph after it and put the
/// caret there, so there's a line to type on.
public let addLineAfterFinalTable: Command = { state, dispatch, _ in
    let doc = state.doc
    guard let last = doc.lastChild, last.type.tableRole == .table,
          let paragraph = state.schema.nodes["paragraph"]?.createAndFill() else { return false }
    guard let dispatch else { return true }
    let at = doc.content.size
    guard let tr = try? state.tr.insert(at, paragraph) else { return false }
    _ = tr.setSelection(TextSelection.create(tr.doc, at + 1))
    dispatch(tr.scrollIntoView())
    return true
}
