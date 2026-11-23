import XCTest
import Foundation
import PMModel
import PMTransform
import PMState
import PMCommands
import PMKeymap
import PMInputRules
import PMHistory
import PMOracle

// Swift mirror of oracle/src/scenarios.js. Keep the two in sync.

func markInputRule(_ pattern: String, _ markType: MarkType) -> InputRule {
    InputRule(pattern, handler: { state, match, start, end in
        guard let group = match.groups.last ?? nil, !group.isEmpty, let full = match[0] else { return nil }
        let fullNS = full as NSString
        let startSpaces = fullNS.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted).location
        let textStart = start + fullNS.range(of: group).location, textEnd = textStart + group.utf16.count
        let tr = state.tr
        do {
            if textEnd < end { try tr.delete(textEnd, end) }
            if textStart > start { try tr.delete(start + startSpaces, textStart) }
            let markEnd = start + startSpaces + group.utf16.count
            // JS's addMark reads past the end of the doc here and throws a TypeError, which
            // aborts input handling. Mirror that: record the error, consume the input, change nothing.
            if markEnd > tr.doc.content.size {
                CommandErrors.last = PMError.generic("Cannot read properties of undefined (reading 'nodeSize')")
                return state.tr
            }
            try tr.addMark(start + startSpaces, markEnd, try markType.create())
        } catch { return nil }
        tr.removeStoredMark(markType)
        return tr
    })
}

struct ScenarioTypes {
    var strong, em, code, underline: MarkType?
    var paragraph, heading, blockquote, codeBlock, hardBreak, hr, bulletList, orderedList, listItem, taskItem: NodeType?
}

