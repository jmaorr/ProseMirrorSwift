#if os(macOS)
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables

/// A table's view: the grid of cells, drawn from the shared editor state. Cells are layers
/// drawing rendered text; editing happens in one cell editor laid over the active cell.
public final class TableGridView: NSView, EmbeddedCursorProviding {
    public let core: EditorCore
    /// Position before the table node; kept current by `TableEmbeds`.
    public internal(set) var tablePos: Int
    public var style: TableStyle { didSet { reload(force: true) } }
    public var cellStyle: CellDocStyle { didSet { cache.removeAll(); reload(force: true) } }
    public private(set) var layout = TableLayout(columnX: [0], columnWidths: [], rowY: [0], rowHeights: [], size: .zero, cellRects: [:])
    /// Width the grid may fill (the text column, minus the grips' gutter).
    public var availableWidth: CGFloat = 600 { didSet { if availableWidth != oldValue { reload(force: true) } } }
    /// Called when the grid's height changes, so the note lays the table's line out again:
    /// with the old height, and whether rows came or went (a change worth animating).
    var onHeightChange: ((_ oldHeight: CGFloat, _ rowsChanged: Bool) -> Void)?

    let cache = CellCache()
    /// Cell layers by grid slot (the row and column of the cell's top-left), which stays put
    /// while cell content (and so cell positions) change, and as columns are added.
    private var cellLayers: [Int: CellLayer] = [:]
    private var slotForPos: [Int: Int] = [:]
    private var shownTable: Node?

