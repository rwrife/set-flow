import Foundation
import Testing
@testable import SetFlowKit

// Shared fixtures: fixed instants so tests never read the wall clock.
private let base = Timestamp(millisecondsSinceUnixEpoch: 1_772_000_000_000) // 2026-02-25 06:00 UTC
private let later = Timestamp(millisecondsSinceUnixEpoch: 1_772_003_600_000)

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func key(_ ts: Timestamp, _ calendar: Calendar = utcCalendar()) -> CalendarWeekKey {
    CalendarWeekKey(instant: ts, calendar: calendar)
}

private func completedEntry(
    sessionID: SessionID,
    exerciseID: ExerciseID,
    sequence: Int,
    at ts: Timestamp = base,
    reps: Int? = 10,
    load: LoadValue? = LoadValue(amountInThousandths: 100_000, unit: .kilograms),
    side: UnilateralSide? = nil
) -> SetEntry {
    SetEntry(
        sessionID: sessionID, exerciseID: exerciseID, sequence: sequence,
        completedAt: ts, repetitions: reps, load: load, side: side
    )
}

@Suite("History week key (timezone and DST safety)")
struct CalendarWeekKeyTests {
    @Test("week key is ISO-scoped and stable")
    func stability() {
        let k = key(base)
        #expect(k.yearForWeekOfYear == 2026)
        #expect(k.weekOfYear == 9)
        #expect(k.isoLabel == "2026-W09")
        #expect(k < CalendarWeekKey(yearForWeekOfYear: 2026, weekOfYear: 10))
        #expect(!(CalendarWeekKey(yearForWeekOfYear: 2026, weekOfYear: 10) < k))
        let round = try! JSONDecoder().decode(
            CalendarWeekKey.self, from: JSONEncoder().encode(k)
        )
        #expect(round == k)
    }

    @Test("DST transition inside a week does not split the week")
    func dstInsideWeek() throws {
        var ny = Calendar(identifier: .iso8601)
        ny.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // US DST begins 02:00 local on 2026-03-08.
        let saturdayNight = Timestamp(millisecondsSinceUnixEpoch: 1_772_941_800_000) // 2026-03-07 23:30 EST
        let sundayAfterShift = Timestamp(millisecondsSinceUnixEpoch: 1_773_010_800_000) // 2026-03-08 23:00 EDT (after spring-forward)
        let before = key(saturdayNight, ny)
        let after = key(sundayAfterShift, ny)
        #expect(before == after, "spring-forward must not split the local week (\(before) vs \(after))")
        #expect(before.weekOfYear == 10)
    }

    @Test("the same instant groups by the supplied time zone")
    func zoneSensitivity() throws {
        // Monday 2026-03-09 01:00 UTC is Sunday 2026-03-08 17:00 in Los Angeles.
        let instant = Timestamp(millisecondsSinceUnixEpoch: 1_773_018_000_000)
        var la = Calendar(identifier: .iso8601)
        la.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(key(instant).weekOfYear == 11) // UTC → ISO week 11 (starts Monday)
        #expect(key(instant, la).weekOfYear == 10) // LA local Sunday → week 10
    }
}

@Suite("Mass conversion (exact thousandths)")
struct MassConversionTests {
    @Test("kilograms to pounds uses the exact factor")
    func kgToLb() {
        // 1 kg = 2.20462262... lb → 2204.62 thousandths → 2205 (half away from zero).
        let oneKg = MassThousandths(amountInThousandths: 1_000, unit: .kilograms)
        #expect(oneKg.converted(to: .pounds).amountInThousandths == 2_205)
    }

    @Test("pounds to kilograms uses the exact factor")
    func lbToKg() {
        let oneLb = MassThousandths(amountInThousandths: 1_000, unit: .pounds)
        #expect(oneLb.converted(to: .kilograms).amountInThousandths == 454)
        let hundred = MassThousandths(amountInThousandths: 100_000, unit: .pounds)
        #expect(hundred.converted(to: .kilograms).amountInThousandths == 45_359)
    }

