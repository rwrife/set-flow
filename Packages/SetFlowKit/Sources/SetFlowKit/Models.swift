import Foundation

public protocol SetFlowIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension SetFlowIdentifier {
    init() { self.init(rawValue: UUID()) }
    var description: String { rawValue.uuidString.lowercased() }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a UUID string")
            )
        }
        self.init(rawValue: uuid)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

public struct RoutineID: SetFlowIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct ExerciseID: SetFlowIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct SetBlockID: SetFlowIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct SessionID: SetFlowIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct SetEntryID: SetFlowIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }

/// Stable, locale-independent timestamp serialized as integer milliseconds since Unix epoch.
public struct Timestamp: Codable, Hashable, Comparable, Sendable {
    public let millisecondsSinceUnixEpoch: Int64

    public init(millisecondsSinceUnixEpoch: Int64) {
        self.millisecondsSinceUnixEpoch = millisecondsSinceUnixEpoch
    }

    public init(date: Date) {
        millisecondsSinceUnixEpoch = Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.millisecondsSinceUnixEpoch = try container.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(millisecondsSinceUnixEpoch)
    }

    public var date: Date {
        Date(timeIntervalSince1970: Double(millisecondsSinceUnixEpoch) / 1_000)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.millisecondsSinceUnixEpoch < rhs.millisecondsSinceUnixEpoch
    }
}

public enum LoadUnit: String, Codable, CaseIterable, Sendable {
    case kilograms
    case pounds
}

/// A non-negative load represented in thousandths to avoid binary floating-point drift.
public struct LoadValue: Codable, Hashable, Sendable {
    public let amountInThousandths: Int64
    public let unit: LoadUnit

    public init(amountInThousandths: Int64, unit: LoadUnit) {
        self.amountInThousandths = amountInThousandths
        self.unit = unit
    }
}

public enum UnilateralSide: String, Codable, CaseIterable, Sendable {
    case bilateral
    case left
    case right
    case unknown
}

/// What a logged set-entry represents in the session event stream.
/// `skipped` entries carry no repetitions and mark a planned slot as
/// intentionally not performed.
public enum SetEntryKind: String, Codable, CaseIterable, Sendable {
    case completed
    case skipped
}

public struct Exercise: Codable, Hashable, Sendable {
    public let id: ExerciseID
    public var name: String
    public var createdAt: Timestamp
    public var updatedAt: Timestamp

    public init(id: ExerciseID = .init(), name: String, createdAt: Timestamp, updatedAt: Timestamp) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SetBlock: Codable, Hashable, Sendable {
    public let id: SetBlockID
    public var exercise: Exercise
    public var position: Int
    public var targetRepetitions: Int?
    public var targetLoad: LoadValue?
    public var note: String?

    public init(
        id: SetBlockID = .init(),
        exercise: Exercise,
        position: Int,
        targetRepetitions: Int? = nil,
        targetLoad: LoadValue? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.exercise = exercise
        self.position = position
        self.targetRepetitions = targetRepetitions
        self.targetLoad = targetLoad
        self.note = note
    }
}

public struct Routine: Codable, Hashable, Sendable {
    public let id: RoutineID
    public var name: String
    public var blocks: [SetBlock]
    public var createdAt: Timestamp
    public var updatedAt: Timestamp

