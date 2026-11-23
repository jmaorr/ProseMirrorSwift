// Port of prosemirror-tables/src/cellselection.ts (without drawCellSelection, a DOM decoration)
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel
import PMTransform
import PMState

/// A selection of a rectangle of cells. Its ranges are the cells' contents, head cell first.
open class CellSelection: Selection {
    /// The position before the anchor cell.
    public let anchorCell: ResolvedPos
    /// The position before the head cell.
    public let headCell: ResolvedPos

    public init(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos? = nil) throws {
        let headCell = headCell ?? anchorCell
        let table = anchorCell.node(-1)
        let map = try TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let rect = try map.rectBetween(anchorCell.pos - tableStart, headCell.pos - tableStart)
        let doc = anchorCell.node(0)
        var cells = map.cellsInRect(rect).filter { $0 != headCell.pos - tableStart }
        cells.insert(headCell.pos - tableStart, at: 0)
        let ranges = try cells.map { pos -> SelectionRange in
            guard let cell = table.nodeAt(pos) else { throw PMError.range("No cell with offset \(pos) found") }
            let from = tableStart + pos + 1
            return SelectionRange(doc.resolve(from), doc.resolve(from + cell.content.size))
        }
        self.anchorCell = anchorCell
        self.headCell = headCell
        super.init(ranges[0].from, ranges[0].to, ranges: ranges)
    }

    open override var visible: Bool { false }

