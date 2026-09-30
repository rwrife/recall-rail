import Foundation

/// Effect a graded transition has on the consecutive-clean-recall counter.
public enum RecallCounterEffect: String, Codable, CaseIterable, Sendable {
    /// The streak restarts (a miss or an effortful recall breaks it).
    case reset
    /// The streak grows by one (a clean recall extends it).
    case increment
}

/// One explicit row of the scheduling rule table.
///
/// Every `(grade, box)` pair must have exactly one row for a given algorithm
/// version; the table is validated at load time so an accidental gap or
/// collision is a programming error surfaced by tests, not a silent fallback.
public struct ScheduleRuleRow: Codable, Equatable, Sendable {
    public let grade: Grade
    /// 1-based box the card is in when the grade is recorded.
    public let fromBox: Int
    /// 1-based box the card moves to after the grade.
    public let toBox: Int
    /// Calendar days (civil days, DST-aware) added to the attempt instant to
    /// produce the next due instant. Zero means immediately due again.
    public let intervalDays: Int
    /// How the consecutive-clean-recall counter changes on this transition.
    public let recallCounterEffect: RecallCounterEffect

    public init(
        grade: Grade,
        fromBox: Int,
        toBox: Int,
        intervalDays: Int,
        recallCounterEffect: RecallCounterEffect
    ) {
        self.grade = grade
        self.fromBox = fromBox
        self.toBox = toBox
        self.intervalDays = intervalDays
        self.recallCounterEffect = recallCounterEffect
    }
}

/// The checked-in Leitner rule table. Every transition the scheduler can make
/// is one of these rows — there are no implicit fallbacks.
///
/// Box ladder: 1 … 6. Clean recalls promote one box (capped at the top box)
/// on the target box's interval; `hard` keeps the box and re-checks tomorrow;
/// `again` drops back to box 1 and re-presents immediately. Skipped, missing,
/// or corrupt evidence never reaches this table — `MasteryDeriver` reports it
/// as insufficient rather than converting it into success or failure.
public enum SchedulingRules {
    /// Number of Leitner boxes in version 1.
    public static let maxBox = 6

    /// Interval in days applied when a card *arrives* at each box (index 0 =
    /// box 1). Version 1: 0, 1, 3, 7, 16, 35 days.
    public static let v1BoxIntervalDays: [Int] = [0, 1, 3, 7, 16, 35]

    /// The full cross product for version 1: 3 grades × 6 boxes = 18 rows.
    public static let v1: [ScheduleRuleRow] = {
        var rows: [ScheduleRuleRow] = []
        for box in 1...maxBox {
            rows.append(ScheduleRuleRow(
                grade: .again, fromBox: box, toBox: 1,
                intervalDays: 0, recallCounterEffect: .reset
            ))
        }
        for box in 1...maxBox {
            rows.append(ScheduleRuleRow(
                grade: .hard, fromBox: box, toBox: box,
                intervalDays: 1, recallCounterEffect: .reset
            ))
        }
        for box in 1...maxBox {
            let target = min(box + 1, maxBox)
            rows.append(ScheduleRuleRow(
                grade: .recalled, fromBox: box, toBox: target,
                intervalDays: v1BoxIntervalDays[target - 1],
                recallCounterEffect: .increment
            ))
        }
        return rows
    }()

    /// All rows for a supported algorithm version. Unknown versions have no
    /// rows, which forces callers to stop rather than guess transitions.
    public static func rows(version: Int) -> [ScheduleRuleRow] {
        switch version {
        case 1: return v1
        default: return []
        }
    }

    /// Look up the one exact rule for a `(version, grade, fromBox)` triple.
    /// Returns `nil` for anything outside the table; the scheduler treats a
    /// missing rule as an error, never a default transition.
    public static func rule(version: Int, grade: Grade, fromBox: Int) -> ScheduleRuleRow? {
        rows(version: version).first { $0.grade == grade && $0.fromBox == fromBox }
    }

    /// Validate that a version's table is total (every grade × box appears
    /// exactly once, boxes stay on the ladder, intervals are non-negative).
    public static func isWellFormed(version: Int) -> Bool {
        let table = rows(version: version)
        guard table.count == Grade.allCases.count * maxBox else { return false }
        var seen = Set<String>()
        for row in table {
            let key = "\(row.grade.rawValue)@\(row.fromBox)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            guard (1...maxBox).contains(row.fromBox),
                  (1...maxBox).contains(row.toBox),
                  row.intervalDays >= 0
            else { return false }
        }
        for grade in Grade.allCases {
            for box in 1...maxBox where rule(version: version, grade: grade, fromBox: box) == nil {
                return false
            }
        }
        return true
    }
}
