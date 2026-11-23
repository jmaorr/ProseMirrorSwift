// prosemirror-tables parity: a seeded corpus of tables (well-formed and
// malformed, the way documents from other editors arrive) and probes of
// TableMap and the table commands. Swift replays the same inputs.
import {Node, Slice} from "prosemirror-model"
import {EditorState, NodeSelection, TextSelection, Selection} from "prosemirror-state"
import {CellSelection, TableMap, cellAround, cellNear, nextCell, colCount, findCell, columnIsHeader, removeColSpan, addColSpan,
        fixTables, tableEditing, addColumnBefore, addColumnAfter, deleteColumn, addRowBefore, addRowAfter, deleteRow,
        mergeCells, splitCell, setCellAttr, toggleHeaderRow, toggleHeaderColumn, toggleHeaderCell, toggleHeader,
        goToNextCell, deleteTable, deleteCellSelection, moveTableRow, moveTableColumn, handlePaste} from "prosemirror-tables"

import {rng} from "./random.js"
import {HeadlessView, keyEvent} from "./scenarios.js"

const WORDS = ["apple", "pear", "fig", "plum", "kiwi", "lime", "date", "Q3", "total", "notes"]

function para(r) {
  if (r.chance(0.15)) return {type: "paragraph"}
  let text = r.pick(WORDS) + (r.chance(0.4) ? " " + r.pick(WORDS) : "")
  return {type: "paragraph", content: [{type: "text", text}]}
}

function cellContent(r) {
  let roll = r.next()
  if (roll < 0.05) return [{type: "heading", attrs: {level: 3}, content: [{type: "text", text: r.pick(WORDS)}]}]
  if (roll < 0.1) return [{type: "bulletList", content: [{type: "listItem", content: [para(r)]}, {type: "listItem", content: [para(r)]}]}]
  if (roll < 0.15) return [para(r), para(r)]
  return [para(r)]
}

function colwidthFor(r, colspan) {
  if (r.chance(0.6)) return null
  let out = []
  for (let i = 0; i < colspan; i++) out.push(r.chance(0.2) ? 0 : 40 + 10 * r.int(20))
  return out
}

// A well-formed table: a grid of slots, each cell claiming a free rectangle.
function wellFormed(r) {
  let height = 1 + r.int(5), width = 1 + r.int(5)
  let taken = [], rows = []
  for (let i = 0; i < height * width; i++) taken.push(false)
  let headerRow = r.chance(0.4), headerCol = r.chance(0.2)
  for (let row = 0; row < height; row++) {
    let cells = []
    for (let col = 0; col < width; col++) {
      if (taken[row * width + col]) continue
      let colspan = 1, rowspan = 1
      if (r.chance(0.15)) {
        let maxW = 0
        while (col + maxW < width && !taken[row * width + col + maxW]) maxW++
        colspan = 1 + r.int(Math.min(maxW, 3))
      }
      if (r.chance(0.15)) rowspan = 1 + r.int(Math.min(height - row, 3))
      for (let h = 0; h < rowspan; h++) for (let w = 0; w < colspan; w++) taken[(row + h) * width + col + w] = true
      let header = (headerRow && row == 0) || (headerCol && col == 0)
      cells.push({type: header ? "tableHeader" : "tableCell",
                  attrs: {colspan, rowspan, colwidth: colwidthFor(r, colspan)}, content: cellContent(r)})
    }
    rows.push({type: "tableRow", content: cells})
  }
  return rows
}

// Damage a table the ways real documents get damaged.
function malform(r, rows) {
  let kind = r.int(6)
  let anyCell = () => {
    let withCells = rows.filter(row => row.content.length)
    if (!withCells.length) return null
    let row = r.pick(withCells)
    return r.pick(row.content)
  }
  if (kind == 0) rows.splice(r.int(rows.length + 1), 0, {type: "tableRow", content: []})
  else if (kind == 1) { let c = anyCell(); if (c) c.attrs.rowspan = rows.length + 1 + r.int(2) }
  else if (kind == 2) { let c = anyCell(); if (c) c.attrs.colspan += 1 + r.int(2) }
  else if (kind == 3) { let row = r.pick(rows); if (row.content.length) row.content.splice(r.int(row.content.length), 1) }
  else if (kind == 4) { let c = anyCell(); if (c) c.attrs.colwidth = [100, 200, 300].slice(0, 1 + r.int(3)) }
  else { let c = anyCell(); if (c) c.attrs.colwidth = Array(c.attrs.colspan).fill(0) }
  return rows
}

function tableJSON(r) {
  let rows = wellFormed(r)
  if (r.chance(0.3)) rows = malform(r, rows)
  if (!rows.length) rows.push({type: "tableRow", content: []})
  return {type: "table", content: rows}
}

