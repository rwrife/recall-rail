import Foundation
@testable import RecallRailKit

/// Fixed instants for deterministic tests: helpers plus a DST-boundary set.
enum Fixtures {
    static let utc = TimeZone(identifier: "UTC")!
    static let ny = TimeZone(identifier: "America/New_York")!

    static func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            preconditionFailure("bad fixture instant: \(iso)")
        }
        return date
    }

    /// A fixed wall-clock instant used as "now" throughout the tests.
    static let now = instant("2026-03-30T12:00:00Z")

    /// US DST spring-forward day 2026: 02:00 America/New_York does not exist;
    /// 2026-03-08T07:30:00Z is 03:30 EDT (after the 07:00Z transition).
    static let dstSpringForwardNY = instant("2026-03-08T07:30:00Z")

    /// US DST fall-back day 2026: 2026-11-01T05:30:00Z is 01:30 EDT, which
    /// also matches 05:30Z one hour later as EST — the classic ambiguity.
    static let dstFallBackNY = instant("2026-11-01T05:30:00Z")

    /// A mid-winter NY instant used as the fall-back "previous day" anchor.
    static let beforeFallBackNY = instant("2026-10-31T05:30:00Z")
}

/// Deterministic clock double.
struct FakeClock: InstantProviding {
    let instant: Date
    func now() -> Date { instant }
}

/// Monotonic double with scripted values.
final class FakeMonotonic: MonotonicTimeProviding, @unchecked Sendable {
    private var value: UInt64
    init(start: UInt64) { value = start }
    func nowNanoseconds() -> UInt64 { value }
    func advance(nanos: UInt64) { value += nanos }
}

/// Small deterministic PRNG (splitmix64) for property tests so failures are
/// reproducible from the seed alone.
struct SplitMix64: Sendable {
    private(set) var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
    /// Uniform value in `0..<bound`.
    mutating func below(_ bound: UInt64) -> UInt64 {
        guard bound > 0 else { return 0 }
        return next() % bound
    }
    mutating func grade() -> Grade {
        Grade.allCases[Int(below(UInt64(Grade.allCases.count)))]
    }
    mutating func box(maxBox: Int) -> Int {
        Int(below(UInt64(maxBox))) + 1
    }
    /// Random instant in 2020...2030 at 1-minute resolution.
    mutating func instant() -> Date {
        let minutes = below(10 * 365 * 24 * 60)
        return Date(timeIntervalSince1970: 1_577_836_800) .addingTimeInterval(TimeInterval(minutes * 60))
    }
}
