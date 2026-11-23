#if os(macOS) && DEBUG
import AppKit
import os

/// A trace of what AppKit's text input sends the view and what it becomes, for chasing input
/// bugs that only real typing shows (autocorrect, predictions). Debug builds only: release builds
/// compile neither this nor its call sites, so a shipped app has no switch that records what its
/// users type. Off unless the `PMInputLog` default is set; the lines carry document text, so the
/// unified log redacts them (`privacy: .private`) unless private data logging is on. Read with
/// `log stream --predicate 'subsystem == "dev.prosemirror-swift"'` or in Library/Logs/PMInputTrace.log.
enum InputTrace {
    static let enabled = UserDefaults.standard.bool(forKey: "PMInputLog")
    private static let log = Logger(subsystem: "dev.prosemirror-swift", category: "input")

    static func note(_ view: ProseTextView, _ what: @autoclosure () -> String) {
        guard enabled else { return }
        let sel = view.selectedRange()
        let marked = view.hasMarkedText() ? " marked=\(view.markedRange())" : ""
        let line = "\(what()) | sel=\(sel.location),\(sel.length)\(marked) para=\(paragraph(view, around: sel.location).debugDescription)"
        log.notice("\(line, privacy: .private)")
        if let file { file.write(Data((line + "\n").utf8)) }
    }

    /// Also appended to Library/Logs/PMInputTrace.log (the app's container when sandboxed).
    private static let file: FileHandle? = {
        guard enabled, let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs") else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let url = logs.appendingPathComponent("PMInputTrace.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    /// The storage paragraph around `offset`.
    private static func paragraph(_ view: ProseTextView, around offset: Int) -> String {
        guard let s = view.textStorage?.string as NSString?, s.length > 0 else { return "" }
        return s.substring(with: s.paragraphRange(for: NSRange(location: min(offset, s.length - 1), length: 0)))
    }
}
#endif
