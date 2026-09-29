import Foundation
import GRDB

public enum StoreError: Error, Equatable, Sendable {
    case recordNotFound(String)
    case foreignKeyConstraintViolation
    case sessionNotEmpty
    case sessionAlreadyCompleted
    case blockConflict(String)
    case migrationFailure(String)
}

public final class SetFlowStore: @unchecked Sendable {
    private let writer: any DatabaseWriter
    private let reader: any DatabaseReader

    private init(writer: any DatabaseWriter) {
        self.writer = writer
        self.reader = writer
    }

    public static func makeInMemory() throws -> SetFlowStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        let store = SetFlowStore(writer: queue)
        try store.migrate()
        return store
    }

    public static func makeOnDisk(at path: String) throws -> SetFlowStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        let store = SetFlowStore(writer: queue)
        try store.migrate()
        return store
    }

    public var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif

        migrator.registerMigration("v1-initial-schema") { db in
            try db.create(table: "exercise") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }

            try db.create(table: "routine") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }

            try db.create(table: "set_block") { t in
                t.column("id", .text).primaryKey()
                t.column("routineId", .text).notNull().references("routine", onDelete: .cascade)
                t.column("exerciseId", .text).notNull().references("exercise", onDelete: .restrict)
                t.column("position", .integer).notNull()
                t.column("targetRepetitions", .integer)
                t.column("targetLoadThousandths", .integer)
                t.column("targetLoadUnit", .text)
                t.column("note", .text)
                t.uniqueKey(["routineId", "position"])
            }

            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("routineId", .text).references("routine", onDelete: .setNull)
                t.column("startedAt", .integer).notNull()
                t.column("completedAt", .integer)
                t.column("note", .text)
            }

            try db.create(table: "set_entry") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade)
                t.column("exerciseId", .text).notNull().references("exercise", onDelete: .restrict)
                t.column("setBlockId", .text).references("set_block", onDelete: .setNull)
                t.column("sequence", .integer).notNull()
                t.column("completedAt", .integer).notNull()
                t.column("repetitions", .integer)
                t.column("loadThousandths", .integer)
                t.column("loadUnit", .text)
                t.column("side", .text)
                t.column("asymmetryNote", .text)
                t.uniqueKey(["sessionId", "sequence"])
            }

            try db.create(index: "idx_set_block_routine", on: "set_block", columns: ["routineId", "position"])
            try db.create(index: "idx_set_entry_session", on: "set_entry", columns: ["sessionId", "sequence"])
            try db.create(index: "idx_set_entry_exercise", on: "set_entry", columns: ["exerciseId", "completedAt"])
        }

        migrator.registerMigration("v2-schema-provenance") { db in
            try db.create(table: "schema_metadata") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
                t.column("appliedAt", .integer).notNull()
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_metadata (key, value, appliedAt) VALUES (?, ?, ?)",
                arguments: ["schema_version", "2", Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }

        migrator.registerMigration("v3-preserve-history-links") { db in
            // v1 used cascading / set-null template relationships, so deleting a
            // routine or set block silently rewrote recorded history. Rebuild the
            // three child tables with RESTRICT actions so logged sessions and
            // set entries keep their routine/block provenance permanently.
            try db.rename(table: "set_entry", to: "set_entry_v2")
            try db.rename(table: "session", to: "session_v2")
            try db.rename(table: "set_block", to: "set_block_v2")

            try db.create(table: "set_block") { t in
                t.column("id", .text).primaryKey()
                t.column("routineId", .text).notNull().references("routine", onDelete: .restrict)
                t.column("exerciseId", .text).notNull().references("exercise", onDelete: .restrict)
                t.column("position", .integer).notNull()
                t.column("targetRepetitions", .integer)
                t.column("targetLoadThousandths", .integer)
                t.column("targetLoadUnit", .text)
                t.column("note", .text)
                t.uniqueKey(["routineId", "position"])
            }
            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("routineId", .text).references("routine", onDelete: .restrict)
                t.column("startedAt", .integer).notNull()
                t.column("completedAt", .integer)
                t.column("note", .text)
            }
            try db.create(table: "set_entry") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).notNull().references("session", onDelete: .cascade)
                t.column("exerciseId", .text).notNull().references("exercise", onDelete: .restrict)
                t.column("setBlockId", .text).references("set_block", onDelete: .restrict)
                t.column("sequence", .integer).notNull()
                t.column("completedAt", .integer).notNull()
                t.column("repetitions", .integer)
                t.column("loadThousandths", .integer)
                t.column("loadUnit", .text)
                t.column("side", .text)
                t.column("asymmetryNote", .text)
                t.uniqueKey(["sessionId", "sequence"])
            }

            try db.execute(sql: """
                INSERT INTO set_block SELECT * FROM set_block_v2;
                INSERT INTO session SELECT * FROM session_v2;
                INSERT INTO set_entry SELECT * FROM set_entry_v2;
                DROP TABLE set_entry_v2;
                DROP TABLE session_v2;
                DROP TABLE set_block_v2;
                """)

            try db.create(index: "idx_set_block_routine", on: "set_block", columns: ["routineId", "position"])
            try db.create(index: "idx_set_entry_session", on: "set_entry", columns: ["sessionId", "sequence"])
            try db.create(index: "idx_set_entry_exercise", on: "set_entry", columns: ["exerciseId", "completedAt"])

            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_metadata (key, value, appliedAt) VALUES (?, ?, ?)",
                arguments: ["schema_version", "3", Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }

        return migrator
    }

    public func migrate() throws {
        try migrator.migrate(writer)
    }

    public func appliedMigrations() throws -> [String] {
        try reader.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier ASC")
        }
    }

}

