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

/// Production monotonic source backed by `DispatchTime`.
public struct SystemMonotonicClock: MonotonicTimeProviding {
    public init() {}
    public func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
