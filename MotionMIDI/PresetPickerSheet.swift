import SwiftUI
import UniformTypeIdentifiers

/// Preset browser, opened by tapping the preset name in the header.
///
/// Ordered most-recently-used first, so whatever you were just playing sits
/// at the top. Tapping a row switches immediately and closes — during a se t
/// that should be one tap, not a tap plus a confirm.
struct PresetPickerSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var newPresetName = ""
    @State private var showNewPrompt = false

    @State private var renameTarget: Preset?
    @State private var renameText = ""

    /// Export is driven off a prepared document rather than off the preset
    /// id, so the flattening happens once when the row is swiped and the
    /// exporter writes exactly what was prepared.
    @State private var exportDocument: PresetDocument?
    @State private var exportName = "Preset"
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.presetsByRecency) { preset in
                        row(for: preset)
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("Presets · \(app.presets.count)")
                }

                Section {
                    Button {
                        newPresetName = app.preset.name
                        showNewPrompt = true
                    } label: {
                        Label("Save As New Preset", systemImage: "plus.square.on.square")
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Preset…", systemImage: "square.and.arrow.down")
                    }
                }
                .tint(Theme.accent)
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Save As New Preset", isPresented: $showNewPrompt) {
                TextField("Name", text: $newPresetName)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    app.duplicateActivePreset(named: newPresetName)
                    dismiss()
                }
            } message: {
                Text("Saves a copy of the current preset with a new name.")
            }
            .alert("Rename Preset", isPresented: renameBinding) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    if let target = renameTarget {
                        app.renamePreset(target.id, to: renameText)
                    }
                    renameTarget = nil
                }
            }
            .fileExporter(isPresented: exportBinding,
                          document: exportDocument,
                          contentType: .motionMIDIPreset,
                          defaultFilename: exportName) { result in
                if case .failure(let error) = result {
                    importError = error.localizedDescription
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.motionMIDIPreset, .json],
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .alert("Import Failed",
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Import

    /// Reads each chosen file and adds it to the library.
    ///
    /// One bad file does not abandon the rest — a multi-select of six presets
    /// where the fourth is something else should import five and say so,
    /// rather than stopping at three.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription

        case .success(let urls):
            var failures: [String] = []
            var lastImported: UUID?

            for url in urls {
                // Files chosen from outside the app's own container are
                // security-scoped; reading without this returns nothing and
                // looks exactly like an empty file.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                do {
                    let data = try Data(contentsOf: url)
                    let incoming = try JSONDecoder().decode(Preset.self, from: data)
                    lastImported = app.importPreset(incoming)
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }

            if !failures.isEmpty {
                importError = failures.count == 1
                    ? "\(failures[0]) isn't a Motion MIDI preset."
                    : "\(failures.count) files weren't Motion MIDI presets."
            }

            // Only close when something actually landed, so a failed import
            // leaves the sheet open with the error on top of the list it
            // failed to add to.
            if lastImported != nil && failures.isEmpty {
                dismiss()
            }
        }
    }

    private var exportBinding: Binding<Bool> {
        Binding(
            get: { exportDocument != nil },
            set: { if !$0 { exportDocument = nil } }
        )
    }

    // MARK: - Row

    private func row(for preset: Preset) -> some View {
        let isActive = preset.id == app.activePresetID

        return Button {
            app.activatePreset(preset.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .foregroundColor(.primary)
                    Text(subtitle(for: preset, isActive: isActive))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundColor(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                renameText = preset.name
                renameTarget = preset
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Theme.accent)

            Button {
                exportName = preset.exportFilename
                exportDocument = app.exportDocument(for: preset.id)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .tint(Theme.dim)
        }
    }

    private func subtitle(for preset: Preset, isActive: Bool) -> String {
        if isActive { return "Playing now" }
        return preset.lastUsed.formatted(.relative(presentation: .named))
    }

    // MARK: - Delete

    /// The visible list is sorted by recency, so an offset from the ForEach
    /// indexes THAT order — never the underlying array. Resolve to ids first.
    private func delete(at offsets: IndexSet) {
        let ordered = app.presetsByRecency
        let ids = offsets.compactMap { ordered.indices.contains($0) ? ordered[$0].id : nil }
        for id in ids {
            app.deletePreset(id)
        }
    }

    /// Presenting the rename alert off an optional target keeps the row it
    /// belongs to unambiguous, even after the list reorders.
    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }
}
