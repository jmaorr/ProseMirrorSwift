// Port of prosemirror-tables/src/commands.ts, and updateColumnWidth from columnresizing.ts
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel
import PMTransform
import PMState

extension SelectedRect {
    /// After a structural change inside a multi-step command, re-read the table from `doc`.
    mutating func refresh(from doc: Node) throws {
        guard let table = tableStart > 0 ? doc.nodeAt(tableStart - 1) : doc else { throw PMError.range("No table found") }
        self.table = table
        self.map = try TableMap.get(table)
    }
}

private func cellType(_ schema: Schema, _ role: TableRole) throws -> NodeType {
    guard let type = tableNodeTypes(schema)[role] else { throw PMError.range("Schema has no \(role.rawValue) node") }
    return type
}

private func nodeAt(_ table: Node, _ pos: Int) throws -> Node {
    guard let node = table.nodeAt(pos) else { throw PMError.range("No cell with offset \(pos) found") }
    return node
}

private func attrInt(_ node: Node, _ name: String) -> Int { cellSpan(node.attrs, name) }

// MARK: Columns

/// Adds a column at `col` (0...width) to the table in `rect`.
@discardableResult
public func addColumn(_ tr: Transaction, _ rect: SelectedRect, _ col: Int) throws -> Transaction {
    let map = rect.map, table = rect.table, tableStart = rect.tableStart
    var refColumn: Int? = col > 0 ? -1 : 0
    if columnIsHeader(map, table, col + refColumn!) { refColumn = col == 0 || col == map.width ? nil : 0 }
    var row = 0
    while row < map.height {
        defer { row += 1 }
        let index = row * map.width + col
        if col > 0 && col < map.width && map.map[index - 1] == map.map[index] {
            let pos = map.map[index]
            let cell = try nodeAt(table, pos)
            try tr.setNodeMarkup(tr.mapping.map(tableStart + pos), nil, addColSpan(cell.attrs, pos: col - map.colCount(pos)))
            row += attrInt(cell, "rowspan") - 1
        } else {
            let type = try refColumn.map { try nodeAt(table, map.map[index + $0]).type } ?? cellType(table.type.schema, .cell)
            let pos = map.positionAt(row: row, col: col, table: table)
            if let node = type.createAndFill() { try tr.insert(tr.mapping.map(tableStart + pos), node) }
        }
    }
    return tr
}

public let addColumnBefore: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    return CommandErrors.run {
        if let dispatch {
            let rect = try selectedRect(state)
            dispatch(try addColumn(state.tr, rect, rect.left))
        }
        return true
    }
}

public let addColumnAfter: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    return CommandErrors.run {
        if let dispatch {
            let rect = try selectedRect(state)
            dispatch(try addColumn(state.tr, rect, rect.right))
        }
        return true
    }
}

/// Removes column `col` from the table in `rect`, narrowing cells that span it.
public func removeColumn(_ tr: Transaction, _ rect: SelectedRect, _ col: Int) throws {
    let map = rect.map, table = rect.table, tableStart = rect.tableStart
    let mapStart = tr.mapping.maps.count
    var row = 0
    while row < map.height {
        let index = row * map.width + col
        let pos = map.map[index]
        let cell = try nodeAt(table, pos)
        if (col > 0 && map.map[index - 1] == pos) || (col < map.width - 1 && map.map[index + 1] == pos) {
            try tr.setNodeMarkup(tr.mapping.slice(mapStart).map(tableStart + pos), nil,
                                 removeColSpan(cell.attrs, pos: col - map.colCount(pos)))
        } else {
            let start = tr.mapping.slice(mapStart).map(tableStart + pos)
            try tr.delete(start, start + cell.nodeSize)
        }
        row += attrInt(cell, "rowspan")
    }
}

public let deleteColumn: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    return CommandErrors.run {
        guard let dispatch else { return true }
        var rect = try selectedRect(state)
        let tr = state.tr
        if rect.left == 0 && rect.right == rect.map.width { return false }
        var i = rect.right - 1
        while true {
            try removeColumn(tr, rect, i)
            if i == rect.left { break }
            try rect.refresh(from: tr.doc)
            i -= 1
        }
        dispatch(tr)
        return true
    }
}

