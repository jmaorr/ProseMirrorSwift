// Scenario runner (see fixtures/scenarios/README.md). The Swift side
// (Tests/ParityTests/Scenario*.swift) mirrors this setup exactly.
import {Fragment} from "prosemirror-model"
import {EditorState, Selection, TextSelection, NodeSelection, AllSelection} from "prosemirror-state"
import {rng, randomDoc} from "./random.js"
import * as cmd from "prosemirror-commands"
import {keymap} from "prosemirror-keymap"
import {inputRules, InputRule, wrappingInputRule, textblockTypeInputRule, smartQuotes, ellipsis, emDash,
        undoInputRule} from "prosemirror-inputrules"
import {history, undo, redo, undoDepth, redoDepth} from "prosemirror-history"
import {splitListItem, liftListItem, sinkListItem, wrapInList} from "prosemirror-schema-list"

// ---- Doc builder: ["doc", ["paragraph", "te<a>xt"]] with <a>/<b>/<node> markers ----

export function buildDoc(schema, spec) {
  let tags = {}
  function build(spec, marks, pos) {
    // returns {nodes, size}
    if (typeof spec == "string") {
      let nodes = [], size = 0, re = /<(a|b|node)>/g, last = 0, m
      let text = ""
      while ((m = re.exec(spec))) {
        text += spec.slice(last, m.index)
        tags[m[1]] = pos + text.length
        last = m.index + m[0].length
      }
      text += spec.slice(last)
      if (text) nodes.push(schema.text(text, marks))
      return {nodes, size: text.length}
    }
    let [name, ...rest] = spec
    let attrs = null
    if (rest.length && rest[0] && typeof rest[0] == "object" && !Array.isArray(rest[0])) attrs = rest.shift()
    if (schema.marks[name]) {
      let mark = schema.marks[name].create(attrs)
      let nodes = [], size = 0
      for (let child of rest) {
        let r = build(child, mark.addToSet(marks), pos + size)
        nodes.push(...r.nodes); size += r.size
      }
      return {nodes, size}
    }
    let type = schema.nodes[name]
    if (!type) throw new Error("Unknown node or mark " + name)
    let children = [], size = 0, inner = type.isLeaf ? 0 : 1
    for (let child of rest) {
      let r = build(child, [], pos + inner + size)
      children.push(...r.nodes); size += r.size
    }
    let node = type.createChecked(attrs, Fragment.from(children), marks.length ? marks : undefined)
    return {nodes: [node], size: node.nodeSize}
  }
  let r = build(spec, [], -1)
  return {doc: r.nodes[0], tags}
}

// ---- Plugin setup (mirrors prosemirror-example-setup, generalized over both schemas) ----

function pick(map, ...names) { for (let n of names) if (map[n]) return map[n]; return null }

export function markInputRule(regexp, markType) {
  return new InputRule(regexp, (state, match, start, end) => {
    let group = match[match.length - 1], full = match[0]
    if (!group) return null
    let startSpaces = full.search(/\S/)
    let textStart = start + full.indexOf(group), textEnd = textStart + group.length
    let tr = state.tr
    if (textEnd < end) tr.delete(textEnd, end)
    if (textStart > start) tr.delete(start + startSpaces, textStart)
    let markEnd = start + startSpaces + group.length
    tr.addMark(start + startSpaces, markEnd, markType.create())
    tr.removeStoredMark(markType)
    return tr
  })
}