    @Test("same-unit conversion is identity")
    func identity() {
        let value = MassThousandths(amountInThousandths: 12_345, unit: .pounds)
        #expect(value.converted(to: .pounds) == value)
    }
}

@Suite("Weekly volume derivation")
struct VolumeDerivationTests {
    @Test("volume sums repetitions x load with unit conversion")
    func conversion() throws {
        let sessionID = SessionID()
        let exerciseID = ExerciseID()
        let kg = SetEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: 0, completedAt: base,
            repetitions: 10, load: LoadValue(amountInThousandths: 100_000, unit: .kilograms)
        )
        let lb = SetEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: 1, completedAt: later,
            repetitions: 10, load: LoadValue(amountInThousandths: 100_000, unit: .pounds)
        )
        let session = Session(id: sessionID, routineID: nil, startedAt: base, completedAt: later)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [session],
            entries: [kg, lb],
            weekKeys: [key(base)],
            calendar: utcCalendar()
        )
        let week = try #require(summaries.first)
        let exercise = try #require(week.exercises.first)
        #expect(exercise.volumeContributingSetCount == 2)
        // 10 × 100_000 kg-thousandths + 10 × round(100_000 lb→kg = 45_359)
        #expect(exercise.volume == MassThousandths(amountInThousandths: 1_000_000 + 453_590, unit: .kilograms))
        #expect(week.totalVolume == exercise.volume)
    }

    @Test("unknown load or omitted/zero reps are excluded, not zero")
    func exclusions() throws {
        let sessionID = SessionID()
        let exerciseID = ExerciseID()
        let noLoad = SetEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: 0, completedAt: base,
            repetitions: 5, load: nil
        )
        let noReps = SetEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: 1, completedAt: base,
            repetitions: nil, load: LoadValue(amountInThousandths: 100_000, unit: .kilograms)
        )
        let zeroReps = SetEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: 2, completedAt: base,
            repetitions: 0, load: LoadValue(amountInThousandths: 100_000, unit: .kilograms)
        )
        let counted = SetEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: 3, completedAt: base,
            repetitions: 4, load: LoadValue(amountInThousandths: 50_000, unit: .kilograms)
        )
        let skip = SetEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: 4, completedAt: base,
            repetitions: nil, load: nil, kind: .skipped
        )
        let session = Session(id: sessionID, routineID: nil, startedAt: base, completedAt: later)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [session],
            entries: [noLoad, noReps, zeroReps, counted, skip],
            weekKeys: [key(base)],
            calendar: utcCalendar()
        )
        let exercise = try #require(summaries.first?.exercises.first)
        #expect(exercise.volumeContributingSetCount == 1)
        #expect(exercise.excludedFromVolumeCount == 3)
        #expect(exercise.volume == MassThousandths(amountInThousandths: 200_000, unit: .kilograms))
        // Skipped entries neither add volume nor appear as exclusions from volume.
        #expect(exercise.adHocCompletedSetCount == 4)
    }

    @Test("empty requested weeks report nils rather than zeros")
    func emptyWeeks() throws {
        #expect(HistoryDerivation.weekSummaries(
            sessions: [], entries: [], weekKeys: [], calendar: utcCalendar()
        ).isEmpty)

        let summaries = HistoryDerivation.weekSummaries(
            sessions: [], entries: [], weekKeys: [key(base)], calendar: utcCalendar()
        )
        let week = try #require(summaries.first)
        #expect(week.sessionCount == 0)
        #expect(week.completionConsistency == nil)
        #expect(week.sessionCompletionRate == nil)
        #expect(week.totalVolume == nil)
        #expect(week.exercises.isEmpty)
    }

    @Test("entries from sessions outside the window are skipped")
    func unknownSessionsSkipped() {
        let orphan = completedEntry(sessionID: SessionID(), exerciseID: ExerciseID(), sequence: 0)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [], entries: [orphan], weekKeys: [key(base)], calendar: utcCalendar()
        )
        let week = summaries[0]
        #expect(week.exercises.isEmpty)
        #expect(week.totalVolume == nil)
    }

    @Test("input order never changes output")
    func orderIndependence() throws {
        let sessionID = SessionID()
        let a = ExerciseID()
        let b = ExerciseID()
        let session = Session(id: sessionID, routineID: nil, startedAt: base, completedAt: later)
        let entries = [
            completedEntry(sessionID: sessionID, exerciseID: a, sequence: 0, at: base, reps: 8),
            completedEntry(sessionID: sessionID, exerciseID: b, sequence: 1, at: base, reps: 5),
            completedEntry(sessionID: sessionID, exerciseID: a, sequence: 2, at: later, reps: 12),
        ]
        let forward = HistoryDerivation.weekSummaries(
            sessions: [session], entries: entries, weekKeys: [key(base)], calendar: utcCalendar()
        )
        let backward = HistoryDerivation.weekSummaries(
            sessions: [session], entries: entries.reversed(), weekKeys: [key(base)], calendar: utcCalendar()
        )
        #expect(forward == backward)
    }
}

