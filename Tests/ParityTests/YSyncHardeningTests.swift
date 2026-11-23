import XCTest
import PMModel
import PMState
@testable import YSync

/// What a hostile collaboration server or peer can send: none of it may crash the client,
/// and reading it must not write (and so broadcast) anything.
final class YSyncHardeningTests: XCTestCase {
    /// Collects the updates `doc` produces itself (not ones applied with origin "remote").
    final class Outgoing {
        var updates: [Data] = []
        init(_ doc: YDocument) { doc.onUpdate { [unowned self] update, origin in if origin != "remote" { updates.append(update) } } }
    }

    func provider(_ doc: YDocument = YDocument(clientID: 1)) throws -> YWebsocketProvider {
        try YWebsocketProvider(url: URL(string: "wss://example.com/room")!, doc: doc)
    }

    // MARK: Wire format

    /// A sync-step-2 frame whose payload length is 2^63 - 1: `pos + count` used to overflow.
    func testHugeLengthFrameIsIgnored() throws {
        let frame = Data([0x00, 0x02] + [UInt8](repeating: 0xFF, count: 8) + [0x7F])
        var decoder = Lib0Decoder(frame)
        XCTAssertEqual(decoder.varUInt(), 0)
        XCTAssertEqual(decoder.varUInt(), 2)
        XCTAssertNil(decoder.varBytes())
        let doc = YDocument(clientID: 1)
        try provider(doc).handle(frame)
        XCTAssertEqual(doc.encodeStateVector(), YDocument(clientID: 2).encodeStateVector())
    }

    /// varUInt accepts what lib0 accepts (up to 2^53 - 1) and nothing larger or truncated.
    func testVarUIntRejectsValuesThatDontFit() {
        func decode(_ bytes: [UInt8]) -> Int? { var d = Lib0Decoder(Data(bytes)); return d.varUInt() }
        func encode(_ v: Int) -> [UInt8] { var e = Lib0Encoder(); e.varUInt(v); return [UInt8](e.data) }
        for v in [0, 1, 127, 128, 300, 1 << 32, (1 << 53) - 1] { XCTAssertEqual(decode(encode(v)), v) }
        XCTAssertNil(decode(encode(1 << 53)))
        XCTAssertNil(decode([UInt8](repeating: 0xFF, count: 9) + [0x01]))
        XCTAssertNil(decode([0x80, 0x80]))
        // A length longer than what's left.
        var d = Lib0Decoder(Data([0x05, 0x01, 0x02]))
        XCTAssertNil(d.varBytes())
        // Works on a slice whose indices don't start at 0.
        let slice = Data([0x09, 0x02, 0xAA, 0xBB, 0xCC]).dropFirst()
        var s = Lib0Decoder(slice)
        XCTAssertEqual(s.varBytes(), Data([0xAA, 0xBB]))
        XCTAssertNil(s.varBytes())
    }

    /// Empty updates (sync step 2 and update frames with a zero-length payload) used to
    /// force-unwrap a nil base address.
    func testEmptyUpdatesAreRejected() throws {
        let doc = YDocument(clientID: 1)
        XCTAssertFalse(doc.applyUpdate(Data()))
        let p = try provider(doc)
        p.handle(Data([0x00, 0x02, 0x00]))
        p.handle(Data([0x00, 0x01, 0x00]))
        p.handle(Data([0x00, 0x00]))  // truncated: no payload length
        XCTAssertFalse(doc.applyUpdate(Data([0xFF, 0xFF, 0xFF])))
    }

    /// A state vector yrs can't decode used to force-unwrap a null diff.
    func testGarbageStateVectorIsIgnored() throws {
        let doc = YDocument(clientID: 1)
        let fragment = doc.xmlFragment("content")
        doc.transact { txn in fragment.insertElement(txn, 0, "paragraph").insertText(txn, 0).insertString(txn, 0, "x") }
        for garbage in [Data([0x05]), Data([0x01, 0xFF]), Data([0x02, 0x01])] {
            XCTAssertNil(doc.encodeDiff(garbage))
            XCTAssertEqual(doc.encodeStateAsUpdate(garbage), Data())
            var e = Lib0Encoder()
            e.varUInt(0); e.varUInt(0); e.varBytes(garbage)
            try provider(doc).handle(e.data)
        }
        // Empty and valid state vectors still work.
        XCTAssertEqual(doc.encodeDiff(Data()), doc.encodeStateAsUpdate())
        XCTAssertNotNil(doc.encodeDiff(YDocument(clientID: 2).encodeStateVector()))
    }

