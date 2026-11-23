// Port of prosemirror-tables/src/tablemap.ts
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel

/// A rectangle of cells: columns `left..<right`, rows `top..<bottom`.
public struct TableRect: Equatable {
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("left", .number(Double(left))), ("top", .number(Double(top))),
                            ("right", .number(Double(right))), ("bottom", .number(Double(bottom)))]))
    }
}

/// A structural problem `TableMap` found; `fixTables` repairs them.
public enum TableProblem: Equatable {
    case collision(row: Int, pos: Int, n: Int)
    case missing(row: Int, n: Int)
    case overlongRowspan(pos: Int, n: Int)
    case colwidthMismatch(pos: Int, colwidth: [Double])
    case zeroSized

    public func toJSON() -> JSONValue {
        func n(_ i: Int) -> JSONValue { .number(Double(i)) }
        switch self {
        case let .collision(row, pos, count):
            return .object(JSONObject([("type", "collision"), ("row", n(row)), ("pos", n(pos)), ("n", n(count))]))
        case let .missing(row, count):
            return .object(JSONObject([("type", "missing"), ("row", n(row)), ("n", n(count))]))
        case let .overlongRowspan(pos, count):
            return .object(JSONObject([("type", "overlong_rowspan"), ("pos", n(pos)), ("n", n(count))]))
        case let .colwidthMismatch(pos, colwidth):
            return .object(JSONObject([("type", "colwidth mismatch"), ("pos", n(pos)),
                                       ("colwidth", .array(colwidth.map { $0.isNaN ? .null : .number($0) }))]))
        case .zeroSized:
            return .object(JSONObject([("type", "zero_sized")]))
        }
    }
}

/// The largest `colspan` or `rowspan` honoured. Attributes come from collaborators and the
/// pasteboard, so a cell can claim any number; spans are clamped to `1...maxCellSpan`.
public let maxCellSpan = 1000

/// The most grid slots (`width * height`, and cell-slot visits while mapping) a table may
/// need; `TableMap` throws for bigger tables rather than allocating for them.
public let maxTableSlots = 1_000_000

/// A cell's `colspan` or `rowspan` (`name`) as a count: 1 when missing or not a finite
/// number, otherwise clamped to `1...maxCellSpan`. (prosemirror-tables reads the attribute
/// as-is; its own documents never hold spans outside this range.)
public func cellSpan(_ attrs: Attrs, _ name: String) -> Int {
    min(max(attrs[name]?.intValue ?? 1, 1), maxCellSpan)
}

/// Cell attributes as numbers (attrs are JSON in the model).
struct CellAttrs {
    var colspan: Int
    var rowspan: Int
    var colwidth: [Double]?

    init(_ attrs: Attrs) {
        colspan = cellSpan(attrs, "colspan")
        rowspan = cellSpan(attrs, "rowspan")
        colwidth = attrs["colwidth"]?.arrayValue?.map { $0.numberValue ?? 0 }
    }
}

/// The structure of a table: which cell covers each slot of its grid. Positions are
/// relative to the start of the table, so maps can be cached per table node.
public final class TableMap {
    public let width: Int
    public let height: Int
    /// `width * height` cell positions, row by row (0 where no cell covers the slot).
    public let map: [Int]
    public fileprivate(set) var problems: [TableProblem]?

    init(width: Int, height: Int, map: [Int], problems: [TableProblem]?) {
        self.width = width
        self.height = height
        self.map = map
        self.problems = problems
    }

    /// The rectangle the cell at `pos` covers.
    public func findCell(_ pos: Int) throws -> TableRect {
        for i in 0..<map.count where map[i] == pos {
            let left = i % width, top = i / width
            var right = left + 1, bottom = top + 1
            var j = 1
            while right < width && map[i + j] == pos { right += 1; j += 1 }
            j = 1
            while bottom < height && map[i + width * j] == pos { bottom += 1; j += 1 }
            return TableRect(left: left, top: top, right: right, bottom: bottom)
        }
        throw PMError.range("No cell with offset \(pos) found")
    }

    /// The left column of the cell at `pos`.
    public func colCount(_ pos: Int) throws -> Int {
        for i in 0..<map.count where map[i] == pos { return i % width }
        throw PMError.range("No cell with offset \(pos) found")
    }

