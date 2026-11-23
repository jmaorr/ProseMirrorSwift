import Foundation
import PMModel
import PMMarkdown

/// tiptap-markdown 0.8.10's serializer as the oracle's `tiptapMarkdown` builds it: PMMarkdown's
/// `TiptapMarkdownSerializerState` with the node and mark rules of tiptap-markdown's own
/// StarterKit extensions (plus task lists and images), bulletListMarker "-" and tightLists.
/// Marks tiptap-markdown writes as HTML through the DOM have no rule here.
enum TiptapMarkdownRules {
    typealias N = MarkdownSerializer.Nodes

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let bulletList: NodeSerializer = { state, node, _, _ in
        state.renderOrRecord { try state.renderList(node, "  ") { _ in "- " } }
    }

    static let serializer: MarkdownSerializer = {
        var options = MarkdownSerializerOptions()
        options.hardBreakNodeName = "hardBreak"
        options.tightLists = true
        let nodes: [String: NodeSerializer] = [
            "doc": { state, node, _, _ in state.renderOrRecord { try state.renderContent(node) } },
            "paragraph": N.paragraph,
            "heading": N.heading,
            "blockquote": N.blockquote,
            "codeBlock": { state, node, _, _ in
                state.write("```" + (node.attrs["language"]?.stringValue ?? "") + "\n")
                state.text(node.textContent, false)
                state.ensureNewLine()
                state.write("```")
                state.closeBlock(node)
            },
            "bulletList": bulletList,
            "orderedList": { state, node, parent, index in
                let start = (node.attrs["start"]?.intValue).flatMap { $0 == 0 ? nil : $0 } ?? 1
                let maxW = String(start + node.childCount - 1).count
                let space = state.repeatString(" ", maxW + 2)
                var adjacent = 0
                while index - adjacent > 0, parent.child(index - adjacent - 1).type.name == node.type.name { adjacent += 1 }
                let separator = adjacent % 2 == 1 ? ") " : ". "
                state.renderOrRecord {
                    try state.renderList(node, space) { i in
                        let n = String(start + i)
                        return state.repeatString(" ", maxW - n.count) + n + separator
                    }
                }
            },
            "listItem": N.listItem,
            "hardBreak": N.hardBreak,
            "horizontalRule": N.horizontalRule,
            "image": N.image,
            "text": { state, node, _, _ in state.text(escapeHTML(node.text ?? "")) },
            "taskList": bulletList,
            "taskItem": { state, node, _, _ in
                state.write(node.attrs["checked"]?.boolValue == true ? "[x] " : "[ ] ")
                state.renderOrRecord { try state.renderContent(node) }
            },
        ]
        let M = MarkdownSerializer.Marks.self
        let marks: [String: MarkSerializerSpec] = [
            "bold": M.strong,
            "italic": M.em,
            "code": M.code,
            "link": M.link,
            "strike": MarkSerializerSpec("~~", "~~", expelEnclosingWhitespace: true),
        ]
        return MarkdownSerializer(nodes: nodes, marks: marks, options: options) {
            TiptapMarkdownSerializerState(nodes: $0, marks: $1, options: $2)
        }
    }()
}
