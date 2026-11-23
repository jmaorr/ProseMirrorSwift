// Port of prosemirror-state/src/transaction.ts, state.ts, plugin.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import Foundation
import PMModel
import PMTransform

// MARK: - View abstraction

/// The parts of an editor view that commands and plugins may use. JS commands
/// receive the real `EditorView`; here any object implementing this protocol
/// (a TextKit view, or a headless test view) can be passed.
public protocol EditorView: AnyObject {
    var state: EditorState { get }
    func dispatch(_ tr: Transaction)
    /// Whether the cursor is at the end of its textblock in the given direction
    /// ("backward"/"forward"/"left"/"right"/"up"/"down").
    func endOfTextblock(_ dir: String, _ state: EditorState?) -> Bool
    /// True while an IME composition is active.
    var composing: Bool { get }
}

public typealias Dispatch = (Transaction) -> Void

/// Commands are functions that take a state and an optional dispatch function
/// (and view). When dispatch is nil they only report applicability.
public typealias Command = (EditorState, Dispatch?, EditorView?) -> Bool

/// A key press, in the shape prosemirror-keymap reads from DOM KeyboardEvents.
public struct KeyEvent {
    public var key: String
    public var keyCode: Int
    public var shiftKey: Bool
    public var altKey: Bool
    public var ctrlKey: Bool
    public var metaKey: Bool

    public init(key: String, keyCode: Int = 0, shiftKey: Bool = false, altKey: Bool = false, ctrlKey: Bool = false, metaKey: Bool = false) {
        self.key = key
        self.keyCode = keyCode
        self.shiftKey = shiftKey
        self.altKey = altKey
        self.ctrlKey = ctrlKey
        self.metaKey = metaKey
    }
}

/// Commands can't throw (their signature is shared with keymaps), but the JS
/// originals can raise exceptions from transform methods in unusual
/// documents. Such errors are caught, recorded here, and the command reports
/// `false`. Like a JS exception, an error aborts `chainCommands` and key
/// handling (see `errorCount`), so no later command runs.
public enum CommandErrors {
    nonisolated(unsafe) public static var last: Error?
    nonisolated(unsafe) public static var handler: ((Error) -> Void)?
    /// Incremented on every caught error; compare before/after running a command.
    nonisolated(unsafe) public static var errorCount = 0

    public static func run(_ body: () throws -> Bool) -> Bool {
        do { return try body() } catch {
            last = error
            errorCount += 1
            handler?(error)
            return false
        }
    }
}

// MARK: - Transaction

