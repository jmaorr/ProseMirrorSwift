#if canImport(UIKit) && !os(macOS)
import UIKit
import PMState

/// A keymap binding the app wants listed in the ⌘-hold shortcut overlay and the iPadOS menu
/// bar: `binding` is a keymap name ("Mod-Shift-8"), `title` what the overlay shows.
public struct ShortcutCommand: Equatable {
    public var title: String
    public var binding: String
    public init(title: String, binding: String) {
        self.title = title
        self.binding = binding
    }

    /// The parts of the binding: its key, and the modifiers (Mod is ⌘).
    var keyAndModifiers: (key: String, modifiers: UIKeyModifierFlags)? {
        var parts = binding.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        // "Mod--" would be the minus key; the last part is the key unless it is empty.
        guard var key = parts.popLast() else { return nil }
        if key.isEmpty, !parts.isEmpty { key = "-"; parts.removeLast() }
        var flags: UIKeyModifierFlags = []
        for part in parts {
            switch part.lowercased() {
            case "mod", "meta", "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option": flags.insert(.alternate)
            case "ctrl", "control": flags.insert(.control)
            default: return nil
            }
        }
        return key.isEmpty ? nil : (key, flags)
    }

    /// The key event a hardware keyboard would report for this shortcut.
    var keyEvent: KeyEvent? {
        guard let (key, flags) = keyAndModifiers else { return nil }
        // With ⌘ or Ctrl, a shifted letter is reported upper case (see `KeyEvent.init(_: UIKey)`).
        let name = flags.contains(.shift) && key.count == 1 ? key.uppercased() : key
        return .named(name, modifiers: flags)
    }

    /// Whether a hardware press is this shortcut's chord.
    func matches(_ event: KeyEvent) -> Bool {
        guard let mine = keyEvent else { return false }
        return mine.key.lowercased() == event.key.lowercased() && mine.shiftKey == event.shiftKey
            && mine.altKey == event.altKey && mine.ctrlKey == event.ctrlKey && mine.metaKey == event.metaKey
    }
}

extension ProseTextView {
    /// One `UIKeyCommand` per shortcut, each with a discoverability title, so ⌘-hold lists them
    /// and the responder chain offers them to the menu bar. Pressing one runs the same keymap
    /// binding a hardware key press would.
    public override var keyCommands: [UIKeyCommand]? {
        let commands: [UIKeyCommand] = shortcutCommands.compactMap { shortcut in
            guard let (key, flags) = shortcut.keyAndModifiers else { return nil }
            let command = UIKeyCommand(title: shortcut.title, image: nil, action: #selector(performShortcut(_:)),
                                       input: key.lowercased(), modifierFlags: flags,
                                       propertyList: shortcut.binding, alternates: [],
                                       discoverabilityTitle: shortcut.title, attributes: [], state: .off)
            // Only the standard text-format chords take priority over the system's own.
            command.wantsPriorityOverSystemBehavior = flags == .command && ["b", "i", "u"].contains(key.lowercased())
            return command
        }
        return (super.keyCommands ?? []) + commands
    }

    @objc func performShortcut(_ sender: UIKeyCommand) {
        guard let binding = sender.propertyList as? String,
              let shortcut = shortcutCommands.first(where: { $0.binding == binding }) else { return }
        _ = runShortcut(shortcut)
    }

    /// Run the registered shortcut with this keymap binding ("Mod-b"), as its key command would;
    /// for the app's Format menu. Returns whether a command took it.
    @discardableResult
    public func runShortcut(binding: String) -> Bool {
        guard let shortcut = shortcutCommands.first(where: { $0.binding == binding }) else { return false }
        return runShortcut(shortcut)
    }

    /// Runs a shortcut through the keymap.
    func runShortcut(_ shortcut: ShortcutCommand) -> Bool {
        guard let event = shortcut.keyEvent else { return false }
        commitComposition()
        return handleKeyDown(event)
    }
}
#endif
