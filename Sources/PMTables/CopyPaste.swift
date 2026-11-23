// Port of prosemirror-tables/src/copypaste.ts and handlePaste from input.ts
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel
import PMTransform
import PMState

/// A rectangle of cells to paste: one fragment of cells per row.
public struct PastedCells {
    public var width: Int
    public var height: Int
    public var rows: [Fragment]
}

private func attr(_ node: Node, _ name: String) -> Int { cellSpan(node.attrs, name) }

/// The cells in a pasted slice (cells, rows or a table), squared up; nil when it holds no cells.
public func pastedCells(_ slice: Slice) -> PastedCells? {
    if slice.size == 0 { return nil }
    var content = slice.content, openStart = slice.openStart, openEnd = slice.openEnd
    while content.childCount == 1 && ((openStart > 0 && openEnd > 0) || content.child(0).tableRole == .table) {
        openStart -= 1
        openEnd -= 1
        content = content.child(0).content
    }
    let first = content.child(0)
    let schema = first.type.schema
    var rows: [Fragment] = []
    switch first.tableRole {
    case .row:
        for i in 0..<content.childCount {
            var cells = content.child(i).content
            let left = i > 0 ? 0 : max(0, openStart - 1)
            let right = i < content.childCount - 1 ? 0 : max(0, openEnd - 1)
            if left > 0 || right > 0, let row = tableNodeTypes(schema)[.row] {
                cells = fitSlice(row, Slice(cells, left, right))?.content ?? cells
            }
            rows.append(cells)
        }
    case .cell, .headerCell:
        if openStart > 0 || openEnd > 0, let row = tableNodeTypes(schema)[.row] {
            rows.append(fitSlice(row, Slice(content, openStart, openEnd))?.content ?? content)
        } else {
            rows.append(content)
        }
    default:
        return nil
    }
    return ensureRectangular(schema, rows)
}

private func ensureRectangular(_ schema: Schema, _ rows: [Fragment]) -> PastedCells {
    var rows = rows
    var widths: [Int] = []
    for (i, row) in rows.enumerated() {
        for j in stride(from: row.childCount - 1, through: 0, by: -1) {
            let cell = row.child(j)
            for r in i..<(i + attr(cell, "rowspan")) {
                while widths.count <= r { widths.append(0) }
                widths[r] += attr(cell, "colspan")
            }
        }
    }
    let width = widths.max() ?? 0
    for r in widths.indices {
        if r >= rows.count { rows.append(.empty) }
        if widths[r] < width, let empty = tableNodeTypes(schema)[.cell]?.createAndFill() {
            rows[r] = rows[r].append(Fragment.from([Node](repeating: empty, count: width - widths[r])))
        }
    }
    return PastedCells(width: width, height: rows.count, rows: rows)
}

private func fitSlice(_ nodeType: NodeType, _ slice: Slice) -> Node? {
    guard let node = nodeType.createAndFill() else { return nil }
    return try? Transform(node).replace(0, node.content.size, slice).doc
}

/// `cells` repeated or cut to `newWidth` × `newHeight`.
public func clipCells(_ cells: PastedCells, _ newWidth: Int, _ newHeight: Int) -> PastedCells {
    var rows = cells.rows, width = cells.width, height = cells.height
    if width != newWidth {
        var added: [Int: Int] = [:]
        var newRows: [Fragment] = []
        for row in 0..<rows.count {
            let frag = rows[row]
            var out: [Node] = []
            var col = added[row] ?? 0, i = 0
            while col < newWidth && frag.childCount > 0 {
                var cell = frag.child(i % frag.childCount)
                if col + attr(cell, "colspan") > newWidth {
                    let colspan = attr(cell, "colspan")
                    cell = (try? cell.type.createChecked(removeColSpan(cell.attrs, pos: colspan, n: col + colspan - newWidth), cell.content)) ?? cell
                }
                out.append(cell)
                col += attr(cell, "colspan")
                for j in stride(from: 1, to: attr(cell, "rowspan"), by: 1) { added[row + j, default: 0] += attr(cell, "colspan") }
                i += 1
            }
            newRows.append(Fragment.from(out))
        }
        rows = newRows
        width = newWidth
    }
    if height != newHeight {
        var newRows: [Fragment] = []
        for row in 0..<newHeight {
            var out: [Node] = []
            let source = rows[row % height]
            for j in 0..<source.childCount {
                var cell = source.child(j)
                if row + attr(cell, "rowspan") > newHeight {
                    var attrs = cell.attrs
                    attrs["rowspan"] = .number(Double(max(1, newHeight - attr(cell, "rowspan"))))
                    cell = (try? cell.type.create(attrs, cell.content)) ?? cell
                }
                out.append(cell)
            }
            newRows.append(Fragment.from(out))
        }
        rows = newRows
        height = newHeight
    }
    return PastedCells(width: width, height: height, rows: rows)
}

