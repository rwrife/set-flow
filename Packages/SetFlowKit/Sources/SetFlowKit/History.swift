import Foundation

// MARK: - History summaries (issue #5)
//
// Deterministic, explainable derivations over the durable session event
// stream. Every summary is a pure function of the inputs passed in — no
// clocks, no hidden state, no stored aggregates. Callers supply the week
// keys (via `CalendarWeekKey`) and a calendar whose `timeZone` decides
// week grouping, so week grouping is timezone and DST safe: a DST shift
// inside a week can never split or merge weeks.
//
// Documented formulas
// ------------------
// Weekly volume (per week, per exercise, per display unit):
//   volume = Σ over ENTRIES IN THE WEEK of (repetitions × loadMass),
//   where loadMass is the entry load converted to the display unit. Only
//   `completed` entries that carry BOTH a load and a positive repetition
//   count contribute. Entries with an unknown/omitted load or
//   unknown/omitted/zero repetitions are EXCLUDED from volume — they are
//   never treated as zero-load or zero-rep work. Skipped entries are
//   excluded. Each side of a unilateral entry contributes its own logged
//   mass once (side-specific facts are preserved, not merged).
//
//   Unit conversion (integer thousandths, exact):
//     1 pound = 0.45359237 kilogram (exact legal definition)
//     kg→lb: thousandths_lb = round(thousandths_kg × 100_000_000 ÷ 45_359_237)
//     lb→kg: thousandths_kg = round(thousandths_lb × 45_359_237 ÷ 100_000_000)
//
// Completion consistency (per week):
//   resolvedPlannedSets = completed planned slots + skipped planned slots
//   completionConsistency = completed ÷ resolvedPlannedSets
//   Reported only when resolvedPlannedSets > 0; a week with no planned
//   slot ever resolved reports nil (not 0%), because the ratio is
//   undefined rather than zero. Ad-hoc entries never enter the ratio.
//   Skipped slots count in the denominator: an intentional skip is a
//   resolved plan slot, and the paired completed/skipped counts make the
//   composition explicit. Planned/ad-hoc attribution comes from the
//   deterministic queue engine, so summaries agree with the runner.
//
// Session completion rate (per week):
//   completed ÷ (completed + abandoned) terminal sessions; nil when no
//   session reached a terminal state that week. Active sessions are
//   excluded from the denominator.
//
// Unilateral asymmetry (per week, per exercise):
//   Side-specific facts stay separate (`completedSetCountsBySide`).
//   `leftMinusRightCompletedSets` is a DESCRIPTIVE set-count difference
//   only — it is never a diagnosis and is never computed from loads,
//   repetitions, or omitted data.

/// Calendar week coordinate: `weekOfYear` scoped to its `yearForWeekOfYear`
/// era per the supplied calendar (ISO-style). Codable and totally ordered.
public struct CalendarWeekKey: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let yearForWeekOfYear: Int
    public let weekOfYear: Int

    public init(yearForWeekOfYear: Int, weekOfYear: Int) {
        self.yearForWeekOfYear = yearForWeekOfYear
        self.weekOfYear = weekOfYear
    }

    /// Derives the week key for an instant under a calendar whose `timeZone`
    /// defines the week boundary.
    public init(instant: Timestamp, calendar: Calendar) {
        let components = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: instant.date)
        self.init(
            yearForWeekOfYear: components.yearForWeekOfYear ?? components.year ?? 0,
            weekOfYear: components.weekOfYear ?? 0
        )
    }

    /// ISO-friendly display label, e.g. `2026-W03`.
    public var isoLabel: String {
        String(format: "%04d-W%02d", yearForWeekOfYear, weekOfYear)
    }

    public var description: String { isoLabel }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.yearForWeekOfYear, lhs.weekOfYear) < (rhs.yearForWeekOfYear, rhs.weekOfYear)
    }
}

/// Exact mass math in integer thousandths of a unit, so summaries never
/// reintroduce binary floating-point drift.
public struct MassThousandths: Codable, Hashable, Sendable {
    public let amountInThousandths: Int64
    public let unit: LoadUnit

    public init(amountInThousandths: Int64, unit: LoadUnit) {
        self.amountInThousandths = amountInThousandths
        self.unit = unit
    }

