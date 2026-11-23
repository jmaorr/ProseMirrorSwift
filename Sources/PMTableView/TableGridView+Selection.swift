#if os(macOS)
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables

extension TableGridView {
    /// The selection, when it's a cell selection in this table.
    public var cellSelection: CellSelection? {
        guard let sel = core.state.selection as? CellSelection, sel.anchorCell.start(-1) == tableStart else { return nil }
        return sel
    }

    // MARK: Overlay

    /// Outline and tint the selected cells (2pt accent outline, 8% accent tint, as the web).
    func updateSelectionOverlay() {
        guard let root = layer else { return }
        let overlay = selectionOverlay ?? {
            let shape = CAShapeLayer()
            shape.zPosition = 10
            root.addSublayer(shape)
            selectionOverlay = shape
            return shape
        }()
        var rects: [CGRect] = []
        if let sel = cellSelection {
            sel.forEachCell { _, pos in
                if let rect = layout.cellRect(pos: pos - tableStart) { rects.append(rect) }
            }
        }
        // A text range running over the whole table (from the line above to the line below)
        // tints every cell, without the cell selection's outline.
        let sel = core.state.selection
        let covered = rects.isEmpty && !sel.empty && table.map { sel.from <= tablePos && sel.to >= tablePos + $0.nodeSize } ?? false
        if covered { rects = Array(layout.cellRects.values) }
        // One outline around the block (cell selections are rectangular): per-cell outlines
        // would double up on shared edges.
        let inset = style.selectionOutline / 2
        let block = rects.reduce(CGRect.null) { $0.union($1) }
        let path = CGMutablePath()
        if !block.isNull { path.addRect(block.insetBy(dx: inset, dy: inset)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = bounds
        overlay.path = path
        overlay.fillColor = style.accent.withAlphaComponent(style.selectionTint).cgColor
        overlay.strokeColor = covered ? nil : style.accent.cgColor
        overlay.lineWidth = style.selectionOutline
        CATransaction.commit()
        let visible: Float = rects.isEmpty ? 0 : 1
        if overlay.opacity != visible {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = overlay.presentation()?.opacity ?? overlay.opacity
            fade.toValue = visible
            fade.duration = TableMotion.selectionFade
            overlay.add(fade, forKey: "fade")
            overlay.opacity = visible
        }
        selectedCellRects = rects
    }

    // MARK: Mouse

    func cellPos(at event: NSEvent) -> Int? {
        layout.cell(at: convert(event.locationInWindow, from: nil)).map { tableStart + $0 }
    }

    /// Shift-click extends from the current cell; a triple click selects the cell.
    func handleSelectionClick(_ event: NSEvent) -> Bool {
        guard let cell = cellPos(at: event) else { return false }
        let doc = core.state.doc
        if event.clickCount >= 3 {
            if let sel = try? CellSelection(doc.resolve(cell)) { select(sel) }
            return true
        }
        if event.modifierFlags.contains(.shift) {
            let anchor = cellSelection?.anchorCell.pos ?? selectedTextCell
            if let anchor, let sel = try? CellSelection(doc.resolve(anchor), doc.resolve(cell)) {
                select(sel)
                return true
            }
        }
        dragAnchor = cell
        return false
    }

    public override func mouseDragged(with event: NSEvent) {
        if resizing != nil {
            updateResize(delta: convert(event.locationInWindow, from: nil).x - resizeStartX)
            return
        }
        guard let anchor = dragAnchor, let cell = cellPos(at: event) else { return super.mouseDragged(with: event) }
        if cell == anchor && cellSelection == nil { return }
        let doc = core.state.doc
        if let sel = try? CellSelection(doc.resolve(anchor), doc.resolve(cell)), !(cellSelection?.eq(sel) ?? false) {
            select(sel)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if resizing != nil { endResize() }
        dragAnchor = nil
        super.mouseUp(with: event)
    }

    func select(_ selection: Selection) {
        editorIfLoaded?.commitComposition()
        core.dispatch(core.state.tr.setSelection(selection))
        if selection is CellSelection { window?.makeFirstResponder(self) }
    }

    // MARK: Keys

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool { true }

    /// Keys with a cell selection, Numbers-like: arrows move the selected cell, Shift-arrows
    /// extend, Return edits the cell, typing replaces it, Backspace empties the cells, Escape
    /// widens to every cell and then leaves the table.
    public override func keyDown(with event: NSEvent) {
        if resizing != nil, event.keyCode == 53 { return cancelResize() }
        if dragging != nil, event.keyCode == 53 { return cancelDrag() }
        guard let sel = cellSelection else { return super.keyDown(with: event) }
        let key = KeyEvent(event)
        if handleShortcut(key) { return }
        let plain = !key.metaKey && !key.ctrlKey && !key.altKey
        switch (key.key, key.shiftKey) {
        case ("ArrowLeft", false), ("ArrowRight", false), ("ArrowUp", false), ("ArrowDown", false):
            moveCellSelection(sel, key.key)
            return
        case ("Enter", _) where plain:
            editCell(sel.anchorCell.pos, replacing: nil)
            return
        case ("Escape", _):
            escape(from: sel)
            return
        case ("Backspace", _), ("Delete", _):
            if deletesTableWhenAllSelected && sel.isRowSelection() && sel.isColSelection() {
                _ = deleteTable(core.state, core.dispatch, hostTextView)
                if let hostTextView { window?.makeFirstResponder(hostTextView) }
                return
            }
        default:
            if plain, let chars = event.characters, let scalar = chars.unicodeScalars.first,
               chars.count == 1, !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 {
                editCell(sel.anchorCell.pos, replacing: chars)
                return
            }
        }
        // prosemirror-tables' keys (Shift-arrows, Backspace) and the rest of the keymaps.
        let view = hostTextView ?? editorIfLoaded
        for plugin in core.state.plugins {
            if let handle = plugin.props.handleKeyDown, let view, handle(view, key) { return }
        }
        super.keyDown(with: event)
    }

    private func moveCellSelection(_ sel: CellSelection, _ key: String) {
        let axis = key == "ArrowLeft" || key == "ArrowRight" ? "horiz" : "vert"
        let dir = key == "ArrowLeft" || key == "ArrowUp" ? -1 : 1
        guard let next = try? nextCell(sel.headCell, axis: axis, dir: dir), let moved = try? CellSelection(next) else { return }
        select(moved)
    }

    /// Edit the cell at `cellPos`: the caret at the end of its text, or its content replaced
    /// by `text`.
    func editCell(_ cellPos: Int, replacing text: String?) {
        editorIfLoaded?.commitComposition()
        let state = core.state
        guard let cell = state.doc.nodeAt(cellPos) else { return }
        let tr = state.tr
        if let text, let paragraph = state.schema.nodes["paragraph"],
           let node = try? paragraph.create(nil, [state.schema.text(text)]) {
            _ = try? tr.replaceWith(cellPos + 1, cellPos + cell.nodeSize - 1, node)
            _ = tr.setSelection(TextSelection.create(tr.doc, cellPos + 2 + text.utf16.count))
        } else {
            _ = tr.setSelection(Selection.near(tr.doc.resolve(cellPos + cell.nodeSize - 1), -1))
        }
        core.dispatch(tr)
        if let editor = editorIfLoaded, !editor.isHidden { window?.makeFirstResponder(editor) }
    }

    private func escape(from sel: CellSelection) {
        editorIfLoaded?.commitComposition()
        let doc = core.state.doc
        if !(sel.isRowSelection() && sel.isColSelection()), let map = try? TableMap.get(sel.anchorCell.node(-1)),
           let first = map.map.first, let last = map.map.last,
           let all = try? CellSelection.create(doc, tableStart + first, tableStart + last) {
            select(all)
            return
        }
        guard let table else { return }
        let after = Selection.near(doc.resolve(tablePos + table.nodeSize), 1)
        core.dispatch(core.state.tr.setSelection(after))
        if let hostTextView { window?.makeFirstResponder(hostTextView) }
    }
}
#endif