    // MARK: Branch identity

    func testBranchIDsForRootsAndLargeClientIDs() {
        let client: UInt64 = (1 << 53) - 1
        let doc = YDocument(clientID: client)
        let fragment = doc.xmlFragment("content")
        XCTAssertEqual(fragment.id.root, "content")
        XCTAssertNil(fragment.id.client)
        let el = doc.transact { fragment.insertElement($0, 0, "paragraph") }
        XCTAssertEqual(el.id.client, client)
        XCTAssertNil(el.id.root)
        XCTAssertNotEqual(el.id, fragment.id)
    }

    // MARK: Depth

    /// A 5000-deep remote tree: reading, comparing and canonicalizing it stop at
    /// `maxDepth` instead of overflowing the stack, the deep part is dropped from the editor
    /// document, and nothing is written back.
    func testDeeplyNestedRemoteDocumentIsCapped() throws {
        let schema = Schemas.tiptap
        let remote = YDocument(clientID: 2)
        let remoteFragment = remote.xmlFragment("content")
        let depth = 5_000
        XCTAssertGreaterThan(depth, YSyncBinding.maxDepth)
        remote.transact { txn in
            remoteFragment.insertElement(txn, 0, "paragraph").insertText(txn, 0).insertString(txn, 0, "kept")
            var parent = remoteFragment.insertElement(txn, 1, "blockquote")
            for _ in 0..<depth { parent = parent.insertElement(txn, 0, "blockquote") }
            parent.insertElement(txn, 0, "paragraph").insertText(txn, 0).insertString(txn, 0, "deep")
        }
        let update = remote.encodeStateAsUpdate()

        let peer = SwiftPeer(schema, clientID: 1)
        let outgoing = Outgoing(peer.ydoc)
        peer.receive([update])
        XCTAssertEqual(peer.state.doc.textContent, "kept")
        XCTAssertTrue(outgoing.updates.isEmpty, "reading wrote to Yjs")
        XCTAssertNotNil(peer.binding.documentFromY())
        XCTAssertTrue(outgoing.updates.isEmpty)

        let canonical = peer.ydoc.read { peer.binding.fragment.canonicalJSON($0) }
        XCTAssertTrue("\(canonical)".contains("truncated"))
        XCTAssertFalse(YSyncBinding.roundTrip(peer.ydoc, schema: schema).lossless)

        // A local edit compares against (and rewrites) the deep tree without recursing into all of it.
        peer.dispatch(try peer.state.tr.insertText("!", 5))
        XCTAssertEqual(peer.state.doc.textContent, "kept!")
    }

    /// Exactly at the cap the content is kept; one level deeper it's dropped.
    func testDepthCapBoundary() throws {
        func build(_ levels: Int) -> String? {
            let ydoc = YDocument(clientID: 2)
            let fragment = ydoc.xmlFragment("content")
            ydoc.transact { txn in
                // The fragment's children are depth 1, so `levels` blockquotes put the paragraph at levels + 1.
                var parent = fragment
                for _ in 0..<levels { parent = parent.insertElement(txn, 0, "blockquote") }
                parent.insertElement(txn, 0, "paragraph").insertText(txn, 0).insertString(txn, 0, "x")
            }
            return YSyncBinding(doc: ydoc, schema: Schemas.tiptap).documentFromY()?.textContent
        }
        XCTAssertEqual(build(YSyncBinding.maxDepth - 1), "x")
        XCTAssertNil(build(YSyncBinding.maxDepth))
    }

    /// Attribute values nested past the cap read as null.
    func testDeeplyNestedAttributeJSONIsCapped() {
        var value: JSONValue = "leaf"
        for _ in 0..<(YSyncBinding.maxDepth + 50) { value = .array([value]) }
        let ydoc = YDocument(clientID: 1)
        let fragment = ydoc.xmlFragment("content")
        ydoc.transact { txn in fragment.insertElement(txn, 0, "paragraph").setAttribute(txn, "deep", value) }
        let read = ydoc.read { txn in fragment.children(txn)[0].attributes(txn)["deep"] }
        var levels = 0
        var v = read
        while case .array(let items)? = v { levels += 1; v = items.first }
        XCTAssertEqual(levels, YSyncBinding.maxDepth)
        XCTAssertEqual(v, .null)
    }