// MARK: Rows

/// Whether every cell in `row` is a header cell.
public func rowIsHeader(_ map: TableMap, _ table: Node, _ row: Int) -> Bool {
    let headerCell = tableNodeTypes(table.type.schema)[.headerCell]
    for col in 0..<map.width {
        if table.nodeAt(map.map[col + row * map.width])?.type !== headerCell { return false }
    }
    return true
}

/// Adds a row at `row` (0...height) to the table in `rect`.
@discardableResult
public func addRow(_ tr: Transaction, _ rect: SelectedRect, _ row: Int) throws -> Transaction {
    let map = rect.map, table = rect.table, tableStart = rect.tableStart
    var rowPos = tableStart
    for i in 0..<row { rowPos += table.child(i).nodeSize }
    var cells: [Node] = []
    var refRow: Int? = row > 0 ? -1 : 0
    if rowIsHeader(map, table, row + refRow!) { refRow = row == 0 || row == map.height ? nil : 0 }
    var col = 0, index = map.width * row
    while col < map.width {
        defer { col += 1; index += 1 }
        if row > 0 && row < map.height && map.map[index] == map.map[index - map.width] {
            let pos = map.map[index]
            let cell = try nodeAt(table, pos)
            var attrs = cell.attrs
            attrs["rowspan"] = .number(Double(attrInt(cell, "rowspan") + 1))
            try tr.setNodeMarkup(tableStart + pos, nil, attrs)
            // As in JS, only the column skips the span (the index doesn't).
            col += attrInt(cell, "colspan") - 1
        } else {
            let type = try refRow.map { table.nodeAt(map.map[index + $0 * map.width])?.type } ?? cellType(table.type.schema, .cell)
            if let node = type?.createAndFill() { cells.append(node) }
        }
    }
    try tr.insert(rowPos, try cellType(table.type.schema, .row).create(nil, cells))
    return tr
}

public let addRowBefore: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    return CommandErrors.run {
        if let dispatch {
            let rect = try selectedRect(state)
            dispatch(try addRow(state.tr, rect, rect.top))
        }
        return true
    }
}

public let addRowAfter: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    return CommandErrors.run {
        if let dispatch {
            let rect = try selectedRect(state)
            dispatch(try addRow(state.tr, rect, rect.bottom))
        }
        return true
    }
}

/// Removes row `row` from the table in `rect`, shortening or moving cells that span it.
public func removeRow(_ tr: Transaction, _ rect: SelectedRect, _ row: Int) throws {
    let map = rect.map, table = rect.table, tableStart = rect.tableStart
    var rowPos = 0
    for i in 0..<row { rowPos += table.child(i).nodeSize }
    let nextRow = rowPos + table.child(row).nodeSize
    let mapFrom = tr.mapping.maps.count
    try tr.delete(rowPos + tableStart, nextRow + tableStart)
    var seen = Set<Int>()
    var col = 0, index = row * map.width
    while col < map.width {
        defer { col += 1; index += 1 }
        let pos = map.map[index]
        if seen.contains(pos) { continue }
        seen.insert(pos)
        if row > 0 && pos == map.map[index - map.width] {
            let cell = try nodeAt(table, pos)
            var attrs = cell.attrs
            attrs["rowspan"] = .number(Double(attrInt(cell, "rowspan") - 1))
            try tr.setNodeMarkup(tr.mapping.slice(mapFrom).map(pos + tableStart), nil, attrs)
            col += attrInt(cell, "colspan") - 1
        } else if row < map.height && index + map.width < map.map.count && pos == map.map[index + map.width] {
            let cell = try nodeAt(table, pos)
            var attrs = cell.attrs
            attrs["rowspan"] = .number(Double(attrInt(cell, "rowspan") - 1))
            let copy = try cell.type.create(attrs, cell.content)
            let newPos = map.positionAt(row: row + 1, col: col, table: table)
            try tr.insert(tr.mapping.slice(mapFrom).map(tableStart + newPos), copy)
            col += attrInt(cell, "colspan") - 1
        }
    }
}