func scenarioSetup(_ schema: Schema) -> (plugins: [Plugin], types: ScenarioTypes) {
    func node(_ names: String...) -> NodeType? { names.lazy.compactMap { schema.nodes[$0] }.first }
    func mark(_ names: String...) -> MarkType? { names.lazy.compactMap { schema.marks[$0] }.first }
    let t = ScenarioTypes(
        strong: mark("strong", "bold"), em: mark("em", "italic"), code: mark("code"), underline: mark("underline"),
        paragraph: node("paragraph"), heading: node("heading"), blockquote: node("blockquote"),
        codeBlock: node("code_block", "codeBlock"), hardBreak: node("hard_break", "hardBreak"),
        hr: node("horizontal_rule", "horizontalRule"), bulletList: node("bullet_list", "bulletList"),
        orderedList: node("ordered_list", "orderedList"), listItem: node("list_item", "listItem"), taskItem: node("taskItem"))
    let orderAttr = t.orderedList?.attributeNames.contains("order") == true ? "order" : "start"

    var rules = smartQuotes + [ellipsis, emDash]
    if let bq = t.blockquote { rules.append(wrappingInputRule("^\\s*>\\s$", bq)) }
    if let ol = t.orderedList {
        rules.append(wrappingInputRule("^(\\d+)\\.\\s$", ol, { m in Attrs([(orderAttr, .number(Double(m[1]!)!))]) },
                                       joinPredicate: { m, node in
                                           Double(node.childCount) + (node.attrs[orderAttr]?.numberValue ?? 0) == Double(m[1]!)!
                                       }))
    }
    if let bl = t.bulletList { rules.append(wrappingInputRule("^\\s*([-+*])\\s$", bl)) }
    if let cb = t.codeBlock { rules.append(textblockTypeInputRule("^```$", cb)) }
    if let h = t.heading { rules.append(textblockTypeInputRule("^(#{1,6})\\s$", h, { m in Attrs([("level", .number(Double(m[1]!.utf16.count)))]) })) }
    if let s = t.strong { rules.append(markInputRule("(?:^|\\s)(\\*\\*(?!\\s+\\*\\*)((?:[^*]+))\\*\\*(?!\\s+\\*\\*))$", s)) }
    if let e = t.em { rules.append(markInputRule("(?:^|\\s)(\\*(?!\\s+\\*)((?:[^*]+))\\*(?!\\s+\\*))$", e)) }
    if let c = t.code { rules.append(markInputRule("(^|[^`])`([^`]+)`(?!`)$", c)) }

    var keys: [String: Command] = [:]
    keys["Mod-z"] = undo
    keys["Shift-Mod-z"] = redo
    keys["Backspace"] = undoInputRule
    keys["Alt-ArrowUp"] = joinUp
    keys["Alt-ArrowDown"] = joinDown
    keys["Mod-BracketLeft"] = lift
    keys["Escape"] = selectParentNode
    if let s = t.strong { keys["Mod-b"] = toggleMark(s); keys["Mod-B"] = toggleMark(s) }
    if let e = t.em { keys["Mod-i"] = toggleMark(e); keys["Mod-I"] = toggleMark(e) }
    if let c = t.code { keys["Mod-`"] = toggleMark(c) }
    if let u = t.underline { keys["Mod-u"] = toggleMark(u) }
    if let bl = t.bulletList { keys["Shift-Ctrl-8"] = wrapInList(bl) }
    if let ol = t.orderedList { keys["Shift-Ctrl-9"] = wrapInList(ol) }
    if let bq = t.blockquote { keys["Ctrl->"] = wrapIn(bq) }
    if let br = t.hardBreak {
        let insertBreak: Command = { state, dispatch, _ in
            if let dispatch, let tr = try? state.tr.replaceSelectionWith(try br.create()) { dispatch(tr.scrollIntoView()) }
            return true
        }
        let c = chainCommands(exitCode, insertBreak)
        keys["Mod-Enter"] = c; keys["Shift-Enter"] = c; keys["Ctrl-Enter"] = c
    }
    let items = [t.listItem, t.taskItem].compactMap { $0 }
    if !items.isEmpty {
        keys["Enter"] = chainCommands(items.map { splitListItem($0) })
        keys["Mod-["] = chainCommands(items.map { liftListItem($0) })
        keys["Mod-]"] = chainCommands(items.map { sinkListItem($0) })
        keys["Tab"] = chainCommands(items.map { sinkListItem($0) })
        keys["Shift-Tab"] = chainCommands(items.map { liftListItem($0) })
    }
    if let p = t.paragraph { keys["Shift-Ctrl-0"] = setBlockType(p) }
    if let cb = t.codeBlock { keys["Shift-Ctrl-\\"] = setBlockType(cb) }
    if let h = t.heading { for i in 1...6 { keys["Shift-Ctrl-\(i)"] = setBlockType(h, Attrs([("level", .number(Double(i)))])) } }
    if let hr = t.hr {
        keys["Mod-_"] = { state, dispatch, _ in
            if let dispatch, let tr = try? state.tr.replaceSelectionWith(try hr.create()) { dispatch(tr.scrollIntoView()) }
            return true
        }
    }
    let plugins = [inputRules(rules), keymap(keys), keymap(baseKeymap), history()]
    return (plugins, t)
}

final class HeadlessView: EditorView {
    var state: EditorState
    var composing = false
    init(_ state: EditorState) { self.state = state }
    func dispatch(_ tr: Transaction) { state = state.apply(tr) }
    func endOfTextblock(_ dir: String, _ state: EditorState?) -> Bool {
        let head = (state ?? self.state).selection.headPos
        if !head.parent.inlineContent { return true }
        if dir == "backward" || dir == "left" || dir == "up" { return head.parentOffset == 0 }
        return head.parentOffset == head.parent.content.size
    }
    func handleTextInput(_ from: Int, _ to: Int, _ text: String) -> Bool {
        for p in state.plugins { if let f = p.props.handleTextInput, f(self, from, to, text) { return true } }
        return false
    }
    func handleKeyDown(_ event: KeyEvent) -> Bool {
        for p in state.plugins { if let f = p.props.handleKeyDown, f(self, event) { return true } }
        return false
    }
}

