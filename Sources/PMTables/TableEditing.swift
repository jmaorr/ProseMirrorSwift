// Port of the plugin in prosemirror-tables/src/index.ts
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel
import PMTransform
import PMState

/// The table editing plugin's key. Its state is the anchor cell's position during a
/// cell-selecting mouse drag, or nil.
public let tableEditingKey = PluginKey("selectingCells")

/// Table editing: keeps tables well-formed (`fixTables`) and selections table-shaped
/// (`normalizeSelection`) after every transaction, and handles table keys.
/// With `allowTableNodeSelection` false (Tiptap's setting) a selected table becomes an
/// all-cells `CellSelection`.
public func tableEditing(allowTableNodeSelection: Bool = false) -> Plugin {
    registerCellSelection()
    return Plugin(PluginSpec(
        props: EditorProps(handleKeyDown: tableHandleKeyDown),
        state: StateField(
            init: { _, _ in nil },
            apply: { tr, cur, _, _ in
                if let set = tr.getMeta(tableEditingKey) { return (set as? Int).flatMap { $0 == -1 ? nil : $0 } }
                guard let cur = cur as? Int, tr.docChanged else { return cur }
                let result = tr.mapping.mapResult(cur)
                return result.deleted ? nil : result.pos
            }),
        key: tableEditingKey,
        appendTransaction: { _, oldState, state in
            normalizeSelection(state, fixTables(state, oldState: oldState), allowTableNodeSelection: allowTableNodeSelection)
        }))
}