@Suite("Completion metrics")
struct CompletionDerivationTests {
    @Test("planned slots drive consistency; ad-hoc sets never do")
    func consistency() throws {
        let sessionID = SessionID()
        let exerciseID = ExerciseID()
        var entries: [SetEntry] = []
        var planned: [SetEntryID: SetSlotStatus] = [:]
        for index in 0..<8 {
            let entry = completedEntry(sessionID: sessionID, exerciseID: exerciseID, sequence: index)
            entries.append(entry)
            planned[entry.id] = .completed
        }
        for index in 8..<10 {
            let skip = SetEntry(
                sessionID: sessionID, exerciseID: exerciseID, sequence: index,
                completedAt: base, kind: .skipped
            )
            entries.append(skip)
            planned[skip.id] = .skipped
        }
        // Ad-hoc completed set — must stay out of the ratio.
        entries.append(completedEntry(sessionID: sessionID, exerciseID: exerciseID, sequence: 10))
        let session = Session(id: sessionID, routineID: nil, startedAt: base, completedAt: later)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [session], entries: entries, plannedStatusByEntryID: planned,
            weekKeys: [key(base)], calendar: utcCalendar()
        )
        let week = try #require(summaries.first)
        let exercise = try #require(week.exercises.first)
        #expect(week.resolvedPlannedSetCount == 10)
        #expect(week.completionConsistency == 0.8)
        #expect(exercise.completedPlannedSetCount == 8)
        #expect(exercise.skippedPlannedSetCount == 2)
        #expect(exercise.adHocCompletedSetCount == 1)
    }

    @Test("weeks with no resolved planned slot report nil consistency")
    func undefinedConsistency() throws {
        let sessionID = SessionID()
        let session = Session(id: sessionID, routineID: nil, startedAt: base, completedAt: later)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [session],
            entries: [completedEntry(sessionID: sessionID, exerciseID: ExerciseID(), sequence: 0)],
            weekKeys: [key(base)], calendar: utcCalendar()
        )
        #expect(summaries.first?.completionConsistency == nil)
    }

    @Test("session completion excludes active sessions")
    func sessionRates() throws {
        let completed1 = Session(id: SessionID(), routineID: nil, startedAt: base, completedAt: later)
        let completed2 = Session(id: SessionID(), routineID: nil, startedAt: base, completedAt: later)
        let abandoned = Session(id: SessionID(), routineID: nil, startedAt: base, abandonedAt: later)
        let active = Session(id: SessionID(), routineID: nil, startedAt: base)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [completed1, completed2, abandoned, active],
            entries: [], weekKeys: [key(base)], calendar: utcCalendar()
        )
        let week = try #require(summaries.first)
        #expect(week.sessionCount == 4)
        #expect(week.completedSessionCount == 2)
        #expect(week.abandonedSessionCount == 1)
        #expect(week.activeSessionCount == 1)
        #expect(week.sessionCompletionRate == 2.0 / 3.0)
    }

    @Test("a week with only active sessions has no session rate")
    func noTerminalSessions() throws {
        let active = Session(id: SessionID(), routineID: nil, startedAt: base)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [active], entries: [], weekKeys: [key(base)], calendar: utcCalendar()
        )
        #expect(summaries.first?.sessionCompletionRate == nil)
    }
}

