import Foundation
import Testing
@testable import SetFlowKit

private let q0 = Timestamp(millisecondsSinceUnixEpoch: 1_800_000_000_000)
private func q(_ offsetSeconds: Int) -> Timestamp {
    Timestamp(millisecondsSinceUnixEpoch: 1_800_000_000_000 + Int64(offsetSeconds) * 1_000)
}

private func ex(_ name: String) -> Exercise {
    Exercise(name: name, createdAt: q0, updatedAt: q0)
}

/// Routine: Squat x3, Row x2 => 5 planned slots [0..2]=Squat block, [3..4]=Row block.
private func makeQueueFixture() -> (Routine, Exercise, Exercise) {
    let squat = ex("Squat")
    let row = ex("Row")
    let routine = Routine(
        name: "Queue day",
        blocks: [
            SetBlock(exercise: squat, position: 0, targetRepetitions: 3),
            SetBlock(exercise: row, position: 1, targetRepetitions: 2),
        ],
        createdAt: q0,
        updatedAt: q0
    )
    return (routine, squat, row)
}

@Suite("Deterministic session queue (pure engine)")
struct SessionQueueTests {
    @Test("routine expands to deterministic ordered slots")
    func plannedExpansion() {
        let (routine, squat, row) = makeQueueFixture()
        let planned = SessionQueue.plannedQueue(for: routine)
        #expect(planned.count == 5)
        #expect(planned.map(\.sequence) == [0, 1, 2, 3, 4])
        #expect(planned.map(\.exerciseID) == [squat.id, squat.id, squat.id, row.id, row.id])
        #expect(planned[0].setBlockID == routine.blocks[0].id)
        #expect(planned[3].setBlockID == routine.blocks[1].id)
    }

    @Test("block without repetition target contributes exactly one slot")
    func singleSlotDefault() {
        let routine = Routine(
            name: "Planned",
            blocks: [SetBlock(exercise: ex("Plank"), position: 0)],
            createdAt: q0,
            updatedAt: q0
        )
        #expect(SessionQueue.plannedQueue(for: routine).count == 1)
        #expect(SessionQueue.plannedQueue(for: nil).isEmpty)
    }

    @Test("empty session reports notStarted with current at slot zero")
    func emptySession() throws {
        let (routine, _, _) = makeQueueFixture()
        let session = Session(routineID: routine.id, startedAt: q0)
        let snapshot = try SessionQueue.snapshot(routine: routine, session: session, entries: [])
        #expect(snapshot.phase == .notStarted)
        #expect(snapshot.current?.sequence == 0)
        #expect(snapshot.nextPreview?.sequence == 1)
        #expect(snapshot.pendingCount == 5)
        #expect(snapshot.completedCount == 0)
        #expect(snapshot.nextAction?.planned.exerciseID == routine.blocks[0].exercise.id)
    }

    @Test("completed entries advance the queue deterministically")
    func advance() throws {
        let (routine, squat, _) = makeQueueFixture()
        let session = Session(routineID: routine.id, startedAt: q0)
        let entry = SetEntry(
            sessionID: session.id, exerciseID: squat.id,
            setBlockID: routine.blocks[0].id, sequence: 0, completedAt: q(1), repetitions: 5
        )
        let snapshot = try SessionQueue.snapshot(routine: routine, session: session, entries: [entry])
        #expect(snapshot.phase == .running)
        #expect(snapshot.current?.sequence == 1)
        #expect(snapshot.completedCount == 1)
        #expect(snapshot.slots[0].status == .completed)
        #expect(snapshot.slots[0].entry?.id == entry.id)
        // Same inputs always yield the same snapshot.
        #expect(try SessionQueue.snapshot(routine: routine, session: session, entries: [entry]) == snapshot)
    }

