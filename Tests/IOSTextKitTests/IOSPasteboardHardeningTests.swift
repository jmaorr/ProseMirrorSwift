#if os(iOS)
import XCTest
import UIKit
import Darwin
import UniformTypeIdentifiers
import PMModel
import PMState
@testable import PMTextKit
import PMExampleSetup

/// The iOS view treats pasteboard and drop content as another app's input: dropped files are
/// read only when regular and under the size limit, and only this process's own cut token
/// makes a paste a move.
@MainActor
final class IOSPasteboardHardeningTests: XCTestCase {
    private var hosts: [HostedTextView] = []
    private var boards: [UIPasteboard] = []
    private var savedLimit = ProseTextView.maxIncomingFileSize

    override func setUp() {
        super.setUp()
        savedLimit = ProseTextView.maxIncomingFileSize
    }

    override func tearDown() {
        ProseTextView.maxIncomingFileSize = savedLimit
        for host in hosts { host.window.isHidden = true }
        hosts = []
        for board in boards { UIPasteboard.remove(withName: board.name) }
        boards = []
        super.tearDown()
    }

    private func view(_ blocks: JSONValue...) throws -> ProseTextView {
        let host = inputHost(try TestDocs.doc(blocks))
        hosts.append(host)
        let board = UIPasteboard.withUniqueName()
        boards.append(board)
        host.view.pasteboard = board
        return host.view
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func load(_ providers: [NSItemProvider]) throws -> [ProseTextView.IncomingFile] {
        var loaded: [ProseTextView.IncomingFile]?
        ProseTextView.loadFiles(providers) { loaded = $0 }
        let deadline = Date().addingTimeInterval(5)
        while loaded == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return try XCTUnwrap(loaded)
    }

    private func fileProvider(_ url: URL, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { done in
            done(url, false, nil)
            return nil
        }
        return provider
    }

    // MARK: Files

    func testReaderSkipsFIFODeviceAndDirectory() throws {
        let dir = try tempDir()
        let pipe = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertNil(IncomingFileReader.read(pipe, limit: 1 << 20))
        XCTAssertNil(IncomingFileReader.read(pipe, limit: 1 << 20, mapped: true))
        XCTAssertNil(IncomingFileReader.read(URL(fileURLWithPath: "/dev/zero"), limit: 1 << 20, mapped: true))
        XCTAssertNil(IncomingFileReader.read(dir, limit: 1 << 20, mapped: true))
        let file = dir.appendingPathComponent("ok.txt")
        try Data("ok".utf8).write(to: file)
        XCTAssertEqual(IncomingFileReader.read(file, limit: 2, mapped: true), Data("ok".utf8))
        XCTAssertNil(IncomingFileReader.read(file, limit: 1, mapped: true))
    }

    /// A dropped file over `maxIncomingFileSize` is skipped; the others still arrive.
    func testDroppedFileOverTheLimitIsSkipped() throws {
        XCTAssertEqual(ProseTextView.maxIncomingFileSize, 100 * 1024 * 1024)
        ProseTextView.maxIncomingFileSize = 16
        let dir = try tempDir()
        let small = dir.appendingPathComponent("small.pdf")
        let large = dir.appendingPathComponent("large.pdf")
        try Data(count: 16).write(to: small)
        try Data(count: 17).write(to: large)
        let files = try load([fileProvider(large, type: .pdf), fileProvider(small, type: .pdf)])
        XCTAssertEqual(files.map(\.data.count), [16])
    }

    // MARK: Cut marker

    /// A slice carrying a cut marker this process never minted pastes as a copy, every time.
    func testForeignCutMarkerIsACopy() throws {
        let v = try view(J.quote([J.p("Mulch")]), J.p(""))
        var origins: [PasteOrigin] = []
        v.adoptPasted = { slice, origin in origins.append(origin); return slice }
        v.dispatch(v.state.tr.setSelection(NodeSelection.create(v.state.doc, 0)))
        v.copy(nil)
        var item = try XCTUnwrap(v.pasteboard.items.first)
        item[PasteOrigin.cutMarkerType] = UUID().uuidString
        v.pasteboard.items = [item]
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.paste(nil)
        v.paste(nil)
        XCTAssertEqual(origins, [.copy, .copy])
    }

    /// An earlier cut's token is no longer a move once a later cut was made.
    func testOnlyTheLatestCutMoves() throws {
        let v = try view(J.p("One"), J.p("Two"), J.p(""))
        var origins: [PasteOrigin] = []
        v.adoptPasted = { slice, origin in origins.append(origin); return slice }
        v.dispatch(v.state.tr.setSelection(NodeSelection.create(v.state.doc, 0)))
        v.cut(nil)
        let firstCut = v.pasteboard.items
        v.dispatch(v.state.tr.setSelection(NodeSelection.create(v.state.doc, 0)))
        v.cut(nil)
        let secondCut = v.pasteboard.items
        v.pasteboard.items = firstCut
        v.dispatch(v.state.tr.setSelection(TextSelection.atEnd(v.state.doc)))
        v.paste(nil)
        v.pasteboard.items = secondCut
        v.paste(nil)
        v.paste(nil)
        XCTAssertEqual(origins, [.copy, .move, .copy])
    }
}
#endif
