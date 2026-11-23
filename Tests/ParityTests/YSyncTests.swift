import XCTest
import PMModel
import PMTransform
import PMState
import PMOracle
import YSync
import PMTables

/// y-prosemirror stores no marks for inline nodes other than text (a bold hard
/// break, a code-marked link card), so neither does YSync; compare without them.
func withoutInlineNodeMarks(_ v: JSONValue) -> JSONValue {
    guard case .object(var o) = v else { return v }
    if o["type"]?.stringValue != "text" { o["marks"] = nil }
    if let content = o["content"]?.arrayValue { o["content"] = .array(content.map(withoutInlineNodeMarks)) }
    return .object(o)
}

func sameDoc(_ a: JSONValue, _ b: JSONValue) -> String? {
    jsonDiff(withoutInlineNodeMarks(a), withoutInlineNodeMarks(b))
}

/// A Swift editor bound to a Y.Doc, as the app wires it.
final class SwiftPeer {
    let ydoc: YDocument
    let binding: YSyncBinding
    var state: EditorState
    var outbox: [Data] = []

    init(_ schema: Schema, clientID: UInt64, doc: Node? = nil) {
        ydoc = YDocument(clientID: clientID)
        binding = YSyncBinding(doc: ydoc, schema: schema)
        binding.enableUndo()
        state = EditorState.create(EditorStateConfig(schema: schema, doc: doc))
        ydoc.onUpdate { [unowned self] update, _ in outbox.append(update) }
        if let doc { binding.seed(doc) }
    }

    /// Apply a local transaction the way the editor does.
    func dispatch(_ tr: Transaction) {
        state = state.apply(tr)
        binding.localStateChanged(state, tr)
    }

    func receive(_ updates: [Data]) {
        for u in updates { XCTAssertTrue(ydoc.applyUpdate(u, origin: "remote")) }
        pull()
    }

    func pull() {
        if let tr = binding.remoteTransaction(state) { dispatch(tr) }
    }

    func take() -> [Data] { defer { outbox = [] }; return outbox }
}

