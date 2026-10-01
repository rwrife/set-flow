import Foundation
import GRDB
import Testing
@testable import SetFlowKit

private let t0 = Timestamp(millisecondsSinceUnixEpoch: 1_700_000_000_000)
private let t1 = Timestamp(millisecondsSinceUnixEpoch: 1_700_000_001_000)

private func makeExercise(name: String = "Goblet squat") -> Exercise {
    Exercise(name: name, createdAt: t0, updatedAt: t1)
}

private func makeRoutine(name: String = "Day A", exercise: Exercise? = nil) -> Routine {
    let exercise = exercise ?? makeExercise()
    return Routine(
        name: name,
        blocks: [
            SetBlock(
                exercise: exercise,
                position: 0,
                targetRepetitions: 8,
                targetLoad: LoadValue(amountInThousandths: 22_500, unit: .kilograms),
                note: "Controlled tempo"
            ),
        ],
        createdAt: t0,
        updatedAt: t1
    )
}

@Suite("Domain serialization and validation")
struct DomainTests {
    @Test("namespace reports domain milestone")
    func namespace() {
        #expect(SetFlowKit.domain == "SetFlowKit")
        #expect(SetFlowKit.milestone == "M3-runner-ui")
        #expect(SetFlowKit.domainSchemaVersion == 4)
    }

    @Test("typed identifiers encode as stable UUID objects")
    func typedIdentifiers() throws {
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let id = RoutineID(rawValue: uuid)
        let encoded = try DomainCoding.encode(id)
        let decoded = try DomainCoding.decode(RoutineID.self, from: encoded)
        #expect(decoded == id)
        #expect(id.description == "00000000-0000-0000-0000-000000000002")
        #expect(String(data: encoded, encoding: .utf8) == "\"00000000-0000-0000-0000-000000000002\"")
    }

    @Test("timestamps round trip as integer milliseconds")
    func timestampRoundTrip() throws {
        let encoded = try DomainCoding.encode(t0)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json == "1700000000000")
        #expect(try DomainCoding.decode(Timestamp.self, from: encoded) == t0)
        #expect(Timestamp(date: t0.date) == t0)
    }

    @Test("routine round trip preserves explicit units and omitted values")
    func routineRoundTrip() throws {
        var routine = makeRoutine()
        routine.blocks.append(
            SetBlock(exercise: makeExercise(name: "Push-up"), position: 1)
        )
        let data = try DomainCoding.encode(routine)
        let decoded = try DomainCoding.decode(Routine.self, from: data)
        #expect(decoded == routine)
        #expect(decoded.blocks[0].targetLoad?.unit == .kilograms)
        #expect(decoded.blocks[1].targetRepetitions == nil)
        #expect(decoded.blocks[1].targetLoad == nil)
        #expect(decoded.blocks[1].note == nil)
    }

    @Test("unknown unilateral side remains explicit")
    func unknownSideRoundTrip() throws {
        let entry = SetEntry(
            sessionID: SessionID(),
            exerciseID: ExerciseID(),
            sequence: 0,
            completedAt: t0,
            side: .unknown,
            asymmetryNote: "Unsure"
        )
        let decoded = try DomainCoding.decode(SetEntry.self, from: DomainCoding.encode(entry))
        #expect(decoded.side == .unknown)
        #expect(decoded.asymmetryNote == "Unsure")
    }

    @Test("routine validation rejects duplicate ordering")
    func duplicateOrdering() throws {
        var routine = makeRoutine()
        routine.blocks.append(SetBlock(exercise: makeExercise(name: "Row"), position: 0))
        #expect(throws: SetFlowValidationError.duplicatePosition(0)) {
            try routine.validate()
        }
    }

    @Test("validation rejects blank names and invalid quantities")
    func invalidValues() throws {
        let exercise = Exercise(name: "  ", createdAt: t0, updatedAt: t1)
        #expect(throws: SetFlowValidationError.blankName) { try exercise.validate() }

        let negativeLoad = SetEntry(
            sessionID: SessionID(),
            exerciseID: ExerciseID(),
            sequence: 0,
            completedAt: t0,
            repetitions: 1,
            load: LoadValue(amountInThousandths: -1, unit: .pounds)
        )
        #expect(throws: SetFlowValidationError.invalidLoad(-1)) { try negativeLoad.validate() }
    }
}