// MARK: - Exercise CRUD

public extension SetFlowStore {
    func saveExercise(_ exercise: Exercise) throws {
        try exercise.validate()
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO exercise (id, name, createdAt, updatedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    exercise.id.rawValue.uuidString.lowercased(),
                    exercise.name,
                    exercise.createdAt.millisecondsSinceUnixEpoch,
                    exercise.updatedAt.millisecondsSinceUnixEpoch,
                ]
            )
        }
    }

    func fetchExercise(id: ExerciseID) throws -> Exercise? {
        try reader.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, name, createdAt, updatedAt FROM exercise WHERE id = ?",
                arguments: [id.rawValue.uuidString.lowercased()]
            ) else {
                return nil
            }
            return try Exercise(row: row)
        }
    }

    func fetchExercises() throws -> [Exercise] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, createdAt, updatedAt FROM exercise ORDER BY name ASC")
            return try rows.map { try Exercise(row: $0) }
        }
    }

    func deleteExercise(id: ExerciseID) throws {
        try writer.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM set_block WHERE exerciseId = ?",
                arguments: [id.rawValue.uuidString.lowercased()]
            ) ?? 0
            if count > 0 {
                throw StoreError.foreignKeyConstraintViolation
            }
            let entries = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM set_entry WHERE exerciseId = ?",
                arguments: [id.rawValue.uuidString.lowercased()]
            ) ?? 0
            if entries > 0 {
                throw StoreError.foreignKeyConstraintViolation
            }
            try db.execute(
                sql: "DELETE FROM exercise WHERE id = ?",
                arguments: [id.rawValue.uuidString.lowercased()]
            )
        }
    }
}

// MARK: - Routine CRUD

