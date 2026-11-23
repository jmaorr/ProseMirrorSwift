// The JS side of the demo: plain ProseMirror + y-prosemirror (the same sync code
// Tiptap's collaboration extension uses) on the Tiptap-style test schema, over
// y-websocket. Blocks render generically.
import * as Y from "yjs"
import {WebsocketProvider} from "y-websocket"
import {ySyncPlugin, yUndoPlugin, undo, redo} from "y-prosemirror"
import {Schema} from "prosemirror-model"
import {EditorState} from "prosemirror-state"
import {EditorView} from "prosemirror-view"
import {keymap} from "prosemirror-keymap"
import {baseKeymap, toggleMark} from "prosemirror-commands"
import tiptap from "../../fixtures/schemas/tiptap.json"

const TAGS = {
  paragraph: "p", blockquote: "blockquote", bulletList: "ul", orderedList: "ol", listItem: "li",
  codeBlock: "pre", horizontalRule: "hr", hardBreak: "br", taskList: "ul", taskItem: "li", image: "img",
  table: "table", tableRow: "tr", tableCell: "td", tableHeader: "th",
}
const MARK_TAGS = {bold: "strong", italic: "em", underline: "u", strike: "s", code: "code", subscript: "sub", superscript: "sup", highlight: "mark", link: "a"}

const nodes = {}, marks = {}
for (const [name, spec] of tiptap.nodes) {
  const s = {...spec}
  if (name !== "text" && name !== "doc") {
    s.toDOM = node => {
      let tag = name === "heading" ? "h" + (node.attrs.level || 1) : TAGS[name] || (spec.inline ? "span" : "div")
      const attrs = {class: "pm-" + name}
      if (name === "taskItem" || name === "taskCard") attrs["data-checked"] = String(!!node.attrs.checked)
      if (name === "linkCard") return ["span", attrs, node.attrs.href || node.attrs.hostname || "link"]
      if (spec.atom || (!spec.content && !spec.inline)) return [tag, attrs]
      if (!spec.content) return [tag, attrs]
      return [tag, attrs, 0]
    }
  }
  nodes[name] = s
}
for (const [name, spec] of tiptap.marks) marks[name] = {...spec, toDOM: () => [MARK_TAGS[name] || "span", {class: "pm-" + name}, 0]}
const schema = new Schema({nodes, marks})

const room = new URLSearchParams(location.search).get("room") || "demo"
const ydoc = new Y.Doc()
const provider = new WebsocketProvider(`ws://${location.host}`, room, ydoc)
const fragment = ydoc.getXmlFragment("content")
const status = document.getElementById("status")
provider.on("status", e => { status.textContent = `${room}: ${e.status}` })

const view = new EditorView(document.getElementById("editor"), {
  state: EditorState.create({
    schema,
    plugins: [
      ySyncPlugin(fragment),
      yUndoPlugin(),
      keymap({"Mod-z": undo, "Mod-y": redo, "Mod-Shift-z": redo, "Mod-b": toggleMark(schema.marks.bold), "Mod-i": toggleMark(schema.marks.italic)}),
      keymap(baseKeymap),
    ],
  }),
})
window.view = view
window.ydoc = ydoc
