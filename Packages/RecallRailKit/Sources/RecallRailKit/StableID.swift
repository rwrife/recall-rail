import Foundation

/// A stable, Codable identifier wrapper around `UUID`.
///
/// All persisted entities carry a `StableID` so identity never depends on
/// array position, database rowid, or import ordering. The raw string form is
/// the `uuidString`, which gives a deterministic total order for queueing
/// tie-breaks that is identical on every platform.
public struct StableID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Creates a brand-new random identifier.
    public init() {
        self.rawValue = UUID().uuidString
    }

    /// Creates an identifier from an already-normalized raw string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Parses a raw string, returning `nil` unless it names a valid UUID.
    public init?(parsing raw: String) {
        guard let uuid = UUID(uuidString: raw) else { return nil }
        self.rawValue = uuid.uuidString
    }

    public var description: String { rawValue }
}