    @Test("skips consume their block slot without repetitions")
    func skipResolution() throws {
        let (routine, squat, row) = makeQueueFixture()
        let session = Session(routineID: routine.id, startedAt: q0)
        let entries = [
            SetEntry(sessionID: session.id, exerciseID: squat.id, setBlockID: routine.blocks[0].id, sequence: 0, completedAt: q(1), repetitions: 5),
            SetEntry(sessionID: session.id, exerciseID: row.id, setBlockID: routine.blocks[1].id, sequence: 1, completedAt: q(2), kind: .skipped),
        ]
        let snapshot = try SessionQueue.snapshot(routine: routine, session: session, entries: entries)
        #expect(snapshot.skippedCount == 1)
        // Squat slots 1-2 and the remaining Row slot are still pending.
        #expect(snapshot.pendingCount == 3)
        #expect(snapshot.current?.sequence == 1)
        let rowSkip = snapshot.slots.first { $0.status == .skipped }
        #expect(rowSkip?.planned?.exerciseID == row.id)
    }

    @Test("exhausted queue reports finished with no actionable current")
    func exhaustedQueue() throws {
        let (routine, _, _) = makeQueueFixture()
        let session = Session(routineID: routine.id, startedAt: q0)
        var entries: [SetEntry] = []
        for (index, slot) in SessionQueue.plannedQueue(for: routine).enumerated() {
            entries.append(
                SetEntry(
                    sessionID: session.id,
                    exerciseID: slot.exerciseID,
                    setBlockID: slot.setBlockID,
                    sequence: index,
                    completedAt: q(index + 1),
                    repetitions: 5
                )
            )
        }
        let snapshot = try SessionQueue.snapshot(routine: routine, session: session, entries: entries)
        #expect(snapshot.phase == .finished)
        #expect(snapshot.current == nil)
        #expect(snapshot.nextAction == nil)
        #expect(snapshot.completedCount == 5)
        #expect(snapshot.pendingCount == 0)
        #expect(snapshot.nextSequence == 5)
    }

    @Test("terminal sessions keep their final queue state")
    func terminalPhases() throws {
        let (routine, _, _) = makeQueueFixture()
        let completed = Session(routineID: routine.id, startedAt: q0, completedAt: q(10))
        let abandoned = Session(routineID: routine.id, startedAt: q0, abandonedAt: q(10))
        #expect(try SessionQueue.snapshot(routine: routine, session: completed, entries: []).phase == .sessionCompleted)
        #expect(try SessionQueue.snapshot(routine: routine, session: abandoned, entries: []).phase == .abandoned)
    }

    @Test("free-session entries are ad-hoc completions")
    func freeSessionAdHoc() throws {
        let session = Session(routineID: nil, startedAt: q0)
        let entry = SetEntry(sessionID: session.id, exerciseID: ex("Chin-up").id, sequence: 0, completedAt: q(1), repetitions: 3)
        let snapshot = try SessionQueue.snapshot(routine: nil, session: session, entries: [entry])
        #expect(snapshot.phase == .running)
        #expect(snapshot.adHocCompletedCount == 1)
        #expect(snapshot.current == nil)

        let fresh = try SessionQueue.snapshot(routine: nil, session: session, entries: [])
        #expect(fresh.phase == .notStarted)
    }

