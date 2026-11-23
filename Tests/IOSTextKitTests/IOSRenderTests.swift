#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// What the iOS ProseTextView builds for a document: ink on screen (light and dark), decorated
/// layout fragments (markers, checkboxes in the margin, chrome boxes) and the decoration view
/// behind the text.
@MainActor
final class IOSRenderTests: XCTestCase {
    private var hosts: [HostedTextView] = []

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        super.tearDown()
    }

    private func host(_ doc: Node, style: DocStyle? = nil, dark: Bool = false) -> HostedTextView {
        let host = HostedTextView(doc, style: style, plugins: [], width: 402, dark: dark)
        host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 1100)
        host.settle()
        hosts.append(host)
        return host
    }

    /// BasicSchema's sample document, rendered through the layer tree, has plenty of ink in its
    /// top half, in light and in dark mode (not a golden image: only that something is drawn).
    func testSampleDocumentRendersInk() throws {
        for dark in [false, true] {
            let view = host(BasicSchema.sampleDocument, dark: dark).view
            let image = Self.render(view)
            XCTAssertGreaterThan(Self.inkPixels(image, dark: dark), 400, dark ? "dark" : "light")
        }
    }

    /// The window's own rendering of the view: the decoration view behind the text, and the
    /// text in TextKit's fragment views.
    static func render(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        // `drawHierarchy` needs the window on a screen, which a test bundle without a host app
        // doesn't have; the layer tree renders the same views without one.
        view.layer.setNeedsDisplay()
        view.layer.displayIfNeeded()
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            (view.backgroundColor ?? .systemBackground).setFill()
            context.fill(view.bounds)
            func display(_ l: CALayer) {
                l.displayIfNeeded()
                l.sublayers?.forEach(display)
            }
            display(view.layer)
            view.layer.render(in: context.cgContext)
        }
    }

    static func inkPixels(_ image: UIImage, dark: Bool) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var count = 0
        for y in stride(from: 0, to: h / 2, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let i = (y * w + x) * 4
                let lum = (Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])) / 3
                if dark ? lum > 180 : lum < 80 { count += 1 }
            }
        }
        return count
    }

    func testFragmentsCarryDecorations() throws {
        var style = InputTestStyle()
        style.quoteBox = ChromeBox()
        let doc = try InputTestSchema.doc([
            J.h(1, "Garden"),
            J.node("bullet_list", nil, [J.li([J.p("Tomatoes along the fence")])]),
            InputTestSchema.taskList([("Buy seed trays", false)]),
            J.quote([J.p("Water before nine"), J.p("and after six")]),
        ])
        let view = host(doc, style: style).view
        let string = view.textStorage.string as NSString
        // The bullet item's fragment carries the marker.
        let bullet = string.range(of: "Tomatoes").location
        let deco = try XCTUnwrap(view.textStorage.attribute(.pmBlock, at: bullet, effectiveRange: nil) as? BlockDecoration)
        if case .bullet = deco.marker {} else { XCTFail("expected a bullet, got \(String(describing: deco.marker))") }
        // The checkbox of "Buy seed trays" sits left of its text, in the margin.
        let task = string.range(of: "Buy seed trays").location
        let box = try XCTUnwrap(view.checkboxRect(atString: task))
        let tlm = try XCTUnwrap(view.textLayoutManager)
        let loc = try XCTUnwrap(tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: task))
        let fragment = try XCTUnwrap(tlm.textLayoutFragment(for: loc))
        XCTAssertEqual(String(describing: type(of: fragment)), "BlockLayoutFragment")
        XCTAssertLessThan(box.maxX, fragment.layoutFragmentFrame.minX + view.textContainerInset.left + InputTestStyle.checkboxIndent + 4)
        // The quote has a box around both its paragraphs.
        let quotePos = try XCTUnwrap(view.renderer.chromes.first { $0.box.activates }?.pos)
        XCTAssertEqual(view.state.doc.nodeAt(quotePos)?.type.name, "blockquote")
        let frame = try XCTUnwrap(view.chromeFrame(at: quotePos))
        XCTAssertGreaterThan(frame.height, 40)
    }

    func testDecorationViewSitsBehindTheText() throws {
        let view = host(BasicSchema.sampleDocument).view
        let first = try XCTUnwrap(view.subviews.first)
        XCTAssertEqual(String(describing: type(of: first)), "DecorationView")
        XCTAssertTrue(first.frame.intersects(CGRect(origin: view.contentOffset, size: view.bounds.size)))
    }
}
#endif
