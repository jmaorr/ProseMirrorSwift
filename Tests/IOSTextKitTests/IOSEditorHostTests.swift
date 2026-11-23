#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// The iOS text view as a host puts it on screen: no shortcuts bar, and a long document is laid
/// out over the whole screen whether it arrives before or after the view is shown.
@MainActor
final class IOSEditorHostTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows { window.isHidden = true }
        windows = []
        super.tearDown()
    }

    private func textView() throws -> ProseTextView {
        BasicStyle().makeTextView(state: TestDocs.state(try TestDocs.paragraphs(["Short"])))
    }

    private func show(_ view: UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        view.frame = window.bounds
        view.layoutIfNeeded()
    }

    private func longDocument(_ tv: ProseTextView) throws -> EditorState {
        let doc = try TestDocs.doc([J.h(1, "Long")] + (0..<300).map { J.p("Line \($0) of a long document") })
        return EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atStart(doc), plugins: tv.state.plugins))
    }

    /// TextKit's viewport covers the screen from the top of the document.
    private func assertViewportCoversScreen(_ tv: ProseTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        let tlm = try XCTUnwrap(tv.textLayoutManager, file: file, line: line)
        let viewport = try XCTUnwrap(tlm.textViewportLayoutController.viewportRange, "viewport laid out", file: file, line: line)
        XCTAssertEqual(tlm.offset(from: tlm.documentRange.location, to: viewport.location), 0, "from the top", file: file, line: line)
        // 874 pt of ~25 pt lines: well over 20 paragraphs of ~25 characters.
        XCTAssertGreaterThan(tlm.offset(from: tlm.documentRange.location, to: viewport.endLocation), 20 * 25,
                             "down the whole screen", file: file, line: line)
    }

    /// The editor brings no iPad shortcuts bar of its own: apps add their own.
    func testNoShortcutsBar() throws {
        let tv = try textView()
        XCTAssertTrue(tv.inputAssistantItem.leadingBarButtonGroups.isEmpty)
        XCTAssertTrue(tv.inputAssistantItem.trailingBarButtonGroups.isEmpty)
    }

    /// A long document given to the text view before it's on screen is laid out once shown.
    func testLongDocumentIsLaidOutOnceShown() throws {
        let tv = try textView()
        tv.setState(try longDocument(tv))
        show(tv)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try assertViewportCoversScreen(tv)
    }

    /// A whole document arriving in one change while on screen (one synced after opening) is laid out.
    func testLongDocumentArrivingOnScreenIsLaidOut() throws {
        let tv = try textView()
        show(tv)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        tv.setState(try longDocument(tv))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try assertViewportCoversScreen(tv)
    }
}
#endif
