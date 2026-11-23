#if os(macOS)
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables

/// A menu item that runs a closure.
public final class TableMenuItem: NSMenuItem {
    let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], enabled: Bool = true,
         checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

extension TableGridView {
    private func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : "\(n) \(many)" }

    /// The Table section of the context menu, for the selection in `state` (§3.5): enabled
    /// items are the ones whose command applies; titles count the selection.
    public func tableMenuItems(for state: EditorState) -> [NSMenuItem] {
        guard let rect = try? selectedRect(state), rect.tableStart == tableStart else { return [] }
        let rows = rect.bottom - rect.top, cols = rect.right - rect.left
        let view = hostTextView ?? editorIfLoaded
        func item(_ title: String, _ command: @escaping Command, key: String = "", modifiers: NSEvent.ModifierFlags = [],
                  checked: Bool = false) -> NSMenuItem {
            TableMenuItem(title, key: key, modifiers: modifiers, enabled: command(state, nil, view), checked: checked) { [weak self] in
                self?.run(command)
            }
        }
        let headerRow = rowIsHeader(rect.map, rect.table, 0)
        let headerColumn = columnIsHeader(rect.map, rect.table, 0)
        let header: NSMenuItem
        if #available(macOS 14, *) {
            header = .sectionHeader(title: "Table")
        } else {
            header = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
            header.isEnabled = false
        }
        var items: [NSMenuItem] = [
            header,
            item("Add Row Above", addRowBefore, key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: .option),
            item("Add Row Below", addRowAfter, key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: .option),
            item("Add Column Before", addColumnBefore, key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: .option),
            item("Add Column After", addColumnAfter, key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .option),
            item("Delete " + plural(rows, "Row", "Rows"), deleteRow),
            item("Delete " + plural(cols, "Column", "Columns"), deleteColumn),
            .separator(),
            item("Merge Cells", mergeCells, key: "m", modifiers: [.option, .command]),
            item("Split Cell", splitCell),
            .separator(),
            item("Header Row", toggleHeaderRow, checked: headerRow),
            item("Header Column", toggleHeaderColumn, checked: headerColumn),
            item("Distribute Columns Evenly", clearColumnWidths(tablePos: tablePos)),
            .separator(),
            item("Select " + plural(rows, "Row", "Rows"), selectRows),
            item("Select " + plural(cols, "Column", "Columns"), selectColumns),
            item("Select Table", selectTable),
            item("Delete Table", deleteTable),
        ]
        if !items.contains(where: { $0.isEnabled && !$0.isSeparatorItem && $0 !== header }) { items = [] }
        return items
    }

    /// Runs a table command against the shared state, through the note's view.
    @discardableResult
    func run(_ command: Command) -> Bool {
        editorIfLoaded?.commitComposition()
        let view = hostTextView ?? editorIfLoaded
        let applied = command(core.state, core.dispatch, view)
        if core.state.selection is CellSelection, cellSelection != nil { window?.makeFirstResponder(self) }
        return applied
    }

    private var selectRows: Command {
        { state, dispatch, _ in
            guard let rect = try? selectedRect(state), let first = rect.map.map[safe: rect.top * rect.map.width],
                  let last = rect.map.map[safe: (rect.bottom - 1) * rect.map.width],
                  let sel = try? CellSelection.rowSelection(state.doc.resolve(rect.tableStart + first),
                                                            state.doc.resolve(rect.tableStart + last)) else { return false }
            dispatch?(state.tr.setSelection(sel))
            return true
        }
    }

    private var selectColumns: Command {
        { state, dispatch, _ in
            guard let rect = try? selectedRect(state), let first = rect.map.map[safe: rect.left],
                  let last = rect.map.map[safe: rect.right - 1],
                  let sel = try? CellSelection.colSelection(state.doc.resolve(rect.tableStart + first),
                                                            state.doc.resolve(rect.tableStart + last)) else { return false }
            dispatch?(state.tr.setSelection(sel))
            return true
        }
    }

    private var selectTable: Command {
        { state, dispatch, _ in
            guard let rect = try? selectedRect(state), let first = rect.map.map.first, let last = rect.map.map.last,
                  let sel = try? CellSelection.create(state.doc, rect.tableStart + first, rect.tableStart + last) else { return false }
            dispatch?(state.tr.setSelection(sel))
            return true
        }
    }

    /// The Table menu for the current selection.
    func menu(forCellSelection: Void) -> NSMenu? {
        let items = tableMenuItems(for: core.state)
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        return menu
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        // A right-click keeps a cell selection it lands in; elsewhere it selects the cell.
        if let cell = cellPos(at: event) {
            let inside = cellSelection.map { sel in
                var hit = false
                sel.forEachCell { _, pos in if pos == cell { hit = true } }
                return hit
            } ?? false
            if !inside, let sel = try? CellSelection(core.state.doc.resolve(cell)) { select(sel) }
        }
        let items = tableMenuItems(for: core.state)
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        return menu
    }

    /// Keyboard shortcuts for the table (§3.6), with a cell selection or in a cell.
    func handleShortcut(_ key: KeyEvent) -> Bool {
        let alt = key.altKey && !key.metaKey && !key.ctrlKey && !key.shiftKey
        if alt {
            switch key.key {
            case "ArrowUp": return run(addRowBefore)
            case "ArrowDown": return run(addRowAfter)
            case "ArrowLeft": return run(addColumnBefore)
            case "ArrowRight": return run(addColumnAfter)
            default: break
            }
        }
        if key.altKey && key.metaKey && (key.key == "m" || key.key == "µ" || key.keyCode == 77) { return run(mergeCells) }
        if key.metaKey && !key.altKey && key.key == "Backspace", let sel = cellSelection {
            if sel.isRowSelection() { return run(deleteRow) }
            if sel.isColSelection() { return run(deleteColumn) }
        }
        return false
    }

    // MARK: Copy and paste

    var pasteboard: NSPasteboard { hostTextView?.pasteboard ?? editorIfLoaded?.pasteboard ?? .general }

    /// Copy the selected cells: the slice (pasted back exactly, as cells), its text, and
    /// whatever `cellsPasteboardWriter` adds (TSV for spreadsheets).
    @objc public func copy(_ sender: Any?) {
        guard let sel = cellSelection else { return }
        let slice = sel.content()
        let board = pasteboard
        var extra = cellsPasteboardWriter?(sel) ?? [:]
        let text = extra.removeValue(forKey: .string)
            ?? hostTextView?.clipboardText?(slice) ?? slice.content.textBetween(0, slice.content.size, blockSeparator: "\t")
        board.declareTypes([.string, ProseTextView.sliceType] + Array(extra.keys), owner: nil)
        board.setString(text, forType: .string)
        board.setString(slice.toJSON().description, forType: ProseTextView.sliceType)
        for (type, value) in extra { board.setString(value, forType: type) }
    }

    @objc public func cut(_ sender: Any?) {
        copy(sender)
        run(deleteCellSelection)
    }

    @objc public func paste(_ sender: Any?) {
        _ = pasteCells(from: pasteboard)
    }

    /// Paste copied cells (or any slice) onto the cell selection or caret cell; true if taken.
    public func pasteCells(from board: NSPasteboard) -> Bool {
        guard let json = board.string(forType: ProseTextView.sliceType), let value = try? JSONValue.parse(json),
              let slice = try? Slice.fromJSON(core.state.schema, value) else {
            guard cellSelection != nil, let text = board.string(forType: .string), !text.isEmpty,
                  let sel = cellSelection else { return false }
            editCell(sel.anchorCell.pos, replacing: text)
            return true
        }
        if cellSelection == nil && pastedCells(slice) == nil { return false }
        return handlePaste(core.state, slice, core.dispatch)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