export function setup(schema) {
  let n = schema.nodes, m = schema.marks
  let types = {
    strong: pick(m, "strong", "bold"), em: pick(m, "em", "italic"), code: pick(m, "code"),
    strike: pick(m, "strike"), underline: pick(m, "underline"),
    paragraph: n.paragraph, heading: n.heading, blockquote: n.blockquote,
    codeBlock: pick(n, "code_block", "codeBlock"), hardBreak: pick(n, "hard_break", "hardBreak"),
    hr: pick(n, "horizontal_rule", "horizontalRule"),
    bulletList: pick(n, "bullet_list", "bulletList"), orderedList: pick(n, "ordered_list", "orderedList"),
    listItem: pick(n, "list_item", "listItem"), taskItem: pick(n, "taskItem"),
  }
  let orderAttr = types.orderedList && types.orderedList.spec.attrs && "order" in types.orderedList.spec.attrs ? "order" : "start"

  let rules = smartQuotes.concat(ellipsis, emDash)
  if (types.blockquote) rules.push(wrappingInputRule(/^\s*>\s$/, types.blockquote))
  if (types.orderedList) rules.push(wrappingInputRule(/^(\d+)\.\s$/, types.orderedList, match => ({[orderAttr]: +match[1]}),
                                                      (match, node) => node.childCount + node.attrs[orderAttr] == +match[1]))
  if (types.bulletList) rules.push(wrappingInputRule(/^\s*([-+*])\s$/, types.bulletList))
  if (types.codeBlock) rules.push(textblockTypeInputRule(/^```$/, types.codeBlock))
  if (types.heading) rules.push(textblockTypeInputRule(/^(#{1,6})\s$/, types.heading, match => ({level: match[1].length})))
  if (types.strong) rules.push(markInputRule(/(?:^|\s)(\*\*(?!\s+\*\*)((?:[^*]+))\*\*(?!\s+\*\*))$/, types.strong))
  if (types.em) rules.push(markInputRule(/(?:^|\s)(\*(?!\s+\*)((?:[^*]+))\*(?!\s+\*))$/, types.em))
  if (types.code) rules.push(markInputRule(/(^|[^`])`([^`]+)`(?!`)$/, types.code))

  let keys = {}
  keys["Mod-z"] = undo
  keys["Shift-Mod-z"] = redo
  keys["Backspace"] = undoInputRule
  keys["Alt-ArrowUp"] = cmd.joinUp
  keys["Alt-ArrowDown"] = cmd.joinDown
  keys["Mod-BracketLeft"] = cmd.lift
  keys["Escape"] = cmd.selectParentNode
  if (types.strong) { keys["Mod-b"] = cmd.toggleMark(types.strong); keys["Mod-B"] = cmd.toggleMark(types.strong) }
  if (types.em) { keys["Mod-i"] = cmd.toggleMark(types.em); keys["Mod-I"] = cmd.toggleMark(types.em) }
  if (types.code) keys["Mod-`"] = cmd.toggleMark(types.code)
  if (types.underline) keys["Mod-u"] = cmd.toggleMark(types.underline)
  if (types.bulletList) keys["Shift-Ctrl-8"] = wrapInList(types.bulletList)
  if (types.orderedList) keys["Shift-Ctrl-9"] = wrapInList(types.orderedList)
  if (types.blockquote) keys["Ctrl->"] = cmd.wrapIn(types.blockquote)
  if (types.hardBreak) {
    let br = types.hardBreak
    let insertBreak = (state, dispatch) => {
      if (dispatch) dispatch(state.tr.replaceSelectionWith(br.create()).scrollIntoView())
      return true
    }
    let c = cmd.chainCommands(cmd.exitCode, insertBreak)
    keys["Mod-Enter"] = c; keys["Shift-Enter"] = c; keys["Ctrl-Enter"] = c
  }
  let items = [types.listItem, types.taskItem].filter(Boolean)
  if (items.length) {
    keys["Enter"] = cmd.chainCommands(...items.map(t => splitListItem(t)))
    keys["Mod-["] = cmd.chainCommands(...items.map(t => liftListItem(t)))
    keys["Mod-]"] = cmd.chainCommands(...items.map(t => sinkListItem(t)))
    keys["Tab"] = cmd.chainCommands(...items.map(t => sinkListItem(t)))
    keys["Shift-Tab"] = cmd.chainCommands(...items.map(t => liftListItem(t)))
  }
  if (types.paragraph) keys["Shift-Ctrl-0"] = cmd.setBlockType(types.paragraph)
  if (types.codeBlock) keys["Shift-Ctrl-\\"] = cmd.setBlockType(types.codeBlock)
  if (types.heading) for (let i = 1; i <= 6; i++) keys["Shift-Ctrl-" + i] = cmd.setBlockType(types.heading, {level: i})
  if (types.hr) {
    let hr = types.hr
    keys["Mod-_"] = (state, dispatch) => {
      if (dispatch) dispatch(state.tr.replaceSelectionWith(hr.create()).scrollIntoView())
      return true
    }
  }

  let plugins = [inputRules({rules}), keymap(keys), keymap(cmd.baseKeymap), history()]
  return {plugins, types}
}