    // MARK: Invalid remote content

    /// Elements and texts the schema rejects are left out of the editor's document without
    /// deleting them from Yjs, so merely receiving them broadcasts nothing.
    func testInvalidRemoteContentIsSkippedWithoutWriting() throws {
        let schema = Schemas.tiptap
        let doc = try schema.nodeFromJSON(["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Hello"]]]]])
        let a = SwiftPeer(schema, clientID: 1, doc: doc)
        let outgoing = Outgoing(a.ydoc)
        let remote = YDocument(clientID: 2)
        XCTAssertTrue(remote.applyUpdate(a.ydoc.encodeStateAsUpdate()))
        let fragment = remote.xmlFragment("content")
        var remoteUpdates: [Data] = []
        remote.onUpdate { update, _ in remoteUpdates.append(update) }
        remote.transact { txn in
            fragment.insertElement(txn, 1, "mysteryBlock").insertText(txn, 0).insertString(txn, 0, "unknown")
            fragment.insertElement(txn, 2, "paragraph").insertText(txn, 0).insertString(txn, 0, "badmark", attributes: ["nosuchmark": [:]])
            fragment.insertElement(txn, 3, "paragraph").insertText(txn, 0).insertString(txn, 0, "fine")
        }
        a.receive(remoteUpdates)
        XCTAssertTrue(outgoing.updates.isEmpty, "reading invalid remote content produced an outgoing update")
        XCTAssertFalse(a.state.doc.textContent.contains("unknown"))
        XCTAssertFalse(a.state.doc.textContent.contains("badmark"))
        XCTAssertTrue(a.state.doc.textContent.hasPrefix("Hello"))
        XCTAssertTrue(a.state.doc.textContent.hasSuffix("fine"))
        // Still in Yjs.
        let tags = a.ydoc.read { txn in a.binding.fragment.children(txn).map { $0.tag ?? "" } }
        XCTAssertTrue(tags.contains("mysteryBlock"))
        // And reading again (a fresh binding) still writes nothing.
        let again = SwiftPeer(schema, clientID: 3)
        let againOutgoing = Outgoing(again.ydoc)
        again.receive([a.ydoc.encodeStateAsUpdate()])
        XCTAssertTrue(againOutgoing.updates.isEmpty)
        XCTAssertEqual(again.state.doc.textContent, a.state.doc.textContent)
    }

    // MARK: Provider

    func testInsecureURLsAreRefused() throws {
        let doc = YDocument(clientID: 1)
        for url in ["ws://example.com/room", "ws://192.168.1.10:1234/room", "http://example.com/room", "ftp://example.com/x", "file:///tmp/x", "ws:///nohost"] {
            XCTAssertThrowsError(try YWebsocketProvider(url: URL(string: url)!, doc: doc), url) { error in
                XCTAssertEqual(error as? YWebsocketProvider.ProviderError, .insecureURL(URL(string: url)!))
            }
        }
        for url in ["wss://example.com/room", "ws://localhost:1234/room", "ws://127.0.0.1:1234/room", "ws://[::1]:1234/room", "WS://LOCALHOST/room", "https://example.com/room"] {
            XCTAssertNoThrow(try YWebsocketProvider(url: URL(string: url)!, doc: doc), url)
        }
        XCTAssertNoThrow(try YWebsocketProvider(url: URL(string: "ws://example.com/room")!, doc: doc, allowInsecure: true))

        // A URL changed to an insecure one later isn't connected to.
        let p = try YWebsocketProvider(url: URL(string: "wss://example.com/room")!, doc: doc)
        p.url = URL(string: "ws://example.com/room")!
        p.connect()
        XCTAssertEqual(p.status, .disconnected)
    }

    /// URLSession retains its delegate; the provider must still be freed, after
    /// `disconnect()` or without it.
    func testProviderIsReleased() throws {
        for callDisconnect in [true, false] {
            weak var weakProvider: YWebsocketProvider?
            try autoreleasepool {
                // Port 1 on loopback: refused at once, no traffic leaves the machine.
                let p = try YWebsocketProvider(url: URL(string: "ws://127.0.0.1:1/room")!, doc: YDocument(clientID: 1))
                weakProvider = p
                p.connect()
                XCTAssertEqual(p.status, .connecting)
                if callDisconnect { p.disconnect() }
            }
            XCTAssertNil(weakProvider, "provider leaked (disconnect: \(callDisconnect))")
        }
    }
}