public let deleteRow: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    return CommandErrors.run {
        guard let dispatch else { return true }
        var rect = try selectedRect(state)
        let tr = state.tr
        if rect.top == 0 && rect.bottom == rect.map.height { return false }
        var i = rect.bottom - 1
        while true {
            try removeRow(tr, rect, i)
            if i == rect.top { break }
            try rect.refresh(from: tr.doc)
            i -= 1
        }
        dispatch(tr)
        return true
    }
}

// MARK: Merge and split

private func isEmpty(_ cell: Node) -> Bool {
    let c = cell.content
    return c.childCount == 1 && c.child(0).isTextblock && c.child(0).childCount == 0
}

private func cellsOverlapRectangle(_ map: TableMap, _ rect: TableRect) -> Bool {
    let width = map.width, height = map.height, m = map.map
    var indexTop = rect.top * width + rect.left, indexLeft = indexTop
    var indexBottom = (rect.bottom - 1) * width + rect.left, indexRight = indexTop + (rect.right - rect.left - 1)
    for _ in rect.top..<rect.bottom {
        if (rect.left > 0 && m[indexLeft] == m[indexLeft - 1]) || (rect.right < width && m[indexRight] == m[indexRight + 1]) {
            return true
        }
        indexLeft += width
        indexRight += width
    }
    for _ in rect.left..<rect.right {
        if (rect.top > 0 && m[indexTop] == m[indexTop - width]) || (rect.bottom < height && m[indexBottom] == m[indexBottom + width]) {
            return true
        }
        indexTop += 1
        indexBottom += 1
    }
    return false
}

/// Merges the selected cells into one, when they form a rectangle no other cell sticks into.
public let mergeCells: Command = { state, dispatch, _ in
    guard let sel = state.selection as? CellSelection, sel.anchorCell.pos != sel.headCell.pos else { return false }
    return CommandErrors.run {
        let rect = try selectedRect(state), map = rect.map
        if cellsOverlapRectangle(map, rect.rect) { return false }
        guard let dispatch else { return true }
        let tr = state.tr
        var seen = Set<Int>()
        var content = Fragment.empty
        var merged: (pos: Int, cell: Node)?
        for row in rect.top..<rect.bottom {
            for col in rect.left..<rect.right {
                let cellPos = map.map[row * map.width + col]
                guard !seen.contains(cellPos), let cell = rect.table.nodeAt(cellPos) else { continue }
                seen.insert(cellPos)
                if merged == nil {
                    merged = (cellPos, cell)
                } else {
                    if !isEmpty(cell) { content = content.append(cell.content) }
                    let mapped = tr.mapping.map(cellPos + rect.tableStart)
                    try tr.delete(mapped, mapped + cell.nodeSize)
                }
            }
        }
        guard let (mergedPos, mergedCell) = merged else { return true }
        let colspan = attrInt(mergedCell, "colspan")
        var attrs = addColSpan(mergedCell.attrs, pos: colspan, n: rect.right - rect.left - colspan)
        attrs["rowspan"] = .number(Double(rect.bottom - rect.top))
        try tr.setNodeMarkup(mergedPos + rect.tableStart, nil, attrs)
        if content.size > 0 {
            let end = mergedPos + 1 + mergedCell.content.size
            let start = isEmpty(mergedCell) ? mergedPos + 1 : end
            try tr.replaceWith(start + rect.tableStart, end + rect.tableStart, content)
        }
        _ = tr.setSelection(try CellSelection(tr.doc.resolve(mergedPos + rect.tableStart)))
        dispatch(tr)
        return true
    }
}

