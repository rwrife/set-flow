import SetFlowKit
import SwiftUI

struct BootstrapHomeView: View {
    @State private var store: SetFlowStore?
    @State private var routines: [Routine] = []
    @State private var activeSession: Session?
    @State private var editingRoutine: Routine?
    @State private var showEditor = false
    @State private var showRunner = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if let activeSession {
                    Section("In progress") {
                        Button("Resume session") {
                            self.activeSession = activeSession
                            showRunner = true
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("session.resume")
                    }
                }
                Section("Routines") {
                    ForEach(routines, id: \.id) { routine in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(routine.name).font(.headline)
                            Text("\(routine.blocks.count) set blocks")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Edit") {
                                    editingRoutine = routine
                                    showEditor = true
                                }
                                .accessibilityIdentifier("routine.edit")
                                Spacer()
                                Button("Start") { start(routine) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(activeSession != nil)
                                    .accessibilityIdentifier("routine.start")
                            }
                            .controlSize(.large)
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 8)
                    }
                }
                Section {
                    Button("Create routine") {
                        editingRoutine = nil
                        showEditor = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("routine.create")
                }
            }
            .navigationTitle("Set Flow")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Data & Privacy") { showSettings = true }
                        .accessibilityIdentifier("settings.open")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("History") { showHistory = true }
                        .accessibilityIdentifier("history.open")
                }
            }
            .navigationDestination(isPresented: $showHistory) {
                if let store {
                    HistoryView(store: store)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                if let store {
                    DataSettingsView(store: store) { reload() }
                }
            }
            .sheet(isPresented: $showEditor) {
                if let store {
                    RoutineEditorView(store: store, initial: editingRoutine) {
                        showEditor = false
                        reload()
                    }
                }
            }
            .navigationDestination(isPresented: $showRunner) {
                if let store, let activeSession {
                    SessionRunnerView(store: store, sessionID: activeSession.id) {
                        showRunner = false
                        reload()
                    }
                }
            }
            .onAppear(perform: reload)
            .onChange(of: showRunner) { _, value in if !value { reload() } }
            .alert("Could not save workout", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
        .accessibilityIdentifier("bootstrap.home")
    }

    private func reload() {
        do {
            if store == nil {
                let uiTesting = CommandLine.arguments.contains("-ui-testing")
                let directory: URL
                if uiTesting {
                    directory = FileManager.default.temporaryDirectory
                } else {
                    directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let databaseURL = directory.appendingPathComponent("set-flow.sqlite")
                if uiTesting {
                    // Deterministic cold start for UI journeys: each launch
                    // process begins with an empty store.
                    for suffix in ["", "-wal", "-shm"] {
                        try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
                    }
                }
                store = try SetFlowStore.makeOnDisk(at: databaseURL.path)
            }
            guard let store else { return }
            routines = try store.fetchRoutines()
            activeSession = try store.fetchActiveSessions().first
        } catch { errorText = error.localizedDescription }
    }

    private func start(_ routine: Routine) {
        guard let store else { return }
        do {
            activeSession = try store.startSession(routineID: routine.id)
            showRunner = true
        } catch { errorText = error.localizedDescription }
    }
}

private struct DraftBlock: Identifiable {
    let id: SetBlockID
    let exerciseID: ExerciseID
    let createdAt: Timestamp
    var name: String
    var sets: Int
    var targetReps: String

    init(block: SetBlock) {
        id = block.id
        exerciseID = block.exercise.id
        createdAt = block.exercise.createdAt
        name = block.exercise.name
        sets = block.targetRepetitions ?? 1
        targetReps = block.note ?? ""
    }

    init() {
        id = SetBlockID()
        exerciseID = ExerciseID()
        createdAt = Timestamp(date: Date())
        name = ""
        sets = 1
        targetReps = ""
    }
}

private struct RoutineEditorView: View {
    let store: SetFlowStore
    let initial: Routine?
    let onSave: @MainActor @Sendable () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var blocks: [DraftBlock]
    @State private var errorText: String?
    @FocusState private var keyboardFocused: Bool

    init(store: SetFlowStore, initial: Routine?, onSave: @escaping @MainActor @Sendable () -> Void) {
        self.store = store
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _blocks = State(initialValue: initial?.blocks.sorted { $0.position < $1.position }.map(DraftBlock.init) ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine") {
                    TextField("Routine name", text: $name)
                        .focused($keyboardFocused)
                        .onSubmit { keyboardFocused = false }
                        .accessibilityIdentifier("routine.name")
                }
                Section {
                    ForEach($blocks) { $block in
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Exercise name", text: $block.name)
                                .focused($keyboardFocused)
                                .onSubmit { keyboardFocused = false }
                                .accessibilityIdentifier("block.name")
                            Stepper("Sets: \(block.sets)", value: $block.sets, in: 1...20)
                                .accessibilityIdentifier("block.sets")
                            TextField("Target reps per set (optional)", text: $block.targetReps)
                                .keyboardType(.numberPad)
                                .focused($keyboardFocused)
                                .accessibilityIdentifier("block.target")
                        }
                        .padding(.vertical, 8)
                    }
                    .onMove { blocks.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { blocks.remove(atOffsets: $0) }
                } header: {
                    Text("Set blocks in workout order")
                } footer: {
                    Text("Use Edit to reorder. Each block contains one or more sets; enter actual reps during the session.")
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).accessibilityIdentifier("routine.error")
                }
            }
            .navigationTitle(initial == nil ? "New routine" : "Edit routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        keyboardFocused = false
                        save()
                    }
                    .accessibilityIdentifier("routine.save")
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button("Add exercise") {
                            keyboardFocused = false
                            blocks.append(DraftBlock())
                        }
                        .accessibilityIdentifier("block.add")
                        Spacer()
                        EditButton()
                    }
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !blocks.isEmpty,
              blocks.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  ($0.targetReps.isEmpty || (Int($0.targetReps) ?? 0) > 0) }) else {
            errorText = "Add routine name and exercise. Target reps must be positive whole numbers."
            return
        }
        do {
            let now = Timestamp(date: Date())
            let setBlocks = blocks.enumerated().map { index, draft in
                SetBlock(
                    id: draft.id,
                    exercise: Exercise(id: draft.exerciseID,
                                       name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                       createdAt: draft.createdAt, updatedAt: now),
                    position: index,
                    targetRepetitions: draft.sets,
                    note: draft.targetReps.isEmpty ? nil : draft.targetReps
                )
            }
            let routine = Routine(id: initial?.id ?? RoutineID(), name: trimmedName,
                                  blocks: setBlocks, createdAt: initial?.createdAt ?? now, updatedAt: now)
            for block in setBlocks { try store.saveExercise(block.exercise) }
            try store.saveRoutine(routine)
            onSave()
        } catch { errorText = error.localizedDescription }
    }
}