/// xorshift, so failures replay from the seed.
struct Rand {
    var s: UInt64
    init(_ seed: Int) { s = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func int(_ n: Int) -> Int { min(n - 1, Int(next() * Double(n))) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    mutating func chance(_ p: Double) -> Bool { next() < p }
}

func dumpY(_ b: YBranch, _ txn: YTransaction) -> JSONValue {
    if b.kind == .text {
        return ["delta": .array(b.textDelta(txn).map { run in ["insert": .string(run.text), "attributes": .object(JSONObject(run.attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))] })]
    }
    return ["name": .string(b.tag ?? "fragment"), "children": .array(b.children(txn).map { dumpY($0, txn) })]
}

func splitsSurrogate(_ doc: Node, _ pos: Int) -> Bool {
    let rpos = doc.resolve(pos)
    guard rpos.textOffset > 0, let text = rpos.parent.child(rpos.index()) as? TextNode else { return false }
    return UTF16.isLeadSurrogate(text.units[rpos.textOffset - 1])
}

/// Random local edits, like the JS peer's `yPeerRandomEdits`.
func randomEdits(_ peer: SwiftPeer, _ r: inout Rand, _ count: Int) {
    let schema = peer.state.schema
    let marks = schema.marks.values.filter { $0.spec.attrs.allSatisfy { $0.1.default != nil } }.sorted { $0.name < $1.name }
    for _ in 0..<count {
        let doc = peer.state.doc
        let size = doc.content.size
        let a = r.int(size + 1), b = r.chance(0.6) ? a : r.int(size + 1)
        // Editors never put the caret inside a surrogate pair.
        if splitsSurrogate(doc, a) || splitsSurrogate(doc, b) { continue }
        let sel = TextSelection.between(doc.resolve(min(a, b)), doc.resolve(max(a, b)))
        let tr = peer.state.tr.setSelection(sel)
        let roll = r.next()
        do {
            if roll < 0.5 {
                _ = try tr.insertText(r.pick(["a", "bc", " ", "é", "😀", "xyz"]))
            } else if roll < 0.75 {
                _ = try tr.deleteSelection()
            } else if !marks.isEmpty, !sel.empty {
                let m = r.pick(marks)
                if r.chance(0.5) { _ = try tr.addMark(sel.from, sel.to, try m.create()) } else { _ = try tr.removeMark(sel.from, sel.to, m) }
            } else {
                _ = try tr.split(sel.from)
            }
        } catch { continue }
        guard tr.docChanged else { continue }
        peer.dispatch(tr)
    }
}

final class YSyncTests: XCTestCase {
    let oracle = Oracle.shared

    func b64(_ d: Data) -> JSONValue { .string(d.base64EncodedString()) }
    func data(_ v: JSONValue) -> Data { Data(base64Encoded: v.stringValue!)! }

    /// Swift-encoded documents decode in JS to the same document, and JS-encoded
    /// ones decode in Swift.
    func testEncodingMatchesYProsemirror() throws {
        for (name, schemaJSON, schema) in [("tiptap", Schemas.tiptapJSON, Schemas.tiptap), ("basic", Schemas.basicJSON, Schemas.basic)] {
            let docs = try oracle.value("randomDocs", ["schema": schemaJSON, "seed": 1, "count": .int(fuzzCount(150))]).arrayValue!
            for (i, json) in docs.enumerated() {
                let doc = try schema.nodeFromJSON(json)
                let peer = SwiftPeer(schema, clientID: 1, doc: doc)
                let update = peer.ydoc.encodeStateAsUpdate()
                let decoded = try oracle.value("yDecodeDoc", ["schema": schemaJSON, "update": b64(update)])
                if let d = sameDoc(decoded, json) { return XCTFail("\(name) doc \(i) Swift->JS: \(d)") }

                let jsUpdate = try oracle.value("yEncodeDoc", ["schema": schemaJSON, "doc": json])
                let other = YDocument(clientID: 2)
                XCTAssertTrue(other.applyUpdate(data(jsUpdate)))
                let back = YSyncBinding(doc: other, schema: schema).documentFromY()
                if let d = sameDoc(back?.toJSON() ?? .null, json) { return XCTFail("\(name) doc \(i) JS->Swift: \(d)") }
            }
        }
    }

    /// Typing sessions in Swift (keys, input rules, commands, undo) stream into a JS
    /// peer, which sees the same document after every step.
    func testLocalSessionsStreamToJS() throws {
        let schema = Schemas.tiptap, schemaJSON = Schemas.tiptapJSON
        let sessions = try oracle.value("randomSessions", ["schema": schemaJSON, "seed": 7, "count": .int(fuzzCount(30)), "steps": 40]).arrayValue!
        for (s, session) in sessions.enumerated() {
            let initial = session["trace"]!.arrayValue![0]["state"]!
            let doc = try schema.nodeFromJSON(initial["doc"]!)
            let peer = SwiftPeer(schema, clientID: 10, doc: doc)
            _ = try oracle.value("yPeerCreate", ["schema": schemaJSON, "id": "js", "clientID": 20])
            defer { _ = try? oracle.value("yPeerDestroy", ["id": "js"]) }
            _ = try oracle.value("yPeerApply", ["id": "js", "updates": .array(peer.take().map(b64))])
            // Replay the session's steps through the scenario runner, mirroring each state into Yjs.
            let (plugins, _) = scenarioSetup(schema)
            let view = HeadlessView(EditorState.create(EditorStateConfig(doc: doc, selection: try Selection.fromJSON(doc, initial["selection"]!), plugins: plugins)))
            // History grouping depends on time; replay the session's clock as the scenario runner does.
            var clock = 1000.0
            let realNow = Transaction.now
            Transaction.now = { clock }
            defer { Transaction.now = realNow }
            for (i, step) in session["steps"]!.arrayValue!.enumerated() {
                clock += step["wait"]?.numberValue ?? 10
                let before = view.state
                applyStep(step, view, schema)
                let expected = session["trace"]!.arrayValue![i + 1]["state"]!
                if let d = jsonDiff(view.state.doc.toJSON(), expected["doc"]!) { return XCTFail("session \(s) step \(i) \(step) replay diverged: \(d)") }
                if view.state.doc !== before.doc {
                    peer.state = view.state
                    peer.binding.localStateChanged(view.state)
                }
                let js = try oracle.value("yPeerApply", ["id": "js", "updates": .array(peer.take().map(b64))])
                if let d = sameDoc(view.state.doc.toJSON(), js) { return XCTFail("session \(s) step \(i) \(step): \(d)") }
            }
        }
    }

    /// Three editors (two Swift, one JS) edit concurrently, then exchange updates;
    /// everyone ends with the same, valid document.
    func testConcurrentEditsConverge() throws {
        let schema = Schemas.tiptap, schemaJSON = Schemas.tiptapJSON
        let docs = try oracle.value("randomDocs", ["schema": schemaJSON, "seed": 500, "count": .int(fuzzCount(40))]).arrayValue!
        for (n, json) in docs.enumerated() {
            var r = Rand(n + 1)
            let a = SwiftPeer(schema, clientID: 101, doc: try schema.nodeFromJSON(json))
            let b = SwiftPeer(schema, clientID: 102)
            _ = try oracle.value("yPeerCreate", ["schema": schemaJSON, "id": "c", "clientID": 103])
            defer { _ = try? oracle.value("yPeerDestroy", ["id": "c"]) }
            let seed = a.take()
            b.receive(seed)
            _ = try oracle.value("yPeerApply", ["id": "c", "updates": .array(seed.map(b64))])
            for round in 0..<6 {
                randomEdits(a, &r, 1 + r.int(4))
                randomEdits(b, &r, 1 + r.int(4))
                _ = try oracle.value("yPeerRandomEdits", ["id": "c", "seed": .int(n * 100 + round), "count": .int(1 + r.int(4))])
                let fromA = a.take(), fromB = b.take()
                let fromC = try oracle.value("yPeerTakeUpdates", ["id": "c"]).arrayValue!.map(data)
                a.receive(fromB + fromC)
                b.receive(fromA + fromC)
                let c = try oracle.value("yPeerApply", ["id": "c", "updates": .array((fromA + fromB).map(b64))])
                // Fixes made while reading (dropped invalid nodes, merged texts) go round until quiet.
                for _ in 0..<4 {
                    let fixA = a.take(), fixB = b.take()
                    let fixC = try oracle.value("yPeerTakeUpdates", ["id": "c"]).arrayValue!.map(data)
                    if fixA.isEmpty && fixB.isEmpty && fixC.isEmpty { break }
                    a.receive(fixB + fixC); b.receive(fixA + fixC)
                    _ = try oracle.value("yPeerApply", ["id": "c", "updates": .array((fixA + fixB).map(b64))])
                }
                let cDoc = try oracle.value("yPeerDoc", ["id": "c"])
                _ = c
                // No doc.check(): concurrent formatting can leave mutually exclusive marks
                // together (code + italic), in y-prosemirror as here.
                if let d = sameDoc(a.state.doc.toJSON(), b.state.doc.toJSON()) { return XCTFail("doc \(n) round \(round) A vs B: \(d)") }
                if let d = sameDoc(a.state.doc.toJSON(), cDoc) { return XCTFail("doc \(n) round \(round) A vs JS: \(d)\nA: \(a.state.doc.toJSON())\nJS: \(cDoc)\nJSY: \((try? oracle.value("yPeerDump", ["id": "c"])) ?? .null)\nSWY: \(a.ydoc.read { dumpY(a.binding.fragment, $0) })\nCAFTER: \((try? oracle.value("yPeerApply", ["id": "c", "updates": [b64(a.ydoc.encodeStateAsUpdate())]])) ?? .null)\nAAFTER: \({ a.receive([data(try! oracle.value("yPeerDiff", ["id": "c"]))]); return a.state.doc.toJSON() }())") }
            }
        }
    }

    /// Undo reverts only this editor's own changes, leaving a collaborator's alone.
    func testUndoIsPerUser() throws {
        let schema = Schemas.tiptap
        let doc = try schema.nodeFromJSON(["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Hello"]]]]])
        let a = SwiftPeer(schema, clientID: 1, doc: doc)
        let b = SwiftPeer(schema, clientID: 2)
        b.receive(a.take())
        a.binding.stopCapturing()

        a.dispatch(try a.state.tr.insertText(" world", 6))
        b.receive(a.take())
        b.dispatch(try b.state.tr.insertText("Oh, ", 1))
        a.receive(b.take())
        XCTAssertEqual(a.state.doc.textContent, "Oh, Hello world")

        XCTAssertTrue(a.binding.undo())
        a.pull()
        XCTAssertEqual(a.state.doc.textContent, "Oh, Hello")
        b.receive(a.take())
        XCTAssertEqual(b.state.doc.textContent, "Oh, Hello")
        XCTAssertTrue(a.binding.redo())
        a.pull()
        XCTAssertEqual(a.state.doc.textContent, "Oh, Hello world")
    }

    /// Tiptap reads `colwidth` (an array, or null) to size columns: it must cross Yjs intact
    /// both ways, including zeros and a colspan cell's per-column widths.
    func testColwidthArrayRoundTrip() throws {
        func cell(_ colspan: Int, _ colwidth: JSONValue) -> JSONValue {
            ["type": "tableCell", "attrs": ["colspan": .int(colspan), "rowspan": 1, "colwidth": colwidth],
             "content": [["type": "paragraph"]]]
        }
        let json: JSONValue = ["type": "doc", "content": [["type": "table", "content": [
            ["type": "tableRow", "content": [cell(1, [120]), cell(1, [0]), cell(1, .null)]],
            ["type": "tableRow", "content": [cell(2, [80, 140]), cell(1, [95.5])]],
        ]]]]
        let doc = try Schemas.tiptap.nodeFromJSON(json)
        let peer = SwiftPeer(Schemas.tiptap, clientID: 1, doc: doc)
        let decoded = try oracle.value("yDecodeDoc", ["schema": Schemas.tiptapJSON, "update": b64(peer.ydoc.encodeStateAsUpdate())])
        if let d = sameDoc(decoded, doc.toJSON()) { XCTFail("Swift->JS: \(d)") }
        let other = YDocument(clientID: 2)
        XCTAssertTrue(other.applyUpdate(data(try oracle.value("yEncodeDoc", ["schema": Schemas.tiptapJSON, "doc": doc.toJSON()]))))
        let back = YSyncBinding(doc: other, schema: Schemas.tiptap).documentFromY()
        if let d = sameDoc(back?.toJSON() ?? .null, doc.toJSON()) { XCTFail("JS->Swift: \(d)") }
    }

    func testSeedIsNotUndoable() throws {
        let doc = try Schemas.tiptap.nodeFromJSON(["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Hi"]]]]])
        let a = SwiftPeer(Schemas.tiptap, clientID: 1, doc: doc)
        XCTAssertFalse(a.binding.canUndo)
    }

    /// Every document y-prosemirror writes round-trips without loss.
    func testRoundTripIsLosslessForJSDocs() throws {
        let docs = try oracle.value("randomDocs", ["schema": Schemas.tiptapJSON, "seed": 3, "count": .int(fuzzCount(100))]).arrayValue!
        for (i, json) in docs.enumerated() {
            let ydoc = YDocument(clientID: 2)
            XCTAssertTrue(ydoc.applyUpdate(data(try oracle.value("yEncodeDoc", ["schema": Schemas.tiptapJSON, "doc": json]))))
            let check = YSyncBinding.roundTrip(ydoc, schema: Schemas.tiptap)
            XCTAssertTrue(check.lossless, "doc \(i)")
            if let d = sameDoc(check.document?.toJSON() ?? .null, json) { return XCTFail("doc \(i): \(d)") }
        }
        XCTAssertTrue(YSyncBinding.roundTrip(YDocument(), schema: Schemas.tiptap).lossless)
    }

    /// Content the schema can't represent is reported, and the shared document is left alone.
    func testRoundTripReportsUnknownContentWithoutTouchingIt() throws {
        func check(_ build: (YTransaction, YBranch) -> Void) -> Bool {
            let ydoc = YDocument(clientID: 1)
            let fragment = ydoc.xmlFragment("content")
            ydoc.transact { txn in
                let p = fragment.insertElement(txn, 0, "paragraph")
                p.insertText(txn, 0).insertString(txn, 0, "Kept")
                build(txn, fragment)
            }
            let before = ydoc.encodeStateAsUpdate()
            let lossless = YSyncBinding.roundTrip(ydoc, schema: Schemas.tiptap).lossless
            XCTAssertEqual(ydoc.encodeStateAsUpdate(), before)
            return lossless
        }
        XCTAssertTrue(check { _, _ in })
        XCTAssertFalse(check { txn, f in f.insertElement(txn, 1, "mysteryBlock").insertText(txn, 0).insertString(txn, 0, "x") })
        XCTAssertFalse(check { txn, f in f.insertElement(txn, 1, "paragraph").insertText(txn, 0).insertString(txn, 0, "x", attributes: ["comment": ["id": "1"]]) })
        // An attr the schema doesn't have is lost too.
        XCTAssertFalse(check { txn, f in f.insertElement(txn, 1, "paragraph").setAttribute(txn, "dir", "rtl") })

        // Differences that lose nothing don't count:
        // attrs written before the schema had them (old notes lack textAlign, link target)...
        XCTAssertTrue(check { txn, f in
            let p = f.insertElement(txn, 1, "paragraph")
            p.insertText(txn, 0).insertString(txn, 0, "old", attributes: ["link": ["href": "https://example.com"]])
            f.insertElement(txn, 2, "heading")
        })
        // ...a text emptied by deleting everything in it...
        XCTAssertTrue(check { txn, f in
            let t = f.insertElement(txn, 1, "paragraph").insertText(txn, 0)
            t.insertString(txn, 0, "gone")
            t.removeText(txn, 0, 4)
        })
        // ...and two adjacent texts, which the editor shows as one text node.
        XCTAssertTrue(check { txn, f in
            let p = f.insertElement(txn, 1, "paragraph")
            p.insertText(txn, 0).insertString(txn, 0, "one ")
            p.insertText(txn, 1).insertString(txn, 0, "two")
        })
    }

    /// The reason for a lossy note names the place by structure, never the text.
    func testRoundTripDifferenceHasNoText() {
        let ydoc = YDocument(clientID: 1)
        let fragment = ydoc.xmlFragment("content")
        ydoc.transact { txn in
            fragment.insertElement(txn, 0, "paragraph").insertText(txn, 0).insertString(txn, 0, "Secret words")
            fragment.insertElement(txn, 1, "paragraph").setAttribute(txn, "dir", "rtl")
        }
        let check = YSyncBinding.roundTrip(ydoc, schema: Schemas.tiptap)
        let difference = try? XCTUnwrap(check.difference)
        XCTAssertEqual(difference, "content>1 (paragraph): attrs dir: string(3) vs null")
        XCTAssertFalse(difference?.contains("Secret") ?? true)
    }

    /// A local change made while Yjs holds unpulled remote changes isn't written over them.
    func testLocalChangeNeverOverwritesUnpulledRemote() throws {
        let schema = Schemas.tiptap
        let doc = try schema.nodeFromJSON(["type": "doc", "content": [
            ["type": "paragraph", "content": [["type": "text", "text": "one"]]],
            ["type": "paragraph", "content": [["type": "text", "text": "two"]]]]])
        let a = SwiftPeer(schema, clientID: 1, doc: doc)
        let b = SwiftPeer(schema, clientID: 2)
        b.receive(a.take())
        b.dispatch(try b.state.tr.insertText("!", 9))
        // a gets b's update but (as during a composition) hasn't pulled it yet.
        for u in b.take() { XCTAssertTrue(a.ydoc.applyUpdate(u, origin: "remote")) }
        XCTAssertTrue(a.binding.hasRemoteChanges)
        let tr = try a.state.tr.insertText("?", 4)
        a.state = a.state.apply(tr)
        XCTAssertFalse(a.binding.localStateChanged(a.state, tr))
        a.pull()
        XCTAssertEqual(a.state.doc.textContent, "onetwo!", "b's edit survives; a's unsynced one is replaced")
        // Pulled first, the same edit goes through.
        a.dispatch(try a.state.tr.insertText("?", 4))
        b.receive(a.take())
        XCTAssertEqual(b.state.doc.textContent, "one?two!")
    }

    /// Sync cost on a long note: one keystroke out, one remote keystroke in.
    func testPerformanceOnLongNote() throws {
        let schema = Schemas.tiptap
        var blocks: [JSONValue] = []
        for i in 0..<2000 { blocks.append(["type": "paragraph", "content": [["type": "text", "text": .string("Paragraph \(i) with some text in it, about a sentence long.")]]]) }
        let doc = try schema.nodeFromJSON(["type": "doc", "content": .array(blocks)])
        let a = SwiftPeer(schema, clientID: 1, doc: doc)
        let b = SwiftPeer(schema, clientID: 2)
        b.receive(a.take())
        var local: [Double] = [], remote: [Double] = []
        for i in 0..<50 {
            let pos = 1000 * 60 + i
            let t0 = DispatchTime.now().uptimeNanoseconds
            a.dispatch(try a.state.tr.insertText("x", pos))
            let t1 = DispatchTime.now().uptimeNanoseconds
            b.receive(a.take())
            let t2 = DispatchTime.now().uptimeNanoseconds
            local.append(Double(t1 - t0) / 1e6)
            remote.append(Double(t2 - t1) / 1e6)
        }
        XCTAssertEqual(a.state.doc.textContent, b.state.doc.textContent)
        let median = { (xs: [Double]) in xs.sorted()[xs.count / 2] }
        print(String(format: "YSYNC PERF 2000 blocks: local keystroke -> Yjs %.2f ms, remote keystroke -> editor %.2f ms (median of 50)", median(local), median(remote)))
    }

    /// A remote insert before the caret keeps the caret on the same character.
    func testSelectionFollowsRemoteEdits() throws {
        let schema = Schemas.tiptap
        let doc = try schema.nodeFromJSON(["type": "doc", "content": [
            ["type": "paragraph", "content": [["type": "text", "text": "abc"]]],
            ["type": "paragraph", "content": [["type": "text", "text": "def"]]],
        ]])
        let a = SwiftPeer(schema, clientID: 1, doc: doc)
        let b = SwiftPeer(schema, clientID: 2)
        b.receive(a.take())
        // Caret between "d" and "ef".
        a.dispatch(a.state.tr.setSelection(TextSelection.create(a.state.doc, 7)))
        b.dispatch(try b.state.tr.insertText("XYZ", 1))
        b.dispatch(try b.state.tr.split(9))
        a.receive(b.take())
        XCTAssertEqual(a.state.doc.textContent, "XYZabcdef")
        let sel = a.state.selection
        XCTAssertEqual(sel.headPos.parent.textContent, "def")
        XCTAssertEqual(sel.headPos.parentOffset, 1)
    }
}

