#if os(macOS)
import XCTest
import AppKit
import Darwin
import PMModel
import PMState
@testable import PMTextKit
import PMExampleSetup

/// The view treats the pasteboard as another app's input: file URLs are read only when they
/// name a regular file under the size limit, a drag decides its operation without reading
/// files, and only this process's own cut token makes a paste a move.
@MainActor
final class PasteboardHardeningTests: XCTestCase {
    private var boards: [NSPasteboard] = []
    private var temps: [URL] = []
    private var savedLimit = ProseTextView.maxIncomingFileSize

    override func setUp() {
        super.setUp()
        savedLimit = ProseTextView.maxIncomingFileSize
    }

    override func tearDown() {
        ProseTextView.maxIncomingFileSize = savedLimit
        for b in boards { b.releaseGlobally() }
        boards = []
        for url in temps { try? FileManager.default.removeItem(at: url) }
        temps = []
        super.tearDown()
    }

    private func board() -> NSPasteboard {
        let b = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        boards.append(b)
        return b
    }

    private func tempURL(_ ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pm-hardening-\(UUID().uuidString).\(ext)")
        temps.append(url)
        return url
    }

    private func tempFile(_ data: Data, ext: String = "txt") throws -> URL {
        let url = tempURL(ext)
        try data.write(to: url)
        return url
    }