    open override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let anchor = doc.resolve(mapping.map(anchorCell.pos)), head = doc.resolve(mapping.map(headCell.pos))
        if pointsAtCell(anchor) && pointsAtCell(head) && inSameTable(anchor, head) {
            let tableChanged = anchorCell.node(-1) !== anchor.node(-1)
            // Where JS throws (a damaged table), fall back to a text selection.
            let sel: CellSelection?
            if tableChanged && isRowSelection() { sel = try? CellSelection.rowSelection(anchor, head) }
            else if tableChanged && isColSelection() { sel = try? CellSelection.colSelection(anchor, head) }
            else { sel = try? CellSelection(anchor, head) }
            if let sel { return sel }
        }
        return TextSelection.between(anchor, head)
    }

    /// The selected cells as a slice of rows (or the whole table when every cell is selected).
    /// Cells cut by the rectangle's edges are trimmed to it.
    open override func content() -> Slice {
        (try? contentThrowing()) ?? .empty
    }

    private func contentThrowing() throws -> Slice {
        let table = anchorCell.node(-1)
        let map = try TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let rect = try map.rectBetween(anchorCell.pos - tableStart, headCell.pos - tableStart)
        var seen = Set<Int>()
        var rows: [Node] = []
        for row in rect.top..<rect.bottom {
            var rowContent: [Node] = []
            var index = row * map.width + rect.left
            for _ in rect.left..<rect.right {
                defer { index += 1 }
                let pos = map.map[index]
                if seen.contains(pos) { continue }
                seen.insert(pos)
                let cellRect = try map.findCell(pos)
                guard var cell = table.nodeAt(pos) else { throw PMError.range("No cell with offset \(pos) found") }
                let extraLeft = rect.left - cellRect.left
                let extraRight = cellRect.right - rect.right
                if extraLeft > 0 || extraRight > 0 {
                    var attrs = cell.attrs
                    if extraLeft > 0 { attrs = removeColSpan(attrs, pos: 0, n: extraLeft) }
                    if extraRight > 0 {
                        attrs = removeColSpan(attrs, pos: cellSpan(attrs, "colspan") - extraRight, n: extraRight)
                    }
                    if cellRect.left < rect.left {
                        guard let filled = cell.type.createAndFill(attrs) else {
                            throw PMError.range("Could not create cell with attrs \(attrs)")
                        }
                        cell = filled
                    } else {
                        cell = try cell.type.create(attrs, cell.content)
                    }
                }
                if cellRect.top < rect.top || cellRect.bottom > rect.bottom {
                    var attrs = cell.attrs
                    attrs["rowspan"] = .number(Double(min(cellRect.bottom, rect.bottom) - max(cellRect.top, rect.top)))
                    if cellRect.top < rect.top {
                        guard let filled = cell.type.createAndFill(attrs) else {
                            throw PMError.range("Could not create cell with attrs \(attrs)")
                        }
                        cell = filled
                    } else {
                        cell = try cell.type.create(attrs, cell.content)
                    }
                }
                rowContent.append(cell)
            }
            rows.append(table.child(row).copy(Fragment.from(rowContent)))
        }
        let fragment = isColSelection() && isRowSelection() ? Fragment.from(table) : Fragment.from(rows)
        return Slice(fragment, 1, 1)
    }

    open override func replace(_ tr: Transaction, _ content: Slice = .empty) throws {
        let mapFrom = tr.steps.count
        for (i, range) in ranges.enumerated() {
            let mapping = tr.mapping.slice(mapFrom)
            try tr.replace(mapping.map(range.from.pos), mapping.map(range.to.pos), i > 0 ? .empty : content)
        }
        if let sel = Selection.findFrom(tr.doc.resolve(tr.mapping.slice(mapFrom).map(to)), -1) {
            _ = tr.setSelection(sel)
        }
    }

    open override func replaceWith(_ tr: Transaction, _ node: Node) throws {
        try replace(tr, Slice(Fragment.from(node), 0, 0))
    }

    /// Calls `f` with each selected cell and the position before it.
    public func forEachCell(_ f: (Node, Int) -> Void) {
        guard let map = try? TableMap.get(anchorCell.node(-1)),
              let rect = try? map.rectBetween(anchorCell.pos - anchorCell.start(-1), headCell.pos - anchorCell.start(-1))
        else { return }
        let table = anchorCell.node(-1), tableStart = anchorCell.start(-1)
        for cell in map.cellsInRect(rect) {
            if let node = table.nodeAt(cell) { f(node, tableStart + cell) }
        }
    }

    /// Whether the selection covers whole columns, top to bottom.
    public func isColSelection() -> Bool {
        let anchorTop = anchorCell.index(-1)
        let headTop = headCell.index(-1)
        if min(anchorTop, headTop) > 0 { return false }
        let anchorBottom = anchorTop + (anchorCell.nodeAfter.map { cellSpan($0.attrs, "rowspan") } ?? 1)
        let headBottom = headTop + (headCell.nodeAfter.map { cellSpan($0.attrs, "rowspan") } ?? 1)
        return max(anchorBottom, headBottom) == headCell.node(-1).childCount
    }

    /// Whether the selection covers whole rows, left to right.
    public func isRowSelection() -> Bool {
        let table = anchorCell.node(-1)
        guard let map = try? TableMap.get(table) else { return false }
        let tableStart = anchorCell.start(-1)
        guard let anchorLeft = try? map.colCount(anchorCell.pos - tableStart),
              let headLeft = try? map.colCount(headCell.pos - tableStart) else { return false }
        if min(anchorLeft, headLeft) > 0 { return false }
        let anchorRight = anchorLeft + (anchorCell.nodeAfter.map { cellSpan($0.attrs, "colspan") } ?? 1)
        let headRight = headLeft + (headCell.nodeAfter.map { cellSpan($0.attrs, "colspan") } ?? 1)
        return max(anchorRight, headRight) == map.width
    }

    /// The whole columns spanning `anchorCell` to `headCell`.
    public static func colSelection(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos? = nil) throws -> CellSelection {
        var anchorCell = anchorCell, headCell = headCell ?? anchorCell
        let table = anchorCell.node(-1)
        let map = try TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let anchorRect = try map.findCell(anchorCell.pos - tableStart)
        let headRect = try map.findCell(headCell.pos - tableStart)
        let doc = anchorCell.node(0)
        if anchorRect.top <= headRect.top {
            if anchorRect.top > 0 { anchorCell = doc.resolve(tableStart + map.map[anchorRect.left]) }
            if headRect.bottom < map.height {
                headCell = doc.resolve(tableStart + map.map[map.width * (map.height - 1) + headRect.right - 1])
            }
        } else {
            if headRect.top > 0 { headCell = doc.resolve(tableStart + map.map[headRect.left]) }
            if anchorRect.bottom < map.height {
                anchorCell = doc.resolve(tableStart + map.map[map.width * (map.height - 1) + anchorRect.right - 1])
            }
        }
        return try CellSelection(anchorCell, headCell)
    }

    /// The whole rows spanning `anchorCell` to `headCell`.
    public static func rowSelection(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos? = nil) throws -> CellSelection {
        var anchorCell = anchorCell, headCell = headCell ?? anchorCell
        let table = anchorCell.node(-1)
        let map = try TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let anchorRect = try map.findCell(anchorCell.pos - tableStart)
        let headRect = try map.findCell(headCell.pos - tableStart)
        let doc = anchorCell.node(0)
        if anchorRect.left <= headRect.left {
            if anchorRect.left > 0 { anchorCell = doc.resolve(tableStart + map.map[anchorRect.top * map.width]) }
            if headRect.right < map.width { headCell = doc.resolve(tableStart + map.map[map.width * (headRect.top + 1) - 1]) }
        } else {
            if headRect.left > 0 { headCell = doc.resolve(tableStart + map.map[headRect.top * map.width]) }
            if anchorRect.right < map.width {
                anchorCell = doc.resolve(tableStart + map.map[map.width * (anchorRect.top + 1) - 1])
            }
        }
        return try CellSelection(anchorCell, headCell)
    }

    open override func eq(_ other: Selection) -> Bool {
        guard let other = other as? CellSelection else { return false }
        return other.anchorCell.pos == anchorCell.pos && other.headCell.pos == headCell.pos
    }

    open override func toJSON() -> JSONValue {
        .object(JSONObject([("type", "cell"), ("anchor", .number(Double(anchorCell.pos))),
                            ("head", .number(Double(headCell.pos)))]))
    }

    public static func create(_ doc: Node, _ anchorCell: Int, _ headCell: Int? = nil) throws -> CellSelection {
        try CellSelection(doc.resolve(anchorCell), doc.resolve(headCell ?? anchorCell))
    }

    open override func getBookmark() -> SelectionBookmark { CellBookmark(anchor: anchorCell.pos, head: headCell.pos) }
}

