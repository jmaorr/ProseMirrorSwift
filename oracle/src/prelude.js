// JavaScriptCore has no browser globals. prosemirror-keymap reads
// navigator.platform at load time to decide what "Mod" means; pretend to be a
// Mac so Mod = Meta (Cmd), matching the Swift port's default on Apple platforms.
if (typeof globalThis.navigator == "undefined") globalThis.navigator = {platform: "MacIntel", userAgent: "JavaScriptCore"}
if (typeof globalThis.console == "undefined") globalThis.console = {log() {}, warn() {}, error() {}}
// lib0 (Yjs) reads crypto.getRandomValues at load time for client IDs. A seeded
// stand-in keeps runs reproducible; tests pick client IDs explicitly anyway.
if (typeof globalThis.crypto == "undefined") {
  let seed = 0x2545f491
  globalThis.crypto = {
    getRandomValues(arr) {
      for (let i = 0; i < arr.length; i++) { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; arr[i] = seed >>> 0 }
      return arr
    },
    subtle: {},
  }
}
