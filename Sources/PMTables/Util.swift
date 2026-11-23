// Port of prosemirror-tables/src/util.ts and tableNodeTypes from schema.ts
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel
import PMState

/// The `tableRole` a node type declares in its spec.
public enum TableRole: String {
    case table, row, cell
    case headerCell = "header_cell"
}

extension NodeType {
    /// The node type's `tableRole`, if it has one.
    public var tableRole: TableRole? { spec.extra["tableRole"]?.stringValue.flatMap(TableRole.init) }
}

extension Node {
    var tableRole: TableRole? { type.tableRole }
    var isCellNode: Bool { tableRole == .cell || tableRole == .headerCell }
}

/// The schema's node type for each table role.
public func tableNodeTypes(_ schema: Schema) -> [TableRole: NodeType] {
    var result: [TableRole: NodeType] = [:]
    for (_, type) in schema.nodes {
        if let role = type.tableRole { result[role] = type }
    }
    return result
}

/// The position of the cell around `pos` (before it), or nil when `pos` isn't in a cell.
public func cellAround(_ pos: ResolvedPos) -> ResolvedPos? {
    var d = pos.depth - 1
    while d > 0 {
        if pos.node(d).tableRole == .row { return pos.node(0).resolve(pos.before(d + 1)) }
        d -= 1
    }
    return nil
}

/// The innermost cell node around `pos`.
public func cellWrapping(_ pos: ResolvedPos) -> Node? {
    var d = pos.depth
    while d > 0 {
        if pos.node(d).isCellNode { return pos.node(d) }
        d -= 1
    }
    return nil
}

/// Whether the selection's head is inside a table row.
public func isInTable(_ state: EditorState) -> Bool {
    let head = state.selection.headPos
    var d = head.depth
    while d > 0 {
        if head.node(d).tableRole == .row { return true }
        d -= 1
    }
    return false
}

/// A cell right after or right before `pos`, descending into first/last children.
public func cellNear(_ pos: ResolvedPos) -> ResolvedPos? {
    var after = pos.nodeAfter, p = pos.pos
    while let node = after {
        if node.isCellNode { return pos.doc.resolve(p) }
        after = node.firstChild
        p += 1
    }
    var before = pos.nodeBefore
    p = pos.pos
    while let node = before {
        if node.isCellNode { return pos.doc.resolve(p - node.nodeSize) }
        before = node.lastChild
        p -= 1
    }
    return nil
}

/// Whether `pos` is in a row, directly before a cell.
public func pointsAtCell(_ pos: ResolvedPos) -> Bool {
    pos.parent.tableRole == .row && pos.nodeAfter != nil
}

/// The position after the cell `pos` points at.
public func moveCellForward(_ pos: ResolvedPos) -> ResolvedPos {
    pos.node(0).resolve(pos.pos + pos.nodeAfter!.nodeSize)
}

/// Whether two cell positions are in the same table.
public func inSameTable(_ a: ResolvedPos, _ b: ResolvedPos) -> Bool {
    a.depth == b.depth && a.pos >= b.start(-1) && a.pos <= b.end(-1)
}

/// The rectangle of the cell `pos` points at.
public func findCell(_ pos: ResolvedPos) throws -> TableRect {
    try TableMap.get(pos.node(-1)).findCell(pos.pos - pos.start(-1))
}

/// The left column of the cell `pos` points at.
public func colCount(_ pos: ResolvedPos) throws -> Int {
    try TableMap.get(pos.node(-1)).colCount(pos.pos - pos.start(-1))
}

/// The cell next to the one `pos` points at, or nil at the table's edge.
public func nextCell(_ pos: ResolvedPos, axis: String, dir: Int) throws -> ResolvedPos? {
    let table = pos.node(-1)
    let map = try TableMap.get(table)
    let tableStart = pos.start(-1)
    guard let moved = try map.nextCell(pos.pos - tableStart, axis: axis, dir: dir) else { return nil }
    return pos.node(0).resolve(tableStart + moved)
}

/// `attrs` with `n` columns removed at `pos` from colspan and colwidth.
public func removeColSpan(_ attrs: Attrs, pos: Int, n: Int = 1) -> Attrs {
    var result = attrs
    result["colspan"] = .number(Double(cellSpan(attrs, "colspan") - n))
    if var colwidth = result["colwidth"]?.arrayValue {
        let lo = min(max(pos, 0), colwidth.count), hi = min(lo + n, colwidth.count)
        colwidth.removeSubrange(lo..<hi)
        result["colwidth"] = colwidth.contains(where: { ($0.numberValue ?? 0) > 0 }) ? .array(colwidth) : .null
    }
    return result
}

/// `attrs` with `n` columns added at `pos` to colspan and colwidth (new widths 0).
public func addColSpan(_ attrs: Attrs, pos: Int, n: Int = 1) -> Attrs {
    var result = attrs
    result["colspan"] = .number(Double(cellSpan(attrs, "colspan") + n))
    if var colwidth = result["colwidth"]?.arrayValue {
        let at = min(max(pos, 0), colwidth.count)
        for _ in 0..<n { colwidth.insert(.number(0), at: at) }
        result["colwidth"] = .array(colwidth)
    }
    return result
}

/// Whether every cell in column `col` is a header cell.
public func columnIsHeader(_ map: TableMap, _ table: Node, _ col: Int) -> Bool {
    let headerCell = tableNodeTypes(table.type.schema)[.headerCell]
    for row in 0..<map.height {
        if table.nodeAt(map.map[col + row * map.width])?.type !== headerCell { return false }
    }
    return true
}

/// The innermost table around `pos`: the node, its position, start and depth.
public func findTable(_ pos: ResolvedPos) -> (node: Node, pos: Int, start: Int, depth: Int)? {
    var depth = pos.depth
    while depth >= 0 {
        let node = pos.node(depth)
        if node.tableRole == .table {
            return (node, depth > 0 ? pos.before(depth) : 0, pos.start(depth), depth)
        }
        depth -= 1
    }
    return nil
}

/// A cell found from the hit position `pos`: around it or next to it.
public func findCellPos(_ doc: Node, _ pos: Int) -> ResolvedPos? {
    let resolved = doc.resolve(pos)
    return cellAround(resolved) ?? cellNear(resolved)
}