// ---- Headless view ----

export class HeadlessView {
  constructor(state) { this.state = state; this.composing = false; this.dispatch = this.dispatch.bind(this) }
  dispatch(tr) { this.state = this.state.apply(tr) }
  endOfTextblock(dir, state) {
    let sel = (state || this.state).selection, $head = sel.$head
    if (!$head.parent.inlineContent) return true
    if (dir == "backward" || dir == "left" || dir == "up") return $head.parentOffset == 0
    return $head.parentOffset == $head.parent.content.size
  }
  someProp(name, f) {
    for (let p of this.state.plugins) {
      let prop = p.props[name]
      if (prop) { let r = f(prop.bind(p)); if (r) return r }
    }
  }
}

const KEYCODES = {Enter: 13, Backspace: 8, Tab: 9, Delete: 46, Escape: 27, " ": 32, "[": 219, "]": 221, "`": 192,
                  "\\": 220, "-": 189, "_": 189, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, ">": 190}

export function keyEvent(spec) {
  let parts = spec.split(/-(?!$)/), key = parts.pop()
  let ev = {key, keyCode: 0, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false}
  for (let mod of parts) {
    if (/^(cmd|meta|m|mod)$/i.test(mod)) ev.metaKey = true
    else if (/^a(lt)?$/i.test(mod)) ev.altKey = true
    else if (/^(c|ctrl|control)$/i.test(mod)) ev.ctrlKey = true
    else if (/^s(hift)?$/i.test(mod)) ev.shiftKey = true
  }
  if (key.length == 1 && /[a-z]/i.test(key)) {
    ev.keyCode = key.toUpperCase().charCodeAt(0)
    ev.key = ev.shiftKey ? key.toUpperCase() : key.toLowerCase()
  } else if (key.length == 1 && /[0-9]/.test(key)) {
    ev.keyCode = 48 + +key
  } else if (key == "BracketLeft") { ev.key = "["; ev.keyCode = 219 }
  else if (key == "BracketRight") { ev.key = "]"; ev.keyCode = 221 }
  else ev.keyCode = KEYCODES[key] || 0
  return ev
}

function namedCommand(name, args, schema, types) {
  let t = a => schema.nodes[a] || types[a], mk = a => schema.marks[a] || types[a]
  switch (name) {
    case "toggleMark": return cmd.toggleMark(mk(args[0]), args[1] || null)
    case "setBlockType": return cmd.setBlockType(t(args[0]), args[1] || null)
    case "wrapIn": return cmd.wrapIn(t(args[0]), args[1] || null)
    case "wrapInList": return wrapInList(t(args[0]), args[1] || null)
    case "splitListItem": return splitListItem(t(args[0]))
    case "liftListItem": return liftListItem(t(args[0]))
    case "sinkListItem": return sinkListItem(t(args[0]))
    case "undo": return undo
    case "redo": return redo
    default:
      if (cmd[name]) return cmd[name]
      throw new Error("Unknown command " + name)
  }
}

export function stateJSON(state) {
  let json = state.toJSON()
  json.undoDepth = undoDepth(state)
  json.redoDepth = redoDepth(state)
  return json
}


function execStep(view, step, schema, types, getClock, setClock) {
  let entry = {step}
  try {
    if (step.wait) setClock(getClock() + step.wait)
    else setClock(getClock() + 10)
    if (step.type != null) {
      for (let ch of Array.from(step.type)) {
        let {from, to} = view.state.selection
        let handled = view.someProp("handleTextInput", f => f(view, from, to, ch))
        if (!handled) view.dispatch(view.state.tr.insertText(ch, from, to))
      }
    } else if (step.key) {
      entry.handled = !!view.someProp("handleKeyDown", f => f(view, keyEvent(step.key)))
    } else if (step.command) {
      entry.handled = namedCommand(step.command, step.args || [], schema, types)(view.state, view.dispatch, view)
    } else if (step.undo) {
      entry.handled = undo(view.state, view.dispatch)
    } else if (step.redo) {
      entry.handled = redo(view.state, view.dispatch)
    } else if (step.select) {
      let [a, h] = step.select
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, a, h == null ? a : h)))
    } else if (step.selectNode != null) {
      view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, step.selectNode)))
    } else if (step.selectAll) {
      view.dispatch(view.state.tr.setSelection(new AllSelection(view.state.doc)))
    } else if (step.insertText != null) {
      let [from, to] = step.at
      view.dispatch(view.state.tr.insertText(step.insertText, from, to == null ? from : to))
    }
  } catch (e) {
    entry.error = String(e.message)
  }
  entry.state = stateJSON(view.state)
  return entry
}