@Suite("Unilateral facts")
struct UnilateralDerivationTests {
    @Test("left/right facts stay separate; asymmetry is descriptive set counts")
    func asymmetry() throws {
        let sessionID = SessionID()
        let exerciseID = ExerciseID()
        var entries: [SetEntry] = []
        var planned: [SetEntryID: SetSlotStatus] = [:]
        var sequence = 0
        for _ in 0..<3 {
            let entry = completedEntry(
                sessionID: sessionID, exerciseID: exerciseID, sequence: sequence, side: .left
            )
            entries.append(entry); planned[entry.id] = .completed; sequence += 1
        }
        let right = completedEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: sequence, side: .right
        )
        entries.append(right); planned[right.id] = .completed; sequence += 1
        let unknown = completedEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: sequence, side: .unknown
        )
        entries.append(unknown); planned[unknown.id] = .completed; sequence += 1
        let unlabeled = completedEntry(
            sessionID: sessionID, exerciseID: exerciseID, sequence: sequence, side: nil
        )
        entries.append(unlabeled); planned[unlabeled.id] = .completed
        let session = Session(id: sessionID, routineID: nil, startedAt: base, completedAt: later)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [session], entries: entries, plannedStatusByEntryID: planned,
            weekKeys: [key(base)], calendar: utcCalendar()
        )
        let exercise = try #require(summaries.first?.exercises.first)
        #expect(exercise.completedSetCountsBySide[.left] == 3)
        #expect(exercise.completedSetCountsBySide[.right] == 1)
        // Unknown and missing sides are labeled together, never folded into left/right.
        #expect(exercise.completedSetCountsBySide[.unknown] == 2)
        #expect(exercise.leftMinusRightCompletedSets == 2)
    }

    @Test("asymmetry is hidden when only one side logged sets")
    func oneSided() throws {
        let sessionID = SessionID()
        let exerciseID = ExerciseID()
        let entry = completedEntry(sessionID: sessionID, exerciseID: exerciseID, sequence: 0, side: .left)
        let session = Session(id: sessionID, routineID: nil, startedAt: base, completedAt: later)
        let summaries = HistoryDerivation.weekSummaries(
            sessions: [session], entries: [entry],
            plannedStatusByEntryID: [entry.id: .completed],
            weekKeys: [key(base)], calendar: utcCalendar()
        )
        #expect(summaries.first?.exercises.first?.leftMinusRightCompletedSets == nil)
    }
}

@Suite("Store-backed history window")
struct StoreHistoryTests {
    @Test("historySessions returns full entry streams newest first")
    func historyWindow() throws {
        let store = try SetFlowStore.makeInMemory()
        let exercise = Exercise(name: "Row", createdAt: base, updatedAt: base)
        try store.saveExercise(exercise)
        let routine = Routine(
            name: "Day A",
            blocks: [SetBlock(exercise: exercise, position: 0, targetRepetitions: 3)],
            createdAt: base, updatedAt: base
        )
        try store.saveRoutine(routine)

        let first = try store.startSession(routineID: routine.id, startedAt: base)
        for _ in 0..<3 {
            _ = try store.logSetEntry(
                sessionID: first.id, exerciseID: exercise.id,
                setBlockID: routine.blocks[0].id, completedAt: base,
                repetitions: 10, load: LoadValue(amountInThousandths: 60_000, unit: .kilograms)
            )
        }
        try store.completeSession(id: first.id, completedAt: later)
        let second = try store.startSession(routineID: routine.id, startedAt: later)

        let history = try store.historySessions()
        #expect(history.count == 2)
        #expect(history[0].session.id == second.id) // newest first
        #expect(history[0].entries.isEmpty)
        #expect(history[1].session.status == .completed)
        #expect(history[1].entries.count == 3)
        #expect(history[1].entries.map(\.sequence) == [0, 1, 2])
    }