    /// The note's text view, for handing focus back.
    weak var hostTextView: ProseTextView? {
        didSet {
            guard hostTextView !== oldValue else { return }
            if let editor = editorIfLoaded { applyHostHooks(to: editor) }
            // A table just inserted (or loaded) may already hold the selection: start editing it
            // once TextKit has finished laying the table out.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                self?.followSelection()
                self?.updateSelectionOverlay()
            }
        }
    }
    var editorIfLoaded: ProseTextView?
    var editorShowsHeader = false
    /// The cell (relative position) whose static drawing is hidden under the editor.
    var hiddenCell: Int?
    /// The editor should take focus once the grid is in a window.
    var focusWhenShown = false
    var selectionOverlay: CAShapeLayer?
    /// The selected cells' rects, as drawn.
    public internal(set) var selectedCellRects: [CGRect] = []
    /// The cell a mouse drag started in.
    var dragAnchor: Int?
    /// Backspace with every cell selected deletes the table (Tiptap's behaviour); otherwise it
    /// empties the cells.
    public var deletesTableWhenAllSelected = false
    /// Extra pasteboard contents for copied cells (TSV for spreadsheets), by type; a `.string`
    /// entry replaces the plain text.
    public var cellsPasteboardWriter: ((CellSelection) -> [NSPasteboard.PasteboardType: String])?
    /// Called before and after each gesture that changes the table (resize, "+", drag), so
    /// the editor can make it one undo step (with Yjs, the undo manager's stopCapturing).
    public var onGestureBoundary: (() -> Void)?
    /// The row and column under the pointer, and the pointer itself (view state only).
    public internal(set) var hovered: (row: Int, column: Int)?
    var hoverPoint: NSPoint?
    /// The column border under the pointer (1...columns).
    public internal(set) var hoveredBorder: Int?
    /// A column resize in progress: the border and the column's width when it started.
    public internal(set) var resizing: (border: Int, start: CGFloat)?
    var resizeStartX: CGFloat = 0
    /// Column widths shown during a resize, not yet written (view state only).
    public internal(set) var previewWidths: [Int: CGFloat] = [:]
    var resizeLine: CALayer?
    /// Called when hover or selection changes what the handles should show.
    var onChromeChange: (() -> Void)?
    /// A row or column drag in progress.
    public internal(set) var dragging: Drag?
    /// The dragged cells while lifted into the host (which doesn't clip), and where it started.
    var dragLift: (layer: CALayer, origin: CGPoint)?
    /// Called once with the cell editor when it's created.
    public var configureEditor: ((ProseTextView) -> Void)?

    /// The cell editor, once a cell has been edited.
    public var editor: ProseTextView? { editorIfLoaded }

    public init(core: EditorCore, tablePos: Int, style: TableStyle, cellStyle: CellDocStyle) {
        self.core = core
        self.tablePos = tablePos
        self.style = style
        self.cellStyle = cellStyle
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        reload(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// The table node this grid shows, if it's still there.
    public var table: Node? {
        guard let node = core.state.doc.nodeAt(tablePos), node.type.tableRole == .table else { return nil }
        return node
    }

    /// Position (relative to the table start) to absolute: the position before the cell.
    public var tableStart: Int { tablePos + 1 }

    public func cellLayer(at cellPos: Int) -> CellLayer? { slotForPos[cellPos].flatMap { cellLayers[$0] } }

    /// The rendered cell at `cellPos` (relative to the table start).
    public func renderedCell(at cellPos: Int) -> RenderedCell? {
        guard let rect = layout.cellRect(pos: cellPos), let node = table?.nodeAt(cellPos) else { return nil }
        return cache.cell(for: node, style: cellStyle, width: contentWidth(rect))
    }

    func contentWidth(_ cellRect: CGRect) -> CGFloat {
        max(cellRect.width - style.cellPadding.left - style.cellPadding.right, 1)
    }

    func update(_ tr: Transaction) {
        reload(force: false)
        followSelection()
        updateSelectionOverlay()
        onChromeChange?()
    }

    func tableRemoved() {
        let hadFocus = editorIfLoaded.map { window?.firstResponder === $0 } ?? false
        hideEditor()
        if hadFocus, let hostTextView { window?.makeFirstResponder(hostTextView) }
    }

    /// Lay the table out again from the current state.
    func reload(force: Bool) {
        guard let table else { return }
        if !force, table === shownTable { return }
        shownTable = table
        guard let map = try? TableMap.get(table) else { return }
        let oldHeight = layout.size.height, oldWidth = layout.size.width
        let oldRows = layout.rowHeights.count, oldColumns = layout.columnWidths.count
        layout = TableLayout.make(table: table, map: map, availableWidth: availableWidth, style: style,
                                  contentHeight: { [cache, cellStyle] pos, width in
                                      guard let node = table.nodeAt(pos) else { return 0 }
                                      return cache.cell(for: node, style: cellStyle, width: width).height(forWidth: width)
                                  }, overrideWidths: previewWidths)
        setFrameSize(NSSize(width: layout.size.width + style.ruleWidth, height: layout.size.height + style.ruleWidth))
        let structural = oldRows > 0 && (map.height != oldRows || map.width != oldColumns)
        // New cells grow out of the old table's right (new columns) or bottom (new rows) edge.
        let grewFrom = !structural ? nil : map.width > oldColumns ? (edge: oldWidth, horizontal: true)
            : map.height > oldRows ? (edge: oldHeight, horizontal: false) : nil
        updateCellLayers(table, map, structural: structural, grewFrom: grewFrom)
        needsDisplay = true
        if layout.size.height != oldHeight {
            onHeightChange?(oldHeight + style.ruleWidth, oldRows > 0 && layout.rowHeights.count != oldRows)
        }
    }

    /// `structural`: rows or columns came or went, so existing cells slide to their new frames.
    private func updateCellLayers(_ table: Node, _ map: TableMap, structural: Bool,
                                  grewFrom: (edge: CGFloat, horizontal: Bool)?) {
        guard let root = layer else { return }
        let firstLoad = cellLayers.isEmpty
        let slide = structural && !TableMotion.reduceMotion()
        var keep: [Int: CellLayer] = [:]
        slotForPos.removeAll(keepingCapacity: true)
        for (index, pos) in map.map.enumerated() where slotForPos[pos] == nil {
            slotForPos[pos] = (index / map.width) << 16 | (index % map.width)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let header = tableNodeTypes(table.type.schema)[.headerCell]
        // Layers take fixed colours: resolve them for this view's appearance.
        var rule = style.rule.cgColor, headerFill = style.headerFill.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rule = style.rule.cgColor
            headerFill = style.headerFill.cgColor
        }
        for (pos, cellRect) in layout.cellRects {
            guard let slot = slotForPos[pos] else { continue }
            // Each cell draws its own rules, so a dragged row takes them along; neighbours
            // overlap by one rule, so shared edges are drawn once.
            let rect = CGRect(origin: cellRect.origin, size: CGSize(width: cellRect.width + style.ruleWidth,
                                                                    height: cellRect.height + style.ruleWidth))
            let isNew = cellLayers[slot] == nil
            let cellLayer = cellLayers[slot] ?? CellLayer()
            if cellLayer.superlayer == nil { root.addSublayer(cellLayer) }
            if isNew && !firstLoad {
                // New rows and columns fade in (a cross-fade is also what Reduce Motion gets).
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = TableMotion.duration
                fade.timingFunction = TableMotion.curve
                cellLayer.add(fade, forKey: "appear")
            }
            let resized = cellLayer.frame.size != rect.size
            if slide && isNew, let grewFrom {
                // A layer added in this transaction gets no implicit move: animate it explicitly.
                let start = grewFrom.horizontal ? CGRect(x: grewFrom.edge, y: rect.minY, width: 0, height: rect.height)
                    : CGRect(x: rect.minX, y: grewFrom.edge, width: rect.width, height: 0)
                cellLayer.frame = rect
                for (key, from, to) in [("position", CGPoint(x: start.midX, y: start.midY), CGPoint(x: rect.midX, y: rect.midY)),
                                        ("bounds.size", start.size, rect.size)] as [(String, Any, Any)] {
                    let move = CABasicAnimation(keyPath: key)
                    move.fromValue = from
                    move.toValue = to
                    move.duration = TableMotion.duration
                    move.timingFunction = TableMotion.curve
                    cellLayer.add(move, forKey: key)
                }
            }
            if cellLayer.frame != rect {
                if slide && !isNew {
                    CATransaction.begin()
                    CATransaction.setDisableActions(false)
                    CATransaction.setAnimationDuration(TableMotion.duration)
                    CATransaction.setAnimationTimingFunction(TableMotion.curve)
                    cellLayer.frame = rect
                    CATransaction.commit()
                } else {
                    cellLayer.frame = rect
                }
            }
            cellLayer.drawingAppearance = effectiveAppearance
            cellLayer.padding = style.cellPadding
            cellLayer.borderWidth = style.ruleWidth
            cellLayer.borderColor = rule
            if let node = table.nodeAt(pos) {
                let rendered = cache.cell(for: node, style: cellStyle, width: contentWidth(cellRect))
                if cellLayer.cell !== rendered { cellLayer.cell = rendered } else if resized { cellLayer.setNeedsDisplay() }
                let fill = node.type === header ? headerFill : nil
                if cellLayer.fill != fill { cellLayer.fill = fill }
            }
            cellLayer.hidesText = pos == hiddenCell
            keep[slot] = cellLayer
        }
        for (slot, cellLayer) in cellLayers where keep[slot] == nil { cellLayer.removeFromSuperlayer() }
        cellLayers = keep
        CATransaction.commit()
    }

    /// The resize cursor over a column border.
    public func cursor(for event: NSEvent) -> NSCursor? {
        let point = convert(event.locationInWindow, from: nil)
        guard resizing != nil || (layout.columnBorder(near: point.x, tolerance: 4).map { $0 > 0 } ?? false) else { return nil }
        return .resizeLeftRight
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reload(force: true)
    }
}

/// Scrolls a wide table sideways and hands every other scroll to the note. NSScrollView
/// takes all scroll gestures it receives, so with the pointer over a table the note stopped
/// scrolling. Each gesture is given away whole: a trackpad swipe or wheel tick that's mostly
/// vertical, or any when the table isn't wider than its column, goes to the next responder
/// (and up to the note's scroll view), its momentum too.
final class SidewaysScrollView: NSScrollView {
    private var passingOn = false

    override func scrollWheel(with event: NSEvent) {
        let startsGesture = event.phase == .began || event.phase == .mayBegin
        let isDiscrete = event.phase == [] && event.momentumPhase == []
        if startsGesture || isDiscrete {
            let canScrollSideways = (documentView?.frame.width ?? 0) > contentView.bounds.width + 0.5
            passingOn = !canScrollSideways || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        }
        if passingOn {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The view in the note's text for a table: the grid, scrolling sideways when it's wider than
/// the text column, with room above it for the column grips. Row grips hang left of it, into
/// the note's margin, so the host doesn't clip.
public final class TableHostView: NSView {
    public let grid: TableGridView
    public let scrollView: NSScrollView = SidewaysScrollView()

    public let rowGrip = TableHandleView(kind: .row(0))
    public let columnGrip = TableHandleView(kind: .column(0))
    public let tableGrip = TableHandleView(kind: .table)
    public let addRowButton = TableHandleView(kind: .addRow)
    public let addColumnButton = TableHandleView(kind: .addColumn)
    /// Room below the grid for the "+" that adds a row.
    static let edgeRoom: CGFloat = 24
    /// Thickness of the "+" bars, and their gap from the grid.
    static let addBar: CGFloat = 16, addGap: CGFloat = 4
    /// How far past the grips the pointer can go before they leave.
    public static let reach: CGFloat = 32

    init(grid: TableGridView) {
        self.grid = grid
        super.init(frame: .zero)
        wantsLayer = true
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = grid
        addSubview(scrollView)
        if #available(macOS 14, *) { clipsToBounds = false }
        for handle in [rowGrip, columnGrip, tableGrip, addRowButton, addColumnButton] {
            handle.color = grid.style.gripGlyph
            handle.accent = grid.style.accent
            addSubview(handle)
        }
        rowGrip.onClick = { [weak self] event in self?.gripClicked(self?.rowGrip, event) }
        columnGrip.onClick = { [weak self] event in self?.gripClicked(self?.columnGrip, event) }
        tableGrip.onClick = { [weak self] event in self?.gripClicked(self?.tableGrip, event) }
        for grip in [rowGrip, columnGrip, tableGrip] {
            grip.onMenu = { [weak self, weak grip] _ in
                guard let self, let grip else { return nil }
                self.selectFor(grip)
                return self.grid.menu(forCellSelection: ())
            }
        }
        rowGrip.onDrag = { [weak self] _, delta in
            guard let self, case .row(let row) = rowGrip.kind else { return }
            if grid.dragging == nil { grid.beginDrag(row: row) }
            grid.updateDrag(offset: -delta.y)
        }
        columnGrip.onDrag = { [weak self] _, delta in
            guard let self, case .column(let column) = columnGrip.kind else { return }
            if grid.dragging == nil { grid.beginDrag(column: column) }
            grid.updateDrag(offset: delta.x)
        }
        rowGrip.onDragEnd = { [weak self] _ in self?.grid.endDrag() }
        columnGrip.onDragEnd = { [weak self] _ in self?.grid.endDrag() }
        addRowButton.onClick = { [weak self] _ in self?.grid.addRowAtEnd() }
        addColumnButton.onClick = { [weak self] _ in self?.grid.addColumnAtEnd() }
        grid.onChromeChange = { [weak self] in self?.layoutHandles() }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.layoutHandles() } }
    }

    private func selectFor(_ grip: TableHandleView) {
        switch grip.kind {
        case .row(let r): grid.selectRow(r)
        case .column(let c): grid.selectColumn(c)
        default: grid.selectAllCells()
        }
    }

    /// A click on a grip selects its row, column or table; a click on a selected grip opens its menu.
    private func gripClicked(_ grip: TableHandleView?, _ event: NSEvent) {
        guard let grip else { return }
        if grip.selected, let menu = grid.menu(forCellSelection: ()) {
            NSMenu.popUpContextMenu(menu, with: event, for: grip)
            return
        }
        selectFor(grip)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // Wider than the host: the grips and the column "+" sit in the margins.
        // Generous around the table: reaching for a grip in the margin (or past it) keeps the grips.
        let rect = bounds.insetBy(dx: -max(grid.style.gutter, Self.addGap + Self.addBar) - Self.reach, dy: -Self.reach)
        addTrackingArea(NSTrackingArea(rect: rect, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = grid.convert(event.locationInWindow, from: nil)
        grid.hover(at: point)
        // Over a grip or "+", the handle sets its own cursor.
        let local = convert(event.locationInWindow, from: nil)
        if let handle = handles.first(where: { $0.alphaValue > 0 && $0.frame.contains(local) }) {
            handle.cursorUpdate(with: event)
            return
        }
        if grid.hoveredBorder != nil { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
    }

    private var handles: [TableHandleView] { [rowGrip, columnGrip, tableGrip, addRowButton, addColumnButton] }

    /// The pointer has rested on the table long enough for its grips to come in.
    private var revealed = false
    private var revealTimer: Timer?

    /// Grips come in only once the pointer rests; passing over a table shows nothing.
    private func updateReveal() {
        guard grid.hovered != nil else {
            revealTimer?.invalidate()
            revealTimer = nil
            revealed = false
            return
        }
        guard !revealed, revealTimer == nil else { return }
        if TableMotion.revealDelay <= 0 {
            revealed = true
            return
        }
        let timer = Timer(timeInterval: TableMotion.revealDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.revealTimer = nil
                self.revealed = self.grid.hovered != nil
                self.layoutHandles()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    public override func mouseExited(with event: NSEvent) {
        guard grid.resizing == nil else { return }
        grid.hover(at: nil)
        NSCursor.arrow.set()
    }

    /// TextKit's line view clips to the line; the grips hang past it into the margin.
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if #available(macOS 14, *) { superview?.clipsToBounds = false }
    }

    /// Place and show the grips and "+" bars for the hovered (or caret) row and column.
    public func layoutHandles() {
        // Clicks past the line view reach the handles through the note's hit-testing.
        if let textView = grid.hostTextView {
            for handle in handles { textView.overhangingViews.add(handle) }
        }
        updateReveal()
        let gutter = grid.style.gutter
        let layout = grid.layout
        let offsetX = scrollView.contentView.bounds.minX
        let target = grid.hovered ?? grid.caretRowColumn
        let dim = grid.hovered == nil
        let sel = grid.cellSelection
        let inRange = target.map { $0.row < layout.rowHeights.count && $0.column < layout.columnWidths.count } ?? false
        if let target, inRange {
            // While dragging, the held grip stays on the dragged block and moves with it.
            let drag = grid.dragging
            let row = drag.flatMap { $0.isRow ? $0.from : nil } ?? target.row...target.row
            let column = drag.flatMap { $0.isRow ? nil : $0.from } ?? target.column...target.column
            if row.upperBound + 1 < layout.rowY.count {
                let top = layout.rowY[row.lowerBound] + (drag?.isRow == true ? drag!.offset : 0)
                let height = layout.rowY[row.upperBound + 1] - layout.rowY[row.lowerBound]
                rowGrip.kind = .row(row.lowerBound)
                rowGrip.frame = NSRect(x: -gutter + 3, y: gutter + top + max(0, (height - 28) / 2), width: 12, height: min(28, height))
            }
            if column.upperBound + 1 < layout.columnX.count {
                let left = layout.columnX[column.lowerBound] - offsetX + (drag?.isRow == false ? drag!.offset : 0)
                let width = layout.columnX[column.upperBound + 1] - layout.columnX[column.lowerBound]
                columnGrip.kind = .column(column.lowerBound)
                columnGrip.frame = NSRect(x: left + max(0, (width - 28) / 2), y: 3, width: min(28, width), height: 12)
            }
        }
        tableGrip.frame = NSRect(x: -gutter + 3, y: 3, width: 12, height: 12)
        rowGrip.selected = sel.map { $0.isRowSelection() } ?? false
        columnGrip.selected = sel.map { $0.isColSelection() } ?? false
        tableGrip.selected = sel.map { $0.isRowSelection() && $0.isColSelection() } ?? false
        // Hovering: full once revealed. Editing a cell (no hover): its row and column, faintly.
        let showGrips: CGFloat = !inRange ? 0 : (dim ? 0.5 : (revealed ? 1 : 0))
        let visibleWidth = min(layout.size.width - offsetX, scrollView.frame.width)
        let shownHeight = shownGridHeight - grid.style.ruleWidth
        addColumnButton.frame = NSRect(x: visibleWidth + Self.addGap, y: gutter, width: Self.addBar, height: shownHeight)
        addRowButton.frame = NSRect(x: 0, y: gutter + shownHeight + Self.addGap, width: visibleWidth, height: Self.addBar)
        let point = grid.hoverPoint
        let nearRight = point.map { $0.x > layout.size.width - 20 } ?? false
        let nearBottom = point.map { $0.y > layout.size.height - 20 } ?? false
        let nearCorner = grid.hovered.map { $0.row == 0 && $0.column == 0 } ?? false
        fade(rowGrip, to: showGrips)
        fade(columnGrip, to: showGrips)
        fade(tableGrip, to: revealed && nearCorner ? 1 : 0)
        fade(addColumnButton, to: revealed && nearRight ? 1 : 0)
        fade(addRowButton, to: revealed && nearBottom ? 1 : 0)
        updateEdgeFade()
    }

    /// The edges a wide table continues past, which fade out.
    public private(set) var fadingEdges: Set<NSRectEdge> = []

    private func updateEdgeFade() {
        let offset = scrollView.contentView.bounds.minX
        var edges: Set<NSRectEdge> = []
        if scrolls {
            if offset > 0.5 { edges.insert(.minX) }
            if offset < grid.frame.width - scrollView.frame.width - 0.5 { edges.insert(.maxX) }
        }
        let width = scrollView.bounds.width
        guard edges != fadingEdges || (scrollView.layer?.mask.map { $0.frame != scrollView.bounds } ?? false) else { return }
        fadingEdges = edges
        guard !edges.isEmpty, width > 0 else {
            scrollView.layer?.mask = nil
            return
        }
        scrollView.wantsLayer = true
        let mask = (scrollView.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        let fade = min(grid.style.edgeFade / width, 0.5)
        let opaque = CGColor(gray: 0, alpha: 1), clear = CGColor(gray: 0, alpha: 0)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [edges.contains(.minX) ? clear : opaque, opaque, opaque, edges.contains(.maxX) ? clear : opaque]
        mask.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = scrollView.bounds
        CATransaction.commit()
        scrollView.layer?.mask = mask
    }

    private func fade(_ view: NSView, to alpha: CGFloat) {
        guard view.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > view.alphaValue ? TableMotion.handleReveal : TableMotion.handleFade
            view.animator().alphaValue = alpha
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Room the table needs in the note besides the grid: the grips above, the "+" below.
    public static func chromeHeight(_ style: TableStyle) -> CGFloat { style.gutter + edgeRoom }

    /// Height the table needs in the note.
    public var height: CGFloat { Self.chromeHeight(grid.style) + shownGridHeight }

    /// The grid's height as shown: it eases to the grid's real height when rows come or go.
    private var shownGridHeight: CGFloat { animatedGridHeight ?? grid.frame.height }
    private var animatedGridHeight: CGFloat?
    private var heightTimer: Timer?

    /// The grid's height changed from `oldHeight`. Rows coming or going ease the table to its
    /// new height, so the note below slides and the clip reveals a new row; `relayout` lays the
    /// table's line out again at each step.
    func gridHeightChanged(from oldHeight: CGFloat, animated: Bool, relayout: @escaping () -> Void) {
        heightTimer?.invalidate()
        heightTimer = nil
        let start = animatedGridHeight ?? oldHeight, end = grid.frame.height
        guard animated, !TableMotion.reduceMotion(), window != nil, start != end else {
            animatedGridHeight = nil
            needsLayout = true
            relayout()
            return
        }
        let began = CACurrentMediaTime()
        animatedGridHeight = start
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = min(1, (CACurrentMediaTime() - began) / TableMotion.duration)
                // Ease out, as TableMotion.curve.
                let eased = 1 - pow(1 - t, 3)
                self.animatedGridHeight = t < 1 ? start + (end - start) * eased : nil
                if t >= 1 {
                    timer.invalidate()
                    self.heightTimer = nil
                }
                self.needsLayout = true
                relayout()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heightTimer = timer
    }

    /// The width the note gives the table.
    func setWidth(_ width: CGFloat) {
        grid.availableWidth = width - grid.style.ruleWidth
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        scrollView.frame = NSRect(x: 0, y: grid.style.gutter, width: max(bounds.width, 1), height: shownGridHeight)
        layoutHandles()
    }

    /// Whether the grid is wider than the room it has (and scrolls sideways).
    public var scrolls: Bool { grid.frame.width > scrollView.frame.width + 0.5 }
}
#endif