export function tableDoc(seed) {
  let r = rng(seed)
  let content = [para(r), tableJSON(r)]
  if (r.chance(0.3)) content.push(para(r), tableJSON(r))
  if (r.chance(0.5)) content.push(para(r))
  return {type: "doc", content}
}

function tables(doc) {
  let out = []
  doc.descendants((node, pos) => {
    if (node.type.spec.tableRole == "table") out.push({node, pos})
  })
  return out
}

function mapJSON(map) {
  return {width: map.width, height: map.height, map: map.map, problems: map.problems || null}
}

// Swift can't call TableMap.get without the cache, so compute fresh: same function.
function freshMap(node) { return TableMap.get(node) }

// normalizeSelection isn't exported; the plugin's appendTransaction runs it (fixTables is a
// no-op when the doc didn't change). Returns the normalized selection.
const editingPlugin = tableEditing()
function normalized(doc, selection) {
  let state = EditorState.create({doc, selection})
  let tr = editingPlugin.spec.appendTransaction([], state, state)
  return (tr || state).selection
}

function catching(f) {
  try { return {ok: f()} } catch (e) { return {error: String(e.message)} }
}

export const tableHandlers = schemaFor => ({
  tableCorpus({seed, count}) {
    let out = []
    for (let i = 0; i < count; i++) out.push(tableDoc(seed + i))
    return out
  },

  tableMap({schema, doc}) {
    let d = Node.fromJSON(schemaFor(schema), doc)
    return tables(d).map(({node, pos}) => ({pos, ...mapJSON(freshMap(node))}))
  },

  tableMapQueries({schema, doc, seed}) {
    let d = Node.fromJSON(schemaFor(schema), doc), r = rng(seed)
    return tables(d).map(({node, pos}) => {
      let map = freshMap(node), cells = [...new Set(map.map)].filter(p => p != 0)
      return {
        pos,
        cells: cells.map(cell => {
          let other = cells.length ? r.pick(cells) : cell
          let rect = catching(() => map.rectBetween(cell, other))
          return {
            cell, other,
            findCell: catching(() => map.findCell(cell)),
            colCount: catching(() => map.colCount(cell)),
            next: [["horiz", -1], ["horiz", 1], ["vert", -1], ["vert", 1]].map(([axis, dir]) =>
              catching(() => map.nextCell(cell, axis, dir))),
            rectBetween: rect,
            cellsInRect: rect.ok ? catching(() => map.cellsInRect(rect.ok)) : null,
          }
        }),
        positionAt: Array.from({length: map.height}, (_, row) =>
          Array.from({length: map.width}, (_, col) => catching(() => map.positionAt(row, col, node)))),
      }
    })
  },

  // Resolved-position helpers at every position, and colspan helpers on every cell.
  tableUtilCases({schema, doc, seed}) {
    let d = Node.fromJSON(schemaFor(schema), doc), r = rng(seed)
    let positions = []
    for (let pos = 0; pos <= d.content.size; pos++) {
      let $pos = d.resolve(pos), $cell = cellAround($pos), $near = cellNear($pos)
      let entry = {pos, cellAround: $cell ? $cell.pos : null, cellNear: $near ? $near.pos : null}
      if ($cell) {
        entry.findCell = catching(() => findCell($cell))
        entry.colCount = catching(() => colCount($cell))
        entry.next = [["horiz", -1], ["horiz", 1], ["vert", -1], ["vert", 1]].map(([axis, dir]) =>
          catching(() => { let n = nextCell($cell, axis, dir); return n ? n.pos : null }))
        let attrs = $cell.nodeAfter.attrs, at = r.int(attrs.colspan + 1), n = 1 + r.int(2)
        entry.colspan = {at, n, remove: removeColSpan(attrs, at, n), add: addColSpan(attrs, at, n)}
      }
      positions.push(entry)
    }
    let headers = tables(d).map(({node}) => {
      let map = TableMap.get(node)
      return Array.from({length: map.width}, (_, col) => catching(() => columnIsHeader(map, node, col)))
    })
    return {positions, headers}
  },

  // Random cell selections: ranges, content, row/column checks and widening, mapping
  // through a random edit.
  cellSelectionCases({schema, doc, seed}) {
    let d = Node.fromJSON(schemaFor(schema), doc), r = rng(seed), out = []
    for (let {node, pos} of tables(d)) {
      let map = TableMap.get(node), cells = [...new Set(map.map)].filter(p => p != 0)
      if (!cells.length) continue
      for (let k = 0; k < 6; k++) {
        let anchor = pos + 1 + r.pick(cells), head = pos + 1 + r.pick(cells)
        let size = d.content.size, a = r.int(size + 1), b = r.int(size + 1)
        let edit = {from: Math.min(a, b), to: Math.max(a, b), text: r.chance(0.5) ? "zz" : ""}
        let entry = {anchor, head, edit}
        Object.assign(entry, catching(() => {
          let sel = CellSelection.create(d, anchor, head)
          let res = {
            ranges: sel.ranges.map(rg => [rg.$from.pos, rg.$to.pos]),
            content: sel.content().toJSON(),
            isRow: sel.isRowSelection(), isCol: sel.isColSelection(),
            rowSel: catching(() => CellSelection.rowSelection(d.resolve(anchor), d.resolve(head)).toJSON()),
            colSel: catching(() => CellSelection.colSelection(d.resolve(anchor), d.resolve(head)).toJSON()),
          }
          res.mapped = catching(() => {
            let state = EditorState.create({doc: d, selection: sel})
            let tr = state.tr
            if (edit.text) tr.insertText(edit.text, edit.from, edit.to)
            else tr.delete(edit.from, edit.to)
            return sel.map(tr.doc, tr.mapping).toJSON()
          })
          return res
        }))
        out.push(entry)
      }
    }
    return out
  },

  // normalizeSelection on node selections of cells/rows/tables and random text selections.
  normalizeCases({schema, doc, seed}) {
    let d = Node.fromJSON(schemaFor(schema), doc), r = rng(seed), out = []
    d.descendants((node, pos) => {
      if (node.type.spec.tableRole)
        out.push({kind: "node", pos, result: catching(() => normalized(d, NodeSelection.create(d, pos)).toJSON())})
    })
    for (let k = 0; k < 30; k++) {
      let size = d.content.size, a = r.int(size + 1), b = r.int(size + 1)
      out.push({kind: "text", anchor: a, head: b, result: catching(() => {
        let sel = TextSelection.between(d.resolve(a), d.resolve(b))
        return [sel.toJSON(), normalized(d, sel).toJSON()]
      })})
    }
    return out
  },

  // fixTables over the whole doc: the fixed doc (or null when nothing to fix).
  fixTables({schema, doc}) {
    let d = Node.fromJSON(schemaFor(schema), doc)
    let tr = fixTables(EditorState.create({doc: d}))
    return tr ? tr.doc.toJSON() : null
  },

  // Every table command from carets in every cell and from random cell rectangles.
  tableCommandCases({schema, doc, seed, commands}) {
    let d = Node.fromJSON(schemaFor(schema), doc), r = rng(seed), out = []
    let selections = []
    for (let {node, pos} of tables(d)) {
      let map = TableMap.get(node), cells = [...new Set(map.map)].filter(p => p != 0)
      for (let c of cells) selections.push(Selection.near(d.resolve(pos + 1 + c + 1)).toJSON())
      for (let k = 0; k < 3 && cells.length; k++)
        selections.push({type: "cell", anchor: pos + 1 + r.pick(cells), head: pos + 1 + r.pick(cells)})
    }
    for (let selJSON of selections) for (let name of commands) {
      out.push({selection: selJSON, command: name, result: catching(() => {
        let state = EditorState.create({doc: d, selection: Selection.fromJSON(d, selJSON)})
        let tr = null
        let applied = tableCommand(name)(state, t => { tr = t })
        return {applied, doc: tr ? tr.doc.toJSON() : null, selection: tr ? tr.selection.toJSON() : null}
      })})
    }
    return out
  },

  // The tableEditing plugin's keys from carets at the start, middle and end of every cell,
  // and from cell selections. The view's endOfTextblock is the headless one.
  tableKeyCases({schema, doc, seed}) {
    let d = Node.fromJSON(schemaFor(schema), doc), r = rng(seed), out = []
    let plugin = tableEditing()
    let selections = []
    for (let {node, pos} of tables(d)) {
      let map = TableMap.get(node), cells = [...new Set(map.map)].filter(p => p != 0)
      for (let c of cells) {
        let cellStart = pos + 1 + c, cell = d.nodeAt(cellStart)
        let first = Selection.near(d.resolve(cellStart + 1)), last = Selection.near(d.resolve(cellStart + cell.nodeSize - 1), -1)
        selections.push(first.toJSON(), last.toJSON())
        if (first.head + 1 < last.head) selections.push(TextSelection.create(d, first.head + 1).toJSON())
      }
      for (let k = 0; k < 3 && cells.length; k++)
        selections.push({type: "cell", anchor: pos + 1 + r.pick(cells), head: pos + 1 + r.pick(cells)})
    }
    for (let selJSON of selections) for (let key of KEYS) {
      out.push({selection: selJSON, key, result: catching(() => {
        let view = new HeadlessView(EditorState.create({doc: d, selection: Selection.fromJSON(d, selJSON), plugins: [plugin]}))
        let handled = !!plugin.props.handleKeyDown(view, keyEvent(key))
        return {handled, doc: view.state.doc.toJSON(), selection: view.state.selection.toJSON()}
      })})
    }
    return out
  },

  // Paste copied cell rectangles (and a plain text slice) at carets and onto cell selections.
  tablePasteCases({schema, doc, seed}) {
    let d = Node.fromJSON(schemaFor(schema), doc), r = rng(seed), out = []
    let all = tables(d)
    if (!all.length) return out
    let pick = () => {
      let {node, pos} = r.pick(all), map = TableMap.get(node), cells = [...new Set(map.map)].filter(p => p != 0)
      return cells.length ? {a: pos + 1 + r.pick(cells), b: pos + 1 + r.pick(cells)} : null
    }
    let slices = []
    for (let k = 0; k < 4; k++) {
      let p = pick()
      if (p) slices.push(CellSelection.create(d, p.a, p.b).content().toJSON())
    }
    let para = d.firstChild
    slices.push(d.slice(1, 1 + para.content.size).toJSON())
    for (let sliceJSON of slices) for (let k = 0; k < 4; k++) {
      let p = pick()
      if (!p) continue
      let selJSON = k % 2 ? {type: "cell", anchor: p.a, head: p.b} : Selection.near(d.resolve(p.a + 1)).toJSON()
      out.push({slice: sliceJSON, selection: selJSON, result: catching(() => {
        let state = EditorState.create({doc: d, selection: Selection.fromJSON(d, selJSON)})
        let tr = null
        let handled = handlePaste({state, dispatch: t => { tr = t }}, null, Slice.fromJSON(state.schema, sliceJSON))
        return {handled, doc: tr ? tr.doc.toJSON() : null, selection: tr ? tr.selection.toJSON() : null}
      })})
    }
    return out
  },
})

