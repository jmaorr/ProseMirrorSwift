# Changelog

## 0.1.1 (2026-11-23)

- PMTextKit (macOS): a node-selected leaf block (an image, a file card, a rule) draws no text
  highlight or caret; the block or the app's chrome shows the selection.
- PMTextKit (macOS): an overhanging view that sets no cursor of its own no longer recurses
  through the text view's cursorUpdate (a crash while hovering it).

## 0.1.0 (2026-11-23)

First public release.

- Ports of prosemirror-model, -transform, -state, -commands, -keymap, -inputrules, -history,
  -markdown (serializer), -tables and y-prosemirror's sync plugin, checked against the
  JavaScript originals.
- PMTextKit: a TextKit 2 editor view for macOS and iOS.
- PMTableView: native tables.
- PMExampleSetup: a basic schema, keymaps, input rules and `BasicStyle` to start from.
- Example apps for macOS and iOS.
