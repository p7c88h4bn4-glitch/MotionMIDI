import SwiftUI

/// Preset browser, opened by tapping the preset name in the header.
///
/// Ordered most-recently-used first, so whatever you were just playing sits
/// at the top. Tapping a row switches immediately and closes — during a set
/// that should be one tap, not a tap plus a confirm.
struct PresetPickerSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var newPresetName = ""
    @State private var showNewPrompt = false

    @State private var renameTarget: Preset?
    @State private var renameText = ""

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
                } footer: {
                    Text(app.presets.count > 1
                         ? "Most recent first. Swipe a row to rename or delete — deleting is permanent."
                         : "Most recent first. Swipe a row to rename. The last remaining preset can't be deleted.")
                }

                Section {
                    Button {
                        newPresetName = ""
                        showNewPrompt = true
                    } label: {
                        Label("New Preset", systemImage: "plus.circle.fill")
                    }

                    Button {
                        app.duplicateActivePreset()
                        dismiss()
                    } label: {
                        Label("Duplicate “\(app.preset.name)”", systemImage: "plus.square.on.square")
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
            .alert("New Preset", isPresented: $showNewPrompt) {
                TextField("Name", text: $newPresetName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    app.createPreset(named: newPresetName)
                    dismiss()
                }
            } message: {
                Text("Starts from the default layout.")
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
        }
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
