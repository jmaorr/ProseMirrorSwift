// Transform parity fuzzer. JS picks random operations against an evolving doc,
// executes them, and records concrete inputs plus results; Swift replays the
// recorded inputs and must produce identical results.
import {Slice, Fragment, Mark, MarkType} from "prosemirror-model"
import {Transform, Step, StepMap, Mapping, liftTarget, findWrapping, canSplit, canJoin, joinPoint,
        insertPoint, dropPoint, replaceStep} from "prosemirror-transform"
import {rng, randomDoc} from "./random.js"

const OPS = ["replace", "replaceForeign", "replaceRange", "replaceRangeWith", "deleteRange", "delete",
             "insertText", "addMark", "removeMark", "setBlockType", "setNodeMarkup", "lift", "wrap",
             "split", "join", "setNodeAttribute", "nodeMark", "replaceRangeForeign"]

function pos2(r, doc) {
  let a = r.int(doc.content.size + 1), b = r.int(doc.content.size + 1)
  return [Math.min(a, b), Math.max(a, b)]
}

// Positions biased towards text positions/block boundaries are more interesting
// than uniform ones, but uniform is fine at this volume.
function randomMark(r, schema) {
  let names = Object.keys(schema.marks), type = schema.marks[r.pick(names)]
  let attrs = {}
  for (let a in type.spec.attrs || {}) {
    let spec = type.spec.attrs[a]
    attrs[a] = Object.prototype.hasOwnProperty.call(spec, "default") && r.chance(0.5) ? spec.default : a + r.int(3)
  }
  try { return type.create(attrs) } catch (e) { return type.create() }
}

function attrsFor(r, type) {
  let attrs = {}
  for (let a in type.spec.attrs || {}) {
    let spec = type.spec.attrs[a], d = spec.default
    attrs[a] = typeof d == "number" ? 1 + r.int(4) : typeof d == "boolean" ? r.chance(0.5)
      : d === undefined ? a + r.int(3) : r.chance(0.5) ? d : (d === null ? null : a + r.int(3))
  }
  return attrs
}

function summarizeRange(range) {
  return range && {from: range.$from.pos, to: range.$to.pos, depth: range.depth}
}