/// iPhone Duo design seam: timer and primary controls stay outside scrollable
/// detail. Future dual-screen APIs may place `detail` on another pane without
/// moving timer ownership or session state; no fold API or iPad target today.
private struct SessionWorkspaceLayout<Controls: View, Detail: View>: View {
    let controls: Controls
    let detail: Detail

    init(@ViewBuilder controls: () -> Controls, @ViewBuilder detail: () -> Detail) {
        self.controls = controls()
        self.detail = detail()
    }

    var body: some View {
        VStack(spacing: 8) {
            controls
            ScrollView {
                detail.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("session.detail")
        }
    }
}

private struct SessionRunnerView: View {
    let store: SetFlowStore
    let sessionID: SessionID
    let onFinish: @MainActor @Sendable () -> Void
    @State private var routine: Routine?
    @State private var snapshot: SessionQueueSnapshot?
    @State private var entries: [SetEntry] = []
    @State private var timer = RestTimer.idle
    @State private var resultReps = ""
    @State private var errorText: String?
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        SessionWorkspaceLayout {
            VStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let time = Timestamp(date: context.date)
                    let seconds = (timer.remainingMilliseconds(at: time) + 999) / 1_000
                    Text("Rest: \(seconds) seconds")
                        .font(.title.bold().monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .accessibilityIdentifier("session.timer")
                        .accessibilityLabel("Rest timer")
                        .accessibilityValue("\(timer.phase(at: time).rawValue), \(seconds) seconds remaining")
                }
                HStack {
                    Button(timer.phase(at: Timestamp(date: Date())) == .paused ? "Resume rest" : "Pause rest") {
                        changeTimer { clock in
                            let now = Timestamp(date: Date())
                            if clock.phase(at: now) == .paused {
                                clock.resume(at: now)
                            } else {
                                clock.pause(at: now)
                            }
                        }
                    }
                    .disabled(timer.phase(at: Timestamp(date: Date())) != .running &&
                              timer.phase(at: Timestamp(date: Date())) != .paused)
                    .accessibilityIdentifier("session.pause")
                    Spacer()
                    Button("Skip rest") { changeTimer { $0.cancel() } }
                        .disabled(timer.isIdle)
                        .accessibilityIdentifier("session.skipRest")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Log set") { logSet(kind: .completed) }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(snapshot?.current == nil)
                    .accessibilityIdentifier("session.log")
            }
            .padding(.horizontal)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                if let snapshot, let current = snapshot.current, let plan = current.planned {
                    Text("Set \(snapshot.completedCount + snapshot.skippedCount + 1) of \(snapshot.plannedCount)")
                        .font(.headline)
                    Text(exerciseName(plan.exerciseID)).font(.largeTitle.bold())
                        .accessibilityIdentifier("session.current")
                    Text("Target: \(target(plan))")
                        .font(.title3)
                        .accessibilityIdentifier("session.target")
                    TextField("Actual repetitions", text: $resultReps)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .focused($keyboardFocused)
                        .accessibilityIdentifier("session.reps")
                    if let next = snapshot.nextPreview?.planned {
                        Text("Next: \(exerciseName(next.exerciseID)), \(target(next))")
                            .accessibilityIdentifier("session.next")
                    } else {
                        Text("Next: finish session").accessibilityIdentifier("session.next")
                    }
                    Button("Skip set") { logSet(kind: .skipped) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("session.skipSet")
                } else if snapshot != nil {
                    Text("All sets logged").font(.title.bold())
                        .accessibilityIdentifier("session.done")
                    Button("Finish session") { finish() }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("session.finish")
                } else {
                    ProgressView("Loading session…")
                }
                if let last = entries.last {
                    Text(last.kind == .skipped ? "Last result: skipped" : "Last result: \(last.repetitions.map { "\($0)" } ?? "no reps") reps")
                        .accessibilityIdentifier("session.result")
                    Button("Undo last set") { undo() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("session.undo")
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).accessibilityIdentifier("session.error")
                }
            }
            .padding()
        }
        .navigationTitle("Session")
        .task { reload() }
    }

