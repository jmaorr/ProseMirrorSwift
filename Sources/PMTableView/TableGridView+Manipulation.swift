#if os(macOS)
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables

/// A handle beside the grid: a row grip (left), column grip (above) or table grip (corner),
/// or an edge "+" bar.
public final class TableHandleView: NSView {
    public enum Kind: Equatable {
        case row(Int), column(Int), table, addRow, addColumn
    }

    public var kind: Kind { didSet { needsDisplay = true } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor
    /// Selected (its row/column/table is the cell selection): drawn in the accent colour.
    var selected = false { didSet { needsDisplay = true } }
    /// The pointer is over it.
    private var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }
    var onClick: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent, NSPoint) -> Void)?
    var onDragEnd: ((NSEvent) -> Void)?
    var onMenu: ((NSEvent) -> NSMenu?)?
    private var downAt: NSPoint?
    private var dragging = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    private var isGrip: Bool { if case .row = kind { return true }; if case .column = kind { return true }; return kind == .table }

    /// Grips are grabbed (an open hand); the "+" buttons take the plain arrow.
    public override func cursorUpdate(with event: NSEvent) {
        (isGrip ? NSCursor.openHand : NSCursor.arrow).set()
    }

    public override func mouseEntered(with event: NSEvent) { hot = true }
    public override func mouseExited(with event: NSEvent) { hot = false }

    public override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .addRow, .addColumn:
            // A soft rounded bar with a drawn "+", in the grips' style.
            let radius = min(bounds.width, bounds.height) / 2
            color.withAlphaComponent(hot ? 0.16 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            color.withAlphaComponent(hot ? 0.85 : 0.5).setStroke()
            let plus = NSBezierPath()
            let arm: CGFloat = 4
            plus.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY))
            plus.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY))
            plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - arm))
            plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + arm))
            plus.lineWidth = 1.5
            plus.lineCapStyle = .round
            plus.stroke()
        default:
            // A plain rounded bar (a small dot for the table), thinner than the view that takes the clicks.
            let fill = selected ? accent : color.withAlphaComponent(hot ? 0.65 : 0.35)
            fill.setFill()
            let thickness: CGFloat = hot || selected ? 5 : 4
            let bar: NSRect
            switch kind {
            case .row: bar = NSRect(x: bounds.midX - thickness / 2, y: bounds.minY + 2, width: thickness, height: max(bounds.height - 4, thickness))
            case .column: bar = NSRect(x: bounds.minX + 2, y: bounds.midY - thickness / 2, width: max(bounds.width - 4, thickness), height: thickness)
            default: bar = NSRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6)
            }
            NSBezierPath(roundedRect: bar, xRadius: min(bar.width, bar.height) / 2, yRadius: min(bar.width, bar.height) / 2).fill()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = false
        if isGrip { NSCursor.closedHand.set() }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let downAt, onDrag != nil else { return }
        let delta = NSPoint(x: event.locationInWindow.x - downAt.x, y: event.locationInWindow.y - downAt.y)
        if dragging || hypot(delta.x, delta.y) > 3 {
            dragging = true
            onDrag?(event, delta)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if dragging { onDragEnd?(event) } else { onClick?(event) }
        downAt = nil
        dragging = false
        if isGrip { NSCursor.openHand.set() }
    }

    public override func menu(for event: NSEvent) -> NSMenu? { onMenu?(event) }
}

extension TableGridView {
    // MARK: Hover

    /// Which row and column the pointer is over (view state only).
    public func hover(at point: NSPoint?) {
        guard let point else {
            hovered = nil
            hoverPoint = nil
            hoveredBorder = nil
            updateResizeLine()
            onChromeChange?()
            return
        }
        hoverPoint = point
        hovered = (row: layout.rowY.lastIndex { $0 <= point.y }.map { min($0, layout.rowHeights.count - 1) } ?? 0,
                   column: layout.columnX.lastIndex { $0 <= point.x }.map { min($0, layout.columnWidths.count - 1) } ?? 0)
        hoveredBorder = layout.columnBorder(near: point.x, tolerance: 4).flatMap { $0 > 0 ? $0 : nil }
        onChromeChange?()
        updateResizeLine()
    }

