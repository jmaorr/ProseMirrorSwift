#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
@testable import PMTextKit

/// A scroll step in a document with many cards (boxes with shadows, from `CheckCardStyle`)
/// draws (almost) nothing: the decoration tiles keep their drawing. Counted, not timed.
@MainActor
final class IOSScrollCostTests: XCTestCase {
    func testScrollStepsAreCheapWithManyCards() throws {
        for cards in [10, 400] {
            let draws = try scrollDraws(cards: cards)
            XCTAssertLessThanOrEqual(draws, 3, "\(cards) cards: tile draws in 60 steps of 12 pt")
        }
    }

    private func scrollDraws(cards: Int) throws -> Int {
        var content: [JSONValue] = []
        for i in 0..<cards {
            content.append(J.p("Paragraph \(i) with some words in it to fill a line."))
            content.append(CheckCard.json("Task \(i)", description: ["Description \(i)"]))
        }
        let doc = try CheckCard.doc(content)
        let view = ProseTextView(state: CheckCard.state(doc), style: CheckCardStyle())
        view.animatesChrome = false
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        view.frame = window.bounds
        view.layoutIfNeeded()
        for t in view.decorations.subviews { t.layer.displayIfNeeded() }
        let draws0 = view.decorations.drawCount
        for i in 1...60 {
            view.contentOffset = CGPoint(x: 0, y: CGFloat(i) * 12)
            view.layoutIfNeeded()
            for t in view.decorations.subviews { t.layer.displayIfNeeded() }
        }
        return view.decorations.drawCount - draws0
    }
}
#endif
