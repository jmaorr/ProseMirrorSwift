#if os(macOS)
import AppKit
import PMModel
import PMState
import PMHistory
import PMTextKit
import PMExampleSetup
import YSync

/// Owns the editor: the schema, the text view, and (while in a room) the YSync session.
@MainActor
final class EditorModel: ObservableObject {
    let schema = BasicSchema.schema
    let textView: ProseTextView

    /// What the toolbar shows.
    @Published private(set) var activeMarks: Set<String> = []
    @Published private(set) var blockName = "Paragraph"
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var syncStatus = "Not in a room"

    init() {
        let doc = BasicSchema.sampleDocument
        let state = EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atStart(doc),
                                                         plugins: exampleSetup(schema: schema)))
        textView = BasicStyle().makeTextView(state: state)
        // Edit > Undo and the toolbar's buttons go through these (Cmd-Z is in the keymap).
        textView.undoCommand = { [unowned self] state, dispatch, view in undoCommand(state, dispatch, view) }
        textView.redoCommand = { [unowned self] state, dispatch, view in redoCommand(state, dispatch, view) }
        textView.separateUndoStep = { [unowned self] tr in
            collab?.binding.stopCapturing()
            return closeHistory(tr)
        }
        textView.onChange = { [weak self] state, tr in self?.stateChanged(state, tr) }
        refresh(state)
    }

    var state: EditorState { textView.state }

    /// Runs a command on the editor and gives it the keyboard focus back.
    func run(_ command: @escaping Command) {
        textView.window?.makeFirstResponder(textView)
        textView.run(command)
    }

    private func stateChanged(_ state: EditorState, _ tr: Transaction?) {
        if let collab, collab.joined { collab.binding.localStateChanged(state, tr) }
        refresh(state)
    }

    private func refresh(_ state: EditorState) {
        activeMarks = Set(["strong", "em", "code"].filter { name in
            schema.marks[name].map { isMarkActive(state, $0) } ?? false
        })
        let parent = state.selection.fromPos.parent
        switch parent.type.name {
        case "heading": blockName = "Heading \(parent.attrs["level"]?.intValue ?? 1)"
        case "code_block": blockName = "Code"
        default: blockName = "Paragraph"
        }
        canUndo = undoCommand(state, nil, nil)
        canRedo = redoCommand(state, nil, nil)
    }

    // MARK: Undo

    /// ProseMirror's history on its own; in a room, YSync's undo manager instead, which undoes
    /// only this editor's changes.
    func undoCommand(_ state: EditorState, _ dispatch: Dispatch?, _ view: EditorView?) -> Bool {
        guard let collab else { return undo(state, dispatch, view) }
        guard collab.binding.canUndo else { return false }
        if dispatch != nil { collab.binding.undo(); pullRemote() }
        return true
    }

    func redoCommand(_ state: EditorState, _ dispatch: Dispatch?, _ view: EditorView?) -> Bool {
        guard let collab else { return redo(state, dispatch, view) }
        guard collab.binding.canRedo else { return false }
        if dispatch != nil { collab.binding.redo(); pullRemote() }
        return true
    }

    // MARK: Collaboration

    /// A YSync session: a Yjs document, the binding between it and the editor, and the
    /// websocket that relays it to the other editors in the room.
    private final class Collab {
        let binding: YSyncBinding
        let provider: YWebsocketProvider
        /// Whether the first sync finished; until then local edits stay out of Yjs.
        var joined = false

        init(binding: YSyncBinding, provider: YWebsocketProvider) {
            self.binding = binding
            self.provider = provider
        }
    }

    private var collab: Collab?
    var inRoom: Bool { collab != nil }

    /// Joins `room` on a y-websocket server (the devserver: `cd devserver && npm install &&
    /// npm start`). An empty room starts with this editor's document; otherwise the room's
    /// document replaces it. Open a second ExampleEditor on the same room to see changes sync.
    func join(room: String, server: String = "ws://localhost:1234") {
        leave()
        // Percent-encode the room so "?", "#" or "/" in it can't change the URL's path or query.
        guard !room.isEmpty,
              let encoded = room.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))),
              let url = URL(string: "\(server)/\(encoded)") else { return }
        let doc = YDocument()
        // Refuses ws:// to anything but this machine (the devserver); use wss:// elsewhere.
        guard let provider = try? YWebsocketProvider(url: url, doc: doc) else { return }
        let binding = YSyncBinding(doc: doc, schema: schema)
        binding.enableUndo()
        let collab = Collab(binding: binding, provider: provider)
        collab.provider.onStatus = { [weak self, weak collab] status in
            guard let self, let collab else { return }
            syncStatus = "\(room): \(status)"
            if status == .synced, !collab.joined { didSync(collab) }
        }
        collab.provider.onRemoteUpdate = { [weak self] in self?.pullRemote() }
        self.collab = collab
        syncStatus = "\(room): connecting"
        collab.provider.connect()
    }

    func leave() {
        guard let collab else { return }
        collab.provider.disconnect()
        self.collab = nil
        syncStatus = "Not in a room"
        // Back to ProseMirror's own history, starting from the document as it is now.
        textView.setState(EditorState.create(EditorStateConfig(doc: state.doc, selection: state.selection,
                                                               plugins: exampleSetup(schema: schema))))
    }

    /// The first sync finished: take the room's document, or seed an empty room with ours.
    /// The editor's history is switched off, as YSync's undo manager takes over.
    private func didSync(_ collab: Collab) {
        collab.joined = true
        let roomDoc = collab.binding.documentFromY()
        if roomDoc == nil { collab.binding.seed(state.doc) }
        let doc = roomDoc ?? state.doc
        // setState reports the new state through onChange, which saves it (and the selection) to Yjs.
        textView.setState(EditorState.create(EditorStateConfig(doc: doc, selection: Selection.atStart(doc),
                                                               plugins: exampleSetup(schema: schema, history: false))))
    }

    /// Brings the editor up to date with Yjs after a remote change, an undo or a redo.
    private func pullRemote() {
        guard let collab, collab.joined, let tr = collab.binding.remoteTransaction(state) else { return }
        textView.dispatch(tr)
    }
}
#endif