public extension SetFlowStore {
    func saveRoutine(_ routine: Routine) throws {
        try routine.validate()
        try writer.write { db in
            // Upsert routine row
            try db.execute(
                sql: """
                INSERT INTO routine (id, name, createdAt, updatedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    routine.id.rawValue.uuidString.lowercased(),
                    routine.name,
                    routine.createdAt.millisecondsSinceUnixEpoch,
                    routine.updatedAt.millisecondsSinceUnixEpoch,
                ]
            )

            // Ensure all exercises in blocks exist
            for block in routine.blocks {
                try db.execute(
                    sql: """
                    INSERT INTO exercise (id, name, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                    arguments: [
                        block.exercise.id.rawValue.uuidString.lowercased(),
                        block.exercise.name,
                        block.exercise.createdAt.millisecondsSinceUnixEpoch,
                        block.exercise.updatedAt.millisecondsSinceUnixEpoch,
                    ]
                )
            }

            // Sync blocks without destroying foreign keys for retained blocks
            let existingBlockIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM set_block WHERE routineId = ?",
                arguments: [routine.id.rawValue.uuidString.lowercased()]
            )
            let newBlockIDStrings = Set(routine.blocks.map { $0.id.rawValue.uuidString.lowercased() })

            // Move existing blocks to negative temporary positions first so
            // swapping two retained positions never violates unique(routineId, position).
            for (index, id) in existingBlockIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE set_block SET position = ? WHERE id = ?",
                    arguments: [-(index + 1), id]
                )
            }

            for oldID in existingBlockIDs where !newBlockIDStrings.contains(oldID) {
                let references = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM set_entry WHERE setBlockId = ?",
                    arguments: [oldID]
                ) ?? 0
                guard references == 0 else { throw StoreError.foreignKeyConstraintViolation }
                try db.execute(sql: "DELETE FROM set_block WHERE id = ?", arguments: [oldID])
            }

            for block in routine.blocks {
                let blockID = block.id.rawValue.uuidString.lowercased()
                let targetExerciseID = block.exercise.id.rawValue.uuidString.lowercased()
                let currentRoutineID = routine.id.rawValue.uuidString.lowercased()

                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT routineId, exerciseId FROM set_block WHERE id = ?",
                    arguments: [blockID]
                ) {
                    let existingRoutineID: String = existing["routineId"]
                    guard existingRoutineID == currentRoutineID else {
                        throw StoreError.blockConflict("Block already belongs to another routine")
                    }
                    let existingExerciseID: String = existing["exerciseId"]
                    if existingExerciseID != targetExerciseID {
                        let references = try Int.fetchOne(
                            db,
                            sql: "SELECT COUNT(*) FROM set_entry WHERE setBlockId = ?",
                            arguments: [blockID]
                        ) ?? 0
                        guard references == 0 else {
                            throw StoreError.blockConflict("Cannot change exercise of a block already referenced in history")
                        }
                    }
                }

                try db.execute(
                    sql: """
                    INSERT INTO set_block (
                        id, routineId, exerciseId, position,
                        targetRepetitions, targetLoadThousandths, targetLoadUnit, note
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        routineId = excluded.routineId,
                        exerciseId = excluded.exerciseId,
                        position = excluded.position,
                        targetRepetitions = excluded.targetRepetitions,
                        targetLoadThousandths = excluded.targetLoadThousandths,
                        targetLoadUnit = excluded.targetLoadUnit,
                        note = excluded.note
                    """,
                    arguments: [
                        blockID,
                        currentRoutineID,
                        targetExerciseID,
                        block.position,
                        block.targetRepetitions,
                        block.targetLoad?.amountInThousandths,
                        block.targetLoad?.unit.rawValue,
                        block.note,
                    ]
                )
            }
        }
    }

    func fetchRoutine(id: RoutineID) throws -> Routine? {
        try reader.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, name, createdAt, updatedAt FROM routine WHERE id = ?",
                arguments: [id.rawValue.uuidString.lowercased()]
            ) else {
                return nil
            }

            let blockRows = try Row.fetchAll(
                db,
                sql: """
                SELECT b.id, b.position, b.targetRepetitions, b.targetLoadThousandths, b.targetLoadUnit, b.note,
                       e.id AS exerciseId, e.name AS exerciseName, e.createdAt AS exerciseCreatedAt, e.updatedAt AS exerciseUpdatedAt
                FROM set_block b
                JOIN exercise e ON e.id = b.exerciseId
                WHERE b.routineId = ?
                ORDER BY b.position ASC
                """,
                arguments: [id.rawValue.uuidString.lowercased()]
            )

            let blocks = try blockRows.map { row -> SetBlock in
                guard let blockUUID = UUID(uuidString: row["id"]) else {
                    throw StoreError.recordNotFound("Invalid block UUID")
                }
                guard let exUUID = UUID(uuidString: row["exerciseId"]) else {
                    throw StoreError.recordNotFound("Invalid exercise UUID")
                }
                let exercise = Exercise(
                    id: ExerciseID(rawValue: exUUID),
                    name: row["exerciseName"],
                    createdAt: Timestamp(millisecondsSinceUnixEpoch: row["exerciseCreatedAt"]),
                    updatedAt: Timestamp(millisecondsSinceUnixEpoch: row["exerciseUpdatedAt"])
                )
                let targetLoad: LoadValue?
                if let thousandths: Int64 = row["targetLoadThousandths"],
                   let unitStr: String = row["targetLoadUnit"],
                   let unit = LoadUnit(rawValue: unitStr) {
                    targetLoad = LoadValue(amountInThousandths: thousandths, unit: unit)
                } else {
                    targetLoad = nil
                }
                return SetBlock(
                    id: SetBlockID(rawValue: blockUUID),
                    exercise: exercise,
                    position: row["position"],
                    targetRepetitions: row["targetRepetitions"],
                    targetLoad: targetLoad,
                    note: row["note"]
                )
            }

            guard let routineUUID = UUID(uuidString: row["id"]) else {
                throw StoreError.recordNotFound("Invalid routine UUID")
            }
            return Routine(
                id: RoutineID(rawValue: routineUUID),
                name: row["name"],
                blocks: blocks,
                createdAt: Timestamp(millisecondsSinceUnixEpoch: row["createdAt"]),
                updatedAt: Timestamp(millisecondsSinceUnixEpoch: row["updatedAt"])
            )
        }
    }

    func fetchRoutines() throws -> [Routine] {
        let ids: [RoutineID] = try reader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM routine ORDER BY updatedAt DESC")
                .compactMap { uuidStr in UUID(uuidString: uuidStr).map(RoutineID.init) }
        }
        return try ids.compactMap { try fetchRoutine(id: $0) }
    }

    func deleteRoutine(id: RoutineID) throws {
        try writer.write { db in
            let routineID = id.rawValue.uuidString.lowercased()
            let sessionCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM session WHERE routineId = ?",
                arguments: [routineID]
            ) ?? 0
            let entryCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM set_entry e
                JOIN set_block b ON b.id = e.setBlockId
                WHERE b.routineId = ?
                """,
                arguments: [routineID]
            ) ?? 0
            guard sessionCount == 0, entryCount == 0 else {
                throw StoreError.foreignKeyConstraintViolation
            }
            try db.execute(sql: "DELETE FROM set_block WHERE routineId = ?", arguments: [routineID])
            try db.execute(sql: "DELETE FROM routine WHERE id = ?", arguments: [routineID])
        }
    }
}

// MARK: - Session & SetEntry (Append-Oriented)

public extension SetFlowStore {
    func startSession(routineID: RoutineID? = nil, startedAt: Timestamp = Timestamp(date: Date()), note: String? = nil) throws -> Session {
        let session = Session(routineID: routineID, startedAt: startedAt, note: note)
        try session.validate()
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO session (id, routineId, startedAt, note) VALUES (?, ?, ?, ?)",
                arguments: [
                    session.id.rawValue.uuidString.lowercased(),
                    session.routineID?.rawValue.uuidString.lowercased(),
                    session.startedAt.millisecondsSinceUnixEpoch,
                    session.note,
                ]
            )
        }
        return session
    }

    func completeSession(id: SessionID, completedAt: Timestamp = Timestamp(date: Date()), note: String? = nil) throws {
        try writer.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT startedAt, completedAt FROM session WHERE id = ?",
                arguments: [id.rawValue.uuidString.lowercased()]
            ) else {
                throw StoreError.recordNotFound("Session not found")
            }
            let existingCompletion: Int64? = row["completedAt"]
            guard existingCompletion == nil else { throw StoreError.sessionAlreadyCompleted }
            let startedAt = Timestamp(millisecondsSinceUnixEpoch: row["startedAt"])
            if completedAt < startedAt {
                throw SetFlowValidationError.timestampOrder
            }
            try db.execute(
                sql: "UPDATE session SET completedAt = ?, note = COALESCE(?, note) WHERE id = ?",
                arguments: [
                    completedAt.millisecondsSinceUnixEpoch,
                    note,
                    id.rawValue.uuidString.lowercased(),
                ]
            )
        }
    }

    func logSetEntry(
        sessionID: SessionID,
        exerciseID: ExerciseID,
        setBlockID: SetBlockID? = nil,
        completedAt: Timestamp = Timestamp(date: Date()),
        repetitions: Int? = nil,
        load: LoadValue? = nil,
        side: UnilateralSide? = nil,
        asymmetryNote: String? = nil
    ) throws -> SetEntry {
        try writer.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT startedAt, completedAt, routineId FROM session WHERE id = ?",
                arguments: [sessionID.rawValue.uuidString.lowercased()]
            ) else {
                throw StoreError.recordNotFound("Session not found")
            }
            let completedAtValue: Int64? = row["completedAt"]
            guard completedAtValue == nil else { throw StoreError.sessionAlreadyCompleted }
            let sessionStartedAt = Timestamp(millisecondsSinceUnixEpoch: row["startedAt"])
            guard completedAt >= sessionStartedAt else {
                throw SetFlowValidationError.timestampOrder
            }

            // A logged block must belong to the session's routine and name the
            // same exercise as the entry; foreign keys alone only prove each ID
            // exists, not that the IDs belong together.
            if let setBlockID {
                guard let blockRow = try Row.fetchOne(
                    db,
                    sql: "SELECT routineId, exerciseId FROM set_block WHERE id = ?",
                    arguments: [setBlockID.rawValue.uuidString.lowercased()]
                ) else {
                    throw StoreError.recordNotFound("Set block not found")
                }
                let blockRoutineID: String = blockRow["routineId"]
                let blockExerciseID: String = blockRow["exerciseId"]
                let entryExerciseID = exerciseID.rawValue.uuidString.lowercased()
                guard blockExerciseID == entryExerciseID else {
                    throw StoreError.blockConflict("Set block does not reference the logged exercise")
                }
                let sessionRoutineID: String? = row["routineId"]
                guard let sessionRoutineID else {
                    throw StoreError.blockConflict("Cannot log a template block into a routine-less session")
                }
                guard blockRoutineID == sessionRoutineID else {
                    throw StoreError.blockConflict("Set block belongs to a different routine than the session")
                }
            }

            // Determine sequence atomically
            let maxSeq = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence), -1) FROM set_entry WHERE sessionId = ?",
                arguments: [sessionID.rawValue.uuidString.lowercased()]
            ) ?? -1
            let nextSeq = maxSeq + 1

            let entry = SetEntry(
                sessionID: sessionID,
                exerciseID: exerciseID,
                setBlockID: setBlockID,
                sequence: nextSeq,
                completedAt: completedAt,
                repetitions: repetitions,
                load: load,
                side: side,
                asymmetryNote: asymmetryNote
            )
            try entry.validate()

            try db.execute(
                sql: """
                INSERT INTO set_entry (
                    id, sessionId, exerciseId, setBlockId, sequence,
                    completedAt, repetitions, loadThousandths, loadUnit, side, asymmetryNote
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    entry.id.rawValue.uuidString.lowercased(),
                    entry.sessionID.rawValue.uuidString.lowercased(),
                    entry.exerciseID.rawValue.uuidString.lowercased(),
                    entry.setBlockID?.rawValue.uuidString.lowercased(),
                    entry.sequence,
                    entry.completedAt.millisecondsSinceUnixEpoch,
                    entry.repetitions,
                    entry.load?.amountInThousandths,
                    entry.load?.unit.rawValue,
                    entry.side?.rawValue,
                    entry.asymmetryNote,
                ]
            )
            return entry
        }
    }

    func fetchSession(id: SessionID) throws -> Session? {
        try reader.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, routineId, startedAt, completedAt, note FROM session WHERE id = ?",
                arguments: [id.rawValue.uuidString.lowercased()]
            ) else {
                return nil
            }
            guard let uuid = UUID(uuidString: row["id"]) else {
                throw StoreError.recordNotFound("Corrupt session ID")
            }
            let routineID = (row["routineId"] as String?).flatMap { UUID(uuidString: $0).map(RoutineID.init) }
            let completedAt = (row["completedAt"] as Int64?).map { Timestamp(millisecondsSinceUnixEpoch: $0) }
            return Session(
                id: SessionID(rawValue: uuid),
                routineID: routineID,
                startedAt: Timestamp(millisecondsSinceUnixEpoch: row["startedAt"]),
                completedAt: completedAt,
                note: row["note"]
            )
        }
    }

    func fetchEntries(sessionID: SessionID) throws -> [SetEntry] {
        try reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, sessionId, exerciseId, setBlockId, sequence,
                       completedAt, repetitions, loadThousandths, loadUnit, side, asymmetryNote
                FROM set_entry
                WHERE sessionId = ?
                ORDER BY sequence ASC
                """,
                arguments: [sessionID.rawValue.uuidString.lowercased()]
            )
            return try rows.map { row in
                guard let idUUID = UUID(uuidString: row["id"]),
                      let sessionUUID = UUID(uuidString: row["sessionId"]),
                      let exerciseUUID = UUID(uuidString: row["exerciseId"]) else {
                    throw StoreError.recordNotFound("Corrupt entry ID")
                }
                let blockUUID = (row["setBlockId"] as String?).flatMap(UUID.init).map(SetBlockID.init)
                let load: LoadValue?
                if let thousandths: Int64 = row["loadThousandths"],
                   let unitStr: String = row["loadUnit"],
                   let unit = LoadUnit(rawValue: unitStr) {
                    load = LoadValue(amountInThousandths: thousandths, unit: unit)
                } else {
                    load = nil
                }
                let side = (row["side"] as String?).flatMap(UnilateralSide.init(rawValue:))
                return SetEntry(
                    id: SetEntryID(rawValue: idUUID),
                    sessionID: SessionID(rawValue: sessionUUID),
                    exerciseID: ExerciseID(rawValue: exerciseUUID),
                    setBlockID: blockUUID,
                    sequence: row["sequence"],
                    completedAt: Timestamp(millisecondsSinceUnixEpoch: row["completedAt"]),
                    repetitions: row["repetitions"],
                    load: load,
                    side: side,
                    asymmetryNote: row["asymmetryNote"]
                )
            }
        }
    }

    /// Discards only an uncompleted session that has zero logged entries. Completed sessions or sessions with logged sets are retained.
    func discardEmptySession(id: SessionID) throws {
        try writer.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM set_entry WHERE sessionId = ?",
                arguments: [id.rawValue.uuidString.lowercased()]
            ) ?? 0
            guard count == 0 else { throw StoreError.sessionNotEmpty }
            try db.execute(
                sql: "DELETE FROM session WHERE id = ? AND completedAt IS NULL",
                arguments: [id.rawValue.uuidString.lowercased()]
            )
        }
    }
}

// MARK: - Row Mapping Helpers

private extension Exercise {
    init(row: Row) throws {
        guard let uuid = UUID(uuidString: row["id"]) else {
            throw StoreError.recordNotFound("Invalid exercise UUID")
        }
        self.init(
            id: ExerciseID(rawValue: uuid),
            name: row["name"],
            createdAt: Timestamp(millisecondsSinceUnixEpoch: row["createdAt"]),
            updatedAt: Timestamp(millisecondsSinceUnixEpoch: row["updatedAt"])
        )
    }
}
