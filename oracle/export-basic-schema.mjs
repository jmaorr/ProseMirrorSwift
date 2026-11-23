// Writes fixtures/schemas/basic.json: prosemirror-schema-basic + list nodes.
import {writeFileSync} from "fs"
import {schema} from "prosemirror-schema-basic"
import {addListNodes} from "prosemirror-schema-list"
import {specToJSON} from "./src/specjson.js"

let nodes = addListNodes(schema.spec.nodes, "paragraph block*", "block")
let json = specToJSON({nodes, marks: schema.spec.marks})
writeFileSync(new URL("../fixtures/schemas/basic.json", import.meta.url), JSON.stringify(json, null, 2) + "\n")
console.log("wrote basic.json:", json.nodes.map(n => n[0]).join(","), "|", json.marks.map(m => m[0]).join(","))
