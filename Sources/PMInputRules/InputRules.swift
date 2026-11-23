// Port of prosemirror-inputrules (inputrules.ts, rulebuilders.ts, rules.ts)
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import Foundation
import PMModel
import PMTransform
import PMState

/// A regex match over UTF-16 text, mirroring a JS `RegExpMatchArray`.
public struct InputRuleMatch {
    /// Groups; index 0 is the whole match. nil = group did not participate (JS `undefined`).
    public let groups: [String?]
    public subscript(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
}

/// Input rules are regular expressions describing a piece of text that, when
/// typed, causes something to happen. Patterns use NSRegularExpression (ICU)
/// syntax, which agrees with JS for the patterns used here; positions and
/// lengths are UTF-16 like JS.
public final class InputRule {
    public let match: NSRegularExpression
    public let handler: (EditorState, InputRuleMatch, Int, Int) -> Transaction?
    public let undoable: Bool
    /// false, true or "only" in JS; nil = false.
    public let inCode: InCode
    public let inCodeMark: Bool

    public enum InCode { case no, yes, only }

    public init(_ pattern: String, handler: @escaping (EditorState, InputRuleMatch, Int, Int) -> Transaction?,
                undoable: Bool = true, inCode: InCode = .no, inCodeMark: Bool = true) {
        match = try! NSRegularExpression(pattern: pattern)
        self.handler = handler
        self.undoable = undoable
        self.inCode = inCode
        self.inCodeMark = inCodeMark
    }

    /// A rule that replaces the matched text (or, if the regex has a group, the group) with `string`.
    public convenience init(_ pattern: String, string: String, undoable: Bool = true, inCode: InCode = .no, inCodeMark: Bool = true) {
        self.init(pattern, handler: stringHandler(string), undoable: undoable, inCode: inCode, inCodeMark: inCodeMark)
    }

