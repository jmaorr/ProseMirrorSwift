// The Swift counterpart of prosemirror-example-setup: input rules, key bindings, history and
// table editing for a schema like `BasicSchema`, as a list of plugins.
import PMModel
import PMTransform
import PMState
import PMCommands
import PMKeymap
import PMInputRules
import PMHistory
import PMTables
import PMTableView

/// The plugins for a basic editor on `schema`, in the order they should be installed: table
/// editing (when the schema has table nodes), input rules (`buildInputRules`), the key bindings
/// of `buildKeymap`, `baseKeymap` and, unless `history` is false, the undo history.
///
/// Like prosemirror-example-setup, it only binds what the schema has: rules and keys for node
/// and mark types the schema lacks are left out, so it works for schemas other than
/// `BasicSchema` that use the same names.
///
/// - Parameters:
///   - schema: The schema the editor's documents use.
///   - history: Whether to include the undo history. Turn it off when something else owns
///     undo, such as YSync's undo manager in a collaborative session.
public func exampleSetup(schema: Schema, history includeHistory: Bool = true) -> [Plugin] {
    var plugins = tablePlugins(schema: schema)
    plugins.append(buildInputRules(schema: schema))
    plugins.append(keymap(buildKeymap(schema: schema)))
    plugins.append(keymap(baseKeymap))
    if includeHistory { plugins.append(history()) }
    return plugins
}

/// Table editing for a schema with table nodes (nodes whose spec has a `tableRole`), or none.
///
/// On macOS: PMTableView's cell navigation keys (Tab, Shift-Tab, Escape, arrows off the table's
/// edge) and PMTables' `tableEditing` plugin (cell selection, table repair, arrow keys between
/// cells). On iOS, where PMTableView's tables are view-only, a table is selected as a whole and
/// the selection never goes into a cell.
public func tablePlugins(schema: Schema) -> [Plugin] {
    guard tableNodeTypes(schema)[.table] != nil else { return [] }
    #if os(iOS)
    return [tableEditing(allowTableNodeSelection: true), viewOnlyTableSelection()]
    #else
    return [keymap(tableNavigationKeymap()), tableEditing()]
    #endif
}

/// prosemirror-example-setup's input rules for the node types in `schema`:
///
/// - smart quotes, `...` to an ellipsis and `--` to an em dash;
/// - `> ` at the start of a textblock wraps it in a `blockquote`;
/// - `1. ` starts an `ordered_list` (numbered from the number typed);
/// - `- `, `+ ` or `* ` starts a `bullet_list`;
/// - three backticks turn the textblock into a `code_block`;
/// - `# ` to `###### ` turn it into a `heading` of that level.
public func buildInputRules(schema: Schema) -> Plugin {
    var rules = smartQuotes + [ellipsis, emDash]
    if let type = schema.nodes["blockquote"] {
        rules.append(wrappingInputRule("^\\s*>\\s$", type))
    }
    if let type = schema.nodes["ordered_list"] {
        rules.append(wrappingInputRule("^(\\d+)\\.\\s$", type,
                                       { match in Attrs([("order", .number(Double(match[1] ?? "") ?? 1))]) },
                                       joinPredicate: { match, node in
                                           Double(node.childCount) + (node.attrs["order"]?.numberValue ?? 1) == Double(match[1] ?? "")
                                       }))
    }
    if let type = schema.nodes["bullet_list"] {
        rules.append(wrappingInputRule("^\\s*([-+*])\\s$", type))
    }
    if let type = schema.nodes["code_block"] {
        rules.append(textblockTypeInputRule("^```$", type))
    }
    if let type = schema.nodes["heading"] {
        rules.append(textblockTypeInputRule("^(#{1,6})\\s$", type) { match in
            Attrs([("level", .number(Double(match[1]?.utf16.count ?? 1)))])
        })
    }
    return inputRules(rules)
}

