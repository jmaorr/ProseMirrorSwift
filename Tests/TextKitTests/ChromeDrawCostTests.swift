#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
@testable import PMTextKit
import PMExampleSetup

/// Drawing the background (chrome boxes) for a strip exposed by scrolling looks only at the boxes
/// near the strip, whatever the length of the document. Counted, not timed, so the test doesn't
/// depend on the machine.
@MainActor
final class ChromeDrawCostTests: XCTestCase {
    func testDrawLooksOnlyAtNearbyBoxes() throws {
        let few = try regionsExamined(boxes: 10)
        let many = try regionsExamined(boxes: 400)
        XCTAssertGreaterThan(few, 0)
        XCTAssertLessThanOrEqual(many, few + 2, "regions looked at per strip: 10 boxes \(few), 400 boxes \(many)")
    }

    /// A strip drawn alone matches the same strip cut from a much taller draw: skipping the
    /// boxes far from the strip drops none that touch it.
    func testStripDrawsEveryBoxNearIt() throws {
        let (tv, mid) = try makeView(boxes: 400)
        var inked = 0
        for offset in stride(from: CGFloat(0), to: 150, by: 3) {
            let strip = NSRect(x: 0, y: mid + offset, width: 700, height: 20)
            let alone = render(tv, strip: strip) { tv.drawBackground(in: strip) }
            let cut = render(tv, strip: strip) { tv.drawBackground(in: strip.insetBy(dx: 0, dy: -400)) }
            if Set(alone).count > 2 { inked += 1 }
            XCTAssertTrue(alone == cut, "strip at \(offset)")
        }
        XCTAssertGreaterThan(inked, 20, "strips with boxes in them")
    }

    private func render(_ tv: ProseTextView, strip: NSRect, _ draw: () -> Void) -> [UInt8] {
        let w = Int(strip.width), h = Int(strip.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: strip.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -strip.minX, y: -strip.minY)
        ctx.clip(to: strip)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    /// Regions looked at, per draw of a 60 pt strip in the middle of the document.
    private func regionsExamined(boxes: Int) throws -> Int {
        let (tv, mid) = try makeView(boxes: boxes)
        let rect = NSRect(x: 0, y: mid, width: 700, height: 60)
        _ = render(tv, strip: rect) { tv.drawBackground(in: rect) }  // warm
        ChromeDrawStats.regionsExamined = 0
        let n = 10
        for i in 0..<n {
            let strip = rect.offsetBy(dx: 0, dy: CGFloat(i * 20))
            _ = render(tv, strip: strip) { tv.drawBackground(in: strip) }
        }
        return Int((Double(ChromeDrawStats.regionsExamined) / Double(n)).rounded(.up))
    }

    private var windows: [NSWindow] = []
    override func tearDown() { for w in windows { w.close() }; windows = []; super.tearDown() }

    /// A document of `boxes` paragraphs each followed by a boxed quote, scrolled to its middle.
    private func makeView(boxes: Int) throws -> (ProseTextView, CGFloat) {
        var blocks: [JSONValue] = []
        for i in 0..<boxes {
            blocks.append(J.p("Paragraph \(i) with some words in it to fill a line."))
            blocks.append(J.quote([J.p("Box \(i)"), J.p("Description \(i)")]))
        }
        let doc = try TestDocs.doc(blocks)
        let tv = ProseTextView(state: TestDocs.state(doc), style: BoxedQuoteStyle())
        tv.animatesChrome = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        scroll.documentView = tv
        tv.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = scroll
        tv.layoutSubtreeIfNeeded()
        // Scroll to the middle, as a reader would be.
        let mid = max(0, tv.frame.height / 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: mid))
        tv.layoutSubtreeIfNeeded()
        return (tv, mid)
    }
}
#endif