const KEYS = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Shift-ArrowLeft", "Shift-ArrowRight",
              "Shift-ArrowUp", "Shift-ArrowDown", "Backspace", "Delete", "Mod-Backspace"]

function moveCommand(name) {
  let m = /^(moveTableRow|moveTableColumn)\((-?\d+),(-?\d+)\)$/.exec(name)
  if (!m) return null
  return (m[1] == "moveTableRow" ? moveTableRow : moveTableColumn)({from: +m[2], to: +m[3]})
}

function updateColumnWidthCommand(width) {
  return (state, dispatch) => {
    let $cell = cellAround(state.selection.$head) || cellNear(state.selection.$head)
    if (!$cell) return false
    let view = {state, dispatch}
    let before = state
    // updateColumnWidth isn't exported; the same logic (columnresizing.ts) inline.
    const table = $cell.node(-1), map = TableMap.get(table), start = $cell.start(-1)
    const col = map.colCount($cell.pos - start) + $cell.nodeAfter.attrs.colspan - 1
    const tr = state.tr
    for (let row = 0; row < map.height; row++) {
      const mapIndex = row * map.width + col
      if (row && map.map[mapIndex] == map.map[mapIndex - map.width]) continue
      const pos = map.map[mapIndex]
      const attrs = table.nodeAt(pos).attrs
      const index = attrs.colspan == 1 ? 0 : col - map.colCount(pos)
      if (attrs.colwidth && attrs.colwidth[index] == width) continue
      const colwidth = attrs.colwidth ? attrs.colwidth.slice() : Array(attrs.colspan).fill(0)
      colwidth[index] = width
      tr.setNodeMarkup(start + pos, null, {...attrs, colwidth})
    }
    if (!tr.docChanged) return false
    if (dispatch) dispatch(tr)
    return true
  }
}

function tableCommand(name) {
  switch (name) {
    case "addColumnBefore": return addColumnBefore
    case "addColumnAfter": return addColumnAfter
    case "deleteColumn": return deleteColumn
    case "addRowBefore": return addRowBefore
    case "addRowAfter": return addRowAfter
    case "deleteRow": return deleteRow
    case "mergeCells": return mergeCells
    case "splitCell": return splitCell
    case "setCellAttr": return setCellAttr("colwidth", [77])
    case "toggleHeaderRow": return toggleHeaderRow
    case "toggleHeaderColumn": return toggleHeaderColumn
    case "toggleHeaderCell": return toggleHeaderCell
    case "toggleHeader(row)": return toggleHeader("row")
    case "toggleHeader(column)": return toggleHeader("column")
    case "toggleHeader(cell)": return toggleHeader("cell")
    case "goToNextCell(1)": return goToNextCell(1)
    case "goToNextCell(-1)": return goToNextCell(-1)
    case "deleteTable": return deleteTable
    case "deleteCellSelection": return deleteCellSelection
    case "updateColumnWidth": return updateColumnWidthCommand(133)
  }
  let move = moveCommand(name)
  if (move) return move
  throw new Error("unknown command " + name)
}
