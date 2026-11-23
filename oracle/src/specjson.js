// Convert a ProseMirror SchemaSpec (or a Schema's spec) into plain JSON.
// Functions (parseDOM/toDOM/leafText/...) and DOM rules are dropped; only the
// properties that affect model behaviour are kept. Node and mark order is
// preserved as arrays of [name, spec] pairs, since order is semantically
// significant (mark rank, default block type, attribute order).
const DROP = new Set(["parseDOM", "toDOM", "toDebugString"])

function clean(value) {
  if (typeof value === "function") return undefined
  if (Array.isArray(value)) return value.map(clean)
  if (value && typeof value === "object") {
    let out = {}
    for (let key of Object.keys(value)) {
      if (DROP.has(key)) continue
      let v = clean(value[key])
      if (v !== undefined) out[key] = v
    }
    return out
  }
  return value
}

function pairs(map) {
  let out = []
  if (map && typeof map.forEach === "function" && !Array.isArray(map) && map.constructor && map.constructor.name !== "Object")
    map.forEach((name, spec) => out.push([name, clean(spec)]))
  else for (let name of Object.keys(map || {})) out.push([name, clean(map[name])])
  return out
}

export function specToJSON(spec) {
  let json = {nodes: pairs(spec.nodes), marks: pairs(spec.marks || {})}
  if (spec.topNode) json.topNode = spec.topNode
  return json
}

// Inverse: build a SchemaSpec object from the JSON form.
export function specFromJSON(json) {
  let nodes = {}, marks = {}
  for (let [name, spec] of json.nodes) nodes[name] = spec
  for (let [name, spec] of json.marks) marks[name] = spec
  let spec = {nodes, marks}
  if (json.topNode) spec.topNode = json.topNode
  return spec
}
