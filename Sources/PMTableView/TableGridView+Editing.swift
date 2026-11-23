#if os(macOS)
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables

extension TableGridView {
    /// The text cell the selection is in, if it's one of this table's cells: the position
    /// before the cell (absolute).
    var selectedTextCell: Int? {
        guard let cell = cellAroundSelection(core.state), cell.start(-1) == tableStart else { return nil }
        return cell.pos
    }

    /// Focus follows the selection: the one place focus moves between the note, the cell
    /// editor and the grid. A selection in one of this table's cells shows the cell editor
    /// over that cell (committing any composition before it moves) and gives it focus if the
    /// note or grid had it; anything else hides the editor and hands focus back.
    func followSelection() {
        guard table != nil else { return hideEditor() }
        if let cellPos = selectedTextCell {
            showEditor(at: cellPos)
            editorIfLoaded?.isEditable = !selectionInReadOnlyBlock(cellPos)
            let focusWindow = window ?? hostTextView?.window
            if let focusWindow, focusWindow.firstResponder === hostTextView || focusWindow.firstResponder === self {
                // TextKit adds the table's view to the note lazily; focus it once it's there.
                if window != nil { window?.makeFirstResponder(editor) } else { focusWhenShown = true }
            }
        } else {
            focusWhenShown = false
            let hadFocus = editorIfLoaded.map { window?.firstResponder === $0 } ?? false
            hideEditor()
            guard hadFocus, let window else { return }
            if let sel = core.state.selection as? CellSelection, sel.anchorCell.start(-1) == tableStart {
                window.makeFirstResponder(self)
            } else if let hostTextView {
                window.makeFirstResponder(hostTextView)
            }
        }
    }

    /// Blocks a cell can't edit natively (code, and anything drawn in a chrome box such as a
    /// task card): the cell editor is read-only while the selection is in one.
    func selectionInReadOnlyBlock(_ cellPos: Int) -> Bool {
        let head = core.state.selection.headPos
        let cellDepth = core.state.doc.resolve(cellPos).depth + 1
        guard head.depth > cellDepth else { return false }
        for d in (cellDepth + 1)...head.depth {
            let node = head.node(d)
            if node.type.spec.code || cellStyle.base.chrome(for: node) != nil { return true }
        }
        return false
    }

    /// Lay the cell editor over the cell at `cellPos` (absolute), scoped to it.
    func showEditor(at cellPos: Int) {
        let editor = self.editor(for: cellPos)
        let rel = cellPos - tableStart
        guard let rect = layout.cellRect(pos: rel) else { return hideEditor() }
        if editor.scope != cellPos {
            let header = table?.nodeAt(rel)?.type.tableRole == .headerCell
            if header != editorShowsHeader {
                var style = cellStyle
                style.header = header
                style.cell = table?.nodeAt(rel)
                editor.setStyle(style)
                editorShowsHeader = header
            }
            editor.scope = cellPos
        }
        let frame = NSRect(x: rect.minX + style.cellPadding.left, y: rect.minY + style.cellPadding.top,
                           width: contentWidth(rect), height: max(rect.height - style.cellPadding.top - style.cellPadding.bottom, 1))
        // NSTextView resizes itself to fit its text; the cell decides its size.
        editor.minSize = frame.size
        editor.maxSize = frame.size
        if editor.frame != frame { editor.frame = frame }
        editor.isHidden = false
        if hiddenCell != rel {
            if let hiddenCell { cellLayer(at: hiddenCell)?.hidesText = false }
            cellLayer(at: rel)?.hidesText = true
            hiddenCell = rel
        }
    }

    func hideEditor() {
        if let hiddenCell { cellLayer(at: hiddenCell)?.hidesText = false }
        hiddenCell = nil
        guard let editor = editorIfLoaded, !editor.isHidden else { return }
        editor.commitComposition()
        editor.isHidden = true
    }

    /// The cell editor, created on first use (scoped to `cellPos`).
    func editor(for cellPos: Int) -> ProseTextView {
        if let editor = editorIfLoaded { return editor }
        var style = cellStyle
        style.header = table?.nodeAt(cellPos - tableStart)?.type.tableRole == .headerCell
        style.cell = table?.nodeAt(cellPos - tableStart)
        editorShowsHeader = style.header
        let editor = ProseTextView(core: core, style: style, scope: cellPos)
        // Layer-backed from the start: becoming layer-backed later re-aligns the frame.
        editor.wantsLayer = true
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.focusRingType = .none
        editor.onScopeLost = { [weak self] in self?.hideEditor() }
        editor.extraMenuItems = { [weak self] state in self?.tableMenuItems(for: state) ?? [] }
        editor.onPaste = { [weak self] board in
            (self?.pasteCells(from: board) ?? false) || (self?.hostTextView?.onPaste?(board) ?? false)
        }
        applyHostHooks(to: editor)
        addSubview(editor)
        editorIfLoaded = editor
        configureEditor?(editor)
        return editor
    }

    /// The note's own hooks (undo, errors, pasteboard, composition end) on the cell editor too.
    func applyHostHooks(to editor: ProseTextView) {
        guard let host = hostTextView else { return }
        editor.undoCommand = host.undoCommand
        editor.redoCommand = host.redoCommand
        editor.separateUndoStep = host.separateUndoStep
        editor.onError = host.onError
        editor.pasteboard = host.pasteboard
        editor.clipboardText = host.clipboardText
        editor.transformPasted = host.transformPasted
        editor.onCompositionEnd = host.onCompositionEnd
        editor.animatesChrome = host.animatesChrome
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenShown, let window else { return }
        focusWhenShown = false
        if selectedTextCell != nil, let editor = editorIfLoaded, !editor.isHidden { window.makeFirstResponder(editor) }
    }

    public override func mouseDown(with event: NSEvent) {
        // A composition goes into the cell it was typed in before anything moves.
        editorIfLoaded?.commitComposition()
        if handleBorderClick(event) { return }
        if handleSelectionClick(event) { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let rel = layout.cell(at: point), let rect = layout.cellRect(pos: rel),
              let rendered = renderedCell(at: rel) else { return super.mouseDown(with: event) }
        let local = CGPoint(x: point.x - rect.minX - style.cellPadding.left, y: point.y - rect.minY - style.cellPadding.top)
        let offset = rendered.characterIndex(at: local) ?? rendered.string.length
        let inCell = rendered.position(atString: offset) ?? 0
        let doc = core.state.doc
        let target = min(tableStart + rel + 1 + inCell, tableStart + rel + (table?.nodeAt(rel)?.nodeSize ?? 2) - 1)
        let selection = Selection.near(doc.resolve(target), 1)
        core.dispatch(core.state.tr.setSelection(selection))
        if let editor = editorIfLoaded, !editor.isHidden { window?.makeFirstResponder(editor) }
    }
}
#endif