private func growTable(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int, _ width: Int, _ height: Int,
                       _ mapFrom: Int) throws -> Bool {
    let types = tableNodeTypes(tr.doc.type.schema)
    var empty: Node?, emptyHead: Node?
    func emptyCell() -> Node? { if empty == nil { empty = types[.cell]?.createAndFill() }; return empty }
    func emptyHeader() -> Node? { if emptyHead == nil { emptyHead = types[.headerCell]?.createAndFill() }; return emptyHead }
    if width > map.width {
        var rowEnd = 0
        for row in 0..<map.height {
            let rowNode = table.child(row)
            rowEnd += rowNode.nodeSize
            let add = rowNode.lastChild == nil || rowNode.lastChild!.type === types[.cell] ? emptyCell() : emptyHeader()
            guard let add else { continue }
            let cells = [Node](repeating: add, count: width - map.width)
            try tr.insert(tr.mapping.slice(mapFrom).map(rowEnd - 1 + start), Fragment.from(cells))
        }
    }
    if height > map.height {
        var cells: [Node] = []
        let lastRow = (map.height - 1) * map.width
        for i in 0..<max(map.width, width) {
            let header = i >= map.width ? false : table.nodeAt(map.map[lastRow + i])?.type === types[.headerCell]
            if let cell = header ? emptyHeader() : emptyCell() { cells.append(cell) }
        }
        if let rowType = types[.row] {
            let emptyRow = try rowType.create(nil, Fragment.from(cells))
            let rows = [Node](repeating: emptyRow, count: height - map.height)
            try tr.insert(tr.mapping.slice(mapFrom).map(start + table.nodeSize - 2), Fragment.from(rows))
        }
    }
    return empty != nil || emptyHead != nil
}

private func isolateHorizontal(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int, _ left: Int, _ right: Int,
                               _ top: Int, _ mapFrom: Int) throws -> Bool {
    if top == 0 || top == map.height { return false }
    var found = false
    var col = left
    while col < right {
        defer { col += 1 }
        let index = top * map.width + col, pos = map.map[index]
        if map.map[index - map.width] == pos {
            found = true
            guard let cell = table.nodeAt(pos) else { continue }
            let cellRect = try map.findCell(pos)
            var attrs = cell.attrs
            attrs["rowspan"] = .number(Double(top - cellRect.top))
            try tr.setNodeMarkup(tr.mapping.slice(mapFrom).map(pos + start), nil, attrs)
            var rest = cell.attrs
            rest["rowspan"] = .number(Double(cellRect.top + attr(cell, "rowspan") - top))
            // As in prosemirror-tables 1.8.5, this position is table-relative (no `start`).
            if let node = cell.type.createAndFill(rest) {
                try tr.insert(tr.mapping.slice(mapFrom).map(map.positionAt(row: top, col: cellRect.left, table: table)), node)
            }
            col += attr(cell, "colspan") - 1
        }
    }
    return found
}