    /// The row and column the caret is in, whose grips stay visible (dimmed) while editing.
    var caretRowColumn: (row: Int, column: Int)? {
        guard let cell = selectedTextCell, let table, let map = try? TableMap.get(table),
              let rect = try? map.findCell(cell - tableStart) else { return nil }
        return (rect.top, rect.left)
    }

    // MARK: Grips and "+"

    /// Select row `row` (and any rows spans tie to it) as a cell selection.
    public func selectRow(_ row: Int) {
        guard let map = table.flatMap({ try? TableMap.get($0) }), row < map.height else { return }
        let doc = core.state.doc
        if let sel = try? CellSelection.rowSelection(doc.resolve(tableStart + map.map[row * map.width]),
                                                     doc.resolve(tableStart + map.map[row * map.width + map.width - 1])) {
            select(sel)
        }
    }

    public func selectColumn(_ column: Int) {
        guard let map = table.flatMap({ try? TableMap.get($0) }), column < map.width else { return }
        let doc = core.state.doc
        if let sel = try? CellSelection.colSelection(doc.resolve(tableStart + map.map[column]),
                                                     doc.resolve(tableStart + map.map[(map.height - 1) * map.width + column])) {
            select(sel)
        }
    }

    public func selectAllCells() {
        guard let map = table.flatMap({ try? TableMap.get($0) }), let first = map.map.first, let last = map.map.last,
              let sel = try? CellSelection.create(core.state.doc, tableStart + first, tableStart + last) else { return }
        select(sel)
    }

    /// The edge "+": a row at the bottom, or a column at the right.
    public func addRowAtEnd() {
        guard let map = table.flatMap({ try? TableMap.get($0) }), let last = map.map.last else { return }
        gesture { $0.dispatch(try addRow($0.state.tr, try self.rectAt(last, $0.state), map.height)) }
    }

    public func addColumnAtEnd() {
        guard let map = table.flatMap({ try? TableMap.get($0) }), let last = map.map.last else { return }
        gesture { $0.dispatch(try addColumn($0.state.tr, try self.rectAt(last, $0.state), map.width)) }
    }

    private func rectAt(_ rel: Int, _ state: EditorState) throws -> SelectedRect {
        guard let table = state.doc.nodeAt(tablePos), table.type.tableRole == .table else { throw PMError.range("No table") }
        let map = try TableMap.get(table)
        return SelectedRect(rect: try map.findCell(rel), map: map, tableStart: tableStart, table: table)
    }

    /// One user gesture: its own undo step (`onGestureBoundary` before and after).
    func gesture(_ body: (EditorCore) throws -> Void) {
        editorIfLoaded?.commitComposition()
        onGestureBoundary?()
        try? body(core)
        onGestureBoundary?()
    }

    // MARK: Column resize

    /// Start resizing the column left of border `border` (1...columns).
    public func beginResize(border: Int) {
        guard border > 0, border <= layout.columnWidths.count else { return }
        resizing = (border, layout.columnWidths[border - 1])
        previewWidths = [:]
        updateResizeLine()
    }

    /// Live preview: the column `delta` points wider (view only, no transaction).
    public func updateResize(delta: CGFloat) {
        guard let (border, start) = resizing else { return }
        previewWidths = [border - 1: max(style.minWrittenWidth, start + delta)]
        reload(force: true)
        followSelection()
        updateResizeLine()
    }

    /// Commit the resize: one transaction setting the column's width.
    public func endResize() {
        guard let (border, _) = resizing else { return }
        let width = previewWidths[border - 1]
        resizing = nil
        previewWidths = [:]
        if let width { setWidth(Int(min(width, TableLayout.maxColumnWidth).rounded()), ofColumn: border - 1) } else { reload(force: true) }
        updateResizeLine()
    }

