// Shared helpers for the iOS text view tests (iOS Simulator only; this target is empty on
// macOS): BasicSchema documents built from JSON, and a ProseTextView in a window styled with
// BasicStyle (tables drawn by PMTableView).
#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// BasicSchema JSON builders, so tests read like the documents they make.
enum J {
    static func text(_ s: String, _ marks: [JSONValue] = []) -> JSONValue {
        marks.isEmpty ? ["type": "text", "text": .string(s)] : ["type": "text", "text": .string(s), "marks": .array(marks)]
    }
    static func mark(_ type: String, _ attrs: JSONValue? = nil) -> JSONValue {
        attrs.map { ["type": .string(type), "attrs": $0] } ?? ["type": .string(type)]
    }
    static func node(_ type: String, _ attrs: JSONValue? = nil, _ content: [JSONValue] = []) -> JSONValue {
        var fields: [(String, JSONValue)] = [("type", .string(type))]
        if let attrs { fields.append(("attrs", attrs)) }
        if !content.isEmpty { fields.append(("content", .array(content))) }
        return .object(JSONObject(fields))
    }
    static func p(_ s: String) -> JSONValue { s.isEmpty ? node("paragraph") : node("paragraph", nil, [text(s)]) }
    static func p(_ content: [JSONValue]) -> JSONValue { node("paragraph", nil, content) }
    static func h(_ level: Int, _ s: String) -> JSONValue {
        node("heading", ["level": .number(Double(level))], s.isEmpty ? [] : [text(s)])
    }
    static func li(_ content: [JSONValue]) -> JSONValue { node("list_item", nil, content) }
    static func ul(_ items: [String]) -> JSONValue { node("bullet_list", nil, items.map { li([p($0)]) }) }
    static func ol(_ items: [String]) -> JSONValue { node("ordered_list", nil, items.map { li([p($0)]) }) }
    static func quote(_ content: [JSONValue]) -> JSONValue { node("blockquote", nil, content) }
    static func code(_ s: String) -> JSONValue { node("code_block", nil, s.isEmpty ? [] : [text(s)]) }
    static var hr: JSONValue { node("horizontal_rule") }
    /// A table of paragraph cells; with `header` the first row is header cells.
    static func table(_ rows: [[String]], header: Bool = false) -> JSONValue {
        node("table", nil, rows.enumerated().map { r, cells in
            node("table_row", nil, cells.map { node(header && r == 0 ? "table_header" : "table_cell", nil, [p($0)]) })
        })
    }
    static func doc(_ content: [JSONValue]) -> JSONValue { node("doc", nil, content) }
}

enum TestDocs {
    static var schema: Schema { BasicSchema.schema }

    static func doc(_ json: JSONValue) throws -> Node { try schema.nodeFromJSON(json) }
    static func doc(_ blocks: [JSONValue]) throws -> Node { try schema.nodeFromJSON(J.doc(blocks)) }
    static func paragraphs(_ texts: [String]) throws -> Node { try doc(texts.map { J.p($0) }) }

    /// A state on `doc` with exampleSetup's plugins (or `plugins`), the selection at `selection`
    /// (a text position) or at the start.
    static func state(_ doc: Node, selection: Int? = nil, plugins: [Plugin]? = nil) -> EditorState {
        let sel = selection.map { TextSelection.create(doc, $0) } ?? Selection.atStart(doc)
        return EditorState.create(EditorStateConfig(doc: doc, selection: sel, plugins: plugins ?? exampleSetup(schema: schema)))
    }
}

/// A ProseTextView in a window (a phone-sized one by default): BasicStyle's
/// `makeTextView(state:)` (tables as grids) unless a style is given, with chrome animation off.
@MainActor
final class HostedTextView {
    let view: ProseTextView
    let window: UIWindow

    init(state: EditorState, style: DocStyle? = nil, width: CGFloat = 402, height: CGFloat = 874, dark: Bool = false) {
        if let style {
            view = ProseTextView(state: state, style: style)
        } else {
            view = BasicStyle().makeTextView(state: state)
        }
        view.animatesChrome = false
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.isHidden = false
        view.frame = window.bounds
        settle()
    }

    convenience init(_ doc: Node, selection: Int? = nil, style: DocStyle? = nil, plugins: [Plugin]? = nil,
                     width: CGFloat = 402, dark: Bool = false) {
        self.init(state: TestDocs.state(doc, selection: selection, plugins: plugins), style: style, width: width, dark: dark)
    }

    var state: EditorState { view.state }

    /// Lays the whole document out, then lets the run loop turn so deferred work runs.
    func settle() {
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}
#endif