    public init(
        id: RoutineID = .init(),
        name: String,
        blocks: [SetBlock],
        createdAt: Timestamp,
        updatedAt: Timestamp
    ) {
        self.id = id
        self.name = name
        self.blocks = blocks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Session: Codable, Hashable, Sendable {
    public let id: SessionID
    public let routineID: RoutineID?
    public let startedAt: Timestamp
    public var completedAt: Timestamp?
    public var abandonedAt: Timestamp?
    public var note: String?

    public init(
        id: SessionID = .init(),
        routineID: RoutineID?,
        startedAt: Timestamp,
        completedAt: Timestamp? = nil,
        abandonedAt: Timestamp? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.routineID = routineID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.abandonedAt = abandonedAt
        self.note = note
    }
}

public struct SetEntry: Codable, Hashable, Sendable {
    public let id: SetEntryID
    public let sessionID: SessionID
    public let exerciseID: ExerciseID
    public let setBlockID: SetBlockID?
    public let sequence: Int
    public let completedAt: Timestamp
    public let repetitions: Int?
    public let load: LoadValue?
    public let side: UnilateralSide?
    public let asymmetryNote: String?
    public let kind: SetEntryKind

    public init(
        id: SetEntryID = .init(),
        sessionID: SessionID,
        exerciseID: ExerciseID,
        setBlockID: SetBlockID? = nil,
        sequence: Int,
        completedAt: Timestamp,
        repetitions: Int? = nil,
        load: LoadValue? = nil,
        side: UnilateralSide? = nil,
        asymmetryNote: String? = nil,
        kind: SetEntryKind = .completed
    ) {
        self.id = id
        self.sessionID = sessionID
        self.exerciseID = exerciseID
        self.setBlockID = setBlockID
        self.sequence = sequence
        self.completedAt = completedAt
        self.repetitions = repetitions
        self.load = load
        self.side = side
        self.asymmetryNote = asymmetryNote
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, exerciseID, setBlockID, sequence, completedAt
        case repetitions, load, side, asymmetryNote, kind
    }

    /// Entries logged before issue #3 carry no `kind`; they decode as
    /// completed so historical backups and store rows stay readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SetEntryID.self, forKey: .id)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        exerciseID = try container.decode(ExerciseID.self, forKey: .exerciseID)
        setBlockID = try container.decodeIfPresent(SetBlockID.self, forKey: .setBlockID)
        sequence = try container.decode(Int.self, forKey: .sequence)
        completedAt = try container.decode(Timestamp.self, forKey: .completedAt)
        repetitions = try container.decodeIfPresent(Int.self, forKey: .repetitions)
        load = try container.decodeIfPresent(LoadValue.self, forKey: .load)
        side = try container.decodeIfPresent(UnilateralSide.self, forKey: .side)
        asymmetryNote = try container.decodeIfPresent(String.self, forKey: .asymmetryNote)
        kind = try container.decodeIfPresent(SetEntryKind.self, forKey: .kind) ?? .completed
    }
}

public enum DomainCoding {
    /// Canonical JSON uses sorted keys; IDs are lowercase UUID strings, timestamps are integer milliseconds,
    /// and load values are integer thousandths with an explicit unit.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public enum SetFlowValidationError: Error, Equatable, Sendable {
    case blankName
    case invalidPosition(Int)
    case duplicatePosition(Int)
    case invalidRepetitions(Int)
    case invalidLoad(Int64)
    case timestampOrder
    case emptyRoutine
    case duplicateIdentifier
    case invalidSequence(expected: Int, actual: Int)
    case sessionAlreadyCompleted
    case sessionAlreadyAbandoned
    case routineIdentityMismatch
    case unmatchableSetEntry(SetEntryID)
    case invalidSkip(String)
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case active
    case completed
    case abandoned
}

public extension Exercise {
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SetFlowValidationError.blankName
        }
        guard createdAt <= updatedAt else { throw SetFlowValidationError.timestampOrder }
    }
}

public extension Routine {
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SetFlowValidationError.blankName
        }
        guard !blocks.isEmpty else { throw SetFlowValidationError.emptyRoutine }
        guard createdAt <= updatedAt else { throw SetFlowValidationError.timestampOrder }

        var positions = Set<Int>()
        var blockIDs = Set<SetBlockID>()
        for block in blocks {
            try block.exercise.validate()
            guard block.position >= 0 else { throw SetFlowValidationError.invalidPosition(block.position) }
            guard positions.insert(block.position).inserted else {
                throw SetFlowValidationError.duplicatePosition(block.position)
            }
            guard blockIDs.insert(block.id).inserted else { throw SetFlowValidationError.duplicateIdentifier }
            if let repetitions = block.targetRepetitions, repetitions <= 0 {
                throw SetFlowValidationError.invalidRepetitions(repetitions)
            }
            if let load = block.targetLoad, load.amountInThousandths < 0 {
                throw SetFlowValidationError.invalidLoad(load.amountInThousandths)
            }
        }
    }
}

public extension Session {
    func validate() throws {
        if let completedAt, completedAt < startedAt { throw SetFlowValidationError.timestampOrder }
        if let abandonedAt, abandonedAt < startedAt { throw SetFlowValidationError.timestampOrder }
    }

    /// Durable session status. Derived state — never stored separately, so a
    /// reopened store can reconstruct it from the same rows deterministically.
    var status: SessionStatus {
        if abandonedAt != nil { return .abandoned }
        if completedAt != nil { return .completed }
        return .active
    }
}

public extension SetEntry {
    func validate() throws {
        guard sequence >= 0 else { throw SetFlowValidationError.invalidSequence(expected: 0, actual: sequence) }
        if let repetitions, repetitions <= 0 { throw SetFlowValidationError.invalidRepetitions(repetitions) }
        if let load, load.amountInThousandths < 0 { throw SetFlowValidationError.invalidLoad(load.amountInThousandths) }
        if kind == .skipped, repetitions != nil {
            throw SetFlowValidationError.invalidSkip("Skipped entries must not carry repetitions")
        }
    }
}
