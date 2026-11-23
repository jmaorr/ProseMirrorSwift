#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// Renders `BasicSchema.sampleDocument` through the AppKit ProseTextView (BasicStyle, tables as
/// grids) into PNGs (light and dark), so the output can be compared by eye before and after
/// changes to the renderer shared with iOS. Runs only with PM_RENDER_SNAPSHOTS=<dir>.
@MainActor
final class RenderSnapshotTests: XCTestCase {
    func testSampleDocumentForReview() throws {
        guard let dir = ProcessInfo.processInfo.environment["PM_RENDER_SNAPSHOTS"] else { throw XCTSkip("PM_RENDER_SNAPSHOTS not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let doc = BasicSchema.sampleDocument
            let state = EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atStart(doc),
                                                             plugins: exampleSetup(schema: BasicSchema.schema)))
            let tv = BasicStyle().makeTextView(state: state)
            tv.animatesChrome = false
            tv.animatesChecks = false
            tv.frame = NSRect(x: 0, y: 0, width: 520, height: 1250)
            tv.textContainerInset = NSSize(width: 24, height: 24)
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            tv.appearance = appearance
            tv.drawsBackground = true
            tv.backgroundColor = .textBackgroundColor
            window.contentView = tv
            tv.textLayoutManager!.ensureLayout(for: tv.textLayoutManager!.documentRange)
            tv.layoutSubtreeIfNeeded()
            let png = try XCTUnwrap(Self.render(tv))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macos-sample-\(dark ? "dark" : "light").png"))
        }
    }

    /// The view's own drawing (background, chrome, markers), then the text fragments, which
    /// TextKit 2 draws in layers that cacheDisplay misses.
    static func render(_ tv: ProseTextView) -> Data? {
        let rect = tv.bounds
        guard let rep = tv.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        tv.cacheDisplay(in: rect, to: rep)
        guard let tlm = tv.textLayoutManager, let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let c = gc.cgContext
        c.translateBy(x: 0, y: rect.height)
        c.scaleBy(x: 1, y: -1)
        tv.effectiveAppearance.performAsCurrentDrawingAppearance {
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
                let o = CGPoint(x: f.layoutFragmentFrame.minX + tv.textContainerOrigin.x, y: f.layoutFragmentFrame.minY + tv.textContainerOrigin.y)
                if o.y > rect.height { return false }
                f.draw(at: o, in: c)
                return true
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