const RANDOM_KEYS = ["Enter", "Enter", "Backspace", "Backspace", "Backspace", "Delete", "Mod-b", "Mod-i", "Mod-`", "Mod-u",
  "Tab", "Shift-Tab", "Mod-z", "Mod-z", "Shift-Mod-z", "Shift-Enter", "Mod-Enter", "Shift-Ctrl-1", "Shift-Ctrl-0",
  "Shift-Ctrl-8", "Shift-Ctrl-9", "Ctrl->", "Shift-Ctrl-\\", "Mod-a", "Escape", "Alt-ArrowUp", "Alt-ArrowDown",
  "Mod-[", "Mod-]", "Mod-BracketLeft", "Mod-_", "Ctrl-h", "Ctrl-d", "Alt-Backspace", "Ctrl-a", "Ctrl-e"]
const RANDOM_TEXT = ["a", "b", " ", "x", "hello", "**", "*", "`", "# ", "## ", "> ", "- ", "1. ", "```", "\"", "'",
  "--", "...", "**b**", "*i*", "`c`", "中", "é"]
// No astral characters in typed text: JS input-rule regexes (non-`u`) match
// half a surrogate pair where NSRegularExpression matches whole code points.
// See docs/LOG.md "Known divergences".

export function randomSession(schema, seed, count) {
  let r = rng(seed)
  let {plugins, types} = setup(schema)
  let doc = randomDoc(schema, seed, {astral: false})
  let clock = 1000, realNow = Date.now
  Date.now = () => clock
  try {
    let initial = Selection.near(doc.resolve(r.int(doc.content.size + 1)))
    let view = new HeadlessView(EditorState.create({doc, selection: initial, plugins}))
    let trace = [{step: null, state: stateJSON(view.state)}]
    for (let i = 0; i < count; i++) {
      let step, roll = r.next()
      if (roll < 0.35) step = {type: r.pick(RANDOM_TEXT)}
      else if (roll < 0.75) step = {key: r.pick(RANDOM_KEYS)}
      else if (roll < 0.9) {
        let d = view.state.doc, a = r.int(d.content.size + 1), b = r.chance(0.5) ? a : r.int(d.content.size + 1)
        let sel = TextSelection.between(d.resolve(a), d.resolve(b))
        if (sel instanceof TextSelection) step = {select: [sel.anchor, sel.head]}
        else step = {selectAll: true}
      } else if (roll < 0.95) step = {wait: 600}
      else {
        let d = view.state.doc, cands = []
        d.descendants((node, pos) => { if (NodeSelection.isSelectable(node) && !node.isText) cands.push(pos) })
        step = cands.length ? {selectNode: r.pick(cands)} : {selectAll: true}
      }
      trace.push(execStep(view, step, schema, types, () => clock, c => clock = c))
    }
    return {trace, steps: trace.slice(1).map(t => t.step)}
  } finally {
    Date.now = realNow
  }
}

export function runScenario(schema, scenario) {
  let {plugins, types} = setup(schema)
  let {doc, tags} = buildDoc(schema, scenario.doc)
  let selection
  if (tags.node != null) selection = NodeSelection.create(doc, tags.node)
  else if (tags.a != null) selection = TextSelection.create(doc, tags.a, tags.b != null ? tags.b : tags.a)
  let clock = 1000
  let realNow = Date.now
  Date.now = () => clock
  try {
    let view = new HeadlessView(EditorState.create({doc, selection, plugins}))
    let trace = [{step: null, state: stateJSON(view.state)}]
    for (let step of scenario.steps) trace.push(execStep(view, step, schema, types, () => clock, c => clock = c))
    let result = {trace}
    if (scenario.expect) {
      let expected = buildDoc(schema, scenario.expect).doc
      result.expectOk = expected.eq(view.state.doc)
      result.expectDoc = expected.toJSON()
    }
    return result
  } finally {
    Date.now = realNow
  }
}
