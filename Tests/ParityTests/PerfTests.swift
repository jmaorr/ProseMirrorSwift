import XCTest
import Foundation
import PMModel
import PMState
import PMOracle

/// Rough keystroke cost: type characters into a large doc through the full
/// plugin setup (input rules, keymaps, history). Run in release for real numbers:
/// `swift test -c release --filter PerfTests`.
final class PerfTests: XCTestCase {
    func testTypingCost() throws {
        let schema = Schemas.basic
        var paragraphs: [JSONValue] = []
        for i in 0..<2000 {
            paragraphs.append(["type": "paragraph", "content": [["type": "text", "text": .string("Paragraph \(i) with some text in it, and a bit more.")]]])
        }
        let doc = try schema.nodeFromJSON(["type": "doc", "content": .array(paragraphs)])
        let (plugins, _) = scenarioSetup(schema)
        let mid = doc.content.size / 2
        let view = HeadlessView(EditorState.create(EditorStateConfig(doc: doc, selection: TextSelection.create(doc, mid), plugins: plugins)))
        let n = 2000
        let start = Date()
        for i in 0..<n {
            let s = String("abcdefghij ".randomElement()!)
            let from = view.state.selection.from, to = view.state.selection.to
            if !view.handleTextInput(from, to, s) { view.dispatch(try view.state.tr.insertText(s, from, to)) }
            if i % 100 == 99 { _ = view.handleKeyDown(scenarioKeyEvent("Enter")) }
        }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(n)
        print(String(format: "typing: %.3f ms per keystroke (doc size %d, %d paragraphs)", ms, view.state.doc.content.size, view.state.doc.childCount))
    }
}
