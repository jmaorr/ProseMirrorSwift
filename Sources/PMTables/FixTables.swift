// Port of prosemirror-tables/src/fixtables.ts
// Copyright (C) 2015-2016 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR-TABLES).

import Foundation
import PMModel
import PMTransform
import PMState

/// Meta key set on transactions `fixTables` creates.
public let fixTablesKey = PluginKey("fix-tables")

/// Calls `f` for every node in `cur` that isn't shared with `old`, skipping unchanged subtrees.
private func changedDescendants(_ old: Node, _ cur: Node, _ offset: Int, _ f: (Node, Int) -> Void) {
    var offset = offset
    let oldSize = old.childCount, curSize = cur.childCount
    var j = 0
    outer: for i in 0..<curSize {
        let child = cur.child(i)
        var scan = j
        while scan < min(oldSize, i + 3) {
            if old.child(scan) === child {
                j = scan + 1
                offset += child.nodeSize
                continue outer
            }
            scan += 1
        }
        f(child, offset)
        if j < oldSize && old.child(j).sameMarkup(child) {
            changedDescendants(old.child(j), child, offset + 1, f)
        } else {
            child.nodesBetween(0, child.content.size, startPos: offset + 1) { node, pos, _, _ in f(node, pos); return true }
        }
        offset += child.nodeSize
    }
}

/// A transaction repairing every malformed table (in the parts of the doc that changed since
/// `oldState`), or nil when nothing needs fixing. Run after every transaction so that tables
/// stay rectangular, as the web editor does.
public func fixTables(_ state: EditorState, oldState: EditorState? = nil) -> Transaction? {
    var tr: Transaction?
    let check: (Node, Int) -> Void = { node, pos in
        if node.tableRole == .table { tr = fixTable(state, node, pos, tr) }
    }
    if let oldState {
        if oldState.doc !== state.doc { changedDescendants(oldState.doc, state.doc, 0, check) }
    } else {
        state.doc.descendants { node, pos, _, _ in check(node, pos); return true }
    }
    return tr
}

private func fixTable(_ state: EditorState, _ table: Node, _ tablePos: Int, _ tr: Transaction?) -> Transaction? {
    guard let map = try? TableMap.get(table), let problems = map.problems else { return tr }
    let tr = tr ?? state.tr
    var mustAdd = [Int](repeating: 0, count: map.height)
    func add(_ row: Int, _ n: Int) { if row >= 0 && row < mustAdd.count { mustAdd[row] += n } }
    for prob in problems {
        switch prob {
        case let .collision(row, pos, n):
            guard let cell = table.nodeAt(pos) else { continue }
            let attrs = CellAttrs(cell.attrs)
            for j in 0..<max(0, attrs.rowspan) { add(row + j, n) }
            _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), nil,
                                      removeColSpan(cell.attrs, pos: attrs.colspan - n, n: n))
        case let .missing(row, n):
            add(row, n)
        case let .overlongRowspan(pos, n):
            guard let cell = table.nodeAt(pos) else { continue }
            var attrs = cell.attrs
            attrs["rowspan"] = .number(Double(CellAttrs(cell.attrs).rowspan - n))
            _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), nil, attrs)
        case let .colwidthMismatch(pos, colwidth):
            guard let cell = table.nodeAt(pos) else { continue }
            var attrs = cell.attrs
            attrs["colwidth"] = .array(colwidth.map { $0.isNaN ? .null : .number($0) })
            _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), nil, attrs)
        case .zeroSized:
            let pos = tr.mapping.map(tablePos)
            _ = try? tr.delete(pos, pos + table.nodeSize)
        }
    }
    var first: Int?, last: Int?
    for i in mustAdd.indices where mustAdd[i] != 0 {
        if first == nil { first = i }
        last = i
    }
    let types = tableNodeTypes(state.schema)
    var pos = tablePos + 1
    for i in 0..<map.height {
        let row = table.child(i)
        let end = pos + row.nodeSize
        let add = mustAdd[i]
        if add > 0 {
            let role = row.firstChild?.tableRole ?? .cell
            var nodes: [Node] = []
            for _ in 0..<add {
                if let node = types[role]?.createAndFill() { nodes.append(node) }
            }
            let side = (i == 0 || first == i - 1) && last == i ? pos + 1 : end - 1
            _ = try? tr.insert(tr.mapping.map(side), Fragment.from(nodes))
        }
        pos = end
    }
    return tr.setMeta(fixTablesKey, ["fixTables": true])
}
