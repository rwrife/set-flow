import Foundation
import GRDB

// MARK: - History window and durable week summaries (issue #5)

/// One session with its full append-only entry stream, newest sessions first.
public struct HistorySession: Sendable, Equatable {
    public let session: Session
    public let entries: [SetEntry]

    public init(session: Session, entries: [SetEntry]) {
        self.session = session
        self.entries = entries
    }
}

public extension SetFlowStore {
    /// Sessions with their entries for history browsing. Completed, abandoned,
    /// and active sessions are all included — history reports what happened,
    /// including unfinished attempts, and never rewrites them.
    func historySessions() throws -> [HistorySession] {
        try reader.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM session ORDER BY startedAt DESC")
            var history: [HistorySession] = []
            history.reserveCapacity(ids.count)
            for idString in ids {
                guard let uuid = UUID(uuidString: idString) else {
                    throw StoreError.recordNotFound("Corrupt session ID")
                }
                let id = SessionID(rawValue: uuid)
                guard let session = try Self.fetchSessionUnlocked(db, id: id) else { continue }
                let entries = try Self.fetchEntriesUnlocked(db, sessionID: id)
                history.append(HistorySession(session: session, entries: entries))
            }
            return history
        }
    }

    /// Week summaries derived from the ENTIRE durable history.
    ///
    /// `calendar`'s time zone defines week grouping (timezone/DST safe — see
    /// `HistoryDerivation`). Planned-slot attribution reuses the same
    /// deterministic queue engine the runner uses, so summaries and the
    /// runner can never disagree about which sets were planned, skipped, or
    /// ad-hoc. A session whose stored events cannot reconstruct a snapshot
    /// contributes its entries as ad-hoc rather than poisoning the summary.
    func weekSummaries(calendar: Calendar) throws -> [WeekSummary] {
        let history = try historySessions()
        let names = try exerciseNames()

        var weekKeys = Set<CalendarWeekKey>()
        var allEntries: [SetEntry] = []
        var plannedStatusByEntryID: [SetEntryID: SetSlotStatus] = [:]

        for item in history {
            weekKeys.insert(CalendarWeekKey(instant: item.session.startedAt, calendar: calendar))
            for entry in item.entries {
                allEntries.append(entry)
                weekKeys.insert(CalendarWeekKey(instant: entry.completedAt, calendar: calendar))
            }
            if item.session.routineID != nil,
               let snapshot = try? queueSnapshot(sessionID: item.session.id) {
                for slot in snapshot.slots where slot.planned != nil {
                    if let entry = slot.entry {
                        plannedStatusByEntryID[entry.id] = slot.status
                    }
                }
            }
        }

        return HistoryDerivation.weekSummaries(
            sessions: history.map(\.session),
            entries: allEntries,
            plannedStatusByEntryID: plannedStatusByEntryID,
            exerciseNames: names,
            weekKeys: weekKeys,
            calendar: calendar
        )
    }

    private func exerciseNames() throws -> [ExerciseID: String] {
        let exercises = try fetchExercises()
        return Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
