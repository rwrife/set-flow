import Foundation
import SetFlowKit
import SwiftUI
import UniformTypeIdentifiers

private struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    let data: Data

    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Files move only through the system document picker after a deliberate tap.
/// Preview does not write; add/replace and reset require separate confirmation.
struct DataSettingsView: View {
    let store: SetFlowStore
    let onChange: @MainActor @Sendable () -> Void
    @State private var exportDocument: ExportDocument?
    @State private var exportName = ""
    @State private var exportType: UTType = .json
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var incoming: Data?
    @State private var preview: RestorePreview?
    @State private var showingReplace = false
    @State private var showingReset = false
    @State private var errorText: String?
    @State private var notice: String?

    var body: some View {
        Form {
            Section("Your data") {
                Text("Workouts stay on this iPhone in app storage. No account, cloud sync, or network connection is required. You choose when to share a backup or CSV file; exported files can be read by anyone you share them with.")
                Text("The rest timer runs in the app. Notification permission is not requested by this version; no location, contacts, camera, microphone or health access is used.")
                Text("Set Flow logs everyday training, not diagnoses, treatments or medical advice.")
            }
            Section("Export") {
                Button("Save JSON backup") { prepareExport(.backup) }
                    .accessibilityIdentifier("settings.backup")
                Button("Save sessions CSV") { prepareExport(.sessions) }
                    .accessibilityIdentifier("settings.sessionsCSV")
                Button("Save sets CSV") { prepareExport(.entries) }
                    .accessibilityIdentifier("settings.entriesCSV")
                Text("CSV dates use Unix milliseconds. Loads use integer thousandths plus an explicit kilograms/pounds unit. Blank means not recorded; skipped sets retain their kind.")
                    .font(.footnote)
            }
            Section("Restore") {
                Button("Choose JSON backup") {
                    incoming = nil
                    preview = nil
                    showingImporter = true
                }
                    .accessibilityIdentifier("settings.import")
                if let preview {
                    Text("Preview: \(preview.adding) new rows, \(preview.replacing) existing rows replaced if you choose Replace, \(preview.conflicts) matching IDs. Nothing has changed yet.")
                        .accessibilityIdentifier("settings.preview")
                    Button("Add new rows") { apply(.add) }
                        .disabled(preview.conflicts > 0)
                        .accessibilityIdentifier("settings.add")
                    Button("Replace all local workouts…", role: .destructive) { showingReplace = true }
                        .accessibilityIdentifier("settings.replace")
                }
            }
            Section("Delete") {
                Text("Reset removes all local exercises, routines, sessions, sets and timer state. This cannot be undone without a separate backup.")
                Button("Delete all local data…", role: .destructive) { showingReset = true }
                    .accessibilityIdentifier("settings.reset")
            }
            if let notice { Text(notice).accessibilityIdentifier("settings.notice") }
            if let errorText { Text(errorText).foregroundStyle(.red).accessibilityIdentifier("settings.error") }
        }
        .navigationTitle("Data & Privacy")
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { errorText = error.localizedDescription }
            exportDocument = nil
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let next = try store.previewRestore(data)
                incoming = data
                preview = next
                errorText = nil
                notice = nil
            } catch {
                incoming = nil
                preview = nil
                errorText = error.localizedDescription
            }
        }
        .confirmationDialog("Replace every local workout with this backup?", isPresented: $showingReplace,
                            titleVisibility: .visible) {
            Button("Replace all workouts", role: .destructive) { apply(.replace) }
        } message: { Text("Current local data will be deleted. This cannot be undone without another backup.") }
        .confirmationDialog("Delete all workouts from this iPhone?", isPresented: $showingReset,
                            titleVisibility: .visible) {
            Button("Delete all workouts", role: .destructive) {
                do {
                    try store.resetLocalData()
                    incoming = nil
                    preview = nil
                    onChange()
                    notice = "Local workout data deleted."
                } catch { errorText = error.localizedDescription }
            }
        } message: { Text("This cannot be undone without a backup.") }
    }

    private enum ExportKind { case backup, sessions, entries }
    private func prepareExport(_ kind: ExportKind) {
        do {
            switch kind {
            case .backup:
                exportDocument = ExportDocument(try store.backup())
                exportName = "set-flow-backup"
                exportType = .json
            case .sessions:
                exportDocument = ExportDocument(try store.exportCSV().sessions)
                exportName = "set-flow-sessions"
                exportType = .commaSeparatedText
            case .entries:
                exportDocument = ExportDocument(try store.exportCSV().entries)
                exportName = "set-flow-sets"
                exportType = .commaSeparatedText
            }
            showingExporter = true
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    private func apply(_ mode: RestoreMode) {
        guard let incoming, let preview else { return }
        do {
            try store.restore(incoming, preview: preview, mode: mode)
            self.incoming = nil
            self.preview = nil
            onChange()
            notice = "Backup restored on this iPhone."
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }
}