public struct CellBookmark: SelectionBookmark {
    public let anchor: Int
    public let head: Int

    public func map(_ mapping: Mappable) -> SelectionBookmark {
        CellBookmark(anchor: mapping.map(anchor), head: mapping.map(head))
    }

    public func resolve(_ doc: Node) -> Selection {
        let anchorCell = doc.resolve(anchor), headCell = doc.resolve(head)
        if anchorCell.parent.tableRole == .row && headCell.parent.tableRole == .row &&
            anchorCell.index() < anchorCell.parent.childCount && headCell.index() < headCell.parent.childCount &&
            inSameTable(anchorCell, headCell), let sel = try? CellSelection(anchorCell, headCell) {
            return sel
        }
        return Selection.near(headCell, 1)
    }
}

private let registration: Void = {
    try? Selection.jsonID("cell") { doc, json in
        let anchor = try doc.resolveChecked(json["anchor"]?.intValue ?? 0)
        let head = try doc.resolveChecked(json["head"]?.intValue ?? 0)
        // Untrusted JSON: both ends must point at cells of one table, or the init would trap.
        guard pointsAtCell(anchor), pointsAtCell(head), inSameTable(anchor, head) else {
            throw PMError.range("Invalid input for CellSelection.fromJSON")
        }
        return try CellSelection(anchor, head)
    }
}()

/// Registers `CellSelection` for `Selection.fromJSON` (JSON type "cell"). Safe to call repeatedly.
public func registerCellSelection() { _ = registration }

/// The cell the selection's head is in or next to.
public func selectionCell(_ state: EditorState) throws -> ResolvedPos {
    let sel = state.selection
    if let sel = sel as? CellSelection { return sel.anchorCell.pos > sel.headCell.pos ? sel.anchorCell : sel.headCell }
    if let sel = sel as? NodeSelection, sel.node.tableRole == .cell { return sel.anchorPos }
    if let cell = cellAround(sel.headPos) ?? cellNear(sel.headPos) { return cell }
    throw PMError.range("No cell found around position \(sel.head)")
}

