// The Swift counterpart of prosemirror-schema-basic, prosemirror-schema-list's addListNodes
// and prosemirror-tables' tableNodes, combined into one ready-made schema.
import PMModel

/// A schema to start from: the nodes and marks of prosemirror-schema-basic, the list nodes of
/// prosemirror-schema-list and the table nodes of prosemirror-tables, under the names those
/// packages use (`paragraph`, `heading`, `bullet_list`, `table_cell`, `strong`, `em`, ...).
///
/// Documents in this schema round-trip with a JavaScript editor that builds the same schema:
///
/// ```js
/// const nodes = addListNodes(basicSchema.spec.nodes, "paragraph block*", "block")
///   .append(tableNodes({tableGroup: "block", cellContent: "block+", cellAttributes: {}}))
/// const schema = new Schema({nodes, marks: basicSchema.spec.marks})
/// ```
///
/// Use `BasicSchema.schema` as it is, or start from `nodes` and `marks` to add your own.
public enum BasicSchema {
    /// The schema built from `nodes` and `marks`.
    public static let schema: Schema = {
        do {
            return try Schema(SchemaSpec(nodes: nodes, marks: marks))
        } catch {
            fatalError("BasicSchema's spec is invalid: \(error)")
        }
    }()

    /// Every node spec, in order: the basic nodes, then the list nodes, then the table nodes.
    public static var nodes: [(String, NodeSpec)] { basicNodes + listNodes + tableNodes() }

    /// prosemirror-schema-basic's nodes: `doc`, `paragraph`, `blockquote`, `horizontal_rule`,
    /// `heading` (levels 1–6), `code_block`, `text`, `image` (inline) and `hard_break`.
    public static var basicNodes: [(String, NodeSpec)] {
        [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
            ("horizontal_rule", NodeSpec(group: "block")),
            ("heading", NodeSpec(content: "inline*", group: "block",
                                 attrs: [("level", AttributeSpec(default: 1, validateType: "number"))], defining: true)),
            ("code_block", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
            ("text", NodeSpec(group: "inline")),
            ("image", NodeSpec(group: "inline", inline: true,
                               attrs: [("src", AttributeSpec(validateType: "string")),
                                       ("alt", AttributeSpec(default: .null, validateType: "string|null")),
                                       ("title", AttributeSpec(default: .null, validateType: "string|null"))],
                               draggable: true)),
            ("hard_break", NodeSpec(group: "inline", inline: true, selectable: false)),
        ]
    }

    /// prosemirror-schema-list's nodes as `addListNodes(nodes, "paragraph block*", "block")`
    /// adds them: `ordered_list` (with an `order` attribute), `bullet_list` and `list_item`.
    public static var listNodes: [(String, NodeSpec)] {
        [
            ("ordered_list", NodeSpec(content: "list_item+", group: "block",
                                      attrs: [("order", AttributeSpec(default: 1, validateType: "number"))])),
            ("bullet_list", NodeSpec(content: "list_item+", group: "block")),
            ("list_item", NodeSpec(content: "paragraph block*", defining: true)),
        ]
    }

    /// prosemirror-tables' `tableNodes`: `table`, `table_row`, `table_cell` and `table_header`,
    /// each tagged with the `tableRole` PMTables looks for. Cells have `colspan`, `rowspan` and
    /// `colwidth` attributes.
    ///
    /// - Parameters:
    ///   - tableGroup: The group the `table` node joins, so it can appear where that group can.
    ///   - cellContent: The content expression of cells.
    public static func tableNodes(tableGroup: String? = "block", cellContent: String = "block+") -> [(String, NodeSpec)] {
        func withRole(_ spec: NodeSpec, _ role: String) -> NodeSpec {
            var spec = spec
            spec.extra["tableRole"] = .string(role)
            return spec
        }
        let cellAttrs: [(String, AttributeSpec)] = [
            ("colspan", AttributeSpec(default: 1, validateType: "number")),
            ("rowspan", AttributeSpec(default: 1, validateType: "number")),
            ("colwidth", AttributeSpec(default: .null, validate: validateColwidth)),
        ]
        return [
            ("table", withRole(NodeSpec(content: "table_row+", group: tableGroup, isolating: true), "table")),
            ("table_row", withRole(NodeSpec(content: "(table_cell | table_header)*"), "row")),
            ("table_cell", withRole(NodeSpec(content: cellContent, attrs: cellAttrs, isolating: true), "cell")),
            ("table_header", withRole(NodeSpec(content: cellContent, attrs: cellAttrs, isolating: true), "header_cell")),
        ]
    }

    /// prosemirror-schema-basic's marks: `link` (with `href` and `title`), `em`, `strong` and `code`.
    public static var marks: [(String, MarkSpec)] {
        [
            ("link", MarkSpec(attrs: [("href", AttributeSpec(validateType: "string")),
                                      ("title", AttributeSpec(default: .null, validateType: "string|null"))],
                              inclusive: false)),
            ("em", MarkSpec()),
            ("strong", MarkSpec()),
            ("code", MarkSpec(code: true)),
        ]
    }

    /// prosemirror-tables' check on `colwidth`: null, or an array of numbers.
    private static func validateColwidth(_ value: JSONValue?) throws {
        switch value {
        case .null?:
            return
        case .array(let items)? where items.allSatisfy({ $0.numberValue != nil }):
            return
        default:
            throw PMError.range("colwidth must be null or an array of numbers")
        }
    }
}
