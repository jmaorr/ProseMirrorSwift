// A local y-websocket relay: one in-memory Y.Doc per room, relayed over the
// y-websocket protocol (what y-websocket and y-partyserver servers speak), plus the
// browser editor from web/. No auth, no persistence.
//
//   npm start            then open http://localhost:1234/?room=demo
//   PORT=4000 npm start
import http from "node:http"
import fs from "node:fs"
import path from "node:path"
import {WebSocketServer} from "ws"
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as awarenessProtocol from "y-protocols/awareness"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"

const PORT = Number(process.env.PORT || 1234)
// Loopback only by default: the relay has no auth. HOST=0.0.0.0 shares it on your network.
const HOST = process.env.HOST || "127.0.0.1"
const MAX_ROOMS = 100
const WEB = path.join(path.dirname(new URL(import.meta.url).pathname), "web")
const MESSAGE_SYNC = 0, MESSAGE_AWARENESS = 1

const rooms = new Map()

function room(name) {
  let r = rooms.get(name)
  if (r) return r
  if (rooms.size >= MAX_ROOMS) return null
  const doc = new Y.Doc()
  const awareness = new awarenessProtocol.Awareness(doc)
  awareness.setLocalState(null)
  r = {doc, awareness, conns: new Set()}
  doc.on("update", (update, origin) => {
    const e = encoding.createEncoder()
    encoding.writeVarUint(e, MESSAGE_SYNC)
    syncProtocol.writeUpdate(e, update)
    const msg = encoding.toUint8Array(e)
    // Every connection, the sender too, as y-partyserver does.
    for (const c of r.conns) send(c, msg)
  })
  awareness.on("update", ({added, updated, removed}, origin) => {
    const changed = added.concat(updated, removed)
    const e = encoding.createEncoder()
    encoding.writeVarUint(e, MESSAGE_AWARENESS)
    encoding.writeVarUint8Array(e, awarenessProtocol.encodeAwarenessUpdate(awareness, changed))
    const msg = encoding.toUint8Array(e)
    for (const c of r.conns) send(c, msg)
  })
  rooms.set(name, r)
  return r
}

function send(conn, msg) {
  if (conn.readyState === 1) conn.send(msg)
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost")
  const file = url.pathname === "/" ? "index.html" : url.pathname.slice(1)
  const full = path.join(WEB, file)
  if (!full.startsWith(WEB) || !fs.existsSync(full)) { res.writeHead(404); return res.end() }
  const type = {".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json"}[path.extname(full)] || "application/octet-stream"
  res.writeHead(200, {"content-type": type})
  fs.createReadStream(full).pipe(res)
})

const wss = new WebSocketServer({server})
wss.on("connection", (conn, req) => {
  const name = new URL(req.url, "http://localhost").pathname.slice(1) || "default"
  const r = room(name)
  if (!r) { conn.close(1013, "too many rooms"); return }
  r.conns.add(conn)
  const clients = new Set()
  conn.binaryType = "arraybuffer"
  conn.on("message", data => {
    const decoder = decoding.createDecoder(new Uint8Array(data))
    const type = decoding.readVarUint(decoder)
    if (type === MESSAGE_SYNC) {
      const e = encoding.createEncoder()
      encoding.writeVarUint(e, MESSAGE_SYNC)
      syncProtocol.readSyncMessage(decoder, e, r.doc, conn)
      if (encoding.length(e) > 1) send(conn, encoding.toUint8Array(e))
    } else if (type === MESSAGE_AWARENESS) {
      const update = decoding.readVarUint8Array(decoder)
      awarenessProtocol.applyAwarenessUpdate(r.awareness, update, conn)
    }
  })
  conn.on("close", () => {
    r.conns.delete(conn)
    awarenessProtocol.removeAwarenessStates(r.awareness, [...clients], null)
  })
  // Sync step 1: ask the client for what we're missing.
  const e = encoding.createEncoder()
  encoding.writeVarUint(e, MESSAGE_SYNC)
  syncProtocol.writeSyncStep1(e, r.doc)
  send(conn, encoding.toUint8Array(e))
  console.log(`[${name}] client connected (${r.conns.size})`)
})

server.listen(PORT, HOST, () => console.log(`devserver on http://localhost:${PORT}  (websocket ws://localhost:${PORT}/<room>)`))