@Suite("Local GRDB store")
struct StoreTests {
    @Test("fresh database applies ordered migrations")
    func freshMigrations() throws {
        let store = try SetFlowStore.makeInMemory()
        #expect(try store.appliedMigrations() == [
            "v1-initial-schema",
            "v2-schema-provenance",
            "v3-preserve-history-links",
            "v4-session-runtime",
        ])
    }

    @Test("exercise CRUD round trip")
    func exerciseCRUD() throws {
        let store = try SetFlowStore.makeInMemory()
        var exercise = makeExercise()
        try store.saveExercise(exercise)
        #expect(try store.fetchExercise(id: exercise.id) == exercise)

        exercise.name = "Front squat"
        exercise.updatedAt = Timestamp(millisecondsSinceUnixEpoch: t1.millisecondsSinceUnixEpoch + 1)
        try store.saveExercise(exercise)
        #expect(try store.fetchExercise(id: exercise.id)?.name == "Front squat")

        try store.deleteExercise(id: exercise.id)
        #expect(try store.fetchExercise(id: exercise.id) == nil)
    }

    @Test("routine CRUD preserves deterministic block order")
    func routineCRUD() throws {
        let store = try SetFlowStore.makeInMemory()
        let first = makeExercise(name: "Squat")
        let second = makeExercise(name: "Row")
        var routine = Routine(
            name: "Full body",
            blocks: [
                SetBlock(exercise: second, position: 1, targetRepetitions: 10),
                SetBlock(exercise: first, position: 0, targetRepetitions: 5),
            ],
            createdAt: t0,
            updatedAt: t1
        )
        try routine.validate()
        try store.saveRoutine(routine)

        let fetched = try #require(try store.fetchRoutine(id: routine.id))
        #expect(fetched.blocks.map(\.position) == [0, 1])
        #expect(fetched.blocks.map(\.exercise.name) == ["Squat", "Row"])

        routine.name = "Full body updated"
        // Exchange the two retained blocks' positions (Row 1->0, Squat 0->1).
        routine.blocks[0].position = 0
        routine.blocks[1].position = 1
        try store.saveRoutine(routine)
        #expect(try store.fetchRoutine(id: routine.id)?.blocks.map(\.exercise.name) == ["Row", "Squat"])

        routine.blocks.removeLast()
        try store.saveRoutine(routine)
        #expect(try store.fetchRoutine(id: routine.id)?.blocks.count == 1)

        try store.deleteRoutine(id: routine.id)
        #expect(try store.fetchRoutine(id: routine.id) == nil)
    }

    @Test("routine edits preserve retained block links in logged history")
    func routineEditPreservesBlockLink() throws {
        let store = try SetFlowStore.makeInMemory()
        var routine = makeRoutine()
        try store.saveRoutine(routine)
        let blockID = routine.blocks[0].id
        let session = try store.startSession(routineID: routine.id, startedAt: t0)
        _ = try store.logSetEntry(
            sessionID: session.id,
            exerciseID: routine.blocks[0].exercise.id,
            setBlockID: blockID,
            completedAt: t1,
            repetitions: 8
        )

        routine.name = "Updated day A"
        routine.blocks[0].targetRepetitions = 10
        routine.updatedAt = Timestamp(millisecondsSinceUnixEpoch: t1.millisecondsSinceUnixEpoch + 1)
        try store.saveRoutine(routine)

        let entries = try store.fetchEntries(sessionID: session.id)
        #expect(entries[0].setBlockID == blockID)
        #expect(try store.fetchRoutine(id: routine.id)?.blocks[0].targetRepetitions == 10)
    }

    @Test("routine and block deletion cannot rewrite logged history")
    func routineDeletionPreservesHistoryLinks() throws {
        let store = try SetFlowStore.makeInMemory()
        var routine = makeRoutine()
        try store.saveRoutine(routine)
        let session = try store.startSession(routineID: routine.id, startedAt: t0)
        _ = try store.logSetEntry(
            sessionID: session.id,
            exerciseID: routine.blocks[0].exercise.id,
            setBlockID: routine.blocks[0].id,
            completedAt: t1,
            repetitions: 8
        )

        #expect(throws: StoreError.foreignKeyConstraintViolation) {
            try store.deleteRoutine(id: routine.id)
        }

        routine.blocks.removeAll()
        #expect(throws: SetFlowValidationError.emptyRoutine) {
            try store.saveRoutine(routine)
        }

        let fetched = try #require(try store.fetchSession(id: session.id))
        #expect(fetched.routineID == routine.id)
        #expect(try store.fetchEntries(sessionID: session.id)[0].setBlockID != nil)
    }

    @Test("cross-routine block adoption is rejected")
    func crossRoutineBlockAdoptionRejected() throws {
        let store = try SetFlowStore.makeInMemory()
        let routineA = makeRoutine(name: "Routine A")
        try store.saveRoutine(routineA)
        let blockFromA = routineA.blocks[0]

        let foreignRoutine = Routine(
            name: "Routine B",
            blocks: [
                SetBlock(
                    id: blockFromA.id,
                    exercise: blockFromA.exercise,
                    position: 0,
                    targetRepetitions: 5
                )
            ],
            createdAt: t0,
            updatedAt: t1
        )
        #expect(throws: StoreError.blockConflict("Block already belongs to another routine")) {
            try store.saveRoutine(foreignRoutine)
        }
    }

    @Test("exercise cannot be reassigned on a block already logged in history")
    func referencedBlockExerciseMutationRejected() throws {
        let store = try SetFlowStore.makeInMemory()
        var routine = makeRoutine(name: "Routine A")
        try store.saveRoutine(routine)
        let session = try store.startSession(routineID: routine.id, startedAt: t0)
        _ = try store.logSetEntry(
            sessionID: session.id,
            exerciseID: routine.blocks[0].exercise.id,
            setBlockID: routine.blocks[0].id,
            completedAt: t1,
            repetitions: 8
        )

        let differentExercise = makeExercise(name: "Overhead press")
        routine.blocks[0].exercise = differentExercise
        #expect(throws: StoreError.blockConflict("Cannot change exercise of a block already referenced in history")) {
            try store.saveRoutine(routine)
        }
    }

    @Test("logged block must match entry exercise and session routine")
    func loggedBlockProvenanceValidated() throws {
        let store = try SetFlowStore.makeInMemory()
        let routineA = makeRoutine(name: "A")
        let routineB = makeRoutine(name: "B")
        try store.saveRoutine(routineA)
        try store.saveRoutine(routineB)

        let sessionA = try store.startSession(routineID: routineA.id, startedAt: t0)
        let otherExercise = makeExercise(name: "Pull-up")
        try store.saveExercise(otherExercise)

        #expect(throws: StoreError.blockConflict("Set block does not reference the logged exercise")) {
            try store.logSetEntry(
                sessionID: sessionA.id,
                exerciseID: otherExercise.id,
                setBlockID: routineA.blocks[0].id,
                completedAt: t1,
                repetitions: 5
            )
        }

        #expect(throws: StoreError.blockConflict("Set block belongs to a different routine than the session")) {
            try store.logSetEntry(
                sessionID: sessionA.id,
                exerciseID: routineB.blocks[0].exercise.id,
                setBlockID: routineB.blocks[0].id,
                completedAt: t1,
                repetitions: 5
            )
        }

        let freeSession = try store.startSession(routineID: nil, startedAt: t0)
        #expect(throws: StoreError.blockConflict("Cannot log a template block into a routine-less session")) {
            try store.logSetEntry(
                sessionID: freeSession.id,
                exerciseID: routineA.blocks[0].exercise.id,
                setBlockID: routineA.blocks[0].id,
                completedAt: t1,
                repetitions: 5
            )
        }

        #expect(throws: SetFlowValidationError.timestampOrder) {
            try store.logSetEntry(
                sessionID: sessionA.id,
                exerciseID: routineA.blocks[0].exercise.id,
                setBlockID: routineA.blocks[0].id,
                completedAt: Timestamp(millisecondsSinceUnixEpoch: t0.millisecondsSinceUnixEpoch - 1),
                repetitions: 5
            )
        }
    }

    @Test("routine save never clobbers a newer exercise edit")
    func routineSaveDoesNotOverwriteNewerExercise() throws {
        let store = try SetFlowStore.makeInMemory()
        var exercise = makeExercise(name: "Squat v1")
        try store.saveExercise(exercise)

        // Routine references the exercise as it looked at v1
        let routine = Routine(
            name: "Squat day",
            blocks: [SetBlock(exercise: exercise, position: 0, targetRepetitions: 5)],
            createdAt: t0,
            updatedAt: t0
        )

        // Exercise is independently updated to v2 with a newer timestamp
        exercise.name = "Squat v2 renamed"
        exercise.updatedAt = Timestamp(millisecondsSinceUnixEpoch: t1.millisecondsSinceUnixEpoch + 10)
        try store.saveExercise(exercise)

        // Saving the routine using its older embedded copy must NOT revert the rename
        try store.saveRoutine(routine)
        let reloaded = try #require(try store.fetchExercise(id: exercise.id))
        #expect(reloaded.name == "Squat v2 renamed")
        #expect(reloaded.updatedAt == exercise.updatedAt)
    }

    @Test("session logging appends immutable ordered entries")
    func sessionLogging() throws {
        let store = try SetFlowStore.makeInMemory()
        let exercise = makeExercise()
        try store.saveExercise(exercise)
        let session = try store.startSession(startedAt: t0)

        let first = try store.logSetEntry(
            sessionID: session.id,
            exerciseID: exercise.id,
            completedAt: t1,
            repetitions: 8,
            load: LoadValue(amountInThousandths: 12_500, unit: .kilograms),
            side: .left,
            asymmetryNote: "Left felt slower"
        )
        let second = try store.logSetEntry(
            sessionID: session.id,
            exerciseID: exercise.id,
            completedAt: Timestamp(millisecondsSinceUnixEpoch: t1.millisecondsSinceUnixEpoch + 1),
            repetitions: 7,
            side: .right
        )

        let entries = try store.fetchEntries(sessionID: session.id)
        #expect(entries.map(\.id) == [first.id, second.id])
        #expect(entries.map(\.sequence) == [0, 1])
        #expect(entries[0].load?.amountInThousandths == 12_500)
        #expect(entries[0].asymmetryNote == "Left felt slower")
        #expect(entries[1].load == nil)
    }

    @Test("session completion validates timestamp order")
    func sessionCompletion() throws {
        let store = try SetFlowStore.makeInMemory()
        let session = try store.startSession(startedAt: t1)
        #expect(throws: SetFlowValidationError.timestampOrder) {
            try store.completeSession(id: session.id, completedAt: t0)
        }
        let completion = Timestamp(millisecondsSinceUnixEpoch: t1.millisecondsSinceUnixEpoch + 1)
        try store.completeSession(id: session.id, completedAt: completion)
        #expect(try store.fetchSession(id: session.id)?.completedAt == completion)
        #expect(throws: StoreError.sessionAlreadyCompleted) {
            try store.completeSession(
                id: session.id,
                completedAt: Timestamp(millisecondsSinceUnixEpoch: completion.millisecondsSinceUnixEpoch + 1)
            )
        }

        let exercise = makeExercise()
        try store.saveExercise(exercise)
        #expect(throws: StoreError.sessionAlreadyCompleted) {
            try store.logSetEntry(
                sessionID: session.id,
                exerciseID: exercise.id,
                completedAt: completion,
                repetitions: 1
            )
        }
        #expect(try store.fetchEntries(sessionID: session.id).isEmpty)
    }

    @Test("only empty active sessions may be discarded")
    func discardEmptySession() throws {
        let store = try SetFlowStore.makeInMemory()
        let empty = try store.startSession(startedAt: t0)
        try store.discardEmptySession(id: empty.id)
        #expect(try store.fetchSession(id: empty.id) == nil)

        let exercise = makeExercise()
        try store.saveExercise(exercise)
        let logged = try store.startSession(startedAt: t0)
        _ = try store.logSetEntry(
            sessionID: logged.id,
            exerciseID: exercise.id,
            completedAt: t1,
            repetitions: 5
        )
        #expect(throws: StoreError.sessionNotEmpty) {
            try store.discardEmptySession(id: logged.id)
        }
        #expect(try store.fetchEntries(sessionID: logged.id).count == 1)
    }

    @Test("referenced exercises cannot be deleted")
    func referencedExerciseDeletion() throws {
        let store = try SetFlowStore.makeInMemory()
        let routine = makeRoutine()
        try store.saveRoutine(routine)
        #expect(throws: StoreError.foreignKeyConstraintViolation) {
            try store.deleteExercise(id: routine.blocks[0].exercise.id)
        }
    }

    @Test("v1 fixture migrates without losing routine or entries")
    func migrationFixture() throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "v1", withExtension: "sql", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "v1", withExtension: "sql")
        )
        let fixtureSQL = try String(contentsOf: fixtureURL, encoding: .utf8)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("set-flow-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v1.sqlite").path

        let legacy = try DatabaseQueue(path: path)
        try legacy.write { db in
            try db.execute(sql: fixtureSQL)
        }

        let migrated = try SetFlowStore.makeOnDisk(at: path)
        #expect(try migrated.appliedMigrations() == [
            "v1-initial-schema",
            "v2-schema-provenance",
            "v3-preserve-history-links",
            "v4-session-runtime",
        ])
        let routineID = RoutineID(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000022")))
        let sessionID = SessionID(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000023")))
        #expect(try migrated.fetchRoutine(id: routineID)?.name == "Legacy plan")
        #expect(try migrated.fetchRoutine(id: routineID)?.blocks.count == 1)
        #expect(try migrated.fetchRoutine(id: routineID)?.blocks[0].targetLoad?.amountInThousandths == 60_500)
        let entries = try migrated.fetchEntries(sessionID: sessionID)
        #expect(entries.count == 1)
        #expect(entries[0].repetitions == 5)
        #expect(entries[0].setBlockID?.rawValue.uuidString.lowercased() == "00000000-0000-0000-0000-000000000025")
        #expect(entries[0].side == .left)
        #expect(entries[0].asymmetryNote == "Legacy asymmetry")
    }
}