/// The selected rectangle (or the cell around the selection) and its table.
public struct SelectedRect {
    public var rect: TableRect
    public var map: TableMap
    public let tableStart: Int
    public var table: Node

    public init(rect: TableRect, map: TableMap, tableStart: Int, table: Node) {
        self.rect = rect
        self.map = map
        self.tableStart = tableStart
        self.table = table
    }

    public var left: Int { rect.left }
    public var top: Int { rect.top }
    public var right: Int { rect.right }
    public var bottom: Int { rect.bottom }
}

public func selectedRect(_ state: EditorState) throws -> SelectedRect {
    let sel = state.selection
    let pos = try selectionCell(state)
    let table = pos.node(-1)
    let tableStart = pos.start(-1)
    let map = try TableMap.get(table)
    let rect = try (sel as? CellSelection).map {
        try map.rectBetween($0.anchorCell.pos - tableStart, $0.headCell.pos - tableStart)
    } ?? map.findCell(pos.pos - tableStart)
    return SelectedRect(rect: rect, map: map, tableStart: tableStart, table: table)
}

// MARK: Normalizing

private func isCellBoundarySelection(_ sel: Selection) -> Bool {
    let from = sel.fromPos, to = sel.toPos
    if from.pos == to.pos || from.pos < to.pos - 6 { return false }
    var afterFrom = from.pos
    var beforeTo = to.pos
    var depth = from.depth
    while depth >= 0 {
        if from.after(depth + 1) < from.end(depth) { break }
        depth -= 1
        afterFrom += 1
    }
    var d = to.depth
    while d >= 0 {
        if to.before(d + 1) > to.start(d) { break }
        d -= 1
        beforeTo -= 1
    }
    // At -1 JS reads node(-1), which is relative to the position's own depth.
    guard afterFrom == beforeTo, depth >= 0 || from.depth > 0 else { return false }
    let role = from.node(depth).tableRole
    return role == .row || role == .table
}

private func isTextSelectionAcrossCells(_ sel: Selection) -> Bool {
    let from = sel.fromPos, to = sel.toPos
    var fromCell: Node?, toCell: Node?
    for i in stride(from: from.depth, to: 0, by: -1) where from.node(i).isCellNode {
        fromCell = from.node(i)
        break
    }
    for i in stride(from: to.depth, to: 0, by: -1) where to.node(i).isCellNode {
        toCell = to.node(i)
        break
    }
    return fromCell !== toCell && to.parentOffset == 0
}

/// Turns node selections of cells, rows and (unless allowed) tables into cell selections, and
/// fixes text selections that only cross cell boundaries. Returns `tr` (or a new transaction)
/// with the fixed selection, or `tr` unchanged.
public func normalizeSelection(_ state: EditorState, _ tr: Transaction?, allowTableNodeSelection: Bool) -> Transaction? {
    let sel = tr?.selection ?? state.selection
    let doc = tr?.doc ?? state.doc
    var normalize: Selection?
    if let sel = sel as? NodeSelection, let role = sel.node.tableRole {
        if role == .cell || role == .headerCell {
            normalize = try? CellSelection.create(doc, sel.from)
        } else if role == .row {
            let cell = doc.resolve(sel.from + 1)
            normalize = try? CellSelection.rowSelection(cell, cell)
        } else if !allowTableNodeSelection, let map = try? TableMap.get(sel.node) {
            let start = sel.from + 1
            let lastCell = start + map.map[map.width * map.height - 1]
            normalize = try? CellSelection.create(doc, start + 1, lastCell)
        }
    } else if sel is TextSelection && isCellBoundarySelection(sel) {
        normalize = TextSelection.create(doc, sel.from)
    } else if sel is TextSelection && isTextSelectionAcrossCells(sel) {
        normalize = TextSelection.create(doc, sel.fromPos.start(), sel.fromPos.end())
    }
    guard let normalize else { return tr }
    let out = tr ?? state.tr
    _ = out.setSelection(normalize)
    return out
}