/// One scenario step on a live view (the subset random sessions use).
private func applyStep(_ step: JSONValue, _ view: HeadlessView, _ schema: Schema) {
    if let text = step["type"]?.stringValue {
        for ch in text {
            let from = view.state.selection.from, to = view.state.selection.to
            if !view.handleTextInput(from, to, String(ch)), let tr = try? view.state.tr.insertText(String(ch), from, to) { view.dispatch(tr) }
        }
    } else if let key = step["key"]?.stringValue {
        _ = view.handleKeyDown(scenarioKeyEvent(key))
    } else if let sel = step["select"]?.arrayValue {
        let a = sel[0].intValue!, h = sel.count > 1 ? sel[1].intValue ?? a : a
        view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, a, h)))
    } else if let pos = step["selectNode"]?.intValue {
        guard view.state.doc.resolve(pos).nodeAfter != nil else { return XCTFail("selectNode \(pos) in \(view.state.doc)") }
        view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, pos)))
    } else if step["selectAll"]?.truthy == true {
        view.dispatch(view.state.tr.setSelection(AllSelection(view.state.doc)))
    }
}

extension YSyncTests {
    /// Swapping a text's marks for as many others is written to Yjs. Comparing only the mark
    /// attrs, an attr-less mark (italic) matched a missing one and the change was skipped.
    func testSwappedMarksReachYjs() throws {
        let schema = Schemas.tiptap
        let doc = try schema.nodeFromJSON(["type": "doc", "content": [["type": "paragraph", "content": [
            ["type": "text", "text": "xyz", "marks": [["type": "italic"], ["type": "underline"]]]]]]])
        let a = SwiftPeer(schema, clientID: 1, doc: doc)
        _ = a.take()
        var tr = a.state.tr
        _ = try tr.removeMark(1, 4, schema.marks["italic"]!)
        _ = try tr.removeMark(1, 4, schema.marks["underline"]!)
        _ = try tr.addMark(1, 4, try schema.marks["bold"]!.create())
        _ = try tr.addMark(1, 4, try schema.marks["strike"]!.create())
        a.dispatch(tr)
        let fresh = SwiftPeer(schema, clientID: 2)
        fresh.receive([a.ydoc.encodeStateAsUpdate()])
        XCTAssertNil(sameDoc(fresh.state.doc.toJSON(), a.state.doc.toJSON()))
    }
}