    /// Escape during a resize: back to the old width, no transaction.
    public func cancelResize() {
        guard resizing != nil else { return }
        resizing = nil
        previewWidths = [:]
        reload(force: true)
        followSelection()
        updateResizeLine()
    }

    /// Double-click a border: fit the column to its widest single-column cell's content.
    public func fitColumn(border: Int) {
        guard let table, let map = try? TableMap.get(table), border > 0, border <= map.width else { return }
        let col = border - 1
        var widest: CGFloat = 0
        for row in 0..<map.height {
            let pos = map.map[row * map.width + col]
            guard let node = table.nodeAt(pos), cellSpan(node.attrs, "colspan") == 1 else { continue }
            widest = max(widest, cache.cell(for: node, style: cellStyle, width: 10_000).text.naturalWidth)
        }
        let width = max(style.minWrittenWidth, widest + style.cellPadding.left + style.cellPadding.right + 1)
        setWidth(Int(min(width, TableLayout.maxColumnWidth).rounded(.up)), ofColumn: col)
    }

    private func setWidth(_ width: Int, ofColumn col: Int) {
        guard let table, let map = try? TableMap.get(table) else { return }
        // updateColumnWidth works from a cell whose right edge is the column's.
        var cellPos: Int?
        for row in 0..<map.height {
            let pos = map.map[row * map.width + col]
            if let rect = try? map.findCell(pos), rect.right == col + 1 { cellPos = tableStart + pos; break }
        }
        guard let cellPos else { return }
        gesture { core in
            _ = updateColumnWidth(cellPos: cellPos, width: Double(width))(core.state, core.dispatch, nil)
        }
    }

    func updateResizeLine() {
        guard let root = layer else { return }
        let line = resizeLine ?? {
            let l = CALayer()
            l.zPosition = 20
            root.addSublayer(l)
            resizeLine = l
            return l
        }()
        let border = resizing?.border ?? hoveredBorder
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let border, border < layout.columnX.count {
            line.isHidden = false
            line.backgroundColor = style.accent.cgColor
            line.frame = CGRect(x: layout.columnX[border] - 1, y: 0, width: 2, height: layout.size.height)
        } else {
            line.isHidden = true
        }
        CATransaction.commit()
    }

    /// Mouse down on a column border starts a resize (or fits the column on a double click).
    func handleBorderClick(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard let border = layout.columnBorder(near: point.x, tolerance: 4), border > 0 else { return false }
        if event.clickCount == 2 {
            fitColumn(border: border)
            return true
        }
        beginResize(border: border)
        resizeStartX = point.x
        return true
    }
}
#endif

#if os(macOS)
extension TableGridView {
    /// A row or column being dragged to a new place (view state only until the drop).
    public struct Drag {
        public var isRow: Bool
        /// The rows (or columns) being moved, in order.
        public var from: ClosedRange<Int>
        public var offset: CGFloat = 0
        /// Where they'd land (index of the first moved row/column after the move).
        public var target: Int
    }

    // MARK: Drag to reorder

    /// Start dragging row (or column) `index`; a row or column selection containing it moves
    /// with it.
    public func beginDrag(row index: Int) { beginDrag(isRow: true, index) }
    public func beginDrag(column index: Int) { beginDrag(isRow: false, index) }

