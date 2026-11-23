#if canImport(UIKit) && !os(macOS)
import UIKit
import PMState

/// HID usages for keys whose DOM `key` is a name, with their DOM keyCodes.
private let namedKeys: [UIKeyboardHIDUsage: (String, Int)] = [
    .keyboardReturnOrEnter: ("Enter", 13), .keypadEnter: ("Enter", 13), .keyboardTab: ("Tab", 9),
    .keyboardDeleteOrBackspace: ("Backspace", 8), .keyboardDeleteForward: ("Delete", 46), .keyboardEscape: ("Escape", 27),
    .keyboardLeftArrow: ("ArrowLeft", 37), .keyboardRightArrow: ("ArrowRight", 39), .keyboardDownArrow: ("ArrowDown", 40),
    .keyboardUpArrow: ("ArrowUp", 38), .keyboardHome: ("Home", 36), .keyboardEnd: ("End", 35),
    .keyboardPageUp: ("PageUp", 33), .keyboardPageDown: ("PageDown", 34), .keyboardSpacebar: (" ", 32),
]

/// HID usages (US layout positions) to DOM keyCodes, for letters, digits and punctuation.
private func domKeyCode(_ usage: UIKeyboardHIDUsage) -> Int {
    let raw = usage.rawValue
    if raw >= UIKeyboardHIDUsage.keyboardA.rawValue && raw <= UIKeyboardHIDUsage.keyboardZ.rawValue {
        return 65 + raw - UIKeyboardHIDUsage.keyboardA.rawValue
    }
    if raw >= UIKeyboardHIDUsage.keyboard1.rawValue && raw <= UIKeyboardHIDUsage.keyboard9.rawValue {
        return 49 + raw - UIKeyboardHIDUsage.keyboard1.rawValue
    }
    switch usage {
    case .keyboard0: return 48
    case .keyboardEqualSign: return 187
    case .keyboardHyphen: return 189
    case .keyboardCloseBracket: return 221
    case .keyboardOpenBracket: return 219
    case .keyboardQuote: return 222
    case .keyboardSemicolon: return 186
    case .keyboardBackslash: return 220
    case .keyboardComma: return 188
    case .keyboardSlash: return 191
    case .keyboardPeriod: return 190
    case .keyboardGraveAccentAndTilde: return 192
    default: return 0
    }
}

public extension KeyEvent {
    /// The DOM-style key event a browser on iPadOS would report for this hardware key.
    init(_ key: UIKey) {
        let flags = key.modifierFlags
        let shift = flags.contains(.shift), alt = flags.contains(.alternate)
        let ctrl = flags.contains(.control), meta = flags.contains(.command)
        if let (name, code) = namedKeys[key.keyCode] {
            self.init(key: name, keyCode: code, shiftKey: shift, altKey: alt, ctrlKey: ctrl, metaKey: meta)
            return
        }
        // With Cmd/Ctrl, browsers report the unmodified (but shifted) character.
        var name = meta || ctrl ? key.charactersIgnoringModifiers : key.characters
        if meta || ctrl, shift { name = name.uppercased() }
        if name.isEmpty { name = "Dead" }
        self.init(key: name, keyCode: domKeyCode(key.keyCode), shiftKey: shift, altKey: alt, ctrlKey: ctrl, metaKey: meta)
    }

    /// A key a software keyboard or the edit menu stands for (Return, Backspace, ⌘B), with the
    /// hardware modifiers held at the time, if any.
    static func named(_ key: String, modifiers: UIKeyModifierFlags = []) -> KeyEvent {
        let code: Int
        switch key {
        case "Enter": code = 13
        case "Backspace": code = 8
        case "Tab": code = 9
        case "Delete": code = 46
        case "Escape": code = 27
        default: code = key.count == 1 ? Int(key.uppercased().unicodeScalars.first!.value) : 0
        }
        return KeyEvent(key: key, keyCode: code, shiftKey: modifiers.contains(.shift), altKey: modifiers.contains(.alternate),
                        ctrlKey: modifiers.contains(.control), metaKey: modifiers.contains(.command))
    }
}
#endif
