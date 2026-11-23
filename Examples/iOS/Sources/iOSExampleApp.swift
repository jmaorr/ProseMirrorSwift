// PMExampleSetup on iOS: BasicSchema, exampleSetup's plugins and BasicStyle in PMTextKit's UIKit
// ProseTextView, with a small formatting bar. Nothing is saved. Tables are view-only on iOS.
import SwiftUI
import UIKit
import PMModel
import PMState
import PMCommands
import PMHistory
import PMTextKit
import PMExampleSetup

@main
struct IOSExampleApp: App {
    var body: some Scene {
        WindowGroup {
            EditorScreen()
        }
    }
}

/// Owns the text view and publishes what the formatting bar shows.
@MainActor
final class EditorModel: ObservableObject {
    let schema = BasicSchema.schema
    let textView: ProseTextView
    @Published private(set) var activeMarks: Set<String> = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    init() {
        let doc = BasicSchema.sampleDocument
        let state = EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atStart(doc),
                                                         plugins: exampleSetup(schema: schema)))
        textView = BasicStyle().makeTextView(state: state)
        // The system's undo (shake, three-finger swipe, the keyboard's buttons) runs these.
        textView.undoCommand = undo
        textView.redoCommand = redo
        textView.separateUndoStep = closeHistory
        textView.onChange = { [weak self] state, _ in self?.refresh(state) }
        refresh(state)
    }

    func run(_ command: @escaping Command) {
        textView.run(command)
    }

    private func refresh(_ state: EditorState) {
        activeMarks = Set(["strong", "em", "code"].filter { name in
            schema.marks[name].map { isMarkActive(state, $0) } ?? false
        })
        canUndo = undo(state, nil, nil)
        canRedo = redo(state, nil, nil)
    }
}

struct EditorScreen: View {
    @StateObject private var model = EditorModel()

    var body: some View {
        NavigationStack {
            TextViewHost(textView: model.textView)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("Example Editor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let schema = model.schema
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.run(undo) } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button { model.run(redo) } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            markButton("strong", symbol: "bold")
            markButton("em", symbol: "italic")
            markButton("code", symbol: "chevron.left.forwardslash.chevron.right")
            Menu {
                Button("Paragraph") { model.run(setBlockType(schema.nodes["paragraph"]!)) }
                ForEach(1...3, id: \.self) { level in
                    Button("Heading \(level)") {
                        model.run(setBlockType(schema.nodes["heading"]!, Attrs([("level", .number(Double(level)))])))
                    }
                }
            } label: { Image(systemName: "textformat.size") }
            Button { model.run(wrapInList(schema.nodes["bullet_list"]!)) } label: { Image(systemName: "list.bullet") }
            Button { model.run(wrapInList(schema.nodes["ordered_list"]!)) } label: { Image(systemName: "list.number") }
            Button { model.run(insertTable(schema: schema)) } label: { Image(systemName: "tablecells") }
        }
    }

    private func markButton(_ name: String, symbol: String) -> some View {
        Button { model.run(toggleMark(model.schema.marks[name]!)) } label: {
            Image(systemName: symbol)
                .foregroundStyle(model.activeMarks.contains(name) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        }
    }
}

/// The text view in SwiftUI. UITextView scrolls by itself.
struct TextViewHost: UIViewRepresentable {
    let textView: ProseTextView
    func makeUIView(context: Context) -> ProseTextView { textView }
    func updateUIView(_ uiView: ProseTextView, context: Context) {}
}
