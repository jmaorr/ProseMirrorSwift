import Foundation

/// Reads a file another app named (a file URL on the pasteboard, a dropped file) for
/// `onIncomingFiles`, defensively: only a regular file (never a device such as /dev/zero, a FIFO
/// or a directory, which would hang or exhaust memory), and only up to a size limit. Anything
/// else is skipped.
enum IncomingFileReader {
    /// The default for `ProseTextView.maxIncomingFileSize`: 100 MB.
    static let defaultLimit = 100 * 1024 * 1024

    /// The contents of the regular file at `url` when it is at most `limit` bytes, else nil.
    /// `mapped` maps the file rather than copying it into memory.
    static func read(_ url: URL, limit: Int, mapped: Bool = false) -> Data? {
        guard url.isFileURL, limit >= 0,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= limit else { return nil }
        if mapped {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count <= limit else { return nil }
            return data
        }
        // Read at most one byte past the limit, so a file that grew since the check (or was
        // swapped) still can't be read without bound.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { return size == 0 ? Data() : nil }
        return data.count <= limit ? data : nil
    }
}
