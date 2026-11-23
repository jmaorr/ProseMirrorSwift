#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTableView
import PMExampleSetup

/// Tables show as grids however the view reaches the screen: made first and put in a window
/// afterwards (as SwiftUI does it), or with a document set after it's in one.
@MainActor
final class LateWindowTableTests: XCTestCase {
    private func grids(_ v: NSView) -> [TableGridView] { ((v as? TableGridView).map { [$0] } ?? []) + v.subviews.flatMap(grids) }

    private func doc() throws -> Node {
        try TestDocs.doc([J.p("Before"), J.table([["Arrival", "Departure"], ["the logbook", "noon"]], header: true), J.p("After")])
    }

    func testTablesDrawWhenTheViewIsAddedToAWindowLater() throws {
        let view = BasicStyle().makeTextView(state: TestDocs.state(try doc()))
        view.animatesChrome = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 860, height: 900))
        scroll.documentView = view
        view.frame = scroll.bounds
        // Only now does it go on screen.
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(grids(scroll).count, 1)
        // Cell text lives in the grid, not as loose paragraphs.
        XCTAssertFalse(view.string.contains("the logbook"))
    }

    func testTablesDrawInADocumentSetLater() throws {
        let host = HostedTextView(try TestDocs.paragraphs(["x"]))
        host.view.setState(TestDocs.state(try doc()))
        host.settle()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.settle()
        XCTAssertEqual(grids(host.scroll).count, 1)
        XCTAssertFalse(host.view.string.contains("the logbook"))
    }
}
#endif
