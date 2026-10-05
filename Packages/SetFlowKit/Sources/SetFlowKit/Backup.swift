import Foundation
import GRDB

/// Portable, user-initiated backup. V1 archives have no timers and set entries
/// without `kind`; V2 includes both. JSON uses sorted keys, integer millisecond
/// timestamps and integer load thousandths, independent of device locale.
public struct BackupArchive: Codable, Equatable, Sendable {
    public let version: Int
    public let exercises: [Exercise]
    public let routines: [Routine]
    public let sessions: [Session]
    public let entries: [SetEntry]
    public let timers: [BackupTimer]?

    public init(version: Int = 2, exercises: [Exercise], routines: [Routine],
                sessions: [Session], entries: [SetEntry], timers: [BackupTimer]? = nil) {
        self.version = version
        self.exercises = exercises
        self.routines = routines
        self.sessions = sessions
        self.entries = entries
        self.timers = timers
    }
}

public struct BackupTimer: Codable, Equatable, Sendable {
    public let sessionID: SessionID
    public let timer: RestTimer
    public let updatedAt: Timestamp

    public init(sessionID: SessionID, timer: RestTimer, updatedAt: Timestamp) {
        self.sessionID = sessionID
        self.timer = timer
        self.updatedAt = updatedAt
    }
}

public enum BackupError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidArchive(String)
    case conflict
    case stalePreview
}

public enum RestoreMode: Equatable, Sendable { case add, replace }

public struct RestorePreview: Equatable, Sendable {
    public let adding: Int
    public let replacing: Int
    public let conflicts: Int
    // The caller must present this preview before applying it. An intervening
    // database edit invalidates the token rather than applying stale consent.
    public let storeFingerprint: Data
    // Bind consent to the validated archive as well as the store.
    public let archiveFingerprint: Data
}

public enum BackupCodec {
    public static func encode(_ archive: BackupArchive) throws -> Data {
        try validate(archive)
        return try DomainCoding.encode(archive)
    }

    public static func decode(_ data: Data) throws -> BackupArchive {
        let archive = try DomainCoding.decode(BackupArchive.self, from: data)
        try validate(archive)
        return archive
    }

    public static func validate(_ archive: BackupArchive) throws {
        guard archive.version == 1 || archive.version == 2 else { throw BackupError.unsupportedVersion }
        guard archive.version != 1 || (archive.timers ?? []).isEmpty else {
            throw BackupError.invalidArchive("V1 cannot contain timers")
        }
        func unique<ID: Hashable>(_ ids: [ID]) -> Bool { Set(ids).count == ids.count }
        guard unique(archive.exercises.map(\.id)), unique(archive.routines.map(\.id)),
              unique(archive.sessions.map(\.id)), unique(archive.entries.map(\.id)),
              unique((archive.timers ?? []).map(\.sessionID)) else {
            throw BackupError.invalidArchive("Duplicate identity")
        }
        let exercises = Dictionary(uniqueKeysWithValues: archive.exercises.map { ($0.id, $0) })
        let routines = Dictionary(uniqueKeysWithValues: archive.routines.map { ($0.id, $0) })
        let sessions = Dictionary(uniqueKeysWithValues: archive.sessions.map { ($0.id, $0) })
        var blockOwners: [SetBlockID: (RoutineID, ExerciseID)] = [:]
        for exercise in archive.exercises { try exercise.validate() }
        for routine in archive.routines {
            try routine.validate()
            for block in routine.blocks {
                guard exercises[block.exercise.id] == block.exercise,
                      blockOwners[block.id] == nil else {
                    throw BackupError.invalidArchive("Conflicting or missing block exercise")
                }
                blockOwners[block.id] = (routine.id, block.exercise.id)
            }
        }
        for session in archive.sessions {
            try session.validate()
            guard session.completedAt == nil || session.abandonedAt == nil,
                  session.routineID == nil || routines[session.routineID!] != nil else {
                throw BackupError.invalidArchive("Invalid session provenance")
            }
        }
        var sequences: [SessionID: Set<Int>] = [:]
        for entry in archive.entries {
            try entry.validate()
            guard let session = sessions[entry.sessionID], exercises[entry.exerciseID] != nil,
                  entry.completedAt >= session.startedAt else {
                throw BackupError.invalidArchive("Orphan or out-of-order entry")
            }
            if let blockID = entry.setBlockID {
                guard let owner = blockOwners[blockID], owner.0 == session.routineID,
                      owner.1 == entry.exerciseID else {
                    throw BackupError.invalidArchive("Invalid block link")
                }
            }
            guard entry.kind != .skipped || (entry.setBlockID != nil && entry.load == nil),
                  sequences[entry.sessionID, default: []].insert(entry.sequence).inserted else {
                throw BackupError.invalidArchive("Invalid entry sequence or skip")
            }
        }
        for (sessionID, numbers) in sequences {
            guard numbers == Set(0..<numbers.count) else {
                throw BackupError.invalidArchive("Non-contiguous sequence for \(sessionID)")
            }
        }
        for timer in archive.timers ?? [] {
            guard sessions[timer.sessionID] != nil else {
                throw BackupError.invalidArchive("Timer without session")
            }
        }
    }
}

