# Editing scenarios

Each `*.json` file here is a list of scenarios. Every scenario runs through **both**
the real JS ProseMirror (in JavaScriptCore) and the Swift port, and after every step
the resulting state (doc, selection, stored marks) must be identical. So a scenario
doesn't need an expected result to be useful — it just has to describe what a user does.
Add an `expect` to also pin down the behaviour you want (checked against JS too).

Cases you've seen break in native editors are welcome here. Rough is fine.

## Format

```json
{
  "name": "bold before typing",
  "schema": "basic",
  "doc": ["doc", ["paragraph", "hello <a>"]],
  "steps": [
    {"key": "Mod-b"},
    {"type": "world"},
    {"key": "Enter"},
    {"type": "next line"}
  ],
  "expect": ["doc", ["paragraph", "hello ", ["strong", "world"]], ["paragraph", ["strong", "next line"]]]
}
```

- `schema`: `"basic"` (prosemirror-schema-basic + lists; node names `paragraph`,
  `heading`, `bullet_list`, `list_item`, marks `strong`, `em`, `code`, `link`) or
  `"tiptap"` (a Tiptap-style schema: `paragraph`, `heading`, `bulletList`, `listItem`,
  `taskItem`, `table`, ..., marks `bold`, `italic`, ...). See `fixtures/schemas/`.
- `doc` / `expect`: nested arrays. `[typeName, {attrs}?, ...children]`. A string is text.
  If `typeName` is a *mark*, its children are text/inline nodes wrapped in that mark,
  e.g. `["strong", "bold"]`, `["link", {"href": "x"}, "text"]`.
- Selection markers inside text: `<a>` = anchor (cursor if alone), `<b>` = head.
  `<node>` before a node selects that node. No marker = cursor at doc start.
- Steps:
  - `{"type": "abc"}` — type text one character at a time, the way a view would:
    input rules first, otherwise `insertText` (respecting stored marks).
  - `{"key": "Mod-b"}` — run the key through the keymaps. `Mod` = Cmd. Names follow
    prosemirror-keymap (`Enter`, `Backspace`, `Delete`, `Shift-Enter`, `Mod-z`, `Tab`,
    `ArrowLeft` is *not* handled — no view).
  - `{"command": "toggleMark", "args": ["strong"]}` — run a named command directly.
  - `{"select": [anchor, head]}` / `{"select": [pos]}` — set a text selection;
    `{"selectNode": pos}`; `{"selectAll": true}`.
  - `{"undo": true}`, `{"redo": true}`.
  - `{"wait": 600}` — advance the clock (ms) before the next step (history groups
    edits closer than 500ms).
  - `{"insertText": "x", "at": [from, to]}` — programmatic insert (no input rules).

The keymap/plugin setup mirrors `prosemirror-example-setup`: input rules (markdown-ish
`# `, `> `, `- `, `1. `, ``` ``` ```, smart quotes; `**bold**`/`*em*`/`` `code` `` mark rules added
here because example-setup lacks them), schema keymap (Mod-b/i/`, Enter in lists, Shift-Enter
hard break, Mod-z/y/Shift-Mod-z, Mod-[ / Mod-]), base keymap, history.
**Tiptap's own keymaps differ in places** (e.g. its Enter / Backspace
chains); scenarios test ProseMirror semantics, which is what the Swift port reproduces.
