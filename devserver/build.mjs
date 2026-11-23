import {build} from "esbuild"
await build({
  entryPoints: [new URL("./web/client.js", import.meta.url).pathname],
  bundle: true,
  format: "esm",
  outfile: new URL("./web/dist/client.js", import.meta.url).pathname,
})
console.log("built web/dist/client.js")