    private func beginDrag(isRow: Bool, _ index: Int) {
        editorIfLoaded?.commitComposition()
        // The grip may be stale (a collaborator removed its row).
        guard index >= 0, index < (isRow ? layout.rowHeights.count : layout.columnWidths.count) else { return }
        var range = index...index
        if let sel = cellSelection, isRow ? sel.isRowSelection() : sel.isColSelection(),
           let map = table.flatMap({ try? TableMap.get($0) }),
           let rect = try? map.rectBetween(sel.anchorCell.pos - tableStart, sel.headCell.pos - tableStart) {
            let lo = isRow ? rect.top : rect.left, hi = (isRow ? rect.bottom : rect.right) - 1
            if (lo...hi).contains(index) { range = lo...hi }
        }
        dragging = Drag(isRow: isRow, from: range, target: range.lowerBound)
        let layers = dragLayers(range, isRow: isRow)
        var background = style.background.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { background = style.background.cgColor }
        for layer in layers {
            // Opaque while lifted, so the shadow falls from the cells, not their text.
            layer.backgroundColor = layer.fill ?? background
            layer.zPosition = 5
        }
        lift(layers)
    }

    /// Move the dragged cells into a layer in the host, above the grid: the grid scrolls
    /// sideways, so it clips, and the block should travel past the table's edge.
    private func lift(_ layers: [CellLayer]) {
        guard let host = enclosingScrollView?.superview, let hostLayer = host.layer, !layers.isEmpty else { return }
        let block = layers.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let lifted = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lifted.frame = convert(block, to: host)
        lifted.zPosition = 10
        lifted.shadowOpacity = 0.25
        lifted.shadowRadius = 6
        lifted.shadowOffset = .zero
        for layer in layers {
            let frame = layer.frame
            layer.removeFromSuperlayer()
            layer.frame = frame.offsetBy(dx: -block.minX, dy: -block.minY)
            lifted.addSublayer(layer)
        }
        hostLayer.addSublayer(lifted)
        CATransaction.commit()
        dragLift = (lifted, lifted.frame.origin)
    }

    /// Put lifted cells back in the grid where the lift had them (`offset` along the drag),
    /// ready to settle.
    private func land(offset: CGFloat, isRow: Bool) {
        guard let (lifted, _) = dragLift, let root = layer else { return }
        dragLift = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let origin = convert(lifted.frame.origin, from: enclosingScrollView?.superview)
        for case let cell as CellLayer in lifted.sublayers ?? [] {
            let frame = cell.frame.offsetBy(dx: origin.x, dy: origin.y)
            cell.removeFromSuperlayer()
            // Under the cell editor and overlays, as before.
            root.insertSublayer(cell, at: 0)
            cell.frame = isRow ? frame.offsetBy(dx: 0, dy: -offset) : frame.offsetBy(dx: -offset, dy: 0)
            cell.transform = isRow ? CATransform3DMakeTranslation(0, offset, 0) : CATransform3DMakeTranslation(offset, 0, 0)
        }
        lifted.removeFromSuperlayer()
        CATransaction.commit()
    }

    /// Follow the pointer: the dragged rows move by `offset`; the rows they pass slide aside.
    public func updateDrag(offset: CGFloat) {
        guard var drag = dragging else { return }
        drag.offset = offset
        let starts = drag.isRow ? layout.rowY : layout.columnX
        let sizes = drag.isRow ? layout.rowHeights : layout.columnWidths
        // Rows removed under the drag (a remote edit): give up the drag.
        guard drag.from.upperBound + 1 < starts.count else { return cancelDrag() }
        let lo = drag.from.lowerBound, hi = drag.from.upperBound
        let size = starts[hi + 1] - starts[lo]
        let center = starts[lo] + offset + size / 2
        // The landing index: how many other rows' midpoints lie before the dragged block's center.
        var target = 0
        for i in sizes.indices where !drag.from.contains(i) && starts[i] + sizes[i] / 2 < center { target += 1 }
        drag.target = target
        dragging = drag
        let reduce = TableMotion.reduceMotion()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let (lifted, origin) = dragLift {
            lifted.frame.origin = drag.isRow ? CGPoint(x: origin.x, y: origin.y + offset) : CGPoint(x: origin.x + offset, y: origin.y)
        } else {
            for layer in dragLayers(drag.from, isRow: drag.isRow) {
                layer.transform = drag.isRow ? CATransform3DMakeTranslation(0, offset, 0) : CATransform3DMakeTranslation(offset, 0, 0)
            }
        }
        CATransaction.commit()
        // The grip being held moves with the block.
        onChromeChange?()
        // Others make room (slide; under Reduce Motion they stay put).
        guard !reduce else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(TableMotion.duration)
        CATransaction.setAnimationTimingFunction(TableMotion.curve)
        for i in sizes.indices where !drag.from.contains(i) {
            let otherIndex = i < lo ? i : i - drag.from.count
            let shift: CGFloat = otherIndex >= target && i < lo ? size : (otherIndex < target && i > hi ? -size : 0)
            for layer in dragLayers(i...i, isRow: drag.isRow) {
                layer.transform = drag.isRow ? CATransform3DMakeTranslation(0, shift, 0) : CATransform3DMakeTranslation(shift, 0, 0)
            }
        }
        CATransaction.commit()
    }

