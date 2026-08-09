import SwiftUI

/// Bottom third: collapsible editor. Fully hidden during performance.
struct EditorView: View {
    @EnvironmentObject var app: AppState
    @State private var page: Page = .mappings

    enum Page: String, CaseIterable, Identifiable {
        case mappings = "Mappings"
        case buttons = "Buttons"
        case xyPad = "XY Pad"
        case settings = "Settings"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Page", selection: $page) {
                ForEach(Page.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch page {
                case .mappings: MappingListView()
                case .buttons:  ButtonListView()
                case .xyPad:    XYPadSettingsView()
                case .settings: SettingsPageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20).fill(Theme.panel)
        )
    }
}

// MARK: - Mappings list

struct MappingListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(app.preset.motionMappings.enumerated()), id: \.element.id) { offset, mapping in
                    NavigationLink {
                        MappingEditorView(
                            mapping: Binding(
                                get: { app.preset.motionMappings[offset] },
                                set: { app.preset.motionMappings[offset] = $0 }
                            )
                        )
                    } label: {
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { app.preset.motionMappings[offset].enabled },
                                set: { app.preset.motionMappings[offset].enabled = $0 }
                            ))
                            .labelsHidden()
                            .tint(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mapping.name)
                                    .font(.subheadline.bold())
                                Text("\(mapping.source.shortLabel) → CC\(mapping.cc) · CH \(mapping.channel + 1)")
                                    .font(.caption.monospaced())
                                    .foregroundColor(Theme.dim)
                            }
                        }
                    }
                    .listRowBackground(Theme.panel2)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Button list

struct ButtonListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(app.preset.buttons.enumerated()), id: \.element.id) { offset, button in
                    NavigationLink {
                        ButtonEditorView(
                            button: Binding(
                                get: { app.preset.buttons[offset] },
                                set: { app.preset.buttons[offset] = $0 }
                            )
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(button.name)
                                .font(.subheadline.bold())
                            Text("Note \(button.note) · CH \(button.channel + 1) · \(button.behavior.label)")
                                .font(.caption.monospaced())
                                .foregroundColor(Theme.dim)
                        }
                    }
                    .listRowBackground(Theme.panel2)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Mapping detail editor

struct MappingEditorView: View {
    @Binding var mapping: MotionMapping

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $mapping.name)
                Toggle("Enabled", isOn: $mapping.enabled)
                    .tint(Theme.accent)
            }

            Section("Source & Target") {
                Picker("Motion Source", selection: $mapping.source) {
                    ForEach(MotionSource.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                Stepper("CC Number: \(mapping.cc)", value: $mapping.cc, in: 0...127)
                Stepper("Channel: \(mapping.channel + 1)", value: $mapping.channel, in: 0...15)
            }

            Section("Processing") {
                LabeledSlider(label: "Dead Zone",
                              value: $mapping.processing.deadZone, range: 0...0.4)
                LabeledSlider(label: "Sensitivity",
                              value: $mapping.processing.sensitivity, range: 0.2...4)
                LabeledSlider(label: "Smoothing",
                              value: $mapping.processing.smoothing, range: 0...0.95)
                Picker("Response Curve", selection: $mapping.processing.curve) {
                    ForEach(ResponseCurve.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                Toggle("Invert", isOn: $mapping.processing.invert)
                    .tint(Theme.accent)
            }

            Section("Output Range") {
                Stepper("Min: \(mapping.processing.outMin)",
                        value: $mapping.processing.outMin, in: 0...127)
                Stepper("Max: \(mapping.processing.outMax)",
                        value: $mapping.processing.outMax, in: 0...127)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle(mapping.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Button detail editor

struct ButtonEditorView: View {
    @Binding var button: ButtonMapping
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $button.name)
            }

            Section("MIDI") {
                Stepper("Note: \(button.note)", value: $button.note, in: 0...127)
                Stepper("Channel: \(button.channel + 1)", value: $button.channel, in: 0...15)
                Picker("Behavior", selection: $button.behavior) {
                    ForEach(ButtonBehavior.allCases) { b in
                        Text(b.label).tag(b)
                    }
                }
            }

            Section("XY Pad Glide Toggle") {
                let isAssigned = app.preset.xyPad.glideToggleButtonId == button.id
                Toggle("Toggle XY Pad Glide", isOn: Binding(
                    get: { isAssigned },
                    set: { newValue in
                        if newValue {
                            // Assign glide toggle to this button, clear any previous assignment
                            app.preset.xyPad.glideToggleButtonId = button.id
                        } else {
                            // Only unassign if this button is currently assigned
                            if isAssigned {
                                app.preset.xyPad.glideToggleButtonId = nil
                            }
                        }
                    }
                ))
                .tint(Theme.accent)
                
                if isAssigned {
                    Text("This button will toggle glide (legato portamento) on the XY pad when pressed.")
                        .font(.caption)
                        .foregroundColor(Theme.dim)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle(button.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.caption.monospaced())
                    .foregroundColor(Theme.dim)
            }
            Slider(value: $value, in: range)
                .tint(Theme.accent)
        }
    }
}

// MARK: - XY pad settings

struct XYPadSettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section("XY Pad MIDI") {
                Stepper("X Axis CC: \(app.preset.xyPad.xCC)",
                        value: $app.preset.xyPad.xCC, in: 0...127)
                Stepper("Y Axis CC: \(app.preset.xyPad.yCC)",
                        value: $app.preset.xyPad.yCC, in: 0...127)
                Stepper("Channel: \(app.preset.xyPad.channel + 1)",
                        value: $app.preset.xyPad.channel, in: 0...15)
                Toggle("Snap Back to Center", isOn: $app.preset.xyPad.snapBack)
                    .tint(Theme.accent)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Settings

struct SettingsPageView: View {
    @EnvironmentObject var app: AppState
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Preset") {
                TextField("Preset Name", text: $app.preset.name)
                LabeledContent("In Library", value: "\(app.presets.count) preset\(app.presets.count == 1 ? "" : "s")")
                Button("Reset This Preset to Default", role: .destructive) {
                    confirmReset = true
                }
            }
            Section("Status") {
                LabeledContent("Motion Engine",
                               value: app.motion.running ? "Running · 100 Hz" : "Stopped")
                LabeledContent("Virtual Source", value: "Motion MIDI")
                LabeledContent("Destinations",
                               value: "\(app.midi.destinationNames.count)")
            }
            Section {
                Text("Tip: hold the phone in playing position, then tap CENTER to zero pitch/roll/yaw. Tap the preset name in the header to switch presets.")
                    .font(.caption)
                    .foregroundColor(Theme.dim)
            }
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("Reset this preset to the default layout? Its name and place in the library are kept.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { app.resetActivePresetToDefault() }
        }
    }
}