/// An editor state transaction: a Transform that also tracks selection,
/// stored marks and metadata.
public final class Transaction: Transform {
    /// Source of `Transaction.time` (ms since 1970 by default). Tests replace it with a fake clock.
    nonisolated(unsafe) public static var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }

    private static let UPDATED_SEL = 1, UPDATED_MARKS = 2, UPDATED_SCROLL = 4

    public var time: Double
    private var curSelection: Selection
    private var curSelectionFor = 0
    private var updated = 0
    private var meta: [String: Any] = [:]
    public private(set) var storedMarks: [Mark]?

    public init(_ state: EditorState) {
        time = Transaction.now()
        curSelection = state.selection
        storedMarks = state.storedMarks
        super.init(state.doc)
    }

    public var selection: Selection {
        if curSelectionFor < steps.count {
            curSelection = curSelection.map(doc, mapping.slice(curSelectionFor))
            curSelectionFor = steps.count
        }
        return curSelection
    }

    @discardableResult
    public func setSelection(_ selection: Selection) -> Transaction {
        precondition(selection.fromPos.doc === doc, "Selection passed to setSelection must point at the current document")
        curSelection = selection
        curSelectionFor = steps.count
        updated = (updated | Transaction.UPDATED_SEL) & ~Transaction.UPDATED_MARKS
        storedMarks = nil
        return self
    }

    public var selectionSet: Bool { (updated & Transaction.UPDATED_SEL) > 0 }

    @discardableResult
    public func setStoredMarks(_ marks: [Mark]?) -> Transaction {
        storedMarks = marks
        updated |= Transaction.UPDATED_MARKS
        return self
    }

    @discardableResult
    public func ensureMarks(_ marks: [Mark]) -> Transaction {
        if !Mark.sameSet(storedMarks ?? selection.fromPos.marks(), marks) { setStoredMarks(marks) }
        return self
    }

    @discardableResult
    public func addStoredMark(_ mark: Mark) -> Transaction {
        ensureMarks(mark.addToSet(storedMarks ?? selection.headPos.marks()))
    }

    @discardableResult
    public func removeStoredMark(_ mark: Mark) -> Transaction {
        ensureMarks(mark.removeFromSet(storedMarks ?? selection.headPos.marks()))
    }

    @discardableResult
    public func removeStoredMark(_ type: MarkType) -> Transaction {
        ensureMarks(type.removeFromSet(storedMarks ?? selection.headPos.marks()))
    }

    public var storedMarksSet: Bool { (updated & Transaction.UPDATED_MARKS) > 0 }

    public override func addStep(_ step: Step, _ doc: Node) {
        super.addStep(step, doc)
        updated = updated & ~Transaction.UPDATED_MARKS
        storedMarks = nil
    }

    @discardableResult
    public func setTime(_ time: Double) -> Transaction {
        self.time = time
        return self
    }

    @discardableResult
    public func replaceSelection(_ slice: Slice) throws -> Transaction {
        try selection.replace(self, slice)
        return self
    }

    @discardableResult
    public func replaceSelectionWith(_ node: Node, inheritMarks: Bool = true) throws -> Transaction {
        let selection = self.selection
        var node = node
        if inheritMarks {
            node = node.mark(storedMarks ?? (selection.empty ? selection.fromPos.marks()
                : (selection.fromPos.marksAcross(selection.toPos) ?? Mark.none)))
        }
        try selection.replaceWith(self, node)
        return self
    }

    @discardableResult
    public func deleteSelection() throws -> Transaction {
        try selection.replace(self)
        return self
    }

    @discardableResult
    public func insertText(_ text: String, _ from: Int? = nil, _ to: Int? = nil) throws -> Transaction {
        let schema = doc.type.schema
        guard let from else {
            if text.isEmpty { return try deleteSelection() }
            return try replaceSelectionWith(schema.text(text), inheritMarks: true)
        }
        let to = to ?? from
        if text.isEmpty {
            try deleteRange(from, to)
            return self
        }
        var marks = storedMarks
        if marks == nil {
            let rFrom = doc.resolve(from)
            marks = to == from ? rFrom.marks() : rFrom.marksAcross(doc.resolve(to))
        }
        try replaceRangeWith(from, to, schema.text(text, marks))
        if !selection.empty && selection.to == from + text.utf16.count {
            setSelection(Selection.near(selection.toPos))
        }
        return self
    }

    @discardableResult
    public func setMeta(_ key: String, _ value: Any?) -> Transaction {
        meta[key] = value
        return self
    }

    @discardableResult
    public func setMeta(_ key: Plugin, _ value: Any?) -> Transaction { setMeta(key.key, value) }

    @discardableResult
    public func setMeta(_ key: PluginKey, _ value: Any?) -> Transaction { setMeta(key.key, value) }

    public func getMeta(_ key: String) -> Any? { meta[key] }
    /// Every metadata entry, by key.
    public var allMeta: [String: Any] { meta }
    public func getMeta(_ key: Plugin) -> Any? { meta[key.key] }
    public func getMeta(_ key: PluginKey) -> Any? { meta[key.key] }

    public var isGeneric: Bool { meta.isEmpty }

    @discardableResult
    public func scrollIntoView() -> Transaction {
        updated |= Transaction.UPDATED_SCROLL
        return self
    }

    public var scrolledIntoView: Bool { (updated & Transaction.UPDATED_SCROLL) > 0 }
}

// MARK: - Plugins

nonisolated(unsafe) private var pluginKeys: [String: Int] = [:]

private func createKey(_ name: String) -> String {
    if let n = pluginKeys[name] {
        pluginKeys[name] = n + 1
        return name + "$" + String(n + 1)
    }
    pluginKeys[name] = 0
    return name + "$"
}

/// A key used to tag plugins so they can be found given an editor state.
public final class PluginKey {
    public let key: String
    public init(_ name: String = "key") { key = createKey(name) }
    public func get(_ state: EditorState) -> Plugin? { state.config.pluginsByKey[key] }
    public func getState(_ state: EditorState) -> Any? { state.field(key) }
}

