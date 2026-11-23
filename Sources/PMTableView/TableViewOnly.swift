// Platform-neutral (no AppKit or UIKit).
import Foundation
import PMModel
import PMState
import PMTables

/// For a view-only table (iOS): the selection never goes inside a table. A caret or selection
/// in one table becomes a node selection of the table; a range reaching into a table from
/// outside grows to the text past it. Use with `tableEditing(allowTableNodeSelection: true)`,
/// which leaves a selected table selected.
public func viewOnlyTableSelection() -> Plugin {
    Plugin(PluginSpec(appendTransaction: { _, _, state in
        guard let selection = selectionOutsideTables(state.selection, in: state.doc) else { return nil }
        return state.tr.setSelection(selection)
    }))
}

/// `selection` moved out of any table it is in, or nil when it's in none. A range with only one
/// end in a table (or its ends in two tables) grows to the text past each table, else to the
/// table's own edge.
func selectionOutsideTables(_ selection: Selection, in doc: Node) -> Selection? {
    func outermostTable(_ pos: ResolvedPos) -> Int? {
        guard pos.depth > 0 else { return nil }
        for depth in 1...pos.depth where pos.node(depth).type.tableRole == .table { return pos.before(depth) }
        return nil
    }
    let from = outermostTable(selection.fromPos), to = outermostTable(selection.toPos)
    guard from != nil || to != nil else { return nil }
    if let from, to == from { return NodeSelection.create(doc, from) }
    let start = from.map { before in Selection.findFrom(doc.resolve(before), -1, textOnly: true)?.headPos ?? doc.resolve(before) }
        ?? selection.fromPos
    let end = to.map { before in
        let after = before + doc.nodeAt(before)!.nodeSize
        return Selection.findFrom(doc.resolve(after), 1, textOnly: true)?.headPos ?? doc.resolve(after)
    } ?? selection.toPos
    // Built directly: `TextSelection.between` would look for text inside the table again.
    return selection.anchor <= selection.head ? TextSelection(start, end) : TextSelection(end, start)
}