    /// Converts to another unit with the exact 0.45359237 kg/lb factor,
    /// rounding half-away-from-zero once at the end; saturates on overflow.
    public func converted(to target: LoadUnit) -> MassThousandths {
        guard target != unit else { return self }
        switch unit {
        case .kilograms where target == .pounds:
            let scaled = amountInThousandths.multipliedReportingOverflow(by: 100_000_000)
            return MassThousandths(
                amountInThousandths: Self.roundDiv(numerator: scaled.partialValue, denominator: 45_359_237, overflow: scaled.overflow),
                unit: target
            )
        case .pounds where target == .kilograms:
            let scaled = amountInThousandths.multipliedReportingOverflow(by: 45_359_237)
            return MassThousandths(
                amountInThousandths: Self.roundDiv(numerator: scaled.partialValue, denominator: 100_000_000, overflow: scaled.overflow),
                unit: target
            )
        default:
            return self
        }
    }

    /// Rounds numerator/denominator half away from zero; saturates when the
    /// caller reports a prior multiplication overflow instead of trapping.
    private static func roundDiv(numerator: Int64, denominator: Int64, overflow: Bool) -> Int64 {
        if overflow {
            return numerator >= 0 ? Int64.max : Int64.min
        }
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        // Sign-aware half-away-from-zero: doubling the remainder magnitude
        // avoids negating Int64.min.
        let doubled = remainder.multipliedReportingOverflow(by: 2)
        if !doubled.overflow && abs(doubled.partialValue) >= abs(denominator) {
            return quotient + (numerator >= 0 ? 1 : -1)
        }
        return quotient
    }
}

/// Per-exercise, per-week derived numbers.
public struct ExerciseWeekSummary: Hashable, Sendable {
    public let exerciseID: ExerciseID
    public let exerciseName: String
    /// Completed entries contributing to volume (load AND reps known).
    public let volumeContributingSetCount: Int
    /// Σ (repetitions × load) for contributing entries; zero with the
    /// week's display unit when nothing contributed.
    public let volume: MassThousandths
    /// Entries excluded from volume (unknown load or unknown/zero reps).
    public let excludedFromVolumeCount: Int
    /// Planned slots resolved as completed in the week.
    public let completedPlannedSetCount: Int
    /// Planned slots resolved as skipped in the week. Shown so the
    /// completion-consistency denominator is explainable.
    public let skippedPlannedSetCount: Int
    /// Completed ad-hoc (non-template) sets in the week, kept separate.
    public let adHocCompletedSetCount: Int
    /// Completed set counts keyed by side. `.unknown` and nil sides are
    /// labeled as `.unknown`, never merged into left/right.
    public let completedSetCountsBySide: [UnilateralSide: Int]
    /// Descriptive set-count asymmetry: left minus right completed planned
    /// sets. Present only when BOTH sides logged at least one completed
    /// planned set in the week. Descriptive data only — never advice.
    public let leftMinusRightCompletedSets: Int?

    public init(
        exerciseID: ExerciseID,
        exerciseName: String,
        volumeContributingSetCount: Int,
        volume: MassThousandths,
        excludedFromVolumeCount: Int,
        completedPlannedSetCount: Int,
        skippedPlannedSetCount: Int,
        adHocCompletedSetCount: Int,
        completedSetCountsBySide: [UnilateralSide: Int],
        leftMinusRightCompletedSets: Int?
    ) {
        self.exerciseID = exerciseID
        self.exerciseName = exerciseName
        self.volumeContributingSetCount = volumeContributingSetCount
        self.volume = volume
        self.excludedFromVolumeCount = excludedFromVolumeCount
        self.completedPlannedSetCount = completedPlannedSetCount
        self.skippedPlannedSetCount = skippedPlannedSetCount
        self.adHocCompletedSetCount = adHocCompletedSetCount
        self.completedSetCountsBySide = completedSetCountsBySide
        self.leftMinusRightCompletedSets = leftMinusRightCompletedSets
    }
}

/// All derived figures for one calendar week.
public struct WeekSummary: Hashable, Sendable {
    public let weekKey: CalendarWeekKey
    public let sessionCount: Int
    public let completedSessionCount: Int
    public let abandonedSessionCount: Int
    public let activeSessionCount: Int
    /// completed ÷ (completed + abandoned) terminal sessions; nil when undefined.
    public let sessionCompletionRate: Double?
    /// completed planned slots + skipped planned slots (any exercise).
    public let resolvedPlannedSetCount: Int
    /// Σ completed planned slots ÷ resolved planned slots; nil when no
    /// planned slot was resolved in the week.
    public let completionConsistency: Double?
    /// Per-exercise summaries sorted by exercise name, then ID.
    public let exercises: [ExerciseWeekSummary]
    /// Σ volume across exercises sharing the week's display unit; nil when
    /// nothing contributed volume.
    public let totalVolume: MassThousandths?

