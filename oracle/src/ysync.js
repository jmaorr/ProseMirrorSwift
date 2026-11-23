// Yjs peers for the YSync parity tests: real yjs + y-prosemirror (the versions
// Tiptap's collaboration extension and y-websocket servers use), driven headlessly. A peer is a Y.Doc
// bound to a ProseMirror document the way ySyncPlugin binds an editor: local
// edits go in through updateYFragment, remote changes come out through
// initProseMirrorDoc.
import * as Y from "yjs"
import {Node, Slice, Fragment} from "prosemirror-model"
import {EditorState, TextSelection} from "prosemirror-state"
import {updateYFragment, prosemirrorJSONToYDoc, yXmlFragmentToProseMirrorRootNode, initProseMirrorDoc} from "y-prosemirror"
import {rng} from "./random.js"
import {randomDoc} from "./random.js"

const FRAGMENT = "content"
const peers = new Map()

const b64 = {
  encode(bytes) { let s = ""; for (let b of bytes) s += String.fromCharCode(b); return btoa(s) },
  decode(str) { let s = atob(str), out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out },
}
if (typeof globalThis.btoa == "undefined") {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  globalThis.btoa = s => {
    let out = ""
    for (let i = 0; i < s.length; i += 3) {
      let a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2)
      let n = (a << 16) | ((b || 0) << 8) | (c || 0)
      out += chars[n >> 18 & 63] + chars[n >> 12 & 63] + (isNaN(b) ? "=" : chars[n >> 6 & 63]) + (isNaN(c) ? "=" : chars[n & 63])
    }
    return out
  }
  globalThis.atob = s => {
    s = s.replace(/=+$/, "")
    let out = ""
    for (let i = 0; i < s.length; i += 4) {
      let n = 0
      for (let j = 0; j < 4; j++) n = n << 6 | (i + j < s.length ? chars.indexOf(s[i + j]) : 0)
      out += String.fromCharCode(n >> 16 & 255)
      if (i + 2 < s.length) out += String.fromCharCode(n >> 8 & 255)
      if (i + 3 < s.length) out += String.fromCharCode(n & 255)
    }
    return out
  }
}

function splitsSurrogate(doc, pos) {
  let $pos = doc.resolve(pos), t = $pos.textOffset
  if (!t) return false
  let code = $pos.parent.child($pos.index()).text.charCodeAt(t - 1)
  return code >= 0xd800 && code <= 0xdbff
}

function peer(id) {
  let p = peers.get(id)
  if (!p) throw new Error("no peer " + id)
  return p
}

// What ySyncPlugin's _typeChanged does: replace the whole document with the
// content built from Yjs. tr.replace fills in required content (an empty
// fragment becomes an empty paragraph), as in a real editor.
function refresh(p) {
  let {doc, meta} = initProseMirrorDoc(p.ydoc.getXmlFragment(FRAGMENT), p.schema)
  if (p.doc) {
    let tr = EditorState.create({doc: p.doc}).tr.replace(0, p.doc.content.size, new Slice(Fragment.from(doc.content), 0, 0))
    doc = tr.doc
  }
  p.doc = doc
  p.meta = meta
}