    @Test("sequence gaps are rejected instead of reinterpreted")
    func sequenceGapRejected() {
        let session = Session(routineID: nil, startedAt: q0)
        let entry = SetEntry(sessionID: session.id, exerciseID: ex("X").id, sequence: 1, completedAt: q(1))
        #expect(throws: SetFlowValidationError.invalidSequence(expected: 0, actual: 1)) {
            _ = try SessionQueue.snapshot(routine: nil, session: session, entries: [entry])
        }
    }

    @Test("block entries must match the next unresolved slot for that block")
    func unmatchableBlockRejected() {
        let (routine, squat, _) = makeQueueFixture()
        let session = Session(routineID: routine.id, startedAt: q0)
        // Entry names the Row block but claims the Squat exercise.
        let entry = SetEntry(
            id: SetEntryID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!),
            sessionID: session.id, exerciseID: squat.id,
            setBlockID: routine.blocks[1].id, sequence: 0, completedAt: q(1), repetitions: 1
        )
        #expect(throws: SetFlowValidationError.unmatchableSetEntry(entry.id)) {
            _ = try SessionQueue.snapshot(routine: routine, session: session, entries: [entry])
        }
    }

    @Test("skip without a planned slot is rejected")
    func blocklessSkipRejected() {
        let (routine, squat, _) = makeQueueFixture()
        let session = Session(routineID: routine.id, startedAt: q0)
        let entry = SetEntry(sessionID: session.id, exerciseID: squat.id, sequence: 0, completedAt: q(1), kind: .skipped)
        #expect(throws: SetFlowValidationError.invalidSkip("A skipped set must reference a planned block slot")) {
            _ = try SessionQueue.snapshot(routine: routine, session: session, entries: [entry])
        }
    }

    @Test("session and routine identity must agree")
    func identityMismatchRejected() {
        let (routine, _, _) = makeQueueFixture()
        let session = Session(routineID: RoutineID(), startedAt: q0)
        #expect(throws: SetFlowValidationError.routineIdentityMismatch) {
            _ = try SessionQueue.snapshot(routine: routine, session: session, entries: [])
        }
    }

    @Test("skipped entries reject repetitions at validation")
    func skipValidation() {
        let entry = SetEntry(
            sessionID: SessionID(), exerciseID: ExerciseID(), setBlockID: SetBlockID(),
            sequence: 0, completedAt: q0, repetitions: 5, kind: .skipped
        )
        #expect(throws: SetFlowValidationError.invalidSkip("Skipped entries must not carry repetitions")) {
            try entry.validate()
        }
    }

    @Test("entry kind round-trips through canonical JSON")
    func kindCodable() throws {
        let entry = SetEntry(
            sessionID: SessionID(), exerciseID: ExerciseID(), setBlockID: SetBlockID(),
            sequence: 0, completedAt: q0, kind: .skipped
        )
        let decoded = try DomainCoding.decode(SetEntry.self, from: DomainCoding.encode(entry))
        #expect(decoded == entry)
        #expect(decoded.kind == .skipped)

        // Legacy payloads without a kind field decode as completed.
        var object = try #require(
            JSONSerialization.jsonObject(with: DomainCoding.encode(SetEntry(
                sessionID: entry.sessionID, exerciseID: entry.exerciseID,
                sequence: 0, completedAt: q0
            ))) as? [String: Any]
        )
        object.removeValue(forKey: "kind")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let legacyDecoded = try DomainCoding.decode(SetEntry.self, from: legacy)
        #expect(legacyDecoded.kind == .completed)
    }
}

@Suite("Durable rest timer")
struct RestTimerTests {
    @Test("idle timer has no phase and zero remaining")
    func idle() {
        let timer = RestTimer.idle
        #expect(timer.phase(at: q0) == .idle)
        #expect(timer.remainingMilliseconds(at: q0) == 0)
        #expect(timer.isIdle)
    }

    @Test("start anchors an absolute deadline and counts down")
    func countdown() {
        var timer = RestTimer.idle
        timer.start(duration: 90, at: q(0))
        #expect(timer.phase(at: q(10)) == .running)
        #expect(timer.remainingMilliseconds(at: q(10)) == 80_000)
        #expect(timer.endsAt == q(90))
        // Later ticks derive from the same anchor — no decrement drift.
        #expect(timer.remainingMilliseconds(at: q(45)) == 45_000)
        // Crossing the deadline flips to finished with zero remaining.
        #expect(timer.phase(at: q(90)) == .finished)
        #expect(timer.remainingMilliseconds(at: q(120)) == 0)
        #expect(timer.hasEligibleFireDeadline(at: q(120)))
    }

    @Test("pause freezes the remainder and resume re-anchors it")
    func pauseResume() {
        var timer = RestTimer.idle
        timer.start(duration: 90, at: q(0))
        timer.pause(at: q(30))
        #expect(timer.phase(at: q(30)) == .paused)
        #expect(timer.pausedRemainingMilliseconds == 60_000)
        #expect(timer.endsAt == nil)
        // Paused remainder does not decay.
        #expect(timer.remainingMilliseconds(at: q(10_000)) == 60_000)

        timer.resume(at: q(120))
        #expect(timer.phase(at: q(120)) == .running)
        #expect(timer.endsAt == q(180))
        #expect(timer.remainingMilliseconds(at: q(150)) == 30_000)
    }

    @Test("pausing an idle timer is a no-op")
    func pauseIdleNoOp() {
        var timer = RestTimer.idle
        timer.pause(at: q(0))
        #expect(timer.phase(at: q(0)) == .idle)
    }

