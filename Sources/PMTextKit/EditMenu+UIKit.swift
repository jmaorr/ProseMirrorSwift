#if canImport(UIKit) && !os(macOS)
import UIKit
import UniformTypeIdentifiers
import PMModel
import PMState

// MARK: Edit menu
//
// The system's actions (Cut, Copy, Paste, Look Up…) then Bold and Italic (with a selection),
// Link… (when the app handles links) and the app's own items (a "Turn Into" submenu, say).
// Bold and Italic run the keymap's ⌘B and ⌘I, like the formatting shortcuts.

extension ProseTextView {
    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                         suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard isEditable else { return UIMenu(children: suggestedActions) }
        var format: [UIMenuElement] = []
        if !state.selection.empty {
            format.append(UIAction(title: "Bold", image: UIImage(systemName: "bold")) { [weak self] _ in
                self?.toggleBoldface(nil)
            })
            format.append(UIAction(title: "Italic", image: UIImage(systemName: "italic")) { [weak self] _ in
                self?.toggleItalics(nil)
            })
        }
        if onEditLink != nil {
            format.append(UIAction(title: "Link…", image: UIImage(systemName: "link")) { [weak self] _ in
                self?.commitComposition()
                self?.onEditLink?()
            })
        }
        var children = suggestedActions
        if !format.isEmpty { children.append(UIMenu(options: .displayInline, children: format)) }
        let extra = extraMenuItems?(state) ?? []
        if !extra.isEmpty { children.append(UIMenu(options: .displayInline, children: extra)) }
        return UIMenu(children: children)
    }
}

// MARK: Drop
//
// UIKit's text drop would edit the text storage directly; the view takes drops itself instead
// (prosemirror-view's drop handler): a note's own content as copied, otherwise plain text, and
// images or files to `onIncomingFiles`. Dragging out stays off, so a drop is always a copy.

extension ProseTextView: UIDropInteractionDelegate {
    func installDropInteraction() {
        if let textDrop = textDropInteraction { removeInteraction(textDrop) }
        addInteraction(UIDropInteraction(delegate: self))
    }

    private var droppableTextTypes: [String] { [Self.sliceType, UTType.plainText.identifier] }

    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        guard isEditable else { return false }
        if session.hasItemsConforming(toTypeIdentifiers: droppableTextTypes) { return true }
        return onIncomingFiles != nil && session.hasItemsConforming(toTypeIdentifiers: [UTType.data.identifier])
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: dropInteraction(interaction, canHandle: session) ? .copy : .cancel)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let pos = dropPosition(session.location(in: self))
        let providers = session.items.map(\.itemProvider)
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(Self.sliceType) }) {
            provider.loadDataRepresentation(forTypeIdentifier: Self.sliceType) { [weak self] data, _ in
                let json = data.flatMap { String(data: $0, encoding: .utf8) }
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.drop(sliceJSON: json, text: nil, at: pos) } }
            }
        } else if onIncomingFiles != nil, providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            // An image (dragged from Photos or Safari) is its bytes, even when it carries text too.
            Self.loadFiles(providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) { [weak self] files in
                guard let self, !files.isEmpty else { return }
                _ = onIncomingFiles?(files, min(pos, state.doc.content.size))
            }
        } else if session.canLoadObjects(ofClass: String.self) {
            _ = session.loadObjects(ofClass: String.self) { [weak self] strings in
                let text = (strings as? [String] ?? []).joined(separator: "\n")
                MainActor.assumeIsolated { _ = self?.drop(sliceJSON: nil, text: text, at: pos) }
            }
        } else if onIncomingFiles != nil {
            Self.loadFiles(providers) { [weak self] files in
                guard let self, !files.isEmpty else { return }
                _ = onIncomingFiles?(files, min(pos, state.doc.content.size))
            }
        }
    }

    /// Each provider's file (its first image or data type), then `done` on the main queue, in
    /// the providers' order. Read from the file the provider writes, mapped rather than copied
    /// into memory, so a large file costs no memory to hand over. Only a regular file of at most
    /// `maxIncomingFileSize` bytes is read; anything else is skipped. Below that, a file over the
    /// app's own upload limit reaches `onIncomingFiles` as a pasted one does, and the app says
    /// it's too large (a large photo it may scale down instead).
    static func loadFiles(_ providers: [NSItemProvider], done: @escaping @MainActor ([IncomingFile]) -> Void) {
        let limit = maxIncomingFileSize
        let group = DispatchGroup()
        let lock = NSLock()
        var files: [(Int, IncomingFile)] = []
        for (index, provider) in providers.enumerated() {
            let types = provider.registeredTypeIdentifiers
            guard let typeID = types.first(where: { UTType($0)?.conforms(to: .image) == true })
                    ?? types.first(where: { UTType($0)?.conforms(to: .data) == true }) else { continue }
            let type = UTType(typeID)
            group.enter()
            // The file is removed once this returns; a mapping of it stays readable.
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                defer { group.leave() }
                guard let url, let data = IncomingFileReader.read(url, limit: limit, mapped: true) else { return }
                var name = provider.suggestedName ?? url.lastPathComponent
                if let ext = type?.preferredFilenameExtension, (name as NSString).pathExtension.isEmpty { name += "." + ext }
                lock.lock()
                files.append((index, IncomingFile(data: data, filename: name, mimeType: type?.preferredMIMEType)))
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { done(files.sorted { $0.0 < $1.0 }.map(\.1)) }
        }
    }

    /// The document position nearest `point` (content coordinates).
    func dropPosition(_ point: CGPoint) -> Int {
        guard let textPosition = closestPosition(to: point) else { return state.selection.from }
        let index = offset(from: beginningOfDocument, to: textPosition)
        return renderer.docPosition(min(index, max(0, textStorage.length - 1)))?.pos ?? state.selection.from
    }

    /// Inserts dropped content at a document position: a note's own content (slice JSON) as
    /// copied, otherwise plain text. The dropped content ends up selected.
    @discardableResult
    public func drop(sliceJSON: String?, text: String?, at pos: Int) -> Bool {
        let schema = state.schema
        var slice: Slice?
        if let sliceJSON, let value = try? JSONValue.parse(sliceJSON), let parsed = try? Slice.fromJSON(schema, value) {
            slice = preparePasted(parsed, .copy)  // a drop is always a copy here
        } else if let text {
            slice = Self.plainTextSlice(text, schema)
        }
        guard let slice else { return false }
        return run { state, dispatch, _ in
            let at = min(pos, state.doc.content.size)
            let tr = state.tr
            guard (try? tr.replaceRange(at, at, slice)) != nil else { return false }
            let inserted = tr.mapping.slice(0)
            tr.setSelection(TextSelection.between(tr.doc.resolve(inserted.map(at, assoc: -1)), tr.doc.resolve(inserted.map(at, assoc: 1))))
            dispatch?(tr.scrollIntoView())
            return true
        }
    }
}
#endif
