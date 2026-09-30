import Foundation

/// A single actionable set slot expanded from a routine template.
/// `sequence` is the slot's 0-based position in the deterministic queue.
public struct PlannedSet: Codable, Hashable, Sendable {
    public let sequence: Int
    public let exerciseID: ExerciseID
    public let setBlockID: SetBlockID?
    public let plannedRepetitions: Int?
    public let plannedLoad: LoadValue?

    public init(
        sequence: Int,
        exerciseID: ExerciseID,
        setBlockID: SetBlockID?,
        plannedRepetitions: Int? = nil,
        plannedLoad: LoadValue? = nil
    ) {
        self.sequence = sequence
        self.exerciseID = exerciseID
        self.setBlockID = setBlockID
        self.plannedRepetitions = plannedRepetitions
        self.plannedLoad = plannedLoad
    }
}

public enum SetSlotStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case completed
    case skipped
}

/// One resolved (or still-pending) position in the session queue.
/// Ad-hoc slots (`planned == nil`) carry logged entries that do not map
/// onto the routine template, e.g. free-session logging.
public struct SetSlotState: Equatable, Sendable {
    public let planned: PlannedSet?
    public let entry: SetEntry?
    public let status: SetSlotStatus

    public init(planned: PlannedSet?, entry: SetEntry?, status: SetSlotStatus) {
        self.planned = planned
        self.entry = entry
        self.status = status
    }

    public var sequence: Int { entry?.sequence ?? planned?.sequence ?? -1 }
}

public enum QueuePhase: String, Codable, CaseIterable, Sendable {
    /// Session active with no logged events yet.
    case notStarted
    /// Active with at least one unresolved planned slot (or a free session with activity).
    case running
    /// Every planned slot is resolved; the runner may offer only ad-hoc logging.
    case finished
    /// Session durably completed.
    case sessionCompleted
    /// Session durably abandoned.
    case abandoned
}

/// Deterministic snapshot of the runner state, derived purely from
/// `(routine, session, entries)`. Rebuilding from the same inputs always
/// produces an identical snapshot — including after app relaunch.
public struct SessionQueueSnapshot: Equatable, Sendable {
    public let slots: [SetSlotState]
    public let phase: QueuePhase
    public let nextSequence: Int
    public let completedCount: Int
    public let skippedCount: Int
    public let pendingCount: Int
    public let plannedCount: Int
    public let adHocCompletedCount: Int

    public init(
        slots: [SetSlotState],
        phase: QueuePhase,
        nextSequence: Int,
        completedCount: Int,
        skippedCount: Int,
        pendingCount: Int,
        plannedCount: Int,
        adHocCompletedCount: Int
    ) {
        self.slots = slots
        self.phase = phase
        self.nextSequence = nextSequence
        self.completedCount = completedCount
        self.skippedCount = skippedCount
        self.pendingCount = pendingCount
        self.adHocCompletedCount = adHocCompletedCount
        self.plannedCount = plannedCount
    }

    /// The current actionable slot: the first still-pending planned slot.
    public var current: SetSlotState? {
        slots.first { $0.planned != nil && $0.status == .pending }
    }

    /// The pending slot immediately after `current`, or nil at queue end.
    public var nextPreview: SetSlotState? {
        guard let current else { return nil }
        return slots.first { $0.planned != nil && $0.status == .pending && $0.sequence > current.sequence }
    }

    /// The runner's next logging action, derived from `current`.
    public var nextAction: QueueAction? {
        guard let current, let planned = current.planned else { return nil }
        return QueueAction(targetBlockID: planned.setBlockID, exerciseID: planned.exerciseID, planned: planned)
    }
}

/// The concrete append the runner must make to resolve the current slot.
public struct QueueAction: Equatable, Sendable {
    public let targetBlockID: SetBlockID?
    public let exerciseID: ExerciseID
    public let planned: PlannedSet

    public init(targetBlockID: SetBlockID?, exerciseID: ExerciseID, planned: PlannedSet) {
        self.targetBlockID = targetBlockID
        self.exerciseID = exerciseID
        self.planned = planned
    }
}