private func isolateVertical(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int, _ top: Int, _ bottom: Int,
                             _ left: Int, _ mapFrom: Int) throws -> Bool {
    if left == 0 || left == map.width { return false }
    var found = false
    var row = top
    while row < bottom {
        defer { row += 1 }
        let index = row * map.width + left, pos = map.map[index]
        if map.map[index - 1] == pos {
            found = true
            guard let cell = table.nodeAt(pos) else { continue }
            let cellLeft = try map.colCount(pos)
            let updatePos = tr.mapping.slice(mapFrom).map(pos + start)
            try tr.setNodeMarkup(updatePos, nil, removeColSpan(cell.attrs, pos: left - cellLeft, n: attr(cell, "colspan") - (left - cellLeft)))
            if let node = cell.type.createAndFill(removeColSpan(cell.attrs, pos: 0, n: left - cellLeft)) {
                try tr.insert(updatePos + cell.nodeSize, node)
            }
            row += attr(cell, "rowspan") - 1
        }
    }
    return found
}

/// Pastes `cells` into the table starting at `tableStart`, with their top-left at `rect`'s,
/// growing the table and splitting spans as needed; selects the pasted cells.
public func insertCells(_ state: EditorState, _ dispatch: Dispatch, _ tableStart: Int, _ rect: TableRect, _ cells: PastedCells) throws {
    guard var table = tableStart > 0 ? state.doc.nodeAt(tableStart - 1) : state.doc else { throw PMError.range("No table found") }
    var map = try TableMap.get(table)
    let top = rect.top, left = rect.left
    let right = left + cells.width, bottom = top + cells.height
    let tr = state.tr
    var mapFrom = 0
    func recomp() throws {
        guard let t = tableStart > 0 ? tr.doc.nodeAt(tableStart - 1) : tr.doc else { throw PMError.range("No table found") }
        table = t
        map = try TableMap.get(table)
        mapFrom = tr.mapping.maps.count
    }
    if try growTable(tr, map, table, tableStart, right, bottom, mapFrom) { try recomp() }
    if try isolateHorizontal(tr, map, table, tableStart, left, right, top, mapFrom) { try recomp() }
    if try isolateHorizontal(tr, map, table, tableStart, left, right, bottom, mapFrom) { try recomp() }
    if try isolateVertical(tr, map, table, tableStart, top, bottom, left, mapFrom) { try recomp() }
    if try isolateVertical(tr, map, table, tableStart, top, bottom, right, mapFrom) { try recomp() }
    for row in top..<bottom {
        let from = map.positionAt(row: row, col: left, table: table), to = map.positionAt(row: row, col: right, table: table)
        try tr.replace(tr.mapping.slice(mapFrom).map(from + tableStart), tr.mapping.slice(mapFrom).map(to + tableStart),
                       Slice(cells.rows[row - top], 0, 0))
    }
    try recomp()
    _ = tr.setSelection(try CellSelection(tr.doc.resolve(tableStart + map.positionAt(row: top, col: left, table: table)),
                                          tr.doc.resolve(tableStart + map.positionAt(row: bottom - 1, col: right - 1, table: table))))
    dispatch(tr)
}

/// Pasting into a table: cells fill a cell selection (repeated or clipped to it), or land
/// with their top-left at the caret's cell, growing the table. Returns whether it handled it.
public func handlePaste(_ state: EditorState, _ slice: Slice, _ dispatch: Dispatch?) -> Bool {
    guard isInTable(state) else { return false }
    return CommandErrors.run {
        var cells = pastedCells(slice)
        if let sel = state.selection as? CellSelection {
            if cells == nil, let cellType = tableNodeTypes(state.schema)[.cell], let fitted = fitSlice(cellType, slice) {
                cells = PastedCells(width: 1, height: 1, rows: [Fragment.from(fitted)])
            }
            guard var cells else { return false }
            let table = sel.anchorCell.node(-1)
            let start = sel.anchorCell.start(-1)
            let rect = try TableMap.get(table).rectBetween(sel.anchorCell.pos - start, sel.headCell.pos - start)
            cells = clipCells(cells, rect.right - rect.left, rect.bottom - rect.top)
            if let dispatch { try insertCells(state, dispatch, start, rect, cells) }
            return true
        } else if let cells {
            let cell = try selectionCell(state)
            let start = cell.start(-1)
            let rect = try TableMap.get(cell.node(-1)).findCell(cell.pos - start)
            if let dispatch { try insertCells(state, dispatch, start, rect, cells) }
            return true
        }
        return false
    }
}