export const ysyncHandlers = schemaFor => ({
  // A whole document as a Yjs update, as an editor seeds a new document.
  yEncodeDoc({schema, doc}) {
    let ydoc = prosemirrorJSONToYDoc(schemaFor(schema), doc, FRAGMENT)
    return b64.encode(Y.encodeStateAsUpdate(ydoc))
  },

  // The ProseMirror document a Yjs update decodes to.
  yDecodeDoc({schema, update}) {
    let ydoc = new Y.Doc()
    Y.applyUpdate(ydoc, b64.decode(update))
    return yXmlFragmentToProseMirrorRootNode(ydoc.getXmlFragment(FRAGMENT), schemaFor(schema)).toJSON()
  },

  randomDocs({schema, seed, count}) {
    let s = schemaFor(schema), out = []
    for (let i = 0; i < count; i++) out.push(randomDoc(s, seed + i, {astral: true}).toJSON())
    return out
  },

  yPeerCreate({schema, id, clientID}) {
    let ydoc = new Y.Doc()
    ydoc.clientID = clientID
    let p = {ydoc, schema: schemaFor(schema), doc: null, meta: null, outbox: []}
    ydoc.on("update", update => p.outbox.push(b64.encode(update)))
    peers.set(id, p)
    refresh(p)
    return null
  },

  yPeerDestroy({id}) { peers.delete(id); return null },

  yPeerApply({id, updates}) {
    let p = peer(id)
    Y.transact(p.ydoc, () => { for (let u of updates) Y.applyUpdate(p.ydoc, b64.decode(u), "remote") })
    refresh(p)
    return p.doc.toJSON()
  },

  // Updates this peer produced since the last call.
  yPeerTakeUpdates({id}) {
    let p = peer(id), out = p.outbox
    p.outbox = []
    return out
  },

  yPeerStateVector({id}) { return b64.encode(Y.encodeStateVector(peer(id).ydoc)) },
  yPeerDiff({id, stateVector}) { return b64.encode(Y.encodeStateAsUpdate(peer(id).ydoc, stateVector ? b64.decode(stateVector) : undefined)) },

  yPeerDoc({id}) { return peer(id).doc.toJSON() },

  // Debugging: the raw Yjs content (elements, attributes, text deltas).
  yPeerDump({id}) {
    const dump = t => t instanceof Y.XmlText ? {delta: t.toDelta()} : {name: t.nodeName, attrs: t.getAttributes ? t.getAttributes() : null, children: t.toArray().map(dump)}
    return dump(peer(id).ydoc.getXmlFragment(FRAGMENT))
  },

  // Replace the peer's document (a local edit), syncing it into Yjs.
  yPeerSetDoc({id, doc}) {
    let p = peer(id)
    let node = Node.fromJSON(p.schema, doc)
    p.ydoc.transact(() => updateYFragment(p.ydoc, p.ydoc.getXmlFragment(FRAGMENT), node, p.meta))
    p.doc = node
    return null
  },

  // Random local typing/deleting/formatting, each synced like an editor transaction.
  yPeerRandomEdits({id, seed, count}) {
    let p = peer(id), r = rng(seed)
    for (let i = 0; i < count; i++) {
      let state = EditorState.create({doc: p.doc})
      let size = p.doc.content.size
      let a = r.int(size + 1), b = r.chance(0.6) ? a : r.int(size + 1)
      // Editors never put the caret inside a surrogate pair.
      if (splitsSurrogate(p.doc, a) || splitsSurrogate(p.doc, b)) continue
      let sel = TextSelection.between(p.doc.resolve(Math.min(a, b)), p.doc.resolve(Math.max(a, b)))
      let tr = state.tr.setSelection(sel)
      let roll = r.next()
      try {
        if (roll < 0.5) tr.insertText(r.pick(["a", "bc", " ", "é", "😀", "xyz"]))
        else if (roll < 0.75) tr.deleteSelection()
        else {
          let marks = Object.values(p.schema.marks).filter(m => !m.spec.attrs || Object.values(m.spec.attrs).every(a => "default" in a))
          if (marks.length && !sel.empty) {
            let m = r.pick(marks)
            if (r.chance(0.5)) tr.addMark(sel.from, sel.to, m.create())
            else tr.removeMark(sel.from, sel.to, m)
          } else {
            tr.split(sel.from)
          }
        }
      } catch (e) { continue }
      if (!tr.docChanged) continue
      p.ydoc.transact(() => updateYFragment(p.ydoc, p.ydoc.getXmlFragment(FRAGMENT), tr.doc, p.meta))
      p.doc = tr.doc
    }
    return p.doc.toJSON()
  },
})