    func exec(_ text: String) -> InputRuleMatch? {
        let ns = text as NSString
        guard let m = match.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        return InputRuleMatch(groups: groups)
    }
}

private func u16(_ s: String) -> Int { s.utf16.count }

private func stringHandler(_ string: String) -> (EditorState, InputRuleMatch, Int, Int) -> Transaction? {
    return { state, match, start, end in
        var insert = string
        var start = start
        if let g1 = match[1], !g1.isEmpty {
            let m0 = match[0]! as NSString
            let offset = m0.range(of: g1, options: .backwards).location
            insert += m0.substring(from: offset + u16(g1))
            start += offset
            let cutOff = start - end
            if cutOff > 0 {
                insert = m0.substring(with: NSRange(location: offset - cutOff, length: cutOff)) + insert
                start = end
            }
        }
        return try? state.tr.insertText(insert, start, end)
    }
}

let MAX_MATCH = 500

/// Plugin state of the input rules plugin: the last applied undoable rule.
public struct InputRuleUndoState {
    public let transform: Transaction
    public let from: Int
    public let to: Int
    public let text: String
}

/// Create an input rules plugin.
public func inputRules(_ rules: [InputRule]) -> Plugin {
    final class Box { var plugin: Plugin! }
    let box = Box()
    let plugin = Plugin(PluginSpec(
        props: EditorProps(handleTextInput: { view, from, to, text in
            run(view, from, to, text, rules, box.plugin)
        }),
        state: StateField(init: { _, _ in nil }, apply: { tr, prev, _, _ in
            if let stored = tr.getMeta(box.plugin) as? InputRuleUndoState { return stored }
            return tr.selectionSet || tr.docChanged ? nil : prev
        }),
        extra: ["isInputRules": true]))
    box.plugin = plugin
    return plugin
}

/// Run input rules for text typed at a cursor; used after IME composition end (`text` = "").
@discardableResult
public func runInputRules(_ view: EditorView, _ from: Int, _ to: Int, _ text: String, plugin: Plugin, rules: [InputRule]) -> Bool {
    run(view, from, to, text, rules, plugin)
}

private func run(_ view: EditorView, _ from: Int, _ to: Int, _ text: String, _ rules: [InputRule], _ plugin: Plugin) -> Bool {
    if view.composing { return false }
    let state = view.state, rFrom = state.doc.resolve(from)
    let textBefore = rFrom.parent.textBetween(max(0, rFrom.parentOffset - MAX_MATCH), rFrom.parentOffset,
                                              blockSeparator: nil, leafText: "\u{fffc}") + text
    for rule in rules {
        if !rule.inCodeMark && rFrom.marks().contains(where: { $0.type.spec.code }) { continue }
        if rFrom.parent.type.spec.code {
            if rule.inCode == .no { continue }
        } else if rule.inCode == .only {
            continue
        }
        guard let match = rule.exec(textBefore), u16(match[0]!) >= u16(text) else { continue }
        let startPos = from - (u16(match[0]!) - u16(text))
        if !rule.inCodeMark {
            var hasMark = false
            state.doc.nodesBetween(startPos, rFrom.pos) { node, _, _, _ in
                if node.isInline && node.marks.contains(where: { $0.type.spec.code }) { hasMark = true }
                return true
            }
            if hasMark { continue }
        }
        guard let tr = rule.handler(state, match, startPos, to) else { continue }
        if rule.undoable { tr.setMeta(plugin, InputRuleUndoState(transform: tr, from: from, to: to, text: text)) }
        view.dispatch(tr)
        return true
    }
    return false
}

/// Undo an input rule that was applied in the most recent transaction.
public let undoInputRule: Command = { state, dispatch, _ in
    for plugin in state.plugins {
        guard plugin.spec.extra["isInputRules"] as? Bool == true, let undoable = plugin.getState(state) as? InputRuleUndoState else { continue }
        if let dispatch {
            let tr = state.tr, toUndo = undoable.transform
            do {
                for j in stride(from: toUndo.steps.count - 1, through: 0, by: -1) {
                    try tr.step(toUndo.steps[j].invert(toUndo.docs[j]))
                }
                if !undoable.text.isEmpty {
                    let marks = tr.doc.resolve(undoable.from).marks()
                    try tr.replaceWith(undoable.from, undoable.to, state.schema.text(undoable.text, marks))
                } else {
                    try tr.delete(undoable.from, undoable.to)
                }
            } catch { return false }
            dispatch(tr)
        }
        return true
    }
    return false
}

// MARK: - Rule builders

/// Build an input rule for automatically wrapping a textblock when a given string is typed.
public func wrappingInputRule(_ pattern: String, _ nodeType: NodeType, _ getAttrs: ((InputRuleMatch) -> Attrs?)? = nil,
                              joinPredicate: ((InputRuleMatch, Node) -> Bool)? = nil) -> InputRule {
    InputRule(pattern, handler: { state, match, start, end in
        let attrs = getAttrs?(match)
        guard let tr = try? state.tr.delete(start, end) else { return nil }
        let rStart = tr.doc.resolve(start)
        guard let range = rStart.blockRange(), let wrapping = findWrapping(range, nodeType, attrs) else { return nil }
        guard (try? tr.wrap(range, wrapping)) != nil else { return nil }
        let before = tr.doc.resolve(start - 1).nodeBefore
        if let before, before.type === nodeType, canJoin(tr.doc, start - 1), joinPredicate?(match, before) ?? true {
            try? tr.join(start - 1)
        }
        return tr
    })
}

/// Build an input rule that changes the type of a textblock when the matched text is typed into it.
public func textblockTypeInputRule(_ pattern: String, _ nodeType: NodeType, _ getAttrs: ((InputRuleMatch) -> Attrs?)? = nil) -> InputRule {
    InputRule(pattern, handler: { state, match, start, end in
        let rStart = state.doc.resolve(start)
        let attrs = getAttrs?(match)
        if !rStart.node(-1).canReplaceWith(rStart.index(-1), rStart.indexAfter(-1), nodeType) { return nil }
        return try? state.tr.delete(start, end).setBlockType(start, start, nodeType, attrs)
    })
}

// MARK: - Predefined rules

public let emDash = InputRule("--$", string: "—", inCodeMark: false)
public let ellipsis = InputRule("\\.\\.\\.$", string: "…", inCodeMark: false)
public let openDoubleQuote = InputRule("(?:^|[\\s\\{\\[\\(\\<'\"\\u2018\\u201C])(\")$", string: "“", inCodeMark: false)
public let closeDoubleQuote = InputRule("\"$", string: "”", inCodeMark: false)
public let openSingleQuote = InputRule("(?:^|[\\s\\{\\[\\(\\<'\"\\u2018\\u201C])(')$", string: "‘", inCodeMark: false)
public let closeSingleQuote = InputRule("'$", string: "’", inCodeMark: false)
public let smartQuotes = [openDoubleQuote, closeDoubleQuote, openSingleQuote, closeSingleQuote]