/// A plugin state field.
public struct StateField {
    public var initialize: (EditorStateConfig, EditorState) -> Any?
    public var apply: (Transaction, Any?, EditorState, EditorState) -> Any?

    public init(init initialize: @escaping (EditorStateConfig, EditorState) -> Any?,
                apply: @escaping (Transaction, Any?, EditorState, EditorState) -> Any?) {
        self.initialize = initialize
        self.apply = apply
    }
}

/// The subset of view props that plugins provide and the headless/native views consult.
public struct EditorProps {
    public var handleKeyDown: ((EditorView, KeyEvent) -> Bool)?
    public var handleTextInput: ((EditorView, Int, Int, String) -> Bool)?
    public init(handleKeyDown: ((EditorView, KeyEvent) -> Bool)? = nil,
                handleTextInput: ((EditorView, Int, Int, String) -> Bool)? = nil) {
        self.handleKeyDown = handleKeyDown
        self.handleTextInput = handleTextInput
    }
}

public struct PluginSpec {
    public var props: EditorProps
    public var state: StateField?
    public var key: PluginKey?
    public var filterTransaction: ((Transaction, EditorState) -> Bool)?
    public var appendTransaction: (([Transaction], EditorState, EditorState) -> Transaction?)?
    /// Arbitrary extra spec properties (e.g. "isInputRules", "historyPreserveItems").
    public var extra: [String: Any]

    public init(props: EditorProps = EditorProps(), state: StateField? = nil, key: PluginKey? = nil,
                filterTransaction: ((Transaction, EditorState) -> Bool)? = nil,
                appendTransaction: (([Transaction], EditorState, EditorState) -> Transaction?)? = nil,
                extra: [String: Any] = [:]) {
        self.props = props
        self.state = state
        self.key = key
        self.filterTransaction = filterTransaction
        self.appendTransaction = appendTransaction
        self.extra = extra
    }
}

public final class Plugin {
    public let spec: PluginSpec
    public let key: String

    public init(_ spec: PluginSpec) {
        self.spec = spec
        key = spec.key?.key ?? createKey("plugin")
    }

    public var props: EditorProps { spec.props }

    public func getState(_ state: EditorState) -> Any? { state.field(key) }
}

// MARK: - EditorState

public struct EditorStateConfig {
    public var schema: Schema?
    public var doc: Node?
    public var selection: Selection?
    public var storedMarks: [Mark]?
    public var plugins: [Plugin]

    public init(schema: Schema? = nil, doc: Node? = nil, selection: Selection? = nil, storedMarks: [Mark]? = nil, plugins: [Plugin] = []) {
        self.schema = schema
        self.doc = doc
        self.selection = selection
        self.storedMarks = storedMarks
        self.plugins = plugins
    }
}

public final class Configuration {
    public let schema: Schema
    public private(set) var plugins: [Plugin] = []
    public private(set) var pluginsByKey: [String: Plugin] = [:]
    /// Plugin state fields, in order.
    fileprivate var fields: [(name: String, field: StateField)] = []

    init(schema: Schema, plugins: [Plugin]) {
        self.schema = schema
        for plugin in plugins {
            precondition(pluginsByKey[plugin.key] == nil, "Adding different instances of a keyed plugin (\(plugin.key))")
            self.plugins.append(plugin)
            pluginsByKey[plugin.key] = plugin
            if let state = plugin.spec.state { fields.append((plugin.key, state)) }
        }
    }
}

/// The state of a ProseMirror editor. Immutable; create new states with `apply`.
public final class EditorState {
    public let config: Configuration
    fileprivate var _doc: Node!
    fileprivate var _selection: Selection!
    public var doc: Node { _doc }
    public var selection: Selection { _selection }
    public fileprivate(set) var storedMarks: [Mark]?
    public fileprivate(set) var scrollToSelection = 0
    private var pluginFields: [String: Any?] = [:]

    init(config: Configuration) { self.config = config }

    public var schema: Schema { config.schema }
    public var plugins: [Plugin] { config.plugins }

    /// The value of a plugin state field, by plugin key.
    public func field(_ key: String) -> Any? { pluginFields[key] ?? nil }

    public func apply(_ tr: Transaction) -> EditorState { applyTransaction(tr).state }

