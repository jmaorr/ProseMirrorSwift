// Model parity probes: given a schema + seed, generate a random doc and record
// a large set of observations about it. Swift replays the same inputs.
import {Node, Slice, Fragment} from "prosemirror-model"
import {rng, randomDoc} from "./random.js"

const markJSON = m => m.toJSON()
const nodeSummary = n => n ? {type: n.type.name, size: n.nodeSize, marks: n.marks.map(markJSON)} : null

export function probeDoc(doc, r) {
  let size = doc.content.size
  let out = {
    doc: doc.toJSON(),
    nodeSize: doc.nodeSize,
    textContent: doc.textContent,
    textBetween: doc.textBetween(0, size, "\n", "*"),
    positions: [],
    slices: [],
    replaces: [],
  }
  for (let pos = 0; pos <= size; pos++) {
    let $pos = doc.resolve(pos), other = r.int(size + 1), $other = doc.resolve(other)
    let levels = []
    for (let d = 0; d <= $pos.depth; d++)
      levels.push({type: $pos.node(d).type.name, index: $pos.index(d), indexAfter: $pos.indexAfter(d),
                   start: $pos.start(d), end: $pos.end(d),
                   before: d ? $pos.before(d) : null, after: d ? $pos.after(d) : null})
    let range = $pos.blockRange($other)
    let at = doc.nodeAt(pos)
    out.positions.push({
      pos, depth: $pos.depth, parentOffset: $pos.parentOffset, textOffset: $pos.textOffset, levels,
      marks: $pos.marks().map(markJSON),
      marksAcross: (m => m && m.map(markJSON))($pos.marksAcross($other)),
      nodeAfter: nodeSummary($pos.nodeAfter), nodeBefore: nodeSummary($pos.nodeBefore),
      nodeAt: nodeSummary(at),
      other, sharedDepth: $pos.sharedDepth(other), sameParent: $pos.sameParent($other),
      blockRange: range && {depth: range.depth, start: range.start, end: range.end, startIndex: range.startIndex, endIndex: range.endIndex},
    })
  }
  for (let i = 0; i < 20; i++) {
    let a = r.int(size + 1), b = r.int(size + 1)
    let from = Math.min(a, b), to = Math.max(a, b)
    let slice = doc.slice(from, to)
    out.slices.push({from, to, slice: slice.toJSON(), maxOpen: Slice.maxOpen(slice.content).toJSON(),
                     rangeHasMark: Object.keys(doc.type.schema.marks).map(m => doc.rangeHasMark(from, to, doc.type.schema.marks[m]))})
  }
  for (let i = 0; i < 30; i++) {
    let a = r.int(size + 1), b = r.int(size + 1), c = r.int(size + 1), d = r.int(size + 1)
    let from = Math.min(a, b), to = Math.max(a, b), sFrom = Math.min(c, d), sTo = Math.max(c, d)
    let entry = {from, to, sFrom, sTo}
    try {
      let result = doc.replace(from, to, doc.slice(sFrom, sTo))
      entry.result = result.toJSON()
      entry.diffStart = doc.content.findDiffStart(result.content)
      let end = doc.content.findDiffEnd(result.content)
      entry.diffEnd = end && [end.a, end.b]
    } catch (e) {
      entry.error = String(e.message)
    }
    out.replaces.push(entry)
  }
  return out
}

// Content-expression observations for every pair of node types.
export function probeSchema(schema) {
  let out = []
  for (let n in schema.nodes) {
    let type = schema.nodes[n], match = type.contentMatch
    let entry = {type: n, inlineContent: type.inlineContent, isLeaf: type.isLeaf, isBlock: type.isBlock,
                 isTextblock: type.isTextblock, isAtom: type.isAtom, defaultType: match.defaultType && match.defaultType.name,
                 validEnd: match.validEnd, edges: match.next.map(e => e.type.name),
                 markSet: type.markSet && type.markSet.map(m => m.name),
                 createAndFill: (f => f && f.toJSON())(type.createAndFill()), wrap: {}, fill: {}}
    for (let t in schema.nodes) {
      let w = match.findWrapping(schema.nodes[t])
      entry.wrap[t] = w && w.map(x => x.name)
      let node = schema.nodes[t].isText ? schema.text("x") : schema.nodes[t].createAndFill()
      let f = node && match.fillBefore(Fragment.from(node), true)
      entry.fill[t] = f ? f.toJSON() || [] : null
    }
    out.push(entry)
  }
  let marks = []
  for (let m in schema.marks) {
    let type = schema.marks[m]
    marks.push({name: m, rank: type.rank, excluded: type.excluded.map(x => x.name)})
  }
  return {nodes: out, marks}
}

export function modelCase(schema, seed) {
  let doc = randomDoc(schema, seed)
  return probeDoc(doc, rng(seed * 7919 + 1))
}

// Mutate a valid doc's JSON randomly so that it is often invalid, then report
// whether fromJSON + check succeed.
export function invalidCase(schema, seed) {
  let r = rng(seed)
  let json = randomDoc(schema, seed).toJSON()
  let nodes = []
  ;(function walk(n) { nodes.push(n); (n.content || []).forEach(walk) })(json)
  let typeNames = Object.keys(schema.nodes), markNames = Object.keys(schema.marks)
  for (let k = 0, count = 1 + r.int(2); k < count; k++) {
    let target = r.pick(nodes)
    switch (r.int(6)) {
      case 0: if (target.type != "text") target.type = r.pick(typeNames); break
      case 1: if (target.content) target.content.splice(r.int(target.content.length), 1); break
      case 2: (target.marks || (target.marks = [])).push({type: r.pick(markNames)}); break
      case 3: target.attrs = Object.assign({}, target.attrs, {bogus: 1}); break
      case 4: if (target.content && target.content.length) target.content.push(target.content[0]); break
      case 5: if (target.type == "text") target.text = ""; break
    }
  }
  let result = {json}
  try {
    let node = Node.fromJSON(schema, json)
    node.check()
    result.ok = node.toJSON()
  } catch (e) {
    result.error = String(e.message)
  }
  return result
}
