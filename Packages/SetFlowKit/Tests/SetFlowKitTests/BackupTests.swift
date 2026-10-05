import Foundation
import GRDB
import Testing
@testable import SetFlowKit

private let instant = Timestamp(millisecondsSinceUnixEpoch: 1700000000000)
private func id(_ text: String) -> UUID { UUID(uuidString: text)! }

@Suite("Portable local backup and deletion")
struct BackupTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test("v1 golden file decodes legacy entries; v2 golden file encodes exactly")
    func goldenFiles() throws {
        let v1 = try BackupCodec.decode(fixture("backup-v1"))
        #expect(v1.version == 1)
        #expect(v1.entries[0].kind == .completed)
        let v2 = try BackupCodec.decode(fixture("backup-v2"))
        #expect(v2.version == 2)
        #expect(try BackupCodec.encode(v2) == fixture("backup-v2"))
        let store = try SetFlowStore.makeInMemory()
        let preview = try store.previewRestore(fixture("backup-v1"))
        try store.restore(fixture("backup-v1"), preview: preview, mode: .add)
        #expect(try BackupCodec.decode(store.backup()).entries == v1.entries)
    }

    @Test("backup round trip preserves session, set, and live timer")
    func roundTrip() throws {
        let store = try SetFlowStore.makeInMemory()
        let exercise = Exercise(name: "Row", createdAt: instant, updatedAt: instant)
        let routine = Routine(name: "Circuit", blocks: [SetBlock(exercise: exercise, position: 0)],
                              createdAt: instant, updatedAt: instant)
        try store.saveRoutine(routine)
        let session = try store.startSession(routineID: routine.id, startedAt: instant)
        _ = try store.logSetEntry(sessionID: session.id, exerciseID: exercise.id,
                                  setBlockID: routine.blocks[0].id, completedAt: instant,
                                  repetitions: 8, load: LoadValue(amountInThousandths: 1250, unit: .pounds))
        var timer = RestTimer.idle
        timer.start(duration: 60, at: instant)
        try store.saveRestTimer(timer, for: session.id, updatedAt: instant)
        let data = try store.backup()
        let copy = try SetFlowStore.makeInMemory()
        let preview = try copy.previewRestore(data)
        #expect(preview.adding == 5)
        #expect(preview.conflicts == 0)
        try copy.restore(data, preview: preview, mode: .add)
        #expect(try copy.backup() == data)
        #expect(try copy.restTimer(for: session.id) == timer)
        #expect(try copy.fetchEntries(sessionID: session.id).count == 1)
    }

    @Test("invalid graph and unsupported schema fail before any writes")
    func invalidArchives() throws {
        let store = try SetFlowStore.makeInMemory()
        let data = try fixture("backup-v2")
        let preview = try store.previewRestore(data)
        try store.restore(data, preview: preview, mode: .add)
        let before = try store.backup()
        let orphan = BackupArchive(exercises: [], routines: [],
                                   sessions: [], entries: try BackupCodec.decode(data).entries)
        #expect(throws: BackupError.invalidArchive("Orphan or out-of-order entry")) {
            try BackupCodec.encode(orphan)
        }
        #expect(throws: BackupError.unsupportedVersion) {
            try BackupCodec.encode(BackupArchive(version: 3, exercises: [], routines: [], sessions: [], entries: []))
        }
        #expect(try store.backup() == before)
    }

    @Test("conflicts, stale preview and reset protect existing data")
    func conflictAndReset() throws {
        let store = try SetFlowStore.makeInMemory()
        let data = try fixture("backup-v2")
        try store.restore(data, preview: store.previewRestore(data), mode: .add)
        let current = try store.backup()
        let conflict = try store.previewRestore(data)
        #expect(conflict.conflicts == 4)
        #expect(throws: BackupError.conflict) {
            try store.restore(data, preview: conflict, mode: .add)
        }
        #expect(try store.backup() == current)
        let extra = Exercise(name: "New", createdAt: instant, updatedAt: instant)
        try store.saveExercise(extra)
        #expect(throws: BackupError.stalePreview) {
            try store.restore(data, preview: conflict, mode: .replace)
        }
        #expect(try store.fetchExercise(id: extra.id) != nil)
        try store.restore(data, preview: store.previewRestore(data), mode: .replace)
        #expect(try store.backup() == current)
        try store.resetLocalData()
        #expect(try BackupCodec.decode(store.backup()).sessions.isEmpty)
        #expect(try BackupCodec.decode(store.backup()).exercises.isEmpty)
    }

    @Test("restore requires consent for the same archive, even when record counts match")
    func archivePreviewCannotBeReused() throws {
        let store = try SetFlowStore.makeInMemory()
        let first = try fixture("backup-v2")
        let archive = try BackupCodec.decode(first)
        let altered = BackupArchive(exercises: [Exercise(id: archive.exercises[0].id,
            name: "Different row", createdAt: instant, updatedAt: instant)],
            routines: [], sessions: [], entries: [])
        let second = try BackupCodec.encode(altered)
        let preview = try store.previewRestore(first)
        #expect(throws: BackupError.stalePreview) {
            try store.restore(second, preview: preview, mode: .replace)
        }
        #expect(try BackupCodec.decode(store.backup()).exercises.isEmpty)
    }

    @Test("database insertion failure rolls back replacement, including deletes")
    func rollbackOnDatabaseFailure() throws {
        let store = try SetFlowStore.makeInMemory()
        let data = try fixture("backup-v2")
        try store.restore(data, preview: store.previewRestore(data), mode: .add)
        let before = try store.backup()
        try store.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_restore BEFORE INSERT ON session
                BEGIN SELECT RAISE(FAIL, 'injected insertion failure'); END
                """)
        }
        let preview = try store.previewRestore(data)
        #expect(throws: DatabaseError.self) {
            try store.restore(data, preview: preview, mode: .replace)
        }
        #expect(try store.backup() == before)
    }

    @Test("CSV documents units and escapes formula-like user text")
    func csvSafety() throws {
        let store = try SetFlowStore.makeInMemory()
        let exercise = Exercise(name: "X", createdAt: instant, updatedAt: instant)
        try store.saveExercise(exercise)
        let session = try store.startSession(startedAt: instant, note: "=HYPERLINK(\"x\")")
        _ = try store.logSetEntry(sessionID: session.id, exerciseID: exercise.id,
                                  completedAt: instant, repetitions: 3,
                                  load: LoadValue(amountInThousandths: 1250, unit: .kilograms),
                                  asymmetryNote: "  +SUM(1,2)")
        let csv = try store.exportCSV()
        let sessions = try #require(String(data: csv.sessions, encoding: .utf8))
        let entries = try #require(String(data: csv.entries, encoding: .utf8))
        #expect(sessions.contains("\"'=HYPERLINK(\"\"x\"\")\""))
        #expect(entries.contains("\"'  +SUM(1,2)\""))
        #expect(entries.contains("\"1250\",\"kilograms\""))
        #expect(entries.contains("load_thousandths,load_unit"))
    }
}
