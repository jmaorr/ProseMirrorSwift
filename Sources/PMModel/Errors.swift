// Errors mirror the JS error classes so callers (and parity tests) can tell
// them apart. Programmer errors that JS reports with RangeError on bad
// positions/indices (e.g. resolving a position outside the document) trap in
// Swift instead; everything that depends on user input or document content
// throws.

public enum PMError: Error, CustomStringConvertible, Equatable {
    /// JS `RangeError`.
    case range(String)
    /// JS `SyntaxError` (content/mark expressions).
    case syntax(String)
    /// `ReplaceError` from prosemirror-model.
    case replace(String)
    /// `TransformError` from prosemirror-transform.
    case transform(String)
    /// Plain JS `Error`.
    case generic(String)

    public var description: String {
        switch self {
        case .range(let m), .syntax(let m), .replace(let m), .transform(let m), .generic(let m): return m
        }
    }

    public var message: String { description }
}