/// Same as keyEvent() in oracle/src/scenarios.js.
func scenarioKeyEvent(_ spec: String) -> KeyEvent {
    var parts: [String] = []
    var cur = ""
    let chars = Array(spec)
    for (i, c) in chars.enumerated() {
        if c == "-" && i != chars.count - 1 { parts.append(cur); cur = "" } else { cur.append(c) }
    }
    let key = cur
    var ev = KeyEvent(key: key)
    for mod in parts {
        switch mod.lowercased() {
        case "cmd", "meta", "m", "mod": ev.metaKey = true
        case "a", "alt": ev.altKey = true
        case "c", "ctrl", "control": ev.ctrlKey = true
        case "s", "shift": ev.shiftKey = true
        default: break
        }
    }
    let codes: [String: Int] = ["Enter": 13, "Backspace": 8, "Tab": 9, "Delete": 46, "Escape": 27, " ": 32, "[": 219, "]": 221,
                                "`": 192, "\\": 220, "-": 189, "_": 189, "ArrowUp": 38, "ArrowDown": 40, "ArrowLeft": 37,
                                "ArrowRight": 39, ">": 190]
    if key.count == 1, let c = key.first, c.isASCII, c.isLetter {
        ev.keyCode = Int(key.uppercased().unicodeScalars.first!.value)
        ev.key = ev.shiftKey ? key.uppercased() : key.lowercased()
    } else if key.count == 1, let c = key.first, c.isASCII, c.isNumber {
        ev.keyCode = 48 + Int(String(c))!
    } else if key == "BracketLeft" {
        ev.key = "["; ev.keyCode = 219
    } else if key == "BracketRight" {
        ev.key = "]"; ev.keyCode = 221
    } else {
        ev.keyCode = codes[key] ?? 0
    }
    return ev
}

func namedCommand(_ name: String, _ args: [JSONValue], _ schema: Schema, _ t: ScenarioTypes) -> Command? {
    func nodeType(_ v: JSONValue?) -> NodeType? { v?.stringValue.flatMap { schema.nodes[$0] } }
    func markType(_ v: JSONValue?) -> MarkType? { v?.stringValue.flatMap { schema.marks[$0] } }
    let attrs = args.count > 1 ? args[1].objectValue : nil
    switch name {
    case "toggleMark": return markType(args.first).map { toggleMark($0, attrs) }
    case "setBlockType": return nodeType(args.first).map { setBlockType($0, attrs) }
    case "wrapIn": return nodeType(args.first).map { wrapIn($0, attrs) }
    case "wrapInList": return nodeType(args.first).map { wrapInList($0, attrs) }
    case "splitListItem": return nodeType(args.first).map { splitListItem($0) }
    case "liftListItem": return nodeType(args.first).map { liftListItem($0) }
    case "sinkListItem": return nodeType(args.first).map { sinkListItem($0) }
    case "undo": return undo
    case "redo": return redo
    case "deleteSelection": return deleteSelection
    case "joinBackward": return joinBackward
    case "joinForward": return joinForward
    case "joinTextblockBackward": return joinTextblockBackward
    case "joinTextblockForward": return joinTextblockForward
    case "selectNodeBackward": return selectNodeBackward
    case "selectNodeForward": return selectNodeForward
    case "joinUp": return joinUp
    case "joinDown": return joinDown
    case "lift": return lift
    case "newlineInCode": return newlineInCode
    case "exitCode": return exitCode
    case "createParagraphNear": return createParagraphNear
    case "liftEmptyBlock": return liftEmptyBlock
    case "splitBlock": return splitBlock
    case "splitBlockKeepMarks": return splitBlockKeepMarks
    case "selectParentNode": return selectParentNode
    case "selectAll": return selectAll
    case "selectTextblockStart": return selectTextblockStart
    case "selectTextblockEnd": return selectTextblockEnd
    default: return nil
    }
}

func scenarioStateJSON(_ state: EditorState) -> JSONValue {
    guard case .object(var json) = state.toJSON() else { fatalError() }
    json["undoDepth"] = .number(Double(undoDepth(state)))
    json["redoDepth"] = .number(Double(redoDepth(state)))
    return .object(json)
}