export function transformCase(schema, seed, opCount) {
  let r = rng(seed)
  let doc = randomDoc(schema, seed)
  let foreign = randomDoc(schema, seed + 7777)
  let tr = new Transform(doc)
  let ops = []
  let nodeTypes = Object.values(schema.nodes), textblocks = nodeTypes.filter(t => t.isTextblock)

  for (let i = 0; i < opCount; i++) {
    let kind = r.pick(OPS), d = tr.doc, size = d.content.size
    let op = {kind}, stepsBefore = tr.steps.length
    try {
      switch (kind) {
        case "replace": case "replaceRange": {
          let [from, to] = pos2(r, d), [a, b] = pos2(r, d)
          let slice = d.slice(a, b)
          Object.assign(op, {from, to, a, b, slice: slice.toJSON()})
          if (kind == "replace") {
            let step = replaceStep(d, from, to, slice)
            op.fitted = step && step.toJSON()
            tr.replace(from, to, slice)
          } else tr.replaceRange(from, to, slice)
          break
        }
        case "replaceForeign": case "replaceRangeForeign": {
          let [from, to] = pos2(r, d), [a, b] = pos2(r, foreign)
          let parents = r.chance(0.2), slice = foreign.slice(a, b, parents)
          Object.assign(op, {from, to, a, b, parents, slice: slice.toJSON()})
          let drop = dropPoint(d, from, slice)
          op.dropPoint = drop
          if (kind == "replaceForeign") tr.replace(from, to, slice)
          else tr.replaceRange(from, to, slice)
          break
        }
        case "replaceRangeWith": {
          let [from, to] = pos2(r, d)
          let type = r.pick(nodeTypes), node = type.isText ? schema.text("zz") : type.createAndFill()
          if (!node) { op.skip = true; break }
          Object.assign(op, {from, to, nodeType: type.name, node: node.toJSON()})
          op.insertPoint = insertPoint(d, from, node.type)
          tr.replaceRangeWith(from, to, node)
          break
        }
        case "deleteRange": case "delete": {
          let [from, to] = pos2(r, d)
          Object.assign(op, {from, to})
          tr[kind](from, to)
          break
        }
        case "insertText": {
          let pos = r.int(size + 1), text = r.pick(["q", "hello", "😀", "a\nb"])
          Object.assign(op, {pos, text})
          tr.insert(pos, schema.text(text))
          break
        }
        case "addMark": {
          let [from, to] = pos2(r, d), mark = randomMark(r, schema)
          Object.assign(op, {from, to, mark: mark.toJSON()})
          tr.addMark(from, to, mark)
          break
        }
        case "removeMark": {
          let [from, to] = pos2(r, d), which = r.int(3)
          Object.assign(op, {from, to, which})
          if (which == 0) { let m = randomMark(r, schema); op.mark = m.toJSON(); tr.removeMark(from, to, m) }
          else if (which == 1) { let t = r.pick(Object.keys(schema.marks)); op.markType = t; tr.removeMark(from, to, schema.marks[t]) }
          else tr.removeMark(from, to, null)
          break
        }
        case "setBlockType": {
          let [from, to] = pos2(r, d), type = r.pick(textblocks), attrs = r.chance(0.5) ? attrsFor(r, type) : null
          Object.assign(op, {from, to, type: type.name, attrs})
          tr.setBlockType(from, to, type, attrs)
          break
        }
        case "setNodeMarkup": {
          let candidates = []
          d.descendants((node, pos) => { if (!node.isText) candidates.push(pos) })
          if (!candidates.length) { op.skip = true; break }
          let pos = r.pick(candidates), type = r.chance(0.5) ? r.pick(nodeTypes.filter(t => !t.isText)) : null
          let attrs = r.chance(0.5) ? attrsFor(r, type || d.nodeAt(pos).type) : null
          Object.assign(op, {pos, type: type && type.name, attrs})
          tr.setNodeMarkup(pos, type, attrs)
          break
        }
        case "lift": case "wrap": {
          let [from, to] = pos2(r, d)
          let range = d.resolve(from).blockRange(d.resolve(to))
          Object.assign(op, {from, to, range: summarizeRange(range)})
          if (!range) break
          if (kind == "lift") {
            let target = liftTarget(range)
            op.target = target
            if (target != null) tr.lift(range, target)
          } else {
            let type = r.pick(nodeTypes.filter(t => !t.isText && !t.isLeaf))
            let wrapping = findWrapping(range, type)
            op.type = type.name
            op.wrapping = wrapping && wrapping.map(w => ({type: w.type.name, attrs: w.attrs}))
            if (wrapping) tr.wrap(range, wrapping)
          }
          break
        }
        case "split": {
          let pos = r.int(size + 1), $pos = d.resolve(pos), depth = 1 + r.int(Math.max(1, $pos.depth))
          let typesAfter = null
          if (r.chance(0.3)) typesAfter = [{type: r.pick(textblocks)}]
          Object.assign(op, {pos, depth, typesAfter: typesAfter && typesAfter.map(t => t.type.name)})
          op.canSplit = canSplit(d, pos, depth, typesAfter)
          if (op.canSplit || r.chance(0.2)) tr.split(pos, depth, typesAfter)
          break
        }
        case "join": {
          let pos = r.int(size + 1), dir = r.chance(0.5) ? -1 : 1
          Object.assign(op, {pos, dir})
          op.canJoin = canJoin(d, pos)
          let point = joinPoint(d, pos, dir)
          op.joinPoint = point === undefined ? null : point
          if (op.canJoin) tr.join(pos)
          else if (point != null && canJoin(d, point)) tr.join(point)
          break
        }
        case "setNodeAttribute": {
          let candidates = []
          d.descendants((node, pos) => { if (!node.isText && Object.keys(node.attrs).length) candidates.push(pos) })
          if (!candidates.length) { op.skip = true; break }
          let pos = r.pick(candidates), node = d.nodeAt(pos), attr = r.pick(Object.keys(node.attrs))
          let value = r.pick([null, 1, 2, "x", true])
          Object.assign(op, {pos, attr, value})
          tr.setNodeAttribute(pos, attr, value)
          break
        }
        case "nodeMark": {
          let candidates = []
          d.descendants((node, pos) => { if (!node.isText) candidates.push(pos) })
          if (!candidates.length) { op.skip = true; break }
          let pos = r.pick(candidates), mark = randomMark(r, schema), add = r.chance(0.6)
          let byType = !add && r.chance(0.5)
          Object.assign(op, {pos, mark: mark.toJSON(), add, byType})
          if (add) tr.addNodeMark(pos, mark)
          else tr.removeNodeMark(pos, byType ? mark.type : mark)
          break
        }
      }
    } catch (e) {
      op.error = String(e.message)
    }
    op.steps = tr.steps.slice(stepsBefore).map(s => s.toJSON())
    op.doc = tr.doc.toJSON()
    ops.push(op)
  }

  // Mapping and step algebra checks on the accumulated transform.
  let checks = {maps: [], inverted: null, rebased: [], merges: [], changedRange: tr.changedRange()}
  let finalSize = tr.doc.content.size, startSize = doc.content.size
  for (let i = 0; i < 30; i++) {
    let pos = r.int(startSize + 1), assoc = r.chance(0.5) ? 1 : -1
    let res = tr.mapping.mapResult(pos, assoc)
    checks.maps.push({pos, assoc, mapped: tr.mapping.map(pos, assoc), res: [res.pos, res.deleted, res.deletedBefore, res.deletedAfter, res.deletedAcross]})
  }
  let inv = tr.mapping.invert()
  checks.invertMaps = []
  for (let i = 0; i < 20; i++) {
    let pos = r.int(finalSize + 1)
    checks.invertMaps.push({pos, mapped: inv.map(pos), mappedBack: inv.map(pos, -1)})
  }
  // Undo every step in reverse; must restore the original doc.
  let undo = new Transform(tr.doc), invertError = null
  try {
    for (let i = tr.steps.length - 1; i >= 0; i--) undo.step(tr.steps[i].invert(tr.docs[i]))
  } catch (e) { invertError = String(e.message) }
  checks.inverted = {doc: undo.doc.toJSON(), error: invertError, equal: undo.doc.eq(doc)}
  // Rebase: map each step over the mapping of the steps after it (like collab).
  for (let i = 0; i < tr.steps.length; i++) {
    let mapped = tr.steps[i].map(tr.mapping.slice(i + 1))
    checks.rebased.push(mapped && mapped.toJSON())
  }
  for (let i = 0; i + 1 < tr.steps.length; i++) {
    let m = tr.steps[i].merge(tr.steps[i + 1])
    checks.merges.push(m && m.toJSON())
  }
  // JSON round trip of all steps.
  checks.roundTrip = tr.steps.map(s => { try { return Step.fromJSON(schema, s.toJSON()).toJSON() } catch (e) { return {error: String(e.message)} } })
  return {doc: doc.toJSON(), foreign: foreign.toJSON(), ops, checks}
}
