// Seeded random document generation. The JS side generates every random
// input and records it in its output, so the Swift side only replays — no
// need to keep two PRNG implementations in sync.
import {Fragment} from "prosemirror-model"

export function rng(seed) {
  let a = seed >>> 0
  let next = () => {
    a |= 0; a = a + 0x6D2B79F5 | 0
    let t = Math.imul(a ^ a >>> 15, 1 | a)
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t
    return ((t ^ t >>> 14) >>> 0) / 4294967296
  }
  return {
    next,
    int(n) { return Math.floor(next() * n) },
    pick(arr) { return arr[Math.floor(next() * arr.length)] },
    chance(p) { return next() < p },
  }
}

const ALPHABET = ["a", "b", "c", "x", "y", " ", " ", "é", "ß", "😀", "中", "\n"]
const BMP_ALPHABET = ALPHABET.filter(c => c.length == 1)
let alphabet = ALPHABET

function randomText(r) {
  let len = 1 + r.int(6), s = ""
  for (let i = 0; i < len; i++) s += r.pick(alphabet)
  return s
}

function randomAttrValue(r, spec, name) {
  let d = spec.default
  if (typeof d == "number") return r.int(6) + 1
  if (typeof d == "boolean") return r.chance(0.5)
  if (typeof d == "string") return r.chance(0.5) ? d : name + r.int(3)
  if (d === null) return r.chance(0.7) ? null : name + r.int(3)
  return d
}

function randomAttrs(r, type) {
  let attrs = {}
  for (let name in type.spec.attrs || {}) {
    let spec = type.spec.attrs[name]
    if (!Object.prototype.hasOwnProperty.call(spec, "default")) { attrs[name] = name + r.int(3); continue }
    attrs[name] = r.chance(0.6) ? spec.default : randomAttrValue(r, spec, name)
  }
  return attrs
}

function randomMarks(r, schema, parentType) {
  let marks = []
  for (let name in schema.marks) {
    let type = schema.marks[name]
    if (!parentType.allowsMarkType(type) || !r.chance(0.25)) continue
    let attrs = randomAttrs(r, type)
    if (!attrs) continue
    try { let m = type.create(attrs); type.checkAttrs(m.attrs); marks = m.addToSet(marks) } catch (e) {}
  }
  return marks
}

// Build a random valid node of `type`.
function randomNode(r, schema, type, depth) {
  let attrs = randomAttrs(r, type)
  if (!attrs) return null
  try { type.checkAttrs(type.computeAttrs(attrs)) } catch (e) { attrs = null }
  if (!attrs) return type.hasRequiredAttrs() ? null : type.createAndFill()
  if (type.isLeaf) return type.create(attrs)
  let children = [], match = type.contentMatch
  let max = depth > 3 ? 2 : 5
  for (let i = 0; i < 8; i++) {
    if (match.validEnd && (children.length >= max || r.chance(0.25))) break
    if (match.edgeCount == 0) break
    let edge = match.edge(r.int(match.edgeCount))
    let child
    if (edge.type.isText) {
      child = schema.text(randomText(r), randomMarks(r, schema, type))
    } else if (depth > 5) {
      child = edge.type.createAndFill()
    } else {
      child = randomNode(r, schema, edge.type, depth + 1)
    }
    if (!child) continue
    if (child.isInline && !child.isText) {
      let marks = randomMarks(r, schema, type)
      if (marks.length) child = child.mark(marks)
    }
    children.push(child)
    match = edge.next
  }
  let content = Fragment.from(children)
  let after = type.contentMatch.matchFragment(content)
  let fill = after && after.fillBefore(Fragment.empty, true)
  if (!fill) return type.createAndFill(attrs)
  return type.create(attrs, content.append(fill))
}

export function randomDoc(schema, seed, {astral = true, alphabet: chars} = {}) {
  alphabet = chars || (astral ? ALPHABET : BMP_ALPHABET)
  let r = rng(seed)
  for (let attempt = 0; attempt < 20; attempt++) {
    let doc = randomNode(r, schema, schema.topNodeType, 0)
    if (doc) { try { doc.check(); return doc } catch (e) {} }
  }
  return schema.topNodeType.createAndFill()
}