/// Runs a scenario in Swift starting from JS's initial state (trace[0]), returning a trace in the same shape.
func runSwiftScenario(_ schema: Schema, _ scenario: JSONValue, initial: JSONValue) throws -> [JSONValue] {
    let (plugins, types) = scenarioSetup(schema)
    let doc = try schema.nodeFromJSON(initial["doc"]!)
    let selection = try Selection.fromJSON(doc, initial["selection"]!)
    var clock = 1000.0
    let realNow = Transaction.now
    Transaction.now = { clock }
    defer { Transaction.now = realNow }
    let view = HeadlessView(EditorState.create(EditorStateConfig(doc: doc, selection: selection, plugins: plugins)))
    var trace: [JSONValue] = [["step": .null, "state": scenarioStateJSON(view.state)]]
    for step in scenario["steps"]!.arrayValue! {
        if ProcessInfo.processInfo.environment["PM_TRACE"] == "2" { print("step \(step) sel \(view.state.selection.toJSON())"); fflush(stdout) }
        var entry = JSONObject([("step", step)])
        CommandErrors.last = nil
        if let w = step["wait"]?.numberValue { clock += w } else { clock += 10 }
        if let text = step["type"]?.stringValue {
            for ch in text {
                let from = view.state.selection.from, to = view.state.selection.to
                let s = String(ch)
                if !view.handleTextInput(from, to, s) {
                    do { view.dispatch(try view.state.tr.insertText(s, from, to)) } catch { entry["error"] = .string("\(error)") }
                }
                // An exception in JS aborts the rest of the step.
                if entry["error"] != nil || CommandErrors.last != nil { break }
            }
        } else if let key = step["key"]?.stringValue {
            entry["handled"] = .bool(view.handleKeyDown(scenarioKeyEvent(key)))
        } else if let name = step["command"]?.stringValue {
            guard let command = namedCommand(name, step["args"]?.arrayValue ?? [], schema, types) else {
                throw PMError.generic("Unknown command \(name)")
            }
            entry["handled"] = .bool(command(view.state, view.dispatch, view))
        } else if step["undo"]?.truthy == true {
            entry["handled"] = .bool(undo(view.state, view.dispatch, nil))
        } else if step["redo"]?.truthy == true {
            entry["handled"] = .bool(redo(view.state, view.dispatch, nil))
        } else if let sel = step["select"]?.arrayValue {
            let a = sel[0].intValue!, h = sel.count > 1 ? sel[1].intValue ?? a : a
            view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, a, h)))
        } else if let pos = step["selectNode"]?.intValue {
            view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, pos)))
        } else if step["selectAll"]?.truthy == true {
            view.dispatch(view.state.tr.setSelection(AllSelection(view.state.doc)))
        } else if let text = step["insertText"]?.stringValue {
            let at = step["at"]!.arrayValue!
            let from = at[0].intValue!, to = at.count > 1 ? at[1].intValue ?? from : from
            do { view.dispatch(try view.state.tr.insertText(text, from, to)) } catch { entry["error"] = .string("\(error)") }
        }
        if let e = CommandErrors.last { entry["error"] = .string("\(e)") }
        entry["state"] = scenarioStateJSON(view.state)
        trace.append(.object(entry))
    }
    return trace
}

func compareTraces(_ name: String, _ swiftTrace: [JSONValue], _ jsTrace: [JSONValue], file: StaticString = #filePath, line: UInt = #line) -> Bool {
    XCTAssertEqual(swiftTrace.count, jsTrace.count, name, file: file, line: line)
    for (i, (s, j)) in zip(swiftTrace, jsTrace).enumerated() {
        var so = s.objectValue!, jo = j.objectValue!
        if (so["error"] == nil) != (jo["error"] == nil) {
            XCTFail("\(name) step \(i) \(jo["step"]!): error mismatch Swift \(so["error"].map { "\($0)" } ?? "none") vs JS \(jo["error"].map { "\($0)" } ?? "none")", file: file, line: line)
            return false
        }
        if so["error"] != nil { so["handled"] = nil; jo["handled"] = nil }
        so["error"] = nil; jo["error"] = nil
        if let d = jsonDiff(.object(so), .object(jo)) {
            XCTFail("\(name) step \(i) \(jo["step"]!): \(d)\nprevious: \(i > 0 ? jsTrace[i - 1]["state"]! : .null)", file: file, line: line)
            return false
        }
    }
    return true
}