/// Splits a merged cell back into single cells, of the type `getCellType` picks.
public func splitCellWithType(_ getCellType: @escaping (_ node: Node, _ row: Int, _ col: Int) -> NodeType?) -> Command {
    return { state, dispatch, _ in
        let sel = state.selection
        var cellNode: Node?
        var cellPos: Int?
        if let sel = sel as? CellSelection {
            if sel.anchorCell.pos != sel.headCell.pos { return false }
            cellNode = sel.anchorCell.nodeAfter
            cellPos = sel.anchorCell.pos
        } else {
            guard let node = cellWrapping(sel.fromPos) else { return false }
            cellNode = node
            cellPos = cellAround(sel.fromPos)?.pos
        }
        guard let cellNode, let cellPos else { return false }
        if attrInt(cellNode, "colspan") == 1 && attrInt(cellNode, "rowspan") == 1 { return false }
        return CommandErrors.run {
            guard let dispatch else { return true }
            var baseAttrs = cellNode.attrs
            let colwidth = baseAttrs["colwidth"]?.arrayValue
            if attrInt(cellNode, "rowspan") > 1 { baseAttrs["rowspan"] = 1 }
            if attrInt(cellNode, "colspan") > 1 { baseAttrs["colspan"] = 1 }
            let rect = try selectedRect(state), tr = state.tr
            var attrs: [Attrs] = []
            for i in 0..<(rect.right - rect.left) {
                if let colwidth {
                    var a = baseAttrs
                    let w = i < colwidth.count ? colwidth[i] : .null
                    a["colwidth"] = (w.numberValue ?? 0) != 0 ? .array([w]) : .null
                    attrs.append(a)
                } else {
                    attrs.append(baseAttrs)
                }
            }
            var lastCell: Int?
            for row in rect.top..<rect.bottom {
                var pos = rect.map.positionAt(row: row, col: rect.left, table: rect.table)
                if row == rect.top { pos += cellNode.nodeSize }
                for (i, col) in (rect.left..<rect.right).enumerated() {
                    if col == rect.left && row == rect.top { continue }
                    let at = tr.mapping.map(pos + rect.tableStart, assoc: 1)
                    lastCell = at
                    guard let type = getCellType(cellNode, row, col) else { throw PMError.range("No cell type") }
                    if let node = type.createAndFill(attrs[i]) { try tr.insert(at, node) }
                }
            }
            try tr.setNodeMarkup(cellPos, getCellType(cellNode, rect.top, rect.left), attrs[0])
            if let sel = sel as? CellSelection {
                _ = tr.setSelection(try CellSelection(tr.doc.resolve(sel.anchorCell.pos), lastCell.map { tr.doc.resolve($0) }))
            }
            dispatch(tr)
            return true
        }
    }
}

/// Splits a merged cell into cells of its own type.
public let splitCell: Command = { state, dispatch, view in
    let types = tableNodeTypes(state.schema)
    return splitCellWithType { node, _, _ in node.type.tableRole.flatMap { types[$0] } }(state, dispatch, view)
}

// MARK: Attributes and headers

/// Sets attribute `name` on the selected cells (or the cell around the selection).
public func setCellAttr(_ name: String, _ value: JSONValue) -> Command {
    return { state, dispatch, _ in
        guard isInTable(state) else { return false }
        return CommandErrors.run {
            let cell = try selectionCell(state)
            guard let cellNode = cell.nodeAfter else { return false }
            if cellNode.attrs[name] == value { return false }
            guard let dispatch else { return true }
            let tr = state.tr
            if let sel = state.selection as? CellSelection {
                var positions: [(Node, Int)] = []
                sel.forEachCell { positions.append(($0, $1)) }
                for (node, pos) in positions where node.attrs[name] != value {
                    var attrs = node.attrs
                    attrs[name] = value
                    try tr.setNodeMarkup(pos, nil, attrs)
                }
            } else {
                var attrs = cellNode.attrs
                attrs[name] = value
                try tr.setNodeMarkup(cell.pos, nil, attrs)
            }
            dispatch(tr)
            return true
        }
    }
}

private func deprecatedToggleHeader(_ type: String) -> Command {
    return { state, dispatch, _ in
        guard isInTable(state) else { return false }
        return CommandErrors.run {
            guard let dispatch else { return true }
            let types = tableNodeTypes(state.schema)
            let rect = try selectedRect(state), tr = state.tr
            let cellsRect: TableRect = type == "column"
                ? TableRect(left: rect.left, top: 0, right: rect.right, bottom: rect.map.height)
                : type == "row" ? TableRect(left: 0, top: rect.top, right: rect.map.width, bottom: rect.bottom) : rect.rect
            let cells = rect.map.cellsInRect(cellsRect)
            let nodes = try cells.map { try nodeAt(rect.table, $0) }
            for i in cells.indices where nodes[i].type === types[.headerCell] {
                try tr.setNodeMarkup(rect.tableStart + cells[i], types[.cell], nodes[i].attrs)
            }
            if tr.steps.isEmpty {
                for i in cells.indices { try tr.setNodeMarkup(rect.tableStart + cells[i], types[.headerCell], nodes[i].attrs) }
            }
            dispatch(tr)
            return true
        }
    }
}

