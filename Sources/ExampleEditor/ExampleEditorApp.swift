// A small macOS editor on PMExampleSetup: BasicSchema, exampleSetup's plugins and BasicStyle in
// a ProseTextView, with a toolbar and an optional collaborative room.
//
//   swift run ExampleEditor
//
// To try collaboration, start the devserver (`cd devserver && npm install && npm start`), run
// two ExampleEditors, and join the same room in both.
#if os(macOS)
import SwiftUI
import AppKit
import PMModel
import PMCommands
import PMTextKit
import PMExampleSetup

@main
struct ExampleEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Example Editor") {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare executable (`swift run`) isn't a regular app until it says so.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var room = ""

    var body: some View {
        VStack(spacing: 0) {
            TextViewHost(textView: model.textView)
            Divider()
            roomBar
        }
        .toolbar { formattingToolbar }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var formattingToolbar: some ToolbarContent {
        let schema = model.schema
        ToolbarItemGroup(placement: .navigation) {
            Menu(model.blockName) {
                Button("Paragraph") { model.run(setBlockType(schema.nodes["paragraph"]!)) }
                ForEach(1...3, id: \.self) { level in
                    Button("Heading \(level)") {
                        model.run(setBlockType(schema.nodes["heading"]!, Attrs([("level", .number(Double(level)))])))
                    }
                }
                Button("Code") { model.run(setBlockType(schema.nodes["code_block"]!)) }
            }
            .frame(minWidth: 110)
        }
        ToolbarItemGroup(placement: .principal) {
            markButton("strong", symbol: "bold", help: "Bold (⌘B)")
            markButton("em", symbol: "italic", help: "Italic (⌘I)")
            markButton("code", symbol: "chevron.left.forwardslash.chevron.right", help: "Code (⌘`)")
            Button { model.run(wrapInList(schema.nodes["bullet_list"]!)) } label: { Image(systemName: "list.bullet") }
                .help("Bullet list (⇧⌃8)")
            Button { model.run(wrapInList(schema.nodes["ordered_list"]!)) } label: { Image(systemName: "list.number") }
                .help("Numbered list (⇧⌃9)")
            Button { model.run(insertTable(schema: schema)) } label: { Image(systemName: "tablecells") }
                .help("Insert table")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.run(model.undoCommand) } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo (⌘Z)")
            Button { model.run(model.redoCommand) } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
        }
    }

    private func markButton(_ name: String, symbol: String, help: String) -> some View {
        Button { model.run(toggleMark(model.schema.marks[name]!)) } label: {
            Image(systemName: symbol)
                .foregroundStyle(model.activeMarks.contains(name) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        }
        .help(help)
    }

    // MARK: Room

    private var roomBar: some View {
        HStack {
            TextField("Room (needs the devserver on ws://localhost:1234)", text: $room)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.join(room: room) }
            if model.inRoom {
                Button("Leave") { model.leave() }
            } else {
                Button("Join") { model.join(room: room) }.disabled(room.isEmpty)
            }
            Text(model.syncStatus).font(.caption).foregroundStyle(.secondary).frame(minWidth: 140, alignment: .leading)
        }
        .padding(8)
    }
}

/// The text view in a scroll view, as AppKit text views are hosted.
struct TextViewHost: NSViewRepresentable {
    let textView: ProseTextView

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
#else
/// ExampleEditor is a macOS app. When the package is built for iOS it's an empty executable,
/// so the whole package still builds; the iOS example is in Examples/iOS.
@main
enum ExampleEditorUnavailable {
    static func main() {
        print("ExampleEditor runs on macOS. See Examples/iOS for the iOS example.")
    }
}
#endif