    /// Drop: one gesture moving the rows (or columns); a move the table can't make (a merged
    /// cell in the way) snaps back.
    public func endDrag() {
        guard let drag = dragging else { return }
        dragging = nil
        land(offset: drag.offset, isRow: drag.isRow)
        var moved = false
        if drag.target != drag.from.lowerBound {
            gesture { core in
                let count = drag.from.count
                for k in 0..<count {
                    let (from, to) = drag.target > drag.from.lowerBound
                        ? (drag.from.lowerBound, drag.target + count - 1)
                        : (drag.from.lowerBound + k, drag.target + k)
                    // prosemirror-tables finds the spans to move from the selection's table.
                    if findTable(core.state.selection.fromPos)?.pos != tablePos {
                        core.dispatch(core.state.tr.setSelection(Selection.near(core.state.doc.resolve(tableStart + 1))))
                    }
                    let command = drag.isRow ? moveTableRow(from: from, to: to, select: k == count - 1, pos: tableStart)
                        : moveTableColumn(from: from, to: to, select: k == count - 1, pos: tableStart)
                    guard command(core.state, core.dispatch, nil) else { break }
                    moved = true
                }
            }
        }
        settleDrag(animated: !moved)
        onChromeChange?()
        if moved, let sel = cellSelection, sel.isRowSelection() || sel.isColSelection() { window?.makeFirstResponder(self) }
    }

    /// Escape during a drag: everything slides back, nothing changes.
    public func cancelDrag() {
        guard let drag = dragging else { return }
        dragging = nil
        land(offset: drag.offset, isRow: drag.isRow)
        settleDrag(animated: true)
        onChromeChange?()
    }

    private func settleDrag(animated: Bool) {
        CATransaction.begin()
        if animated && !TableMotion.reduceMotion() {
            CATransaction.setAnimationDuration(TableMotion.duration)
            CATransaction.setAnimationTimingFunction(TableMotion.curve)
        } else {
            CATransaction.setDisableActions(true)
        }
        for layer in layer?.sublayers?.compactMap({ $0 as? CellLayer }) ?? [] {
            layer.transform = CATransform3DIdentity
            layer.backgroundColor = layer.fill
            layer.zPosition = 0
            layer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    /// Cell layers of the cells starting in rows (or columns) `range`.
    public func dragLayers(_ range: ClosedRange<Int>, isRow: Bool) -> [CellLayer] {
        guard let map = table.flatMap({ try? TableMap.get($0) }) else { return [] }
        var out: [CellLayer] = []
        var seen = Set<Int>()
        for (index, pos) in map.map.enumerated() where pos != 0 && !seen.contains(pos) {
            seen.insert(pos)
            let line = isRow ? index / max(map.width, 1) : index % max(map.width, 1)
            if range.contains(line), let layer = cellLayer(at: pos) { out.append(layer) }
        }
        return out
    }
}
#endif
