// Markdown serialization oracles:
// - prosemirror-markdown's defaultMarkdownSerializer on its own schema;
// - tiptap-markdown 0.8.10's serializer: its MarkdownSerializerState (vendored, MIT) with
//   the node and mark rules of tiptap-markdown's own StarterKit extensions (bulletListMarker
//   "-", tightLists), on the tiptap test schema.
import {defaultMarkdownSerializer, schema as markdownSchema} from "prosemirror-markdown"
import {Transform} from "prosemirror-transform"
import {MarkdownSerializerState as TiptapState} from "./vendor/tiptap-markdown/state.js"
import {randomDoc} from "./random.js"
import {specToJSON} from "./specjson.js"

const d = defaultMarkdownSerializer
const MD_ALPHABET = ["a", "b", "x", " ", " ", "*", "_", "`", "[", "]", "#", ">", "-", "+", "1", ".", "!", "\\", "~", "<", "é", "😀"]

function escapeHTML(value) { return value?.replace(/</g, '&lt;').replace(/>/g, '&gt;') }

function findIndexOfAdjacentNode(node, parent, index) {
  let i = 0
  for (; index - i > 0; i++) if (parent.child(index - i - 1).type.name !== node.type.name) break
  return i
}

const bulletList = (state, node) => state.renderList(node, "  ", () => "- ")

// tiptap-markdown's rules for StarterKit's nodes (plus its task list and image extensions).
const tiptapNodes = {
  doc(state, node) { state.renderContent(node) },
  paragraph: d.nodes.paragraph,
  heading: d.nodes.heading,
  blockquote: d.nodes.blockquote,
  codeBlock(state, node) {
    state.write("```" + (node.attrs.language || "") + "\n")
    state.text(node.textContent, false)
    state.ensureNewLine()
    state.write("```")
    state.closeBlock(node)
  },
  bulletList,
  orderedList(state, node, parent, index) {
    const start = node.attrs.start || 1
    const maxW = String(start + node.childCount - 1).length
    const space = state.repeat(" ", maxW + 2)
    const adjacentIndex = findIndexOfAdjacentNode(node, parent, index)
    const separator = adjacentIndex % 2 ? ') ' : '. '
    state.renderList(node, space, i => {
      const nStr = String(start + i)
      return state.repeat(" ", maxW - nStr.length) + nStr + separator
    })
  },
  listItem: d.nodes.list_item,
  hardBreak(state, node, parent, index) {
    for (let i = index + 1; i < parent.childCount; i++)
      if (parent.child(i).type != node.type) { state.write("\\\n"); return }
  },
  horizontalRule: d.nodes.horizontal_rule,
  image: d.nodes.image,
  text(state, node) { state.text(escapeHTML(node.text)) },
  taskList: bulletList,
  taskItem(state, node) {
    state.write(`${node.attrs.checked ? '[x]' : '[ ]'} `)
    state.renderContent(node)
  },
}

// tiptap-markdown's rules for StarterKit's marks. Marks it writes as HTML through the DOM
// (underline, highlight, sub/superscript, textStyle) are left out of the docs instead.
const tiptapMarks = {
  bold: d.marks.strong,
  italic: d.marks.em,
  code: d.marks.code,
  link: d.marks.link,
  strike: {open: '~~', close: '~~', expelEnclosingWhitespace: true},
}

export function tiptapMarkdown(doc) {
  const state = new TiptapState(tiptapNodes, tiptapMarks, {hardBreakNodeName: "hardBreak", tightLists: true})
  state.renderContent(doc)
  return state.out
}

function containsTable(doc) {
  let found = false
  doc.descendants(n => { if (n.type.spec.tableRole) found = true; return !found })
  return found
}

// `doc` without the marks tiptapMarks has no rule for.
function withoutHTMLMarks(doc) {
  const tr = new Transform(doc)
  for (const name in doc.type.schema.marks)
    if (!tiptapMarks[name]) tr.removeMark(0, tr.doc.content.size, doc.type.schema.marks[name])
  return tr.doc
}

export function markdownHandlers(schemaFor) {
  return {
    markdownSchema() { return specToJSON(markdownSchema.spec) },
    // prosemirror-markdown's default serializer on random docs of its schema.
    defaultMarkdownCases({seed, count}) {
      const out = []
      for (let i = 0; out.length < count && i < count * 10; i++) {
        const doc = randomDoc(markdownSchema, seed + i, {alphabet: MD_ALPHABET})
        let md
        try { md = d.serialize(doc, {tightLists: i % 2 == 0}) } catch (e) { continue }
        out.push({doc: doc.toJSON(), tight: i % 2 == 0, md})
      }
      return out
    },
    // tiptap-markdown's serializer on random docs of the tiptap schema (tables left out:
    // tiptap-markdown writes them through the DOM).
    tiptapMarkdownCases({schema, seed, count}) {
      const s = schemaFor(schema), out = []
      for (let i = 0; out.length < count && i < count * 10; i++) {
        const doc = withoutHTMLMarks(randomDoc(s, seed + i, {alphabet: MD_ALPHABET}))
        if (containsTable(doc)) continue
        let md
        // A link or image without a URL makes the JS throw.
        try { md = tiptapMarkdown(doc) } catch (e) { continue }
        out.push({doc: doc.toJSON(), md})
      }
      return out
    },
    tiptapMarkdown({schema, doc}) { return tiptapMarkdown(schemaFor(schema).nodeFromJSON(doc)) },
  }
}
