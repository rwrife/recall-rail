/// Platform-neutral domain namespace for Recall Rail.
///
/// Domain models, scheduling, import validation, and backup codecs are added to
/// this package so they remain deterministic and testable without UIKit.
public enum RecallRailKit {
    public static let productName = "Recall Rail"
    public static let foundationVersion = 1
}