public extension SetFlowStore {
    /// Snapshot from one database read, including active rest timer anchors.
    func backup() throws -> Data {
        let archive = try reader.read { db in try Self.backupUnlocked(db) }
        return try BackupCodec.encode(archive)
    }

    func previewRestore(_ data: Data) throws -> RestorePreview {
        let incoming = try BackupCodec.decode(data)
        return try reader.read { db in
            let current = try Self.backupUnlocked(db)
            return try Self.preview(incoming, against: current)
        }
    }

    /// All rows, including reset, are changed in ONE GRDB writer transaction.
    /// The preview is rechecked while holding the writer; failures roll back.
    func restore(_ data: Data, preview: RestorePreview, mode: RestoreMode) throws {
        let incoming = try BackupCodec.decode(data)
        try writer.write { db in
            let current = try Self.backupUnlocked(db)
            let now = try Self.preview(incoming, against: current)
            guard now == preview else { throw BackupError.stalePreview }
            if mode == .add && preview.conflicts > 0 { throw BackupError.conflict }
            if mode == .replace {
                try db.execute(sql: "DELETE FROM rest_timer; DELETE FROM set_entry; DELETE FROM session; DELETE FROM set_block; DELETE FROM routine; DELETE FROM exercise")
            }
            try Self.insert(incoming, into: db)
        }
    }