    private func fifo() throws -> URL {
        let url = tempURL("fifo")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0, "mkfifo")
        return url
    }

    private func board(with urls: [URL]) -> NSPasteboard {
        let b = board()
        b.clearContents()
        XCTAssertTrue(b.writeObjects(urls as [NSURL]))
        return b
    }

    private func view(blocks: [JSONValue] = [J.p("Seeds"), J.p("")]) throws -> ProseTextView {
        let doc = try TestDocs.doc(blocks)
        let state = EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atEnd(doc), plugins: exampleSetup(schema: TestDocs.schema)))
        let v = ProseTextView(state: state, style: BasicStyle())
        v.pasteboard = board()
        return v
    }

    // MARK: Files

    func testRegularFileUnderTheLimitIsRead() throws {
        let url = try tempFile(Data("hello".utf8))
        let files = ProseTextView.files(on: board(with: [url]))
        XCTAssertEqual(files.map(\.data), [Data("hello".utf8)])
        XCTAssertEqual(files.first?.filename, url.lastPathComponent)
    }

    /// A FIFO would block the read forever; it's skipped without being opened.
    func testFIFOIsSkipped() throws {
        let pipe = try fifo()
        let regular = try tempFile(Data("ok".utf8))
        let files = ProseTextView.files(on: board(with: [pipe, regular]))
        XCTAssertEqual(files.map(\.data), [Data("ok".utf8)], "only the regular file")
    }

    /// A character device (endless zeros) and a directory are not regular files.
    func testDeviceAndDirectoryAreSkipped() throws {
        let dir = tempURL("dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(ProseTextView.files(on: board(with: [URL(fileURLWithPath: "/dev/zero"), dir])).isEmpty)
        XCTAssertNil(IncomingFileReader.read(URL(fileURLWithPath: "/dev/zero"), limit: 1 << 20))
    }

    func testFileOverTheLimitIsSkipped() throws {
        ProseTextView.maxIncomingFileSize = 8
        let small = try tempFile(Data(count: 8))
        let large = try tempFile(Data(count: 9))
        let files = ProseTextView.files(on: board(with: [large, small]))
        XCTAssertEqual(files.map(\.data.count), [8], "the file at the limit is read, the one past it is not")
    }

    func testDefaultLimitIs100MB() {
        XCTAssertEqual(IncomingFileReader.defaultLimit, 100 * 1024 * 1024)
        XCTAssertEqual(savedLimit, IncomingFileReader.defaultLimit)
    }

    func testEmptyRegularFileIsRead() throws {
        let url = try tempFile(Data())
        XCTAssertEqual(IncomingFileReader.read(url, limit: 10), Data())
        XCTAssertEqual(IncomingFileReader.read(url, limit: 10, mapped: true)?.count ?? 0, 0)
    }

    /// Pasting a pasteboard that names only a FIFO returns promptly and hands nothing over.
    func testPasteOfFIFOIsSkipped() throws {
        let v = try view()
        let pipe = try fifo()
        v.pasteboard.clearContents()
        XCTAssertTrue(v.pasteboard.writeObjects([pipe as NSURL]))
        var received: [[ProseTextView.IncomingFile]] = []
        v.onIncomingFiles = { files, _ in received.append(files); return true }
        v.paste(nil)
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: Drag

    /// Deciding a drag's operation reads no file: a FIFO on the drag pasteboard would block it.
    func testDropOperationReadsNoFiles() throws {
        let v = try view()
        v.onIncomingFiles = { _, _ in true }
        let pipe = try fifo()
        let drag = FakeDrag(board(with: [pipe]))
        XCTAssertEqual(v.dropOperation(drag), .copy, "a file URL offers a copy, unread")

        let empty = board()
        empty.clearContents()
        empty.setData(Data(), forType: NSPasteboard.PasteboardType("com.example.other"))
        XCTAssertEqual(v.dropOperation(FakeDrag(empty)), [])

        v.onIncomingFiles = nil
        XCTAssertEqual(v.dropOperation(drag), [], "no handler, no file drop")
    }

    /// The drop itself reads the files; one with nothing readable (a FIFO) is refused.
    func testPerformDropReadsFilesOnlyThen() throws {
        let v = try view()
        var received: [[Data]] = []
        v.onIncomingFiles = { files, _ in received.append(files.map(\.data)); return true }
        let url = try tempFile(Data("dropped".utf8))
        XCTAssertTrue(v.performDragOperation(FakeDrag(board(with: [url]))))
        XCTAssertEqual(received, [[Data("dropped".utf8)]])

        XCTAssertFalse(v.performDragOperation(FakeDrag(board(with: [try fifo()]))))
        XCTAssertEqual(received.count, 1, "nothing readable, nothing handed over")
    }

    // MARK: Cut marker

    /// A slice with a cut marker this process never minted pastes as a copy, every time.
    func testForeignCutMarkerIsACopy() throws {
        let v = try view()
        var origins: [PasteOrigin] = []
        v.adoptPasted = { slice, origin in origins.append(origin); return slice }
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 0, v.state.doc.child(0).nodeSize)))
        v.copy(nil)
        v.pasteboard.addTypes([ProseTextView.cutMarkerType], owner: nil)
        v.pasteboard.setString(UUID().uuidString, forType: ProseTextView.cutMarkerType)
        v.dispatch(v.state.tr.setSelection(Selection.atEnd(v.state.doc)))
        v.paste(nil)
        v.paste(nil)
        XCTAssertEqual(origins, [.copy, .copy])
    }

    /// Only the latest cut's token counts; earlier ones are forgotten, and foreign markers are
    /// never remembered.
    func testOnlyTheLatestCutTokenIsAMove() {
        let first = PasteOrigin.newCutToken()
        let second = PasteOrigin.newCutToken()
        XCTAssertEqual(PasteOrigin.forPaste(marker: first), .copy, "superseded")
        XCTAssertEqual(PasteOrigin.forPaste(marker: "forged"), .copy)
        XCTAssertEqual(PasteOrigin.pendingCutToken, second, "a foreign marker leaves the pending token alone")
        XCTAssertEqual(PasteOrigin.forPaste(marker: second), .move)
        XCTAssertNil(PasteOrigin.pendingCutToken, "used up")
        XCTAssertEqual(PasteOrigin.forPaste(marker: second), .copy)
        XCTAssertEqual(PasteOrigin.forPaste(marker: nil), .copy)
        XCTAssertEqual(PasteOrigin.forPaste(marker: ""), .copy)
    }

    /// A real cut still moves once.
    func testOwnCutStillMovesOnce() throws {
        let v = try view()
        var origins: [PasteOrigin] = []
        v.adoptPasted = { slice, origin in origins.append(origin); return slice }
        v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 0, v.state.doc.child(0).nodeSize)))
        v.cut(nil)
        v.dispatch(v.state.tr.setSelection(Selection.atEnd(v.state.doc)))
        v.paste(nil)
        v.paste(nil)
        XCTAssertEqual(origins, [.move, .copy])
    }
}

/// A drag that only has a pasteboard, for asking the view what it would do.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
