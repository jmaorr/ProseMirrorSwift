import Foundation

/// Where pasted or dropped content comes from, for an app that gives copied content new
/// identities (a block with an id gets a new one): `.move` is the same content put somewhere else (a
/// cut pasted once, a drag that moves), `.copy` is everything else (a copy, a second paste of a
/// cut, a drag that copies, content from another app).
public enum PasteOrigin: Equatable, Sendable {
    case copy
    case move

    /// The pasteboard type a cut adds beside its slice: a token naming that cut. Its first paste
    /// is a move; later pastes of it (the token is used up) are copies. Any later copy replaces
    /// the pasteboard's items, so the token never outlives its slice. Only a token this process
    /// minted for its latest cut counts: any app can write this type, and a foreign or stale
    /// token pastes as a copy (a move keeps block ids, so a forged one would duplicate them).
    public static let cutMarkerType = "dev.prosemirror-swift.cut"

    /// The token of this process's latest cut, until its first paste uses it up. One at a time:
    /// a cut replaces the pasteboard, so an earlier cut's token can't be pasted as a move.
    @MainActor private(set) static var pendingCutToken: String?

    /// A new token for a cut; it replaces any earlier cut's token.
    @MainActor
    static func newCutToken() -> String {
        let token = UUID().uuidString
        pendingCutToken = token
        return token
    }

    /// The origin of a paste whose pasteboard carries `marker` (nil when it has none): a move
    /// the first time this process's latest cut token is seen, a copy otherwise.
    @MainActor
    static func forPaste(marker: String?) -> PasteOrigin {
        guard let marker, let pending = pendingCutToken, marker == pending else { return .copy }
        pendingCutToken = nil
        return .move
    }
}
