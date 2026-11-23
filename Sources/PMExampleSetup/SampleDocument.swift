import PMModel

extension BasicSchema {
    /// A short document that uses every node and mark in `BasicSchema`: headings 1–6,
    /// paragraphs with each mark, a hard break and an image, nested bullet and ordered lists, a
    /// block quote, a code block, a horizontal rule and a table with a header row. Handy for
    /// trying out a style or a setup.
    public static var sampleDocument: Node {
        do {
            return try schema.nodeFromJSON(try JSONValue.parse(sampleJSON))
        } catch {
            fatalError("BasicSchema.sampleDocument doesn't fit the schema: \(error)")
        }
    }

    /// `sampleDocument` as ProseMirror JSON (`Node.toJSON`'s form).
    public static let sampleJSON = #"""
    {"type": "doc", "content": [
      {"type": "heading", "attrs": {"level": 1}, "content": [{"type": "text", "text": "Welcome to ProseMirror Swift"}]},
      {"type": "paragraph", "content": [
        {"type": "text", "text": "This editor runs ProseMirror's model, transforms and commands natively. Text can be "},
        {"type": "text", "marks": [{"type": "strong"}], "text": "strong"},
        {"type": "text", "text": ", "},
        {"type": "text", "marks": [{"type": "em"}], "text": "emphasised"},
        {"type": "text", "text": ", "},
        {"type": "text", "marks": [{"type": "code"}], "text": "code"},
        {"type": "text", "text": " or a "},
        {"type": "text", "marks": [{"type": "link", "attrs": {"href": "https://prosemirror.net", "title": null}}], "text": "link"},
        {"type": "text", "text": "."}
      ]},
      {"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": "Try the input rules"}]},
      {"type": "bullet_list", "content": [
        {"type": "list_item", "content": [
          {"type": "paragraph", "content": [{"type": "text", "text": "Type \"# \" at the start of a line for a heading, \"- \" for a list."}]},
          {"type": "bullet_list", "content": [
            {"type": "list_item", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Tab and Shift-Tab nest and lift list items."}]}]}
          ]}
        ]},
        {"type": "list_item", "content": [
          {"type": "paragraph", "content": [{"type": "text", "text": "Quotes become “smart”, three dots an ellipsis… and two dashes an em dash."}]}
        ]}
      ]},
      {"type": "ordered_list", "attrs": {"order": 1}, "content": [
        {"type": "list_item", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Cmd-B, Cmd-I and Cmd-` toggle marks."}]}]},
        {"type": "list_item", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Shift-Ctrl-1 to 6 make headings, Shift-Ctrl-0 a paragraph."}]}]}
      ]},
      {"type": "blockquote", "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "A block quote. Type \"> \" at the start of a line to make one."}]}
      ]},
      {"type": "code_block", "content": [{"type": "text", "text": "let schema = BasicSchema.schema\nlet plugins = exampleSetup(schema: schema)"}]},
      {"type": "horizontal_rule"},
      {"type": "paragraph", "content": [
        {"type": "text", "text": "An inline image "},
        {"type": "image", "attrs": {"src": "https://prosemirror.net/img/logo.png", "alt": "ProseMirror logo", "title": null}},
        {"type": "text", "text": " and a hard break (Shift-Enter)"},
        {"type": "hard_break"},
        {"type": "text", "text": "on the next line."}
      ]},
      {"type": "heading", "attrs": {"level": 3}, "content": [{"type": "text", "text": "A table"}]},
      {"type": "table", "content": [
        {"type": "table_row", "content": [
          {"type": "table_header", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Module"}]}]},
          {"type": "table_header", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Ports"}]}]}
        ]},
        {"type": "table_row", "content": [
          {"type": "table_cell", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "PMModel"}]}]},
          {"type": "table_cell", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "prosemirror-model"}]}]}
        ]},
        {"type": "table_row", "content": [
          {"type": "table_cell", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "PMTables"}]}]},
          {"type": "table_cell", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "prosemirror-tables"}]}]}
        ]}
      ]},
      {"type": "heading", "attrs": {"level": 4}, "content": [{"type": "text", "text": "Heading 4"}]},
      {"type": "heading", "attrs": {"level": 5}, "content": [{"type": "text", "text": "Heading 5"}]},
      {"type": "heading", "attrs": {"level": 6}, "content": [{"type": "text", "text": "Heading 6"}]},
      {"type": "paragraph", "content": [{"type": "text", "text": "Happy editing."}]}
    ]}
    """#
}
