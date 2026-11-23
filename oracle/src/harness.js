import "./prelude.js"
import {Schema, Node} from "prosemirror-model"
import {specFromJSON} from "./specjson.js"
import {modelCase, invalidCase, probeSchema} from "./model.js"
import {transformCase} from "./transform.js"
import {runScenario, randomSession} from "./scenarios.js"
import {ysyncHandlers} from "./ysync.js"
import {tableHandlers} from "./tables.js"
import {markdownHandlers} from "./markdown.js"

const schemaCache = new Map()
export function schemaFor(json) {
  let key = typeof json == "string" ? json : JSON.stringify(json)
  let schema = schemaCache.get(key)
  if (!schema) {
    schema = new Schema(specFromJSON(typeof json == "string" ? JSON.parse(json) : json))
    schemaCache.set(key, schema)
  }
  return schema
}

export const handlers = {
  ping() { return "pong" },

  // Parse a doc from JSON, check it, serialize it back.
  roundTrip({schema, doc}) {
    let node = Node.fromJSON(schemaFor(schema), doc)
    node.check()
    return {doc: node.toJSON(), size: node.content.size, text: node.textContent}
  },

  modelCases({schema, seed, count}) {
    let s = schemaFor(schema), out = []
    for (let i = 0; i < count; i++) out.push(modelCase(s, seed + i))
    return out
  },

  invalidCases({schema, seed, count}) {
    let s = schemaFor(schema), out = []
    for (let i = 0; i < count; i++) out.push(invalidCase(s, seed + i))
    return out
  },

  transformCases({schema, seed, count, ops}) {
    let s = schemaFor(schema), out = []
    for (let i = 0; i < count; i++) out.push(transformCase(s, seed + i, ops))
    return out
  },

  randomSessions({schema, seed, count, steps}) {
    let s = schemaFor(schema), out = []
    for (let i = 0; i < count; i++) out.push(randomSession(s, seed + i, steps))
    return out
  },

  runScenario({schema, scenario}) { return runScenario(schemaFor(schema), scenario) },

  probeSchema({schema}) { return probeSchema(schemaFor(schema)) },

  ...ysyncHandlers(schemaFor),
  ...markdownHandlers(schemaFor),

  ...tableHandlers(schemaFor),

  schemaError({schema}) {
    try { schemaFor(schema); return null } catch (e) { return String(e.message) }
  },
}

// Single entry point used from Swift: name + JSON args in, JSON string out.
// Errors come back as {error: message} so Swift can compare failure parity.
export function call(name, argsJSON) {
  let fn = handlers[name]
  if (!fn) return JSON.stringify({error: "unknown handler " + name})
  try {
    return JSON.stringify({ok: fn(argsJSON ? JSON.parse(argsJSON) : {})})
  } catch (e) {
    return JSON.stringify({error: String(e && e.message || e)})
  }
}