    @Test("a clock rewound behind the anchor clamps instead of inflating")
    func clockRewindClamp() {
        var timer = RestTimer.idle
        timer.start(duration: 90, at: q(0))
        // System clock jumps back 60s: remaining is clamped to the full duration.
        #expect(timer.remainingMilliseconds(at: q(-60)) == 90_000)
    }

    @Test("a forward clock jump lands directly on finished")
    func clockJumpForward() {
        var timer = RestTimer.idle
        timer.start(duration: 90, at: q(0))
        #expect(timer.phase(at: q(3_600)) == .finished)
        #expect(timer.remainingMilliseconds(at: q(3_600)) == 0)
    }

    @Test("cancel clears all anchors")
    func cancel() {
        var timer = RestTimer.idle
        timer.start(duration: 90, at: q(0))
        timer.cancel()
        #expect(timer.phase(at: q(1)) == .idle)
        #expect(timer.isIdle)
    }

    @Test("anchors round-trip through Codable unchanged")
    func codableRoundTrip() throws {
        var timer = RestTimer.idle
        timer.start(duration: 90, at: q(0))
        timer.pause(at: q(20))
        let decoded = try DomainCoding.decode(RestTimer.self, from: DomainCoding.encode(timer))
        #expect(decoded == timer)
        #expect(decoded.phase(at: q(20)) == .paused)
        #expect(decoded.remainingMilliseconds(at: q(9_999)) == 70_000)
    }
}

@Suite("Session runtime persistence")
struct SessionRuntimeStoreTests {
    private func fixture() throws -> (SetFlowStore, Routine, SessionID) {
        let store = try SetFlowStore.makeInMemory()
        let (routine, _, _) = makeQueueFixture()
        try store.saveRoutine(routine)
        let session = try store.startSession(routineID: routine.id, startedAt: q(0))
        return (store, routine, session.id)
    }

