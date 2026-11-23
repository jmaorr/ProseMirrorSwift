#if os(macOS)
import AppKit
import PMState

/// Mac virtual key codes for keys whose DOM `key` is a name, with their DOM keyCodes.
private let namedKeys: [UInt16: (String, Int)] = [
    36: ("Enter", 13), 76: ("Enter", 13), 48: ("Tab", 9), 51: ("Backspace", 8), 117: ("Delete", 46),
    53: ("Escape", 27), 123: ("ArrowLeft", 37), 124: ("ArrowRight", 39), 125: ("ArrowDown", 40),
    126: ("ArrowUp", 38), 115: ("Home", 36), 119: ("End", 35), 116: ("PageUp", 33), 121: ("PageDown", 34),
    49: (" ", 32),
]

/// Mac virtual key codes (ANSI layout positions) to DOM keyCodes.
private let domKeyCodes: [UInt16: Int] = {
    var map: [UInt16: Int] = [
        24: 187, 27: 189, 30: 221, 33: 219, 39: 222, 41: 186, 42: 220, 43: 188, 44: 191, 47: 190, 50: 192,
    ]
    let letters: [(UInt16, Character)] = [
        (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"), (38, "J"),
        (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"),
        (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
    ]
    for (code, ch) in letters { map[code] = Int(ch.asciiValue!) }
    let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
    for (d, code) in digits.enumerated() { map[code] = 48 + d }
    return map
}()

public extension KeyEvent {
    /// The DOM-style key event a browser on macOS would report for this NSEvent.
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift), alt = flags.contains(.option)
        let ctrl = flags.contains(.control), meta = flags.contains(.command)
        if let (name, code) = namedKeys[event.keyCode] {
            self.init(key: name, keyCode: code, shiftKey: shift, altKey: alt, ctrlKey: ctrl, metaKey: meta)
            return
        }
        // With Cmd/Ctrl, browsers report the unmodified (but shifted) character.
        var key = (meta || ctrl ? event.charactersIgnoringModifiers : event.characters) ?? ""
        if key.isEmpty { key = "Dead" }
        self.init(key: key, keyCode: domKeyCodes[event.keyCode] ?? 0, shiftKey: shift, altKey: alt, ctrlKey: ctrl, metaKey: meta)
    }
}
#endif