    private func exerciseName(_ id: ExerciseID) -> String {
        routine?.blocks.first(where: { $0.exercise.id == id })?.exercise.name ?? "Exercise"
    }

    private func target(_ slot: PlannedSet) -> String {
        routine?.blocks.first(where: { $0.id == slot.setBlockID })?.note.map { "\($0) reps" }
            ?? "reps as able"
    }

    @MainActor
    private func reload() {
        do {
            guard let session = try store.fetchSession(id: sessionID) else {
                throw StoreError.recordNotFound("Session not found")
            }
            routine = try session.routineID.flatMap { try store.fetchRoutine(id: $0) }
            snapshot = try store.queueSnapshot(sessionID: sessionID)
            entries = try store.fetchEntries(sessionID: sessionID)
            timer = try store.restTimer(for: sessionID)
            if let plan = snapshot?.current?.planned {
                resultReps = routine?.blocks.first(where: { $0.id == plan.setBlockID })?.note ?? ""
            } else {
                resultReps = ""
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func logSet(kind: SetEntryKind) {
        guard let action = snapshot?.nextAction else { return }
        let repetitions = Int(resultReps)
        guard kind == .skipped || (repetitions ?? 0) > 0 else {
            errorText = "Enter positive whole-number repetitions before logging."
            return
        }
        keyboardFocused = false
        do {
            let now = Timestamp(date: Date())
            try store.logSetEntry(sessionID: sessionID, exerciseID: action.exerciseID,
                                  setBlockID: action.targetBlockID, completedAt: now,
                                  repetitions: kind == .skipped ? nil : repetitions,
                                  load: kind == .skipped ? nil : action.planned.plannedLoad,
                                  kind: kind)
            let remaining = try store.queueSnapshot(sessionID: sessionID)
            var updated = try store.restTimer(for: sessionID)
            if remaining.current != nil {
                updated.start(duration: 60, at: now)
            } else {
                updated.cancel()
            }
            try store.saveRestTimer(updated, for: sessionID, updatedAt: now)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func changeTimer(_ change: (inout RestTimer) -> Void) {
        do {
            var updated = try store.restTimer(for: sessionID)
            change(&updated)
            try store.saveRestTimer(updated, for: sessionID, updatedAt: Timestamp(date: Date()))
            timer = updated
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func undo() {
        keyboardFocused = false
        do {
            try store.undoLastSetEntry(sessionID: sessionID)
            changeTimer { $0.cancel() }
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func finish() {
        guard snapshot?.pendingCount == 0 else { return }
        do {
            try store.completeSession(id: sessionID)
            onFinish()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