    @Test("queue snapshot tracks logged sets")
    func liveQueueSnapshot() throws {
        let (store, routine, sessionID) = try fixture()
        let squat = routine.blocks[0].exercise.id
        let row = routine.blocks[1].exercise.id

        var snapshot = try store.queueSnapshot(sessionID: sessionID)
        #expect(snapshot.phase == .notStarted)
        #expect(snapshot.nextAction?.targetBlockID == routine.blocks[0].id)

        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(1), repetitions: 5)
        snapshot = try store.queueSnapshot(sessionID: sessionID)
        #expect(snapshot.current?.sequence == 1)

        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: row, setBlockID: routine.blocks[1].id, completedAt: q(2), kind: .skipped)
        snapshot = try store.queueSnapshot(sessionID: sessionID)
        #expect(snapshot.skippedCount == 1)
        #expect(snapshot.current?.sequence == 1)
    }

    @Test("skips require a planned block slot at the store boundary")
    func storeRejectsBlocklessSkip() throws {
        let (store, routine, sessionID) = try fixture()
        let squat = routine.blocks[0].exercise.id
        #expect(throws: SetFlowValidationError.invalidSkip("A skipped set must reference a planned block slot")) {
            _ = try store.logSetEntry(sessionID: sessionID, exerciseID: squat, completedAt: q(1), kind: .skipped)
        }
    }

    @Test("undo reopens the last set deterministically")
    func undo() throws {
        let (store, routine, sessionID) = try fixture()
        let squat = routine.blocks[0].exercise.id
        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(1), repetitions: 5)
        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(2), repetitions: 4)

        let undone = try store.undoLastSetEntry(sessionID: sessionID)
        #expect(undone.repetitions == 4)
        let snapshot = try store.queueSnapshot(sessionID: sessionID)
        #expect(snapshot.completedCount == 1)
        #expect(snapshot.current?.sequence == 1)

        // Relogging after undo reuses the dense sequence slot.
        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(3), repetitions: 6)
        let entries = try store.fetchEntries(sessionID: sessionID)
        #expect(entries.map(\.sequence) == [0, 1])
        #expect(entries[1].repetitions == 6)

        // Undo on a completed session is refused.
        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(4), repetitions: 3)
        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: routine.blocks[1].exercise.id, setBlockID: routine.blocks[1].id, completedAt: q(5), repetitions: 8)
        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: routine.blocks[1].exercise.id, setBlockID: routine.blocks[1].id, completedAt: q(6), repetitions: 8)
        #expect(try store.queueSnapshot(sessionID: sessionID).phase == .finished)
        try store.completeSession(id: sessionID, completedAt: q(7))
        #expect(throws: StoreError.sessionAlreadyCompleted) {
            _ = try store.undoLastSetEntry(sessionID: sessionID)
        }
    }

    @Test("undo on an empty session reports nothing to undo")
    func undoEmpty() throws {
        let (store, _, sessionID) = try fixture()
        #expect(throws: StoreError.recordNotFound("Session has no entries to undo")) {
            _ = try store.undoLastSetEntry(sessionID: sessionID)
        }
    }

    @Test("reopening an interrupted session reconstructs the identical queue")
    func relaunchReconstruction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("set-flow-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        let (routine, _, _) = makeQueueFixture()
        let store = try SetFlowStore.makeOnDisk(at: path)
        try store.saveRoutine(routine)
        let session = try store.startSession(routineID: routine.id, startedAt: q(0))
        let squat = routine.blocks[0].exercise.id
        _ = try store.logSetEntry(sessionID: session.id, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(1), repetitions: 5)
        _ = try store.logSetEntry(sessionID: session.id, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(2), kind: .skipped)
        var timer = RestTimer.idle
        timer.start(duration: 90, at: q(2))
        try store.saveRestTimer(timer, for: session.id, updatedAt: q(2))

        // Simulated relaunch: a brand-new store over the same file.
        let reopened = try SetFlowStore.makeOnDisk(at: path)
        let active = try reopened.fetchActiveSessions()
        #expect(active.map(\.id) == [session.id])
        let restored = try reopened.queueSnapshot(sessionID: session.id)
        let original = try store.queueSnapshot(sessionID: session.id)
        #expect(restored == original)
        #expect(restored.phase == .running)
        #expect(restored.completedCount == 1)
        #expect(restored.skippedCount == 1)
        #expect(restored.current?.sequence == 2)

        let restoredTimer = try reopened.restTimer(for: session.id)
        #expect(restoredTimer == timer)
        #expect(restoredTimer.remainingMilliseconds(at: q(20)) == 72_000)
    }

    @Test("abandonment is durable and terminal")
    func abandon() throws {
        let (store, routine, sessionID) = try fixture()
        let squat = routine.blocks[0].exercise.id
        _ = try store.logSetEntry(sessionID: sessionID, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(1), repetitions: 5)

        try store.abandonSession(id: sessionID, abandonedAt: q(2))
        #expect(try store.fetchSession(id: sessionID)?.status == .abandoned)
        #expect(try store.queueSnapshot(sessionID: sessionID).phase == .abandoned)
        // Logged history survives abandonment.
        #expect(try store.fetchEntries(sessionID: sessionID).count == 1)

        #expect(throws: SetFlowValidationError.sessionAlreadyAbandoned) {
            _ = try store.logSetEntry(sessionID: sessionID, exerciseID: squat, setBlockID: routine.blocks[0].id, completedAt: q(3), repetitions: 1)
        }
        #expect(throws: SetFlowValidationError.sessionAlreadyAbandoned) {
            _ = try store.undoLastSetEntry(sessionID: sessionID)
        }
        #expect(throws: SetFlowValidationError.sessionAlreadyAbandoned) {
            try store.completeSession(id: sessionID, completedAt: q(3))
        }
        #expect(throws: SetFlowValidationError.sessionAlreadyAbandoned) {
            try store.saveRestTimer(.idle, for: sessionID, updatedAt: q(3))
        }
        #expect(throws: SetFlowValidationError.sessionAlreadyAbandoned) {
            try store.abandonSession(id: sessionID, abandonedAt: q(4))
        }
        // Abandoned sessions are not resumable.
        #expect(try store.fetchActiveSessions().isEmpty)
        // An abandoned session with entries cannot be discarded.
        #expect(throws: StoreError.sessionNotEmpty) {
            try store.discardEmptySession(id: sessionID)
        }
    }

    @Test("abandon and complete are mutually exclusive")
    func completeThenAbandon() throws {
        let (store, _, sessionID) = try fixture()
        try store.completeSession(id: sessionID, completedAt: q(5))
        #expect(throws: StoreError.sessionAlreadyCompleted) {
            try store.abandonSession(id: sessionID, abandonedAt: q(6))
        }
        #expect(try store.fetchSession(id: sessionID)?.status == .completed)
        // Empty abandoned sessions can be discarded cleanly.
        let ephemeral = try store.startSession(startedAt: q(0))
        try store.abandonSession(id: ephemeral.id, abandonedAt: q(1))
        try store.discardEmptySession(id: ephemeral.id)
        #expect(try store.fetchSession(id: ephemeral.id) == nil)
    }

    @Test("unilateral facts survive logging, undo, and relaunch")
    func unilateralSetsSurviveRuntimeLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("set-flow-unilateral-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        let (store, sessionID) = try freeFixture(at: path)
        let lateral = ex("Lateral raise")
        try store.saveExercise(lateral)
        let left = try store.logSetEntry(
            sessionID: sessionID, exerciseID: lateral.id, completedAt: q(1),
            repetitions: 10, load: LoadValue(amountInThousandths: 6_000, unit: .kilograms),
            side: .left, asymmetryNote: "Left weaker"
        )
        _ = try store.logSetEntry(
            sessionID: sessionID, exerciseID: lateral.id, completedAt: q(2),
            repetitions: 12, side: .right
        )
        let undone = try store.undoLastSetEntry(sessionID: sessionID)
        #expect(undone.side == .right)

        let reopened = try SetFlowStore.makeOnDisk(at: path)
        let entries = try reopened.fetchEntries(sessionID: sessionID)
        #expect(entries.map(\.id) == [left.id])
        #expect(entries[0].side == .left)
        #expect(entries[0].asymmetryNote == "Left weaker")
        #expect(entries[0].load?.unit == .kilograms)
        let snapshot = try reopened.queueSnapshot(sessionID: sessionID)
        #expect(snapshot.adHocCompletedCount == 1)
    }

    private func freeFixture(at path: String) throws -> (SetFlowStore, SessionID) {
        let store = try SetFlowStore.makeOnDisk(at: path)
        let session = try store.startSession(startedAt: q(0))
        return (store, session.id)
    }

    @Test("rest timer persistence preserves anchors and refuses stale writes")
    func timerPersistence() throws {
        let (store, _, sessionID) = try fixture()
        #expect(try store.restTimer(for: sessionID) == .idle)

        var timer = RestTimer.idle
        timer.start(duration: 90, at: q(0))
        try store.saveRestTimer(timer, for: sessionID, updatedAt: q(0))

        timer.pause(at: q(30))
        try store.saveRestTimer(timer, for: sessionID, updatedAt: q(30))
        let stored = try store.restTimer(for: sessionID)
        #expect(stored.phase(at: q(30)) == .paused)
        #expect(stored.remainingMilliseconds(at: q(500)) == 60_000)

        // A stale in-memory copy must not clobber the fresher anchor.
        #expect(throws: StoreError.staleRestTimerWrite) {
            var stale = RestTimer.idle
            stale.start(duration: 30, at: q(5))
            try store.saveRestTimer(stale, for: sessionID, updatedAt: q(10))
        }

        // Equal timestamps are allowed (idempotent re-save of the same state).
        try store.saveRestTimer(stored, for: sessionID, updatedAt: q(30))

        // Terminal sessions refuse timer writes.
        try store.completeSession(id: sessionID, completedAt: q(40))
        #expect(throws: StoreError.sessionAlreadyCompleted) {
            try store.saveRestTimer(timer, for: sessionID, updatedAt: q(41))
        }
    }

    @Test("rest timer cannot be stored for an unknown session")
    func timerUnknownSession() throws {
        let (store, _, _) = try fixture()
        #expect(throws: StoreError.recordNotFound("Session not found")) {
            try store.saveRestTimer(.idle, for: SessionID(), updatedAt: q(0))
        }
    }
}