private func isHeaderEnabledByType(_ type: String, _ rect: SelectedRect, _ types: [TableRole: NodeType]) -> Bool {
    let cellPositions = rect.map.cellsInRect(TableRect(left: 0, top: 0, right: type == "row" ? rect.map.width : 1,
                                                       bottom: type == "column" ? rect.map.height : 1))
    for pos in cellPositions {
        if let cell = rect.table.nodeAt(pos), cell.type !== types[.headerCell] { return false }
    }
    return true
}

/// Toggles header cells for the selected row(s) (`"row"`), column(s) (`"column"`) or cells
/// (`"cell"`). The exported toggles use the deprecated logic, as Tiptap does.
public func toggleHeader(_ type: String, useDeprecatedLogic: Bool = false) -> Command {
    if useDeprecatedLogic { return deprecatedToggleHeader(type) }
    return { state, dispatch, _ in
        guard isInTable(state) else { return false }
        return CommandErrors.run {
            guard let dispatch else { return true }
            let types = tableNodeTypes(state.schema)
            let rect = try selectedRect(state), tr = state.tr
            let isHeaderRowEnabled = isHeaderEnabledByType("row", rect, types)
            let isHeaderColumnEnabled = isHeaderEnabledByType("column", rect, types)
            let startsAt = (type == "column" ? isHeaderRowEnabled : type == "row" ? isHeaderColumnEnabled : false) ? 1 : 0
            let cellsRect: TableRect = type == "column"
                ? TableRect(left: 0, top: startsAt, right: 1, bottom: rect.map.height)
                : type == "row" ? TableRect(left: startsAt, top: 0, right: rect.map.width, bottom: 1) : rect.rect
            let newType = type == "column" ? (isHeaderColumnEnabled ? types[.cell] : types[.headerCell])
                : type == "row" ? (isHeaderRowEnabled ? types[.cell] : types[.headerCell]) : types[.cell]
            for relative in rect.map.cellsInRect(cellsRect) {
                let cellPos = relative + rect.tableStart
                if let cell = tr.doc.nodeAt(cellPos) { try tr.setNodeMarkup(cellPos, newType, cell.attrs) }
            }
            dispatch(tr)
            return true
        }
    }
}

public let toggleHeaderRow = toggleHeader("row", useDeprecatedLogic: true)
public let toggleHeaderColumn = toggleHeader("column", useDeprecatedLogic: true)
public let toggleHeaderCell = toggleHeader("cell", useDeprecatedLogic: true)

// MARK: Navigation and deletion

private func findNextCell(_ cell: ResolvedPos, _ dir: Int) -> Int? {
    if dir < 0 {
        if let before = cell.nodeBefore { return cell.pos - before.nodeSize }
        var row = cell.index(-1) - 1, rowEnd = cell.before()
        while row >= 0 {
            let rowNode = cell.node(-1).child(row)
            if let lastChild = rowNode.lastChild { return rowEnd - 1 - lastChild.nodeSize }
            rowEnd -= rowNode.nodeSize
            row -= 1
        }
    } else {
        if cell.index() < cell.parent.childCount - 1, let after = cell.nodeAfter { return cell.pos + after.nodeSize }
        let table = cell.node(-1)
        var row = cell.indexAfter(-1), rowStart = cell.after()
        while row < table.childCount {
            let rowNode = table.child(row)
            if rowNode.childCount > 0 { return rowStart + 1 }
            rowStart += rowNode.nodeSize
            row += 1
        }
    }
    return nil
}

