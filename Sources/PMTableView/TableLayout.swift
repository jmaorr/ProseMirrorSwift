#if os(macOS) || os(iOS)
import CoreGraphics
import PMModel
import PMTables

/// Where a table's columns, rows and cells go. Pure geometry: computed from the table node,
/// its map, the width available and each cell's content height.
public struct TableLayout: Equatable {
    /// The widest a column's `colwidth` can make it, in points.
    public static let maxColumnWidth: CGFloat = 100_000

    /// Left edge of each column, plus the right edge of the last (`width + 1` values).
    public let columnX: [CGFloat]
    public let columnWidths: [CGFloat]
    /// Top edge of each row, plus the bottom of the last.
    public let rowY: [CGFloat]
    public let rowHeights: [CGFloat]
    public let size: CGSize
    /// Each cell's rect, by its position relative to the table start (as in `TableMap`).
    public let cellRects: [Int: CGRect]

    public func cellRect(pos: Int) -> CGRect? { cellRects[pos] }

    /// The cell under `point`, by position relative to the table start.
    public func cell(at point: CGPoint) -> Int? {
        cellRects.first { $0.value.contains(point) }?.key
    }

    /// The column border (1...columns, the right edge of column k-1) within `tolerance` of `x`.
    public func columnBorder(near x: CGFloat, tolerance: CGFloat) -> Int? {
        guard columnX.count > 1 else { return nil }
        let best = (1..<columnX.count).min { abs(columnX[$0] - x) < abs(columnX[$1] - x) }!
        return abs(columnX[best] - x) <= tolerance ? best : nil
    }

    /// Lays out `table`. Column widths follow the web editor (Tiptap's column resizing over
    /// `table-layout: fixed; width: 100%`): a column takes the `colwidth` its cell in the first
    /// row sets; the rest share what's left of `availableWidth`, at least `minFlexibleWidth`
    /// each; with every column set, the table is their sum. `overrideWidths` (by column)
    /// replaces widths during a live resize. Rows are as tall as their tallest cell (a cell
    /// spanning rows adds any extra height to its last row).
    public static func make(table: Node, map: TableMap, availableWidth: CGFloat, style: TableStyle,
                            contentHeight: (_ cellPos: Int, _ contentWidth: CGFloat) -> CGFloat,
                            overrideWidths: [Int: CGFloat] = [:]) -> TableLayout {
        let columns = max(map.width, 0), rows = max(map.height, 0)
        var fixed = [CGFloat?](repeating: nil, count: columns)
        if table.childCount > 0 {
            let firstRow = table.child(0)
            var col = 0
            for i in 0..<firstRow.childCount {
                let attrs = firstRow.child(i).attrs
                // Attrs are untrusted: clamp the span to the columns left, and widths to sane values.
                let colspan = min(cellSpan(attrs, "colspan"), max(columns - col, 0))
                let widths = attrs["colwidth"]?.arrayValue
                for j in 0..<colspan {
                    if let w = widths.flatMap({ j < $0.count ? $0[j].numberValue : nil }), w > 0, w.isFinite {
                        fixed[col + j] = min(CGFloat(w), maxColumnWidth)
                    }
                }
                col += colspan
            }
        }
        for (col, width) in overrideWidths where col < columns { fixed[col] = width }
        let flexible = fixed.filter { $0 == nil }.count
        let fixedTotal = fixed.compactMap { $0 }.reduce(0, +)
        let share = flexible > 0 ? max(style.minFlexibleWidth, (availableWidth - fixedTotal) / CGFloat(flexible)) : 0
        let widths = fixed.map { $0 ?? share }
        var columnX: [CGFloat] = [0]
        for w in widths { columnX.append(columnX.last! + w) }

        // Cells by the rectangle they cover, in one pass: a cell's first slot is its top-left,
        // its last its bottom-right (what TableMap.findCell finds, without a scan per cell).
        var first: [Int: Int] = [:], last: [Int: Int] = [:]
        var order: [Int] = []
        for (index, pos) in map.map.enumerated() where pos != 0 {
            if first[pos] == nil { first[pos] = index; order.append(pos) }
            last[pos] = index
        }
        let stride = max(columns, 1)
        let cells: [(pos: Int, rect: TableRect)] = order.map { pos in
            let a = first[pos]!, b = last[pos]!
            return (pos, TableRect(left: a % stride, top: a / stride, right: b % stride + 1, bottom: b / stride + 1))
        }
        let padding = style.cellPadding.top + style.cellPadding.bottom
        let minRow = padding + 1
        func needed(_ cell: (pos: Int, rect: TableRect)) -> CGFloat {
            let width = columnX[cell.rect.right] - columnX[cell.rect.left] - style.cellPadding.left - style.cellPadding.right
            return contentHeight(cell.pos, max(width, 1)) + padding
        }
        var heights = [CGFloat](repeating: minRow, count: rows)
        for cell in cells where cell.rect.bottom - cell.rect.top == 1 {
            heights[cell.rect.top] = max(heights[cell.rect.top], needed(cell))
        }
        for cell in cells.sorted(by: { $0.rect.bottom < $1.rect.bottom }) where cell.rect.bottom - cell.rect.top > 1 {
            let spanned = heights[cell.rect.top..<cell.rect.bottom].reduce(0, +)
            let extra = needed(cell) - spanned
            if extra > 0 { heights[cell.rect.bottom - 1] += extra }
        }
        var rowY: [CGFloat] = [0]
        for h in heights { rowY.append(rowY.last! + h) }
        var rects: [Int: CGRect] = [:]
        for cell in cells {
            rects[cell.pos] = CGRect(x: columnX[cell.rect.left], y: rowY[cell.rect.top],
                                     width: columnX[cell.rect.right] - columnX[cell.rect.left],
                                     height: rowY[cell.rect.bottom] - rowY[cell.rect.top])
        }
        return TableLayout(columnX: columnX, columnWidths: widths, rowY: rowY, rowHeights: heights,
                           size: CGSize(width: columnX.last!, height: max(rowY.last!, minRow)), cellRects: rects)
    }
}
#endif