    /// The cell next to `pos` along `axis` ("horiz" or "vert") in direction `dir`, or nil at the edge.
    public func nextCell(_ pos: Int, axis: String, dir: Int) throws -> Int? {
        let r = try findCell(pos)
        if axis == "horiz" {
            if dir < 0 ? r.left == 0 : r.right == width { return nil }
            return map[r.top * width + (dir < 0 ? r.left - 1 : r.right)]
        } else {
            if dir < 0 ? r.top == 0 : r.bottom == height { return nil }
            return map[r.left + width * (dir < 0 ? r.top - 1 : r.bottom)]
        }
    }

    /// The smallest rectangle covering both cells.
    public func rectBetween(_ a: Int, _ b: Int) throws -> TableRect {
        let ra = try findCell(a), rb = try findCell(b)
        return TableRect(left: min(ra.left, rb.left), top: min(ra.top, rb.top),
                         right: max(ra.right, rb.right), bottom: max(ra.bottom, rb.bottom))
    }

    /// Positions of the cells whose top-left corner is inside `rect`.
    public func cellsInRect(_ rect: TableRect) -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        for row in rect.top..<max(rect.top, rect.bottom) {
            for col in rect.left..<max(rect.left, rect.right) {
                let index = row * width + col
                let pos = map[index]
                if seen.contains(pos) { continue }
                seen.insert(pos)
                if (col == rect.left && col != 0 && map[index - 1] == pos) ||
                    (row == rect.top && row != 0 && map[index - width] == pos) { continue }
                result.append(pos)
            }
        }
        return result
    }

    /// Where a cell at (`row`, `col`) starts, or would be inserted, within `table`.
    public func positionAt(row: Int, col: Int, table: Node) -> Int {
        var rowStart = 0
        var i = 0
        while true {
            let rowEnd = rowStart + table.child(i).nodeSize
            if i == row {
                var index = col + row * width
                let rowEndIndex = (row + 1) * width
                while index < rowEndIndex && map[index] < rowStart { index += 1 }
                return index == rowEndIndex ? rowEnd - 1 : map[index]
            }
            rowStart = rowEnd
            i += 1
        }
    }

    nonisolated(unsafe) private static let cache = NSMapTable<Node, TableMap>.weakToStrongObjects()
    private static let lock = NSLock()

    /// The map for `table`, cached by node identity.
    public static func get(_ table: Node) throws -> TableMap {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.object(forKey: table) { return cached }
        let map = try computeMap(table)
        cache.setObject(map, forKey: table)
        return map
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("width", .number(Double(width))), ("height", .number(Double(height))),
                            ("map", .array(map.map { .number(Double($0)) })),
                            ("problems", problems.map { .array($0.map { $0.toJSON() }) } ?? .null)]))
    }
}