    public func filterTransaction(_ tr: Transaction, ignore: Int = -1) -> Bool {
        for (i, plugin) in config.plugins.enumerated() where i != ignore {
            if let f = plugin.spec.filterTransaction, !f(tr, self) { return false }
        }
        return true
    }

    public func applyTransaction(_ rootTr: Transaction) -> (state: EditorState, transactions: [Transaction]) {
        if !filterTransaction(rootTr) { return (self, []) }
        var trs = [rootTr]
        var newState = applyInner(rootTr)
        var seen: [(state: EditorState, n: Int)]? = nil
        while true {
            var haveNew = false
            for (i, plugin) in config.plugins.enumerated() {
                guard let append = plugin.spec.appendTransaction else { continue }
                let n = seen?[i].n ?? 0, oldState = seen?[i].state ?? self
                let tr: Transaction? = n < trs.count ? append(n > 0 ? Array(trs[n...]) : trs, oldState, newState) : nil
                if let tr, newState.filterTransaction(tr, ignore: i) {
                    tr.setMeta("appendedTransaction", rootTr)
                    if seen == nil {
                        seen = []
                        for j in 0..<config.plugins.count {
                            seen!.append(j < i ? (newState, trs.count) : (self, 0))
                        }
                    }
                    trs.append(tr)
                    newState = newState.applyInner(tr)
                    haveNew = true
                }
                if seen != nil { seen![i] = (newState, trs.count) }
            }
            if !haveNew { return (newState, trs) }
        }
    }

    func applyInner(_ tr: Transaction) -> EditorState {
        precondition(tr.before.eq(doc), "Applying a mismatched transaction")
        let next = EditorState(config: config)
        next._doc = tr.doc
        next._selection = tr.selection
        next.storedMarks = next.selection.cursor != nil ? tr.storedMarks : nil
        next.scrollToSelection = tr.scrolledIntoView ? scrollToSelection + 1 : scrollToSelection
        for (name, field) in config.fields {
            next.pluginFields[name] = field.apply(tr, pluginFields[name] ?? nil, self, next)
        }
        return next
    }

    /// Start a transaction from this state.
    public var tr: Transaction { Transaction(self) }

    public static func create(_ config: EditorStateConfig) -> EditorState {
        let schema = config.doc?.type.schema ?? config.schema!
        let conf = Configuration(schema: schema, plugins: config.plugins)
        let instance = EditorState(config: conf)
        instance._doc = config.doc ?? schema.topNodeType.createAndFill()!
        instance._selection = config.selection ?? Selection.atStart(instance.doc)
        instance.storedMarks = config.storedMarks
        for (name, field) in conf.fields { instance.pluginFields[name] = field.initialize(config, instance) }
        return instance
    }

    public func reconfigure(plugins: [Plugin]) -> EditorState {
        let conf = Configuration(schema: schema, plugins: plugins)
        let instance = EditorState(config: conf)
        instance._doc = doc
        instance._selection = selection
        instance.storedMarks = storedMarks
        instance.scrollToSelection = scrollToSelection
        let cfg = EditorStateConfig(schema: schema, doc: doc, selection: selection, storedMarks: storedMarks, plugins: plugins)
        for (name, field) in conf.fields {
            instance.pluginFields[name] = pluginFields.keys.contains(name) ? pluginFields[name]! : field.initialize(cfg, instance)
        }
        return instance
    }

    public func toJSON() -> JSONValue {
        var result = JSONObject([("doc", doc.toJSON()), ("selection", selection.toJSON())])
        if let storedMarks { result["storedMarks"] = .array(storedMarks.map { $0.toJSON() }) }
        return .object(result)
    }

    public static func fromJSON(schema: Schema, plugins: [Plugin] = [], _ json: JSONValue) throws -> EditorState {
        let conf = Configuration(schema: schema, plugins: plugins)
        let instance = EditorState(config: conf)
        instance._doc = try Node.fromJSON(schema, json["doc"] ?? .null)
        instance._selection = try Selection.fromJSON(instance.doc, json["selection"] ?? .null)
        if let sm = json["storedMarks"], sm.truthy {
            instance.storedMarks = try sm.arrayValue?.map { try schema.markFromJSON($0) }
        }
        let cfg = EditorStateConfig(schema: schema, plugins: plugins)
        for (name, field) in conf.fields { instance.pluginFields[name] = field.initialize(cfg, instance) }
        return instance
    }
}