    @Test("store summaries attribute planned and skipped slots via the queue engine")
    func storeSummaries() throws {
        let store = try SetFlowStore.makeInMemory()
        let exercise = Exercise(name: "Goblet squat", createdAt: base, updatedAt: base)
        try store.saveExercise(exercise)
        let routine = Routine(
            name: "Day A",
            blocks: [SetBlock(
                exercise: exercise, position: 0, targetRepetitions: 4,
                targetLoad: LoadValue(amountInThousandths: 20_000, unit: .kilograms)
            )],
            createdAt: base, updatedAt: base
        )
        try store.saveRoutine(routine)

        let session = try store.startSession(routineID: routine.id, startedAt: base)
        for _ in 0..<3 {
            _ = try store.logSetEntry(
                sessionID: session.id, exerciseID: exercise.id,
                setBlockID: routine.blocks[0].id, completedAt: base,
                repetitions: 5, load: LoadValue(amountInThousandths: 20_000, unit: .kilograms)
            )
        }
        _ = try store.logSetEntry(
            sessionID: session.id, exerciseID: exercise.id,
            setBlockID: routine.blocks[0].id, completedAt: base, kind: .skipped
        )
        try store.completeSession(id: session.id, completedAt: later)

        let summaries = try store.weekSummaries(calendar: utcCalendar())
        #expect(summaries.count == 1)
        let week = summaries[0]
        #expect(week.weekKey == key(base))
        #expect(week.completedSessionCount == 1)
        #expect(week.sessionCompletionRate == 1.0)
        #expect(week.resolvedPlannedSetCount == 4)
        #expect(week.completionConsistency == 0.75)
        let exerciseSummary = try #require(week.exercises.first)
        #expect(exerciseSummary.exerciseName == "Goblet squat")
        #expect(exerciseSummary.volumeContributingSetCount == 3)
        // 3 sets × 5 reps × 20 kg = 300 kg in thousandths.
        #expect(exerciseSummary.volume == MassThousandths(amountInThousandths: 300_000, unit: .kilograms))
        #expect(exerciseSummary.skippedPlannedSetCount == 1)
        #expect(exerciseSummary.adHocCompletedSetCount == 0)
    }

    @Test("explainer texts state formulas and avoid advice language")
    func explainerIsExplanatory() {
        #expect(SummaryExplainer.weeklyVolumeFormula.contains("excluded"))
        #expect(SummaryExplainer.completionConsistencyFormula.contains("skipped"))
        #expect(SummaryExplainer.sessionCompletionFormula.contains("abandoned") == false
                || SummaryExplainer.sessionCompletionFormula.contains("reached an end"))
        #expect(SummaryExplainer.asymmetryNotice.contains("not a diagnosis"))
        for text in [
            SummaryExplainer.weeklyVolumeFormula,
            SummaryExplainer.completionConsistencyFormula,
            SummaryExplainer.sessionCompletionFormula,
            SummaryExplainer.asymmetryNotice,
        ] {
            let lowered = text.lowercased()
            for banned in ["must", "should", "doctor", "treat", "diagnos", "injur"] where lowered.contains(banned) {
                // "not a diagnosis" is the required disclaimer; anything else about
                // diagnosis/injury or prescriptive language is out of contract.
                if banned == "diagnos", lowered.contains("not a diagnosis") { continue }
                Issue.record("explainer contains out-of-contract word '\(banned)': \(text)")
            }
        }
    }
}