func computeMap(_ table: Node) throws -> TableMap {
    if table.type.spec.extra["tableRole"]?.stringValue != "table" {
        throw PMError.range("Not a table node: \(table.type.name)")
    }
    let width = findWidth(table), height = table.childCount
    // Spans are clamped, but enough cells can still describe a huge grid, or one where
    // overlapping spans visit slots far more often than it has them: refuse those.
    if width * height > maxTableSlots { throw PMError.range("Table too large (\(width) × \(height))") }
    var visits = 0
    for row in 0..<height {
        let rowNode = table.child(row)
        for i in 0..<rowNode.childCount {
            let attrs = CellAttrs(rowNode.child(i).attrs)
            visits += attrs.colspan * min(attrs.rowspan, height - row)
        }
        if visits > maxTableSlots { throw PMError.range("Table too large (\(visits) cell slots)") }
    }
    var map = [Int](repeating: 0, count: width * height)
    var mapPos = 0
    var problems: [TableProblem]?
    // Per column: the width seen, and how many rows agreed on it.
    var colWidths = [(width: Double, count: Int)?](repeating: nil, count: width)
    var pos = 0
    for row in 0..<height {
        let rowNode = table.child(row)
        pos += 1
        var i = 0
        while true {
            while mapPos < map.count && map[mapPos] != 0 { mapPos += 1 }
            if i == rowNode.childCount { break }
            let cellNode = rowNode.child(i)
            let attrs = CellAttrs(cellNode.attrs)
            for h in 0..<max(0, attrs.rowspan) {
                if h + row >= height {
                    problems.append(.overlongRowspan(pos: pos, n: attrs.rowspan - h))
                    break
                }
                let start = mapPos + h * width
                for w in 0..<max(0, attrs.colspan) {
                    // JS reads past the end as undefined, which counts as taken.
                    if start + w < map.count && map[start + w] == 0 {
                        map[start + w] = pos
                    } else {
                        problems.append(.collision(row: row, pos: pos, n: attrs.colspan - w))
                    }
                    if let colW = attrs.colwidth.flatMap({ w < $0.count ? $0[w] : nil }), colW != 0 {
                        let col = (start + w) % width
                        if let prev = colWidths[col] {
                            if prev.width != colW && prev.count == 1 {
                                colWidths[col] = (colW, 1)
                            } else if prev.width == colW {
                                colWidths[col] = (colW, prev.count + 1)
                            }
                        } else {
                            colWidths[col] = (colW, 1)
                        }
                    }
                }
            }
            mapPos += attrs.colspan
            pos += cellNode.nodeSize
            i += 1
        }
        let expectedPos = (row + 1) * width
        var missing = 0
        while mapPos < expectedPos {
            if map[mapPos] == 0 { missing += 1 }
            mapPos += 1
        }
        if missing > 0 { problems.append(.missing(row: row, n: missing)) }
        pos += 1
    }
    if width == 0 || height == 0 { problems.append(.zeroSized) }
    let tableMap = TableMap(width: width, height: height, map: map, problems: problems)
    if colWidths.contains(where: { $0 != nil && $0!.count < height }) {
        try findBadColWidths(tableMap, colWidths.map { $0?.width }, table)
    }
    return tableMap
}

private extension Optional where Wrapped == [TableProblem] {
    mutating func append(_ problem: TableProblem) {
        if self == nil { self = [] }
        self!.append(problem)
    }
}

func findWidth(_ table: Node) -> Int {
    var width = -1
    var hasRowSpan = false
    for row in 0..<table.childCount {
        let rowNode = table.child(row)
        var rowWidth = 0
        if hasRowSpan {
            // Spans are clamped to maxCellSpan, so only that many rows back can reach this one.
            for j in max(0, row - maxCellSpan)..<row {
                let prevRow = table.child(j)
                for i in 0..<prevRow.childCount {
                    let cell = CellAttrs(prevRow.child(i).attrs)
                    if j + cell.rowspan > row { rowWidth += cell.colspan }
                }
            }
        }
        for i in 0..<rowNode.childCount {
            let cell = CellAttrs(rowNode.child(i).attrs)
            rowWidth += cell.colspan
            if cell.rowspan > 1 { hasRowSpan = true }
        }
        if width == -1 { width = rowWidth } else if width != rowWidth { width = max(width, rowWidth) }
    }
    return width
}

private func findBadColWidths(_ map: TableMap, _ colWidths: [Double?], _ table: Node) throws {
    if map.problems == nil { map.problems = [] }
    var seen = Set<Int>()
    for i in 0..<map.map.count {
        let pos = map.map[i]
        if seen.contains(pos) { continue }
        seen.insert(pos)
        guard let node = table.nodeAt(pos) else { throw PMError.range("No cell with offset \(pos) found") }
        var updated: [Double]?
        let attrs = CellAttrs(node.attrs)
        // A slot no cell covers maps to 0, which is the first row: no colspan, nothing to check.
        let colspan = node.attrs["colspan"] == nil ? 0 : attrs.colspan
        for j in 0..<max(0, colspan) {
            guard let colWidth = colWidths[(i + j) % map.width] else { continue }
            let current = attrs.colwidth.flatMap { j < $0.count ? $0[j] : nil }
            if attrs.colwidth == nil || current != colWidth {
                if updated == nil { updated = freshColWidth(attrs) }
                // JS assigns past the end of a short array, padding with holes (null in JSON).
                while updated!.count <= j { updated!.append(.nan) }
                updated![j] = colWidth
            }
        }
        if let updated { map.problems!.insert(.colwidthMismatch(pos: pos, colwidth: updated), at: 0) }
    }
}

func freshColWidth(_ attrs: CellAttrs) -> [Double] {
    if let colwidth = attrs.colwidth { return colwidth }
    return [Double](repeating: 0, count: max(0, attrs.colspan))
}