    /// Explicitly destructive; UI must require a separate confirmation.
    func resetLocalData() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM rest_timer; DELETE FROM set_entry; DELETE FROM session; DELETE FROM set_block; DELETE FROM routine; DELETE FROM exercise")
        }
    }

    /// Separate CSV tables, fixed header and UTF-8 bytes. Every field is CSV
    /// quoted; spreadsheet formula prefixes are escaped to avoid execution.
    func exportCSV() throws -> (sessions: Data, entries: Data) {
        let archive = try reader.read { db in try Self.backupUnlocked(db) }
        func row(_ cells: [String]) -> String {
            cells.map { cell in
                let trimmed = cell.drop(while: { $0.isWhitespace || $0.isNewline })
                let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + cell : cell
                return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",") + "\r\n"
        }
        let sessionHeader = "session_id,routine_id,started_at_ms,completed_at_ms,abandoned_at_ms,note\r\n"
        let entryHeader = "entry_id,session_id,exercise_id,block_id,sequence,kind,completed_at_ms,repetitions,load_thousandths,load_unit,side,asymmetry_note\r\n"
        let sessions = archive.sessions.map { s in row([
            s.id.description, s.routineID?.description ?? "", "\(s.startedAt.millisecondsSinceUnixEpoch)",
            s.completedAt.map { "\($0.millisecondsSinceUnixEpoch)" } ?? "",
            s.abandonedAt.map { "\($0.millisecondsSinceUnixEpoch)" } ?? "", s.note ?? ""
        ]) }.joined()
        let entries = archive.entries.map { e in row([
            e.id.description, e.sessionID.description, e.exerciseID.description, e.setBlockID?.description ?? "",
            "\(e.sequence)", e.kind.rawValue, "\(e.completedAt.millisecondsSinceUnixEpoch)",
            e.repetitions.map(String.init) ?? "", e.load.map { "\($0.amountInThousandths)" } ?? "",
            e.load?.unit.rawValue ?? "", e.side?.rawValue ?? "", e.asymmetryNote ?? ""
        ]) }.joined()
        return (Data((sessionHeader + sessions).utf8), Data((entryHeader + entries).utf8))
    }

    private static func preview(_ incoming: BackupArchive, against current: BackupArchive) throws -> RestorePreview {
        let exerciseIDs = Set(current.exercises.map(\.id))
        let routineIDs = Set(current.routines.map(\.id))
        let sessionIDs = Set(current.sessions.map(\.id))
        let entryIDs = Set(current.entries.map(\.id))
        let timerIDs = Set((current.timers ?? []).map(\.sessionID))
        let exerciseConflicts = incoming.exercises.filter { exerciseIDs.contains($0.id) }.count
        let routineConflicts = incoming.routines.filter { routineIDs.contains($0.id) }.count
        let sessionConflicts = incoming.sessions.filter { sessionIDs.contains($0.id) }.count
        let entryConflicts = incoming.entries.filter { entryIDs.contains($0.id) }.count
        let timerConflicts = (incoming.timers ?? []).filter { timerIDs.contains($0.sessionID) }.count
        let conflicts = exerciseConflicts + routineConflicts + sessionConflicts + entryConflicts + timerConflicts
        let incomingCount = [incoming.exercises.count, incoming.routines.count, incoming.sessions.count,
                             incoming.entries.count, (incoming.timers ?? []).count].reduce(0, +)
        let currentCount = [current.exercises.count, current.routines.count, current.sessions.count,
                            current.entries.count, (current.timers ?? []).count].reduce(0, +)
        return RestorePreview(adding: incomingCount - conflicts, replacing: currentCount, conflicts: conflicts,
                              storeFingerprint: try BackupCodec.encode(current),
                              archiveFingerprint: try BackupCodec.encode(incoming))
    }

    private static func backupUnlocked(_ db: Database) throws -> BackupArchive {
        let exercises = try Row.fetchAll(db, sql: "SELECT id, name, createdAt, updatedAt FROM exercise ORDER BY id").map { row -> Exercise in
            guard let uuid = UUID(uuidString: row["id"]) else { throw BackupError.invalidArchive("Corrupt exercise ID") }
            return Exercise(id: ExerciseID(rawValue: uuid), name: row["name"],
                            createdAt: Timestamp(millisecondsSinceUnixEpoch: row["createdAt"]),
                            updatedAt: Timestamp(millisecondsSinceUnixEpoch: row["updatedAt"]))
        }
        let routineIDs = try String.fetchAll(db, sql: "SELECT id FROM routine ORDER BY id")
        let routines = try routineIDs.map { id -> Routine in
            guard let uuid = UUID(uuidString: id), let routine = try fetchRoutineUnlocked(db, id: RoutineID(rawValue: uuid)) else {
                throw BackupError.invalidArchive("Corrupt routine ID")
            }
            return routine
        }
        let sessionIDs = try String.fetchAll(db, sql: "SELECT id FROM session ORDER BY id")
        var sessions: [Session] = []
        var entries: [SetEntry] = []
        for id in sessionIDs {
            guard let uuid = UUID(uuidString: id), let session = try fetchSessionUnlocked(db, id: SessionID(rawValue: uuid)) else {
                throw BackupError.invalidArchive("Corrupt session ID")
            }
            sessions.append(session)
            entries += try fetchEntriesUnlocked(db, sessionID: session.id)
        }
        let timers = try Row.fetchAll(db, sql: "SELECT * FROM rest_timer ORDER BY sessionId").map { row -> BackupTimer in
            guard let uuid = UUID(uuidString: row["sessionId"]) else { throw BackupError.invalidArchive("Corrupt timer ID") }
            return BackupTimer(sessionID: SessionID(rawValue: uuid),
                               timer: RestTimer(startedAt: (row["startedAt"] as Int64?).map(Timestamp.init(millisecondsSinceUnixEpoch:)),
                                                endsAt: (row["endsAt"] as Int64?).map(Timestamp.init(millisecondsSinceUnixEpoch:)),
                                                duration: row["durationSeconds"],
                                                pausedAt: (row["pausedAt"] as Int64?).map(Timestamp.init(millisecondsSinceUnixEpoch:)),
                                                pausedRemainingMilliseconds: row["pausedRemainingMilliseconds"]),
                               updatedAt: Timestamp(millisecondsSinceUnixEpoch: row["updatedAt"]))
        }
        return BackupArchive(exercises: exercises, routines: routines, sessions: sessions, entries: entries,
                             timers: timers)
    }

    private static func insert(_ archive: BackupArchive, into db: Database) throws {
        for exercise in archive.exercises {
            try db.execute(sql: "INSERT INTO exercise (id,name,createdAt,updatedAt) VALUES (?,?,?,?)",
                           arguments: [exercise.id.description, exercise.name, exercise.createdAt.millisecondsSinceUnixEpoch,
                                       exercise.updatedAt.millisecondsSinceUnixEpoch])
        }
        for routine in archive.routines {
            try db.execute(sql: "INSERT INTO routine (id,name,createdAt,updatedAt) VALUES (?,?,?,?)",
                           arguments: [routine.id.description, routine.name, routine.createdAt.millisecondsSinceUnixEpoch,
                                       routine.updatedAt.millisecondsSinceUnixEpoch])
            for block in routine.blocks {
                try db.execute(sql: "INSERT INTO set_block (id,routineId,exerciseId,position,targetRepetitions,targetLoadThousandths,targetLoadUnit,note) VALUES (?,?,?,?,?,?,?,?)",
                               arguments: [block.id.description, routine.id.description, block.exercise.id.description, block.position,
                                           block.targetRepetitions, block.targetLoad?.amountInThousandths,
                                           block.targetLoad?.unit.rawValue, block.note])
            }
        }
        for session in archive.sessions {
            try db.execute(sql: "INSERT INTO session (id,routineId,startedAt,completedAt,note,abandonedAt) VALUES (?,?,?,?,?,?)",
                           arguments: [session.id.description, session.routineID?.description,
                                       session.startedAt.millisecondsSinceUnixEpoch, session.completedAt?.millisecondsSinceUnixEpoch,
                                       session.note, session.abandonedAt?.millisecondsSinceUnixEpoch])
        }
        for entry in archive.entries {
            try db.execute(sql: "INSERT INTO set_entry (id,sessionId,exerciseId,setBlockId,sequence,completedAt,repetitions,loadThousandths,loadUnit,side,asymmetryNote,kind) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                           arguments: [entry.id.description, entry.sessionID.description, entry.exerciseID.description,
                                       entry.setBlockID?.description, entry.sequence, entry.completedAt.millisecondsSinceUnixEpoch,
                                       entry.repetitions, entry.load?.amountInThousandths, entry.load?.unit.rawValue,
                                       entry.side?.rawValue, entry.asymmetryNote, entry.kind.rawValue])
        }
        for timer in archive.timers ?? [] {
            try db.execute(sql: "INSERT INTO rest_timer (sessionId,phase,startedAt,endsAt,durationSeconds,pausedAt,pausedRemainingMilliseconds,updatedAt) VALUES (?,?,?,?,?,?,?,?)",
                           arguments: [timer.sessionID.description, timer.timer.phase(at: timer.updatedAt).rawValue,
                                       timer.timer.startedAt?.millisecondsSinceUnixEpoch, timer.timer.endsAt?.millisecondsSinceUnixEpoch,
                                       timer.timer.duration, timer.timer.pausedAt?.millisecondsSinceUnixEpoch,
                                       timer.timer.pausedRemainingMilliseconds, timer.updatedAt.millisecondsSinceUnixEpoch])
        }
    }
}
