// Port of prosemirror-keymap/src/keymap.ts and the parts of w3c-keyname it uses.
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import PMState

/// Platform flags. "Mod" means Cmd on Mac (default on Apple platforms), Ctrl elsewhere.
public enum KeymapPlatform {
    #if os(macOS) || os(iOS) || os(visionOS)
    nonisolated(unsafe) public static var mac = true
    #else
    nonisolated(unsafe) public static var mac = false
    #endif
    nonisolated(unsafe) public static var windows = false
}

// MARK: w3c-keyname

public let keyNameBase: [Int: String] = {
    var base: [Int: String] = [
        8: "Backspace", 9: "Tab", 10: "Enter", 12: "NumLock", 13: "Enter", 16: "Shift", 17: "Control", 18: "Alt",
        20: "CapsLock", 27: "Escape", 32: " ", 33: "PageUp", 34: "PageDown", 35: "End", 36: "Home",
        37: "ArrowLeft", 38: "ArrowUp", 39: "ArrowRight", 40: "ArrowDown", 44: "PrintScreen", 45: "Insert",
        46: "Delete", 59: ";", 61: "=", 91: "Meta", 92: "Meta", 106: "*", 107: "+", 108: ",", 109: "-",
        110: ".", 111: "/", 144: "NumLock", 145: "ScrollLock", 160: "Shift", 161: "Shift", 162: "Control",
        163: "Control", 164: "Alt", 165: "Alt", 173: "-", 186: ";", 187: "=", 188: ",", 189: "-", 190: ".",
        191: "/", 192: "`", 219: "[", 220: "\\", 221: "]", 222: "'",
    ]
    for i in 0..<10 { base[48 + i] = String(i); base[96 + i] = String(i) }
    for i in 1...24 { base[i + 111] = "F\(i)" }
    for i in 65...90 { base[i] = String(UnicodeScalar(UInt8(i + 32))) }
    return base
}()

public let keyNameShift: [Int: String] = {
    var shift: [Int: String] = [
        48: ")", 49: "!", 50: "@", 51: "#", 52: "$", 53: "%", 54: "^", 55: "&", 56: "*", 57: "(", 59: ":",
        61: "+", 173: "_", 186: ":", 187: "+", 188: "<", 189: "_", 190: ">", 191: "?", 192: "~", 219: "{",
        220: "|", 221: "}", 222: "\"",
    ]
    for i in 65...90 { shift[i] = String(UnicodeScalar(UInt8(i))) }
    for (code, name) in keyNameBase where shift[code] == nil { shift[code] = name }
    return shift
}()

/// Name of a key event, like w3c-keyname's `keyName`.
public func keyName(_ event: KeyEvent) -> String {
    let ignoreKey = KeymapPlatform.mac && event.metaKey && event.shiftKey && !event.ctrlKey && !event.altKey ||
        event.key == "Unidentified"
    var name: String
    if !ignoreKey && !event.key.isEmpty {
        name = event.key
    } else if let n = (event.shiftKey ? keyNameShift : keyNameBase)[event.keyCode] {
        name = n
    } else {
        name = event.key.isEmpty ? "Unidentified" : event.key
    }
    switch name {
    case "Esc": name = "Escape"
    case "Del": name = "Delete"
    case "Left": name = "ArrowLeft"
    case "Up": name = "ArrowUp"
    case "Right": name = "ArrowRight"
    case "Down": name = "ArrowDown"
    default: break
    }
    return name
}

// MARK: keymap

func normalizeKeyName(_ name: String) -> String {
    // split(/-(?!$)/): split on dashes that aren't the last character
    var parts: [String] = []
    var cur = ""
    let chars = Array(name)
    for (i, c) in chars.enumerated() {
        if c == "-" && i != chars.count - 1 {
            parts.append(cur)
            cur = ""
        } else {
            cur.append(c)
        }
    }
    parts.append(cur)
    var result = parts.last!
    if result == "Space" { result = " " }
    var alt = false, ctrl = false, shift = false, meta = false
    for mod in parts.dropLast() {
        switch mod.lowercased() {
        case "cmd", "meta", "m": meta = true
        case "a", "alt": alt = true
        case "c", "ctrl", "control": ctrl = true
        case "s", "shift": shift = true
        case "mod": if KeymapPlatform.mac { meta = true } else { ctrl = true }
        default: preconditionFailure("Unrecognized modifier name: \(mod)")
        }
    }
    if alt { result = "Alt-" + result }
    if ctrl { result = "Ctrl-" + result }
    if meta { result = "Meta-" + result }
    if shift { result = "Shift-" + result }
    return result
}

private func modifiers(_ name: String, _ event: KeyEvent, shift: Bool = true) -> String {
    var name = name
    if event.altKey { name = "Alt-" + name }
    if event.ctrlKey { name = "Ctrl-" + name }
    if event.metaKey { name = "Meta-" + name }
    if shift && event.shiftKey { name = "Shift-" + name }
    return name
}

/// Create a keymap plugin for the given set of bindings.
public func keymap(_ bindings: [String: Command]) -> Plugin {
    Plugin(PluginSpec(props: EditorProps(handleKeyDown: keydownHandler(bindings))))
}

/// Given a set of bindings, return a keydown handler.
public func keydownHandler(_ bindings: [String: Command]) -> (EditorView, KeyEvent) -> Bool {
    var map: [String: Command] = [:]
    for (k, v) in bindings { map[normalizeKeyName(k)] = v }
    return { view, event in
        // A command error aborts handling of the event (an exception in JS); report it as handled.
        let errors = CommandErrors.errorCount
        func run(_ command: Command) -> Bool {
            command(view.state, view.dispatch, view) || CommandErrors.errorCount != errors
        }
        let name = keyName(event)
        if let direct = map[modifiers(name, event)], run(direct) { return true }
        if name.utf16.count == 1 && name != " " {
            var fromCode: Command?
            if (event.altKey || event.metaKey || event.ctrlKey) && !(KeymapPlatform.windows && event.ctrlKey && event.altKey),
               let baseName = keyNameBase[event.keyCode], baseName != name {
                fromCode = map[modifiers(baseName, event)]
            }
            // Departure from prosemirror-keymap: an explicit Shift binding spelled with the
            // unshifted key (`Mod-Shift-b`, Quote) wins over a shift-less spelling of the shifted
            // name (`Mod-B`, the Caps Lock alias of Bold), which upstream tries first.
            if event.shiftKey, let fromCode, run(fromCode) { return true }
            if event.shiftKey, let noShift = map[modifiers(name, event, shift: false)], run(noShift) {
                return true
            }
            if !event.shiftKey, let fromCode, run(fromCode) { return true }
        }
        return false
    }
}
