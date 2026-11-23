// Bundles the oracle harness into a single IIFE (global `PMOracle`) that the
// Swift tests load into JavaScriptCore. Output is committed so `swift test`
// works without Node installed.
import {build} from "esbuild"
await build({
  entryPoints: [new URL("./src/harness.js", import.meta.url).pathname],
  bundle: true,
  format: "iife",
  globalName: "PMOracle",
  target: "es2019",
  outfile: new URL("./dist/oracle.js", import.meta.url).pathname,
  legalComments: "inline",
})
console.log("built oracle/dist/oracle.js")