    public init(
        weekKey: CalendarWeekKey,
        sessionCount: Int,
        completedSessionCount: Int,
        abandonedSessionCount: Int,
        activeSessionCount: Int,
        sessionCompletionRate: Double?,
        resolvedPlannedSetCount: Int,
        completionConsistency: Double?,
        exercises: [ExerciseWeekSummary],
        totalVolume: MassThousandths?
    ) {
        self.weekKey = weekKey
        self.sessionCount = sessionCount
        self.completedSessionCount = completedSessionCount
        self.abandonedSessionCount = abandonedSessionCount
        self.activeSessionCount = activeSessionCount
        self.sessionCompletionRate = sessionCompletionRate
        self.resolvedPlannedSetCount = resolvedPlannedSetCount
        self.completionConsistency = completionConsistency
        self.exercises = exercises
        self.totalVolume = totalVolume
    }
}

/// Plain-text explanation of the formulas and exclusions shown to users —
/// explainable summaries, not opaque coaching claims. Contains no
/// prescriptive or medical advice.
public enum SummaryExplainer {
    public static let weeklyVolumeFormula =
        "Weekly volume adds repetitions × load for completed sets that recorded both a load and a rep count. Sets with unknown or omitted load or reps, and skipped sets, are excluded rather than counted as zero."
    public static let completionConsistencyFormula =
        "Completion consistency divides completed planned sets by all resolved planned sets (completed plus intentionally skipped). Weeks with no resolved planned set show no value instead of 0%."
    public static let sessionCompletionFormula =
        "Session completion divides finished sessions by sessions that reached an end (finished plus abandoned). Sessions still in progress are not counted."
    public static let asymmetryNotice =
        "Side counts keep left and right logged sets separate. A left/right difference describes what was logged; it is not a diagnosis."
}

/// Pure derivation engine over a history window.
public enum HistoryDerivation {
    /// Derives week summaries for the requested week keys.
    ///
    /// Contract:
    /// - Input order never affects output: results are sorted by week key,
    ///   and per-exercise results are sorted by name then ID.
    /// - A set entry contributes to the week containing its `completedAt`;
    ///   a session contributes to the week containing its `startedAt`.
    /// - Entries whose session is absent from `sessions` are skipped —
    ///   they cannot be attributed to session counts for their week.
    /// - `plannedStatusByEntryID` maps entries resolved by the queue
    ///   engine to their slot status (`.completed` or `.skipped`). Entries
    ///   absent from the map are ad-hoc (free-session logging) and are
    ///   counted separately from planned slots.
    public static func weekSummaries(
        sessions: [Session],
        entries: [SetEntry],
        plannedStatusByEntryID: [SetEntryID: SetSlotStatus] = [:],
        exerciseNames: [ExerciseID: String] = [:],
        weekKeys requested: Set<CalendarWeekKey>,
        calendar: Calendar
    ) -> [WeekSummary] {
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let weekKeys = requested.sorted()
        guard !weekKeys.isEmpty else { return [] }

        var contributorsByWeek: [CalendarWeekKey: [SetEntry]] = [:]
        for entry in entries {
            guard sessionsByID[entry.sessionID] != nil else { continue }
            let key = CalendarWeekKey(instant: entry.completedAt, calendar: calendar)
            guard requested.contains(key) else { continue }
            contributorsByWeek[key, default: []].append(entry)
        }

        var sessionsByWeek: [CalendarWeekKey: [Session]] = [:]
        for session in sessions {
            let key = CalendarWeekKey(instant: session.startedAt, calendar: calendar)
            guard requested.contains(key) else { continue }
            sessionsByWeek[key, default: []].append(session)
        }

        return weekKeys.map { weekKey in
            let weekSessions = sessionsByWeek[weekKey] ?? []
            let completedSessions = weekSessions.filter { $0.status == .completed }.count
            let abandonedSessions = weekSessions.filter { $0.status == .abandoned }.count
            let activeSessions = weekSessions.filter { $0.status == .active }.count
            let terminal = completedSessions + abandonedSessions
            let sessionRate = terminal > 0 ? Double(completedSessions) / Double(terminal) : nil

            let weekEntries = contributorsByWeek[weekKey] ?? []
            var byExercise: [ExerciseID: [SetEntry]] = [:]
            for entry in weekEntries {
                byExercise[entry.exerciseID, default: []].append(entry)
            }

            var exerciseSummaries: [ExerciseWeekSummary] = []
            exerciseSummaries.reserveCapacity(byExercise.count)
            var totalVolumeThousandths: Int64 = 0
            var totalVolumeUnit: LoadUnit?
            var weekCompletedPlanned = 0
            var weekSkippedPlanned = 0

            for (exerciseID, exerciseEntries) in byExercise {
                let summary = exerciseWeekSummary(
                    exerciseID: exerciseID,
                    entries: exerciseEntries,
                    exerciseNames: exerciseNames,
                    plannedStatusByEntryID: plannedStatusByEntryID
                )
                exerciseSummaries.append(summary)
                weekCompletedPlanned += summary.completedPlannedSetCount
                weekSkippedPlanned += summary.skippedPlannedSetCount
                if summary.volumeContributingSetCount > 0 {
                    if totalVolumeUnit == nil {
                        totalVolumeUnit = summary.volume.unit
                    }
                    if summary.volume.unit == totalVolumeUnit {
                        totalVolumeThousandths += summary.volume.amountInThousandths
                    }
                }
            }

            exerciseSummaries.sort {
                if $0.exerciseName != $1.exerciseName { return $0.exerciseName < $1.exerciseName }
                return $0.exerciseID.description < $1.exerciseID.description
            }

            let resolved = weekCompletedPlanned + weekSkippedPlanned
            let consistency = resolved > 0 ? Double(weekCompletedPlanned) / Double(resolved) : nil
            let totalVolume = totalVolumeUnit.map {
                MassThousandths(amountInThousandths: totalVolumeThousandths, unit: $0)
            }

            return WeekSummary(
                weekKey: weekKey,
                sessionCount: weekSessions.count,
                completedSessionCount: completedSessions,
                abandonedSessionCount: abandonedSessions,
                activeSessionCount: activeSessions,
                sessionCompletionRate: sessionRate,
                resolvedPlannedSetCount: resolved,
                completionConsistency: consistency,
                exercises: exerciseSummaries,
                totalVolume: totalVolume
            )
        }
    }

