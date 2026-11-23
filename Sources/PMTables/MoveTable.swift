// Port of prosemirror-tables/src/utils/{convert,move-row-in-array-of-rows,get-cells,selection-range,
// transpose,move-row,move-column}.ts and moveTableRow/moveTableColumn from commands.ts
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel
import PMTransform
import PMState

// MARK: Grid conversion

/// The table as a grid of cells; slots covered by a span (from above or the left) are nil.
private func arrayOfRows(_ table: Node) throws -> [[Node?]] {
    let map = try TableMap.get(table)
    var rows: [[Node?]] = []
    for rowIndex in 0..<map.height {
        var row: [Node?] = []
        for colIndex in 0..<map.width {
            let cellIndex = rowIndex * map.width + colIndex
            let cellPos = map.map[cellIndex]
            if rowIndex > 0 && cellPos == map.map[cellIndex - map.width] { row.append(nil); continue }
            if colIndex > 0 && cellPos == map.map[cellIndex - 1] { row.append(nil); continue }
            row.append(table.nodeAt(cellPos))
        }
        rows.append(row)
    }
    return rows
}

/// A copy of `table` with its cells taken from `grid`, slot by slot.
private func tableNode(_ table: Node, _ grid: [[Node?]]) throws -> Node {
    let map = try TableMap.get(table)
    var newRows: [Node] = []
    for rowIndex in 0..<map.height {
        let oldRow = table.child(rowIndex)
        var newCells: [Node] = []
        for colIndex in 0..<map.width {
            guard let cell = grid[rowIndex][colIndex] else { continue }
            guard let oldCell = table.nodeAt(map.map[rowIndex * map.width + colIndex]) else { continue }
            newCells.append(try oldCell.type.createChecked(cell.attrs, cell.content, cell.marks))
        }
        newRows.append(try oldRow.type.createChecked(oldRow.attrs, Fragment.from(newCells), oldRow.marks))
    }
    return try table.type.createChecked(table.attrs, Fragment.from(newRows), table.marks)
}

private func moveRowInArrayOfRows<T>(_ rows: [T], _ origin: [Int], _ target: [Int], _ directionOverride: Int) -> [T] {
    var rows = rows
    let direction = origin[0] > target[0] ? -1 : 1
    let extracted = Array(rows[origin[0]..<min(rows.count, origin[0] + origin.count)])
    rows.removeSubrange(origin[0]..<min(rows.count, origin[0] + origin.count))
    let positionOffset = extracted.count % 2 == 0 ? 1 : 0
    let at: Int
    if directionOverride == -1 && direction == 1 {
        at = target[0] - 1
    } else if directionOverride == 1 && direction == -1 {
        at = target[target.count - 1] - positionOffset + 1
    } else {
        at = direction == -1 ? target[0] : target[target.count - 1] - positionOffset
    }
    // JS splice: a negative index counts from the end.
    rows.insert(contentsOf: extracted, at: min(at < 0 ? max(rows.count + at, 0) : at, rows.count))
    return rows
}

private func transpose<T>(_ array: [[T?]]) -> [[T?]] {
    guard let first = array.first else { return [] }
    return first.indices.map { i in array.map { i < $0.count ? $0[i] : nil } }
}

// MARK: Cells in a row or column

private struct FoundCell {
    let pos: Int
    let node: Node
}

private func cellsInColumn(_ columnIndex: Int, _ selection: Selection) -> [FoundCell]? {
    guard let table = findTable(selection.fromPos), let map = try? TableMap.get(table.node) else { return nil }
    if columnIndex < 0 || columnIndex > map.width - 1 { return nil }
    return map.cellsInRect(TableRect(left: columnIndex, top: 0, right: columnIndex + 1, bottom: map.height)).compactMap { p in
        table.node.nodeAt(p).map { FoundCell(pos: p + table.start, node: $0) }
    }
}

private func cellsInRow(_ rowIndex: Int, _ selection: Selection) -> [FoundCell]? {
    guard let table = findTable(selection.fromPos), let map = try? TableMap.get(table.node) else { return nil }
    if rowIndex < 0 || rowIndex > map.height - 1 { return nil }
    return map.cellsInRect(TableRect(left: 0, top: rowIndex, right: map.width, bottom: rowIndex + 1)).compactMap { p in
        table.node.nodeAt(p).map { FoundCell(pos: p + table.start, node: $0) }
    }
}

