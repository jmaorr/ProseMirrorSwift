#if os(iOS)
import UIKit
import PMModel
import PMState
import PMTextKit
import PMTables

// Tables on iOS (first version) are view-only: the grid is drawn as on the Mac, from the same
// `TableLayout`, `TableStyle` and `CellRenderer`, but there is no cell editor, no grips and no
// cell selection. A tap selects the whole table (one character in the note's text).

/// A table's grid: cell layers drawing each cell's rendered text, laid out by `TableLayout`.
public final class TableGridView: UIView {
    public let core: EditorCore
    /// Position before the table node; kept current by `TableEmbeds`.
    public internal(set) var tablePos: Int
    public var style: TableStyle { didSet { reload(force: true) } }
    public var cellStyle: CellDocStyle { didSet { cache.removeAll(); reload(force: true) } }
    public private(set) var layout = TableLayout(columnX: [0], columnWidths: [], rowY: [0], rowHeights: [], size: .zero, cellRects: [:])
    /// Width the grid may fill (the text column).
    public var availableWidth: CGFloat = 600 { didSet { if availableWidth != oldValue { reload(force: true) } } }
    /// Called when the grid's height changes, so the note lays the table's line out again.
    var onHeightChange: (() -> Void)?
    /// Called after the table changed (its size or rows and columns).
    var onReload: (() -> Void)?

    let cache = CellCache()
    /// Cell layers by grid slot (the row and column of the cell's top-left), as on the Mac.
    private var cellLayers: [Int: CellLayer] = [:]
    private var slotForPos: [Int: Int] = [:]
    private var shownTable: Node?

    /// The cell editor: none on iOS until tables are editable there.
    public var editor: ProseTextView? { nil }

    public init(core: EditorCore, tablePos: Int, style: TableStyle, cellStyle: CellDocStyle) {
        self.core = core
        self.tablePos = tablePos
        self.style = style
        self.cellStyle = cellStyle
        super.init(frame: .zero)
        isOpaque = false
        reload(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    func update(_ tr: Transaction) { reload(force: false) }

    func tableRemoved() {}

    /// Lay the table out again from the current state.
    func reload(force: Bool) {
        guard let table else { return }
        if !force, table === shownTable { return }
        shownTable = table
        guard let map = try? TableMap.get(table) else { return }
        let oldHeight = layout.size.height
        layout = TableLayout.make(table: table, map: map, availableWidth: availableWidth, style: style,
                                  contentHeight: { [cache, cellStyle] pos, width in
                                      guard let node = table.nodeAt(pos) else { return 0 }
                                      return cache.cell(for: node, style: cellStyle, width: width).height(forWidth: width)
                                  })
        frame.size = CGSize(width: layout.size.width + style.ruleWidth, height: layout.size.height + style.ruleWidth)
        updateCellLayers(table, map)
        onReload?()
        if layout.size.height != oldHeight { onHeightChange?() }
    }

    private func updateCellLayers(_ table: Node, _ map: TableMap) {
        var keep: [Int: CellLayer] = [:]
        slotForPos.removeAll(keepingCapacity: true)
        for (index, pos) in map.map.enumerated() where slotForPos[pos] == nil {
            slotForPos[pos] = (index / map.width) << 16 | (index % map.width)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let header = tableNodeTypes(table.type.schema)[.headerCell]
        // Layers take fixed colours: resolve them for this view's traits.
        let rule = style.rule.resolvedColor(with: traitCollection).cgColor
        let headerFill = style.headerFill.resolvedColor(with: traitCollection).cgColor
        let scale = window?.screen.scale ?? (traitCollection.displayScale > 0 ? traitCollection.displayScale : 3)
        for (pos, cellRect) in layout.cellRects {
            guard let slot = slotForPos[pos] else { continue }
            // Each cell draws its own rules; neighbours overlap by one rule, as on the Mac.
            let rect = CGRect(origin: cellRect.origin, size: CGSize(width: cellRect.width + style.ruleWidth,
                                                                    height: cellRect.height + style.ruleWidth))
            let cellLayer = cellLayers[slot] ?? CellLayer()
            if cellLayer.superlayer == nil { layer.addSublayer(cellLayer) }
            let resized = cellLayer.frame.size != rect.size
            if cellLayer.frame != rect { cellLayer.frame = rect }
            if cellLayer.contentsScale != scale {
                cellLayer.contentsScale = scale
                cellLayer.setNeedsDisplay()
            }
            cellLayer.drawingTraits = traitCollection
            cellLayer.padding = style.cellPadding
            cellLayer.borderWidth = style.ruleWidth
            cellLayer.borderColor = rule
            if let node = table.nodeAt(pos) {
                let rendered = cache.cell(for: node, style: cellStyle, width: contentWidth(cellRect))
                if cellLayer.cell !== rendered { cellLayer.cell = rendered } else if resized { cellLayer.setNeedsDisplay() }
                let fill = node.type === header ? headerFill : nil
                if cellLayer.fill != fill { cellLayer.fill = fill }
            }
            keep[slot] = cellLayer
        }
        for (slot, cellLayer) in cellLayers where keep[slot] == nil { cellLayer.removeFromSuperlayer() }
        cellLayers = keep
        CATransaction.commit()
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previous?.displayScale != traitCollection.displayScale
            || previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previous?.accessibilityContrast != traitCollection.accessibilityContrast {
            reload(force: true)
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // The screen's scale (and traits) are known once in a window.
        if window != nil { reload(force: true) }
    }
}

/// The view in the note's text for a table: the grid, scrolling sideways when it's wider than
/// the text column. A tap selects the table.
public final class TableHostView: UIView {
    public let grid: TableGridView
    public let scrollView = UIScrollView()
    /// Called on a tap (`TableAttachment` selects the table).
    var onTap: (() -> Void)?

    init(grid: TableGridView) {
        self.grid = grid
        super.init(frame: .zero)
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.scrollsToTop = false
        scrollView.addSubview(grid)
        addSubview(scrollView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        accessibilityHint = "Selects the table"
        grid.onReload = { [weak self] in self?.gridChanged() }
        gridChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The height the table's line needs.
    public var height: CGFloat { grid.frame.height }

    func setWidth(_ width: CGFloat) {
        grid.availableWidth = width - grid.style.ruleWidth
        setNeedsLayout()
    }

    /// Whether the grid is wider than the room it has (and scrolls sideways).
    public var scrolls: Bool { grid.frame.width > scrollView.frame.width + 0.5 }

    public override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: grid.frame.height)
        scrollView.contentSize = grid.frame.size
        grid.frame.origin = .zero
    }

    private func gridChanged() {
        scrollView.contentSize = grid.frame.size
        let rows = grid.layout.rowHeights.count, columns = grid.layout.columnWidths.count
        accessibilityLabel = "Table, \(rows) \(rows == 1 ? "row" : "rows"), \(columns) \(columns == 1 ? "column" : "columns")"
        setNeedsLayout()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        tap(at: recognizer.location(in: grid))
    }

    /// A tap at `point` (in the grid): selects the table. Cells aren't editable on iOS yet.
    public func tap(at point: CGPoint) { onTap?() }

    public override func accessibilityActivate() -> Bool {
        onTap?()
        return onTap != nil
    }
}
#endif
