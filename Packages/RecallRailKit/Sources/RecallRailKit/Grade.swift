import Foundation

/// Self-grade recorded on an attempt. The grades are deliberately coarse and
/// honest: the learner's judgment is captured, never reinterpreted.
public enum Grade: String, Codable, CaseIterable, Sendable {
    /// The answer was not recoverable; the card returns to the first box.
    case again
    /// The answer came back with noticeable effort or delay.
    case hard
    /// The answer was recalled cleanly.
    case recalled
}

/// The practice context an attempt was recorded in.
public enum PracticeMode: String, Codable, CaseIterable, Sendable {
    /// Standard silent prompt/reveal/self-grade loop.
    case tapReveal
    /// Spoken-answer rehearsal; grading semantics are identical.
    case spoken
}
