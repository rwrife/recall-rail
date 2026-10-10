import Dispatch
import Foundation

/// Injectable source of current instants. All domain scheduling receives its
/// clock so tests stay deterministic and resume behavior can model clock
/// drift explicitly.
public protocol InstantProviding: Sendable {
    func now() -> Date
}

/// Production wall-clock source.
public struct SystemClock: InstantProviding {
    public init() {}
    public func now() -> Date { Date() }
}

/// Injectable source of monotonic nanoseconds. Monotonic time measures real
/// elapsed time across background/foreground interruptions and is unaffected
/// by wall-clock changes made by the user or the network time service.
public protocol MonotonicTimeProviding: Sendable {
    func nowNanoseconds() -> UInt64
}

/// Process-relative elapsed time. Persisted/exported anchors measure elapsed time
/// between app events rather than exposing the device's boot-relative uptime.
/// A new process starts a new origin; practice resume resets its live anchor.
public struct SystemMonotonicClock: MonotonicTimeProviding {
    public init() {}
    private static let origin = DispatchTime.now().uptimeNanoseconds
    public func nowNanoseconds() -> UInt64 {
        let origin = Self.origin
        let current = DispatchTime.now().uptimeNanoseconds
        return current >= origin ? current - origin : 0
    }
}