    private static func exerciseWeekSummary(
        exerciseID: ExerciseID,
        entries: [SetEntry],
        exerciseNames: [ExerciseID: String],
        plannedStatusByEntryID: [SetEntryID: SetSlotStatus]
    ) -> ExerciseWeekSummary {
        // Deterministic processing order: completedAt, then sequence, then id.
        let ordered = entries.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt < $1.completedAt }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.description < $1.id.description
        }

        var displayUnit: LoadUnit?
        var volumeThousandths: Int64 = 0
        var contributing = 0
        var excluded = 0
        var adHocCompleted = 0
        var completedPlanned = 0
        var skippedPlanned = 0
        var sideCounts: [UnilateralSide: Int] = [:]
        var plannedCompletedBySide: [UnilateralSide: Int] = [:]

        for entry in ordered {
            let side = entry.side ?? .unknown
            let plannedStatus = plannedStatusByEntryID[entry.id]

            if entry.kind == .skipped {
                // A skipped entry resolves exactly one planned slot (the
                // queue engine rejects skip-without-slot).
                if plannedStatus == .skipped {
                    skippedPlanned += 1
                }
                continue
            }

            if plannedStatus == .completed {
                completedPlanned += 1
                plannedCompletedBySide[side, default: 0] += 1
            } else if plannedStatus == nil {
                adHocCompleted += 1
            }

            // Side facts preserved for every completed entry, labeled rather
            // than merged when the side is unknown.
            sideCounts[side, default: 0] += 1

            if let load = entry.load, let repetitions = entry.repetitions, repetitions > 0 {
                let mass = MassThousandths(amountInThousandths: load.amountInThousandths, unit: load.unit)
                let normalized: MassThousandths
                if let unit = displayUnit {
                    normalized = mass.converted(to: unit)
                } else {
                    displayUnit = load.unit
                    normalized = mass
                }
                // Volume = repetitions × mass, exact in thousandths.
                let product = normalized.amountInThousandths.multipliedReportingOverflow(by: Int64(repetitions))
                volumeThousandths = product.overflow ? Int64.max : volumeThousandths + product.partialValue
                contributing += 1
            } else {
                excluded += 1
            }
        }

        let left = plannedCompletedBySide[.left] ?? 0
        let right = plannedCompletedBySide[.right] ?? 0
        let asymmetry = (left > 0 && right > 0) ? left - right : nil

        let volume = MassThousandths(
            amountInThousandths: volumeThousandths,
            unit: displayUnit ?? .kilograms
        )

        return ExerciseWeekSummary(
            exerciseID: exerciseID,
            exerciseName: exerciseNames[exerciseID] ?? "Exercise \(exerciseID.description.prefix(8))",
            volumeContributingSetCount: contributing,
            volume: volume,
            excludedFromVolumeCount: excluded,
            completedPlannedSetCount: completedPlanned,
            skippedPlannedSetCount: skippedPlanned,
            adHocCompletedSetCount: adHocCompleted,
            completedSetCountsBySide: sideCounts,
            leftMinusRightCompletedSets: asymmetry
        )
    }
}