/// Selects the content of the next (`1`) or previous (`-1`) cell.
public func goToNextCell(_ direction: Int) -> Command {
    return { state, dispatch, _ in
        guard isInTable(state) else { return false }
        return CommandErrors.run {
            guard let cell = findNextCell(try selectionCell(state), direction) else { return false }
            if let dispatch {
                let resolved = state.doc.resolve(cell)
                dispatch(state.tr.setSelection(TextSelection.between(resolved, moveCellForward(resolved))).scrollIntoView())
            }
            return true
        }
    }
}

/// Deletes the table around the selection.
public let deleteTable: Command = { state, dispatch, _ in
    let pos = state.selection.anchorPos
    var d = pos.depth
    while d > 0 {
        if pos.node(d).tableRole == .table {
            if let dispatch {
                return CommandErrors.run {
                    dispatch(try state.tr.delete(pos.before(d), pos.after(d)).scrollIntoView())
                    return true
                }
            }
            return true
        }
        d -= 1
    }
    return false
}

/// Empties the selected cells (a `CellSelection`).
public let deleteCellSelection: Command = { state, dispatch, _ in
    guard let sel = state.selection as? CellSelection else { return false }
    return CommandErrors.run {
        guard let dispatch else { return true }
        let tr = state.tr
        guard let baseContent = try cellType(state.schema, .cell).createAndFill()?.content else { return true }
        var cells: [(Node, Int)] = []
        sel.forEachCell { cells.append(($0, $1)) }
        for (cell, pos) in cells where !cell.content.eq(baseContent) {
            try tr.replace(tr.mapping.map(pos + 1), tr.mapping.map(pos + cell.nodeSize - 1), Slice(baseContent, 0, 0))
        }
        if tr.docChanged { dispatch(tr) }
        return true
    }
}

// MARK: Column width

/// Sets the width of the column at the right edge of the cell at `cellPos` (the position
/// before it) to `width`, on every cell covering that column, in one transaction. This is
/// prosemirror-tables' `updateColumnWidth`, which the web's column resizing calls on mouse-up.
public func updateColumnWidth(cellPos: Int, width: Double) -> Command {
    return { state, dispatch, _ in
        CommandErrors.run {
            let cell = state.doc.resolve(cellPos)
            let table = cell.node(-1), map = try TableMap.get(table), start = cell.start(-1)
            guard let cellNode = cell.nodeAfter else { return false }
            let col = try map.colCount(cell.pos - start) + attrInt(cellNode, "colspan") - 1
            let tr = state.tr
            for row in 0..<map.height {
                let mapIndex = row * map.width + col
                if row > 0 && map.map[mapIndex] == map.map[mapIndex - map.width] { continue }
                let pos = map.map[mapIndex]
                let node = try nodeAt(table, pos)
                let attrs = node.attrs
                let colspan = attrInt(node, "colspan")
                let index = colspan == 1 ? 0 : try col - map.colCount(pos)
                let current = attrs["colwidth"]?.arrayValue
                if let current, index < current.count, current[index].numberValue == width { continue }
                var colwidth = current ?? [JSONValue](repeating: .number(0), count: colspan)
                while colwidth.count <= index { colwidth.append(.null) }
                colwidth[index] = .number(width)
                var newAttrs = attrs
                newAttrs["colwidth"] = .array(colwidth)
                try tr.setNodeMarkup(start + pos, nil, newAttrs)
            }
            guard tr.docChanged else { return false }
            dispatch?(tr)
            return true
        }
    }
}

/// Clears every column width in the table at `tablePos`, so columns share the width evenly.
public func clearColumnWidths(tablePos: Int) -> Command {
    return { state, dispatch, _ in
        CommandErrors.run {
            guard let table = state.doc.nodeAt(tablePos), table.tableRole == .table else { return false }
            let tr = state.tr
            table.descendants { node, pos, _, _ in
                if node.isCellNode, node.attrs["colwidth"] != nil, node.attrs["colwidth"] != .null {
                    var attrs = node.attrs
                    attrs["colwidth"] = .null
                    _ = try? tr.setNodeMarkup(tablePos + 1 + pos, nil, attrs)
                }
                return !node.isCellNode
            }
            guard tr.docChanged else { return false }
            dispatch?(tr)
            return true
        }
    }
}