func runRandomSessions(schemaJSON: JSONValue, schema: Schema, seed: Int, count: Int, steps: Int) throws -> Int {
    let batch = 20
    var done = 0, total = 0
    while done < count {
        let n = min(batch, count - done)
        let sessions = try Oracle.shared.value("randomSessions", ["schema": schemaJSON, "seed": .int(seed + done), "count": .int(n), "steps": .int(steps)])
        for (i, session) in sessions.arrayValue!.enumerated() {
            if ProcessInfo.processInfo.environment["PM_TRACE"] != nil { print("session seed \(seed + done + i)"); fflush(stdout) }
            let jsTrace = session["trace"]!.arrayValue!
            let swiftTrace = try runSwiftScenario(schema, ["steps": session["steps"]!], initial: jsTrace[0]["state"]!)
            if !compareTraces("session seed \(seed + done + i)", swiftTrace, jsTrace) { return total }
            total += steps
        }
        done += n
    }
    return total
}

final class ScenarioTests: XCTestCase {
    func testRandomSessionsBasic() throws {
        let n = try runRandomSessions(schemaJSON: Schemas.basicJSON, schema: Schemas.basic, seed: 1, count: fuzzCount(200), steps: 40)
        print("basic: \(n) random editing steps")
    }

    func testRandomSessionsTiptap() throws {
        let n = try runRandomSessions(schemaJSON: Schemas.tiptapJSON, schema: Schemas.tiptap, seed: Int(ProcessInfo.processInfo.environment["PM_SEED"] ?? "") ?? 50_000, count: fuzzCount(200), steps: 40)
        print("tiptap: \(n) random editing steps")
    }

    func testScenarios() throws {
        let dir = Fixtures.url("scenarios")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        var count = 0
        for file in files {
            let scenarios = try Fixtures.json("scenarios/\(file)")
            for scenario in scenarios.arrayValue! {
                let name = "\(file): \(scenario["name"]?.stringValue ?? "?")"
                let schemaName = scenario["schema"]?.stringValue ?? "basic"
                let (schemaJSON, schema) = schemaName == "tiptap" ? (Schemas.tiptapJSON, Schemas.tiptap) : (Schemas.basicJSON, Schemas.basic)
                let js: JSONValue
                switch Oracle.shared.call("runScenario", ["schema": schemaJSON, "scenario": scenario]) {
                case .success(let v): js = v
                case .failure(let e): XCTFail("\(name): JS failed: \(e)"); continue
                }
                if js["expectOk"]?.boolValue == false {
                    XCTFail("\(name): JS result doesn't match `expect` (fix the scenario): got \(js["trace"]!.arrayValue!.last!["state"]!["doc"]!)")
                }
                let jsTrace = js["trace"]!.arrayValue!
                let swiftTrace = try runSwiftScenario(schema, scenario, initial: jsTrace[0]["state"]!)
                for (i, (s, j)) in zip(swiftTrace, jsTrace).enumerated() {
                    var so = s.objectValue!, jo = j.objectValue!
                    if (so["error"] == nil) != (jo["error"] == nil) {
                        XCTFail("\(name) step \(i) \(jo["step"]!): error mismatch Swift \(so["error"].map { "\($0)" } ?? "none") vs JS \(jo["error"].map { "\($0)" } ?? "none")")
                        break
                    }
                    so["error"] = nil; jo["error"] = nil
                    if let d = jsonDiff(.object(so), .object(jo)) {
                        XCTFail("\(name) step \(i) \(jo["step"]!): \(d)")
                        break
                    }
                }
                count += 1
            }
        }
        print("ran \(count) scenarios")
    }
}
