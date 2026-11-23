#if os(macOS)
import XCTest
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// One EditorCore shared by several views: every view follows it, observers hear each change once.
@MainActor
final class EditorCoreTests: XCTestCase {
    private func core(_ text: String) throws -> EditorCore {
        EditorCore(state: TestDocs.state(try TestDocs.paragraphs([text])))
    }

    private final class Recorder: EditorCoreObserver {
        var calls: [Transaction?] = []
        func coreDidUpdate(_ core: EditorCore, _ tr: Transaction?) { calls.append(tr) }
    }

    func testTwoViewsShareCore() throws {
        let core = try core("ab")
        let a = ProseTextView(core: core, style: BasicStyle())
        let b = ProseTextView(core: core, style: BasicStyle())
        a.dispatch(try a.state.tr.insertText("X", 2))
        XCTAssertEqual(b.textStorage?.string, "aXb\n")
        XCTAssertTrue(a.state === b.state)
        XCTAssertTrue(core.state === a.state)
    }

    func testObserversNotifiedOnce() throws {
        let core = try core("ab")
        let recorder = Recorder()
        core.addObserver(recorder)
        var changes = 0
        core.onChange = { _, _ in changes += 1 }
        core.dispatch(try core.state.tr.insertText("X", 1))
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertNotNil(recorder.calls.first ?? nil)
        XCTAssertEqual(changes, 1)
        core.removeObserver(recorder)
        core.dispatch(try core.state.tr.insertText("Y", 1))
        XCTAssertEqual(recorder.calls.count, 1)
    }

    func testSetStateNotifiesWithNilTransaction() throws {
        let core = try core("ab")
        let recorder = Recorder()
        core.addObserver(recorder)
        let view = ProseTextView(core: core, style: BasicStyle())
        let other = try self.core("new text")
        core.setState(other.state)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertNil(recorder.calls[0])
        XCTAssertEqual(view.textStorage?.string, "new text\n")
    }

    func testViewOnChangeStillFires() throws {
        let view = ProseTextView(state: try core("ab").state, style: BasicStyle())
        var seen: Transaction?
        view.onChange = { _, tr in seen = tr }
        view.dispatch(try view.state.tr.insertText("Z", 1))
        XCTAssertNotNil(seen)
        XCTAssertEqual(view.textStorage?.string, "Zab\n")
    }
}
#endif