/// The indexes of the rows (`isRow`) or columns a move of `start` has to take along, because
/// spans tie them together. nil when there is no such row or column.
private func spannedIndexes(_ tr: Transaction, _ start: Int, isRow: Bool) -> [Int]? {
    let cells: (Int) -> [FoundCell]? = { isRow ? cellsInRow($0, tr.selection) : cellsInColumn($0, tr.selection) }
    let other: (Int) -> [FoundCell]? = { isRow ? cellsInColumn($0, tr.selection) : cellsInRow($0, tr.selection) }
    let span = isRow ? "rowspan" : "colspan"
    var startIndex = start, endIndex = start
    var i = start
    while i >= 0 {
        for cell in cells(i) ?? [] {
            let maybeEnd = cellSpan(cell.node.attrs, span) + i - 1
            if maybeEnd >= startIndex { startIndex = i }
            if maybeEnd > endIndex { endIndex = maybeEnd }
        }
        i -= 1
    }
    i = start
    while i <= endIndex {
        for cell in cells(i) ?? [] {
            let s = cellSpan(cell.node.attrs, span)
            let maybeEnd = s + i - 1
            if s > 1 && maybeEnd > endIndex { endIndex = maybeEnd }
        }
        i += 1
    }
    var indexes: [Int] = []
    if startIndex <= endIndex {
        for j in startIndex...endIndex where !(cells(j) ?? []).isEmpty { indexes.append(j) }
    }
    guard let first = indexes.first, let last = indexes.last,
          let firstSelected = cells(first), let firstOther = other(0) else { return nil }
    _ = firstSelected
    // The range needs a head cell in the first row/column, as JS checks.
    var j = last
    while j >= first {
        if let line = cells(j), let head = line.first {
            if firstOther.contains(where: { $0.pos == head.pos }) { return indexes }
        }
        j -= 1
    }
    return nil
}

// MARK: Moving

private func move(_ tr: Transaction, origin: Int, target: Int, select: Bool, pos: Int, isRow: Bool) throws -> Bool {
    guard let table = findTable(tr.doc.resolve(pos)) else { return false }
    guard let originIndexes = spannedIndexes(tr, origin, isRow: isRow),
          let targetIndexes = spannedIndexes(tr, target, isRow: isRow) else { return false }
    if originIndexes.contains(target) { return false }
    var grid = try arrayOfRows(table.node)
    if isRow {
        grid = moveRowInArrayOfRows(grid, originIndexes, targetIndexes, 0)
    } else {
        grid = transpose(moveRowInArrayOfRows(transpose(grid), originIndexes, targetIndexes, 0))
    }
    let newTable = try tableNode(table.node, grid)
    try tr.replaceWith(table.pos, table.pos + table.node.nodeSize, newTable)
    if !select { return true }
    let map = try TableMap.get(newTable)
    let start = table.start
    if isRow {
        let last = tr.doc.resolve(start + map.positionAt(row: target, col: map.width - 1, table: newTable))
        let first = tr.doc.resolve(start + map.positionAt(row: target, col: 0, table: newTable))
        _ = tr.setSelection(try CellSelection.rowSelection(last, first))
    } else {
        let last = tr.doc.resolve(start + map.positionAt(row: map.height - 1, col: target, table: newTable))
        let first = tr.doc.resolve(start + map.positionAt(row: 0, col: target, table: newTable))
        _ = tr.setSelection(try CellSelection.colSelection(last, first))
    }
    return true
}

/// Moves row `from` (with any rows spans tie to it) to index `to`, in the table at `pos`
/// (default: the selection's). With `select`, the moved row ends up selected.
public func moveTableRow(from: Int, to: Int, select: Bool = true, pos: Int? = nil) -> Command {
    return { state, dispatch, _ in
        CommandErrors.run {
            let tr = state.tr
            guard try move(tr, origin: from, target: to, select: select, pos: pos ?? state.selection.from, isRow: true) else { return false }
            dispatch?(tr)
            return true
        }
    }
}

/// Moves column `from` (with any columns spans tie to it) to index `to`.
public func moveTableColumn(from: Int, to: Int, select: Bool = true, pos: Int? = nil) -> Command {
    return { state, dispatch, _ in
        CommandErrors.run {
            let tr = state.tr
            guard try move(tr, origin: from, target: to, select: select, pos: pos ?? state.selection.from, isRow: false) else { return false }
            dispatch?(tr)
            return true
        }
    }
}