/// prosemirror-example-setup's key bindings for the node and mark types in `schema`.
///
/// | Key | Command |
/// | --- | --- |
/// | Mod-z, Shift-Mod-z, Mod-y | undo, redo, redo |
/// | Backspace | undo the input rule that just ran |
/// | Alt-ArrowUp, Alt-ArrowDown | join with the block above / below |
/// | Mod-BracketLeft | lift the block out of its parent |
/// | Escape | select the parent node |
/// | Mod-b, Mod-i, Mod-\` | toggle `strong`, `em`, `code` |
/// | Shift-Ctrl-8, Shift-Ctrl-9 | wrap in a `bullet_list`, `ordered_list` |
/// | Ctrl-> | wrap in a `blockquote` |
/// | Shift-Enter, Mod-Enter, Ctrl-Enter | insert a `hard_break` (or leave a code block) |
/// | Enter, Tab, Shift-Tab | split, sink, lift a `list_item` |
/// | Mod-[, Mod-] | lift, sink a `list_item` |
/// | Shift-Ctrl-0 | make the block a `paragraph` |
/// | Shift-Ctrl-\\ | make the block a `code_block` |
/// | Shift-Ctrl-1 … Shift-Ctrl-6 | make the block a `heading` of that level |
/// | Mod-_ | insert a `horizontal_rule` |
///
/// "Mod" is Cmd on Apple platforms. Undo and redo do nothing without the history plugin, so
/// keys fall through to whatever else handles them (an Edit menu's Undo, for example).
public func buildKeymap(schema: Schema) -> [String: Command] {
    var keys: [String: Command] = [:]
    keys["Mod-z"] = undo
    keys["Shift-Mod-z"] = redo
    keys["Mod-y"] = redo
    keys["Backspace"] = undoInputRule
    keys["Alt-ArrowUp"] = joinUp
    keys["Alt-ArrowDown"] = joinDown
    keys["Mod-BracketLeft"] = lift
    keys["Escape"] = selectParentNode

    if let type = schema.marks["strong"] {
        keys["Mod-b"] = toggleMark(type)
        keys["Mod-B"] = toggleMark(type)
    }
    if let type = schema.marks["em"] {
        keys["Mod-i"] = toggleMark(type)
        keys["Mod-I"] = toggleMark(type)
    }
    if let type = schema.marks["code"] {
        keys["Mod-`"] = toggleMark(type)
    }
    if let type = schema.nodes["bullet_list"] {
        keys["Shift-Ctrl-8"] = wrapInList(type)
    }
    if let type = schema.nodes["ordered_list"] {
        keys["Shift-Ctrl-9"] = wrapInList(type)
    }
    if let type = schema.nodes["blockquote"] {
        keys["Ctrl->"] = wrapIn(type)
    }
    if let type = schema.nodes["hard_break"] {
        let breakOrExit = chainCommands(exitCode, insertNode(type))
        keys["Mod-Enter"] = breakOrExit
        keys["Shift-Enter"] = breakOrExit
        keys["Ctrl-Enter"] = breakOrExit
    }
    if let type = schema.nodes["list_item"] {
        keys["Enter"] = splitListItem(type)
        keys["Mod-["] = liftListItem(type)
        keys["Mod-]"] = sinkListItem(type)
        keys["Tab"] = sinkListItem(type)
        keys["Shift-Tab"] = liftListItem(type)
    }
    if let type = schema.nodes["paragraph"] {
        keys["Shift-Ctrl-0"] = setBlockType(type)
    }
    if let type = schema.nodes["code_block"] {
        keys["Shift-Ctrl-\\"] = setBlockType(type)
    }
    if let type = schema.nodes["heading"] {
        for level in 1...6 {
            keys["Shift-Ctrl-\(level)"] = setBlockType(type, Attrs([("level", .number(Double(level)))]))
        }
    }
    if let type = schema.nodes["horizontal_rule"] {
        keys["Mod-_"] = insertNode(type)
    }
    return keys
}

/// A command that replaces the selection with a new node of `type` (a hard break, a
/// horizontal rule) and scrolls it into view.
public func insertNode(_ type: NodeType, _ attrs: Attrs? = nil) -> Command {
    return { state, dispatch, _ in
        guard let node = try? type.create(attrs), let tr = try? state.tr.replaceSelectionWith(node) else { return false }
        dispatch?(tr.scrollIntoView())
        return true
    }
}

/// A command that inserts an empty `rows` × `cols` table in place of the selection and puts
/// the caret in its first cell. With `headerRow` the first row is made of header cells.
/// It does nothing when `schema` has no table nodes or the table can't go there.
public func insertTable(schema: Schema, rows: Int = 3, cols: Int = 3, headerRow: Bool = true) -> Command {
    return { state, dispatch, _ in
        let types = tableNodeTypes(schema)
        guard rows > 0, cols > 0, let table = types[.table], let row = types[.row], let cell = types[.cell] else { return false }
        let header = types[.headerCell] ?? cell
        let rowNodes: [Node] = (0..<rows).compactMap { r in
            let cells = (0..<cols).compactMap { _ in (headerRow && r == 0 ? header : cell).createAndFill() }
            return try? row.create(nil, cells)
        }
        guard let node = try? table.createChecked(nil, Fragment.from(rowNodes)),
              let tr = try? state.tr.replaceSelectionWith(node) else { return false }
        guard let dispatch else { return true }
        // replaceSelectionWith leaves the selection at the end of what it inserted: inside the
        // new table's last cell. Move it to the first.
        let end = tr.selection.fromPos
        let tablePos = (0...end.depth).reversed().first { end.node($0).type === table }.map { end.before($0) }
        if let tablePos, let caret = Selection.findFrom(tr.doc.resolve(tablePos + 1), 1, textOnly: true) {
            _ = tr.setSelection(caret)
        }
        dispatch(tr.scrollIntoView())
        return true
    }
}

/// Whether `type` is active at the selection: in the stored marks or at the caret for an
/// empty selection, anywhere in the range otherwise. Handy for toolbar buttons.
public func isMarkActive(_ state: EditorState, _ type: MarkType) -> Bool {
    let selection = state.selection
    if selection.empty { return type.isInSet(state.storedMarks ?? selection.fromPos.marks()) != nil }
    return state.doc.rangeHasMark(selection.from, selection.to, type)
}
