#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
@testable import PMTextKit
import PMExampleSetup

/// Chrome box shadows drawn from the cached nine-slice template look the same as the live blur.
@MainActor
final class ChromeShadowTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() {
        ChromeShadow.usesCache = true
        for w in windows { w.close() }
        windows = []
        super.tearDown()
    }

    /// Boxes of several heights (one line, two, four).
    private func makeView(shadow: Bool = true) throws -> ProseTextView {
        let doc = try TestDocs.doc([
            J.p("Before the boxes."),
            J.quote([J.p("One line only")]),
            J.quote([J.p("With a second line"), J.p("One line of description.")]),
            J.p("Between."),
            J.quote([J.p("Longer"), J.p("First paragraph."), J.p("Second paragraph."), J.p("Third paragraph, a bit longer than the others.")]),
            J.p("After."),
        ])
        var style = BoxedQuoteStyle()
        if !shadow { style.shadow = nil }
        let view = ProseTextView(state: TestDocs.state(doc), style: style)
        view.animatesChrome = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The view as AppKit draws it into a backing store of this scale, as RGBA bytes.
    private func render(_ view: ProseTextView, scale: CGFloat, cached: Bool, appearance: NSAppearance) -> [UInt8] {
        ChromeShadow.usesCache = cached
        view.appearance = appearance
        defer { view.appearance = nil }
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    func testCachedShadowMatchesTheLiveBlur() throws {
        let view = try makeView()
        let pos = try XCTUnwrap(view.renderer.chromes.first?.pos)
        XCTAssertNotNil(view.chromeFrame(at: pos))
        XCTAssertNotNil(view.renderer.chromes.first?.box.shadow)
        for scale: CGFloat in [1, 2] {
            for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
                let live = render(view, scale: scale, cached: false, appearance: appearance)
                let cached = render(view, scale: scale, cached: true, appearance: appearance)
                // The shadows are there to compare: without them the picture changes.
                let shadowless = render(try makeView(shadow: false), scale: scale, cached: true, appearance: appearance)
                XCTAssertGreaterThan(maxDifference(live, shadowless), 5, "no shadow drawn at \(scale)x")
                XCTAssertLessThanOrEqual(maxDifference(live, cached), 3, "scale \(scale) \(appearance.name.rawValue)")
            }
        }
    }

    /// Faded part way (a box opening), the cached shadow fades the same.
    func testCachedShadowFadesWithProgress() throws {
        let view = try makeView()
        let region = try XCTUnwrap(view.renderer.chromes.first { $0.box.shadow != nil })
        let rect = try XCTUnwrap(view.chromeRect(region))
        func draw(cached: Bool) -> [UInt8] {
            ChromeShadow.usesCache = cached
            let w = 200, h = 200
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            let box = CGRect(x: 30.3, y: 40.6, width: 140, height: min(rect.height, 120))
            let path = CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: region.box.cornerRadius,
                              cornerHeight: region.box.cornerRadius, transform: nil)
            ctx.addRect(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.addPath(path)
            ctx.clip(using: .evenOdd)
            if cached {
                XCTAssertTrue(ChromeShadow.draw(around: box, cornerRadius: region.box.cornerRadius, blur: region.box.shadowRadius,
                                                color: CGColor(gray: 0, alpha: 0.3), alpha: 0.4, in: ctx))
            } else {
                ctx.setShadow(offset: .zero, blur: region.box.shadowRadius, color: CGColor(gray: 0, alpha: 0.3 * 0.4))
            }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(path)
            ctx.fillPath()
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: data, count: w * h * 4))
        }
        let live = draw(cached: false), cached = draw(cached: true)
        XCTAssertGreaterThan(live.max() ?? 0, 5)
        XCTAssertLessThanOrEqual(maxDifference(live, cached), 3)
    }

    /// Boxes of one look share a template: a second draw renders no new templates.
    func testBoxesShareTemplates() throws {
        let view = try makeView()
        _ = render(view, scale: 2, cached: true, appearance: NSAppearance(named: .aqua)!)
        let before = ChromeShadow.renderCount
        _ = render(view, scale: 2, cached: true, appearance: NSAppearance(named: .aqua)!)
        XCTAssertEqual(ChromeShadow.renderCount, before, "a second draw renders no new templates")
    }
}
#endif