/// Pure, event-sourced queue engine: the queue is a function of the routine
/// template and the session's append-only event stream. No hidden counters.
public enum SessionQueue {
    /// Expands a routine into its ordered actionable slots. A block with no
    /// explicit repetition target contributes exactly one slot.
    public static func plannedQueue(for routine: Routine?) -> [PlannedSet] {
        guard let routine else { return [] }
        var slots: [PlannedSet] = []
        for block in routine.blocks.sorted(by: { $0.position < $1.position }) {
            let repetitions = block.targetRepetitions ?? 1
            for _ in 0..<max(1, repetitions) {
                slots.append(
                    PlannedSet(
                        sequence: slots.count,
                        exerciseID: block.exercise.id,
                        setBlockID: block.id,
                        plannedRepetitions: block.targetRepetitions,
                        plannedLoad: block.targetLoad
                    )
                )
            }
        }
        return slots
    }

    /// Reconstructs the queue from durable state. Entries must form a dense
    /// 0-based sequence in append order; block-bearing entries must match the
    /// next unresolved slot for that block, otherwise the snapshot is rejected
    /// rather than silently reinterpreted.
    public static func snapshot(
        routine: Routine?,
        session: Session,
        entries: [SetEntry]
    ) throws -> SessionQueueSnapshot {
        if session.routineID == nil, routine != nil {
            throw SetFlowValidationError.routineIdentityMismatch
        }
        if let routine, let routineID = session.routineID, routine.id != routineID {
            throw SetFlowValidationError.routineIdentityMismatch
        }

        let planned = plannedQueue(for: routine)
        let sorted = entries.sorted { $0.sequence < $1.sequence }

        for (index, entry) in sorted.enumerated() {
            guard entry.sequence == index else {
                throw SetFlowValidationError.invalidSequence(expected: index, actual: entry.sequence)
            }
        }

        // FIFO matchers per block so repeated slots of one block resolve in plan order.
        var pendingByBlock: [SetBlockID: [Int]] = [:]
        for (index, slot) in planned.enumerated() {
            if let blockID = slot.setBlockID {
                pendingByBlock[blockID, default: []].append(index)
            }
        }

        var statuses = [SetSlotStatus](repeating: .pending, count: planned.count)
        var entryByPlannedIndex = [Int: SetEntry](minimumCapacity: sorted.count)
        var adHocEntries: [SetEntry] = []

        for entry in sorted {
            guard let blockID = entry.setBlockID else {
                if entry.kind == .skipped {
                    throw SetFlowValidationError.invalidSkip("A skipped set must reference a planned block slot")
                }
                adHocEntries.append(entry)
                continue
            }
            guard var pending = pendingByBlock[blockID], !pending.isEmpty else {
                throw SetFlowValidationError.unmatchableSetEntry(entry.id)
            }
            let slotIndex = pending.removeFirst()
            guard planned[slotIndex].exerciseID == entry.exerciseID else {
                throw SetFlowValidationError.unmatchableSetEntry(entry.id)
            }
            pendingByBlock[blockID] = pending
            statuses[slotIndex] = entry.kind == .skipped ? .skipped : .completed
            entryByPlannedIndex[slotIndex] = entry
        }

        var slots: [SetSlotState] = []
        slots.reserveCapacity(planned.count + adHocEntries.count)
        for (index, plannedSlot) in planned.enumerated() {
            let status = statuses[index]
            slots.append(
                SetSlotState(
                    planned: plannedSlot,
                    entry: status == .pending ? nil : entryByPlannedIndex[index],
                    status: status
                )
            )
        }
        for entry in adHocEntries {
            slots.append(SetSlotState(planned: nil, entry: entry, status: .completed))
        }

        let completedCount = statuses.filter { $0 == .completed }.count
        let skippedCount = statuses.filter { $0 == .skipped }.count
        let pendingCount = statuses.filter { $0 == .pending }.count

        let phase: QueuePhase
        if session.abandonedAt != nil {
            phase = .abandoned
        } else if session.completedAt != nil {
            phase = .sessionCompleted
        } else if entries.isEmpty {
            phase = .notStarted
        } else if planned.isEmpty {
            // Free (routine-less) sessions always accept more ad-hoc logging.
            phase = .running
        } else if pendingCount == 0 {
            phase = .finished
        } else {
            phase = .running
        }

        return SessionQueueSnapshot(
            slots: slots,
            phase: phase,
            nextSequence: sorted.count,
            completedCount: completedCount,
            skippedCount: skippedCount,
            pendingCount: pendingCount,
            plannedCount: planned.count,
            adHocCompletedCount: adHocEntries.count
        )
    }
}
