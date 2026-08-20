import SwiftUI

/// Bottom third: collapsible editor. Fully hidden during performance.
struct EditorView: View {
    @EnvironmentObject var app: AppState
    @State private var page: Page = .motion

    /// The XY Pad page is deliberately absent. Everything it held now lives
    /// in the pad's own config sheet, reachable from the gear in the pad
    /// header — one place to configure the pad instead of two that showed
    /// overlapping subsets of the same settings.
    enum Page: String, CaseIterable, Identifiable {
        case motion = "Motion"
        case buttons = "Buttons"
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
                case .motion:   MappingListView()
                case .buttons:  ButtonListView()
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

/// ID-based throughout — deliberately NOT the offset/enumerated pattern
/// used elsewhere, because add/delete on an offset-indexed list is exactly
/// what caused an earlier crash class in this app (see MappingListView,
/// which still avoids add/delete for that reason). The dial's step editor
/// solved this the same way: look everything up by stable id, every time,
/// so a delete or reorder can never leave a binding pointing at a stale
/// offset.
struct ButtonListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.preset.buttons) { button in
                        NavigationLink {
                            ButtonEditorView(buttonID: button.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(button.name)
                                    .font(.subheadline.bold())
                                Text(button.summary)
                                    .font(.caption.monospaced())
                                    .foregroundColor(Theme.dim)
                            }
                        }
                        .listRowBackground(Theme.panel2)
                    }
                    .onMove { from, to in
                        app.preset.buttons.move(fromOffsets: from, toOffset: to)
                    }
                    .onDelete { offsets in
                        app.preset.buttons.remove(atOffsets: offsets)
                    }
                }

                if isPadIdiom {
                    Section {
                        Button {
                            // Claim a CC no other button here is using, the
                            // same way a new dial step picks a free number.
                            app.preset.buttons.append(
                                ButtonMapping(
                                    name: "NEW",
                                    cc: MIDIDefaults.firstFreeButtonCC(
                                        avoiding: app.preset.usedButtonCCs
                                            .union(app.preset.usedDrawbarCCs))
                                )
                            )
                        } label: {
                            Label("Add Button", systemImage: "plus.circle.fill")
                                .foregroundColor(Theme.accent)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationBarHidden(true)
            .toolbar {
                if isPadIdiom {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                }
            }
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
                IntWheelRow(title: "CC Number", selection: $mapping.cc, range: 0...127)
                IntWheelRow(title: "Channel", selection: $mapping.channel, range: 0...15) { String($0 + 1) }
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
                IntWheelRow(title: "Min", selection: $mapping.processing.outMin, range: 0...127)
                IntWheelRow(title: "Max", selection: $mapping.processing.outMax, range: 0...127)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle(mapping.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Button detail editor

/// Looked up by ID on every render, matching the pattern in
/// `DialStepEditor` — so a delete or reorder elsewhere can never leave this
/// editor pointed at a stale array position.
struct ButtonEditorView: View {
    @EnvironmentObject var app: AppState
    let buttonID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var button: ButtonMapping? {
        app.preset.buttons.first { $0.id == buttonID }
    }

    var body: some View {
        Form {
            if let button = button {
                Section("Identity") {
                    TextField("Name", text: nameBinding)
                }

                Section {
                    Picker("Sends", selection: messageBinding) {
                        ForEach(ButtonMessage.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch button.message {
                    case .cc:
                        IntWheelRow(title: "CC Number", selection: ccBinding, range: 0...127)
                        IntWheelRow(title: "On Value", selection: onValueBinding, range: 0...127)
                        IntWheelRow(title: "Off Value", selection: offValueBinding, range: 0...127)
                    case .note:
                        IntWheelRow(title: "Note", selection: noteBinding, range: 0...127) { MIDIWheelText.note($0) }
                        IntWheelRow(title: "Velocity", selection: velocityBinding, range: 1...127)
                    }

                    IntWheelRow(title: "Channel", selection: channelBinding, range: 0...15) { String($0 + 1) }
                    Picker("Behavior", selection: behaviorBinding) {
                        ForEach(ButtonBehavior.allCases) { b in
                            Text(b.label).tag(b)
                        }
                    }
                } header: {
                    Text("MIDI")
                }

                Section("XY Pad Glide Toggle") {
                    let isAssigned = app.preset.xyPad.glideToggleButtonId == buttonID
                    Toggle("Toggle XY Pad Glide", isOn: Binding(
                        get: { isAssigned },
                        set: { newValue in
                            if newValue {
                                // Assign glide toggle to this button, clear any previous assignment
                                app.preset.xyPad.glideToggleButtonId = buttonID
                            } else if isAssigned {
                                app.preset.xyPad.glideToggleButtonId = nil
                            }
                        }
                    ))
                    .tint(Theme.accent)

                }

                if isPadIdiom && app.preset.buttons.count > 1 {
                    Section {
                        Button("Delete Button", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
            } else {
                Text("This button was deleted.")
                    .foregroundColor(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle(button?.name ?? "Button")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this button?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                app.preset.buttons.removeAll { $0.id == buttonID }
                dismiss()
            }
        }
    }

    // ── ID-based bindings ──────────────────────────────────────────

    /// One generic binding instead of a near-identical block per field.
    /// Still looks the button up by ID on every get and set, which is the
    /// point of the pattern — a delete or reorder elsewhere can never leave
    /// this editor writing into a stale array position.
    private func bind<Value>(_ keyPath: WritableKeyPath<ButtonMapping, Value>,
                             default fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.button?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                guard let i = self.app.preset.buttons
                    .firstIndex(where: { $0.id == self.buttonID }) else { return }
                self.app.preset.buttons[i][keyPath: keyPath] = newValue
            }
        )
    }

    private var nameBinding: Binding<String> { bind(\.name, default: "") }
    private var noteBinding: Binding<Int> { bind(\.note, default: 60) }
    private var ccBinding: Binding<Int> { bind(\.cc, default: MIDIDefaults.buttonCCPool[0]) }
    private var onValueBinding: Binding<Int> { bind(\.onValue, default: 127) }
    private var offValueBinding: Binding<Int> { bind(\.offValue, default: 0) }
    private var velocityBinding: Binding<Int> {
        Binding(
            get: { max(self.button?.onValue ?? 127, 1) },
            set: { self.onValueBinding.wrappedValue = min(max($0, 1), 127) }
        )
    }
    private var channelBinding: Binding<Int> { bind(\.channel, default: 0) }
    private var behaviorBinding: Binding<ButtonBehavior> { bind(\.behavior, default: .tap) }

    /// Switching to CC on a button that was last a note button lands it on a
    /// free number when its stored CC is already taken — otherwise flipping
    /// three buttons to CC in a row would point all three at the same
    /// controller, and only the first would appear to work.
    private var messageBinding: Binding<ButtonMessage> {
        Binding(
            get: { self.button?.message ?? .cc },
            set: { newValue in
                guard let i = self.app.preset.buttons
                    .firstIndex(where: { $0.id == self.buttonID }) else { return }

                if newValue == .cc {
                    let others = Set(
                        self.app.preset.buttons
                            .filter { $0.id != self.buttonID && $0.message == .cc }
                            .map(\.cc)
                    )
                    let unavailable = others.union(self.app.preset.usedDrawbarCCs)
                    if unavailable.contains(self.app.preset.buttons[i].cc) {
                        self.app.preset.buttons[i].cc =
                            MIDIDefaults.firstFreeButtonCC(avoiding: unavailable)
                    }
                }
                self.app.preset.buttons[i].message = newValue
            }
        )
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

// MARK: - Settings

struct SettingsPageView: View {
    @EnvironmentObject var app: AppState
    @State private var confirmReset = false
    @State private var showBluetooth = false
    @State private var showInstructions = false

    var body: some View {
        Form {
            Section {
                Button {
                    showInstructions = true
                } label: {
                    Label("Instructions", systemImage: "book.closed.fill")
                        .foregroundColor(Theme.accent)
                }
            }

            Section("Preset") {
                TextField("Preset Name", text: $app.preset.name)
                LabeledContent("In Library", value: "\(app.presets.count) preset\(app.presets.count == 1 ? "" : "s")")
                Button("Reset This Preset to Default", role: .destructive) {
                    confirmReset = true
                }
            }

            Section("Connection") {
                Button {
                    showBluetooth = true
                } label: {
                    Label("Bluetooth MIDI", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundColor(Theme.accent)
                }

                MIDIDestinationStatus(midi: app.midi)
            }

            Section("Status") {
                MotionEngineStatus(motion: app.motion)
                LabeledContent("Virtual Source", value: "Motion MIDI")
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showBluetooth) {
            BluetoothMIDIView()
        }
        .fullScreenCover(isPresented: $showInstructions) {
            InstructionsView()
        }
        .confirmationDialog("Reset this preset to the default layout? Its name and place in the library are kept.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { app.resetActivePresetToDefault() }
        }
    }
}

// MARK: - Instructions

struct InstructionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Getting Started") {
                    bullet("Connect MIDI", "For another device, open Settings → Connection → Bluetooth MIDI. For an app on this iPhone/iPad, select ‘Motion MIDI’ as a MIDI input in that app.")
                    bullet("Center Motion", "Hold the device in your normal playing position and tap Center. Re-center whenever your playing position changes.")
                    bullet("Presets", "Tap the preset name above the pad to switch. Presets are most-recent first. Swipe to rename or delete; the last preset cannot be deleted. Save As New Preset copies the current setup.")
                    bullet("Lower Settings", "Tap the lower Settings button to open the editor. It stays highlighted while the editor is open; tap it again to close.")
                }

                Section("XY Pad") {
                    bullet("Open Pad Settings", "Tap the Settings icon beside the preset name.")
                    bullet("Four Modes", "XY sends X and Y CCs. Morph blends four corner outputs. Drawbars gives independent CC faders. Notes turns the pad into a scale instrument.")
                    bullet("XY", "Choose X CC, Y CC, channel, and optional spring return.")
                    bullet("Morph", "Each corner has its own CC and channel. Curve changes how widely corners influence the pad; Center Strength changes the center blend; Equal Power keeps the combined level steadier.")
                    bullet("Drawbars", "Choose 1–9 bars and a direction. The arrow points toward value 127; the opposite end is 0. All drawbars use the Shared MIDI channel and hold their positions in the preset.")
                    bullet("Drawbar Touch", "Individual moves only the bar you first touch. Sweep moves every bar you cross. Ramp 0 is instant; Ramp 1–10 glides changes from 100 ms to 1.0 second.")
                    bullet("Notes: Root & Scale", "Set root and scale in Pad Settings. You can also tap the key/scale chip on the pad for quick scale changes.")
                    bullet("Notes: Voices", "Choose 1–3 voices. If you exceed the limit, the oldest voice is temporarily stolen and returns when the newer finger lifts.")
                    bullet("Notes: Diagonal & Range", "The selected diagonal sets the direction of rising pitch. Note Range sets the total span; dotted root-octave lines show where octaves fall.")
                    bullet("Glide", "Glide slides between notes instead of retriggering. MotionMIDI uses CC65 for portamento on/off and CC5 for glide time; the receiving instrument must support them.")
                    bullet("Velocity", "Use a fixed velocity or map movement perpendicular to the note bands to velocity.")
                }

                Section("Stepped Dial") {
                    bullet("Open Dial Settings", "Long-press a dial for about 0.5 seconds to open its settings menu.")
                    bullet("Move Through Steps", "Drag around the knob to select steps, or swipe up/down one step at a time. Steps run clockwise from the lower-left; the knob shows the first four characters of each label.")
                    bullet("Manage Steps", "Add steps, drag to reorder, and swipe to delete. A step can perform several actions at once.")
                    bullet("Dial Presets", "Local dials live only in the current preset. Shared dials can be linked to multiple presets; editing a shared dial changes every preset linked to it.")
                    bullet("Dial Channel", "The dial channel is the starting channel for new MIDI actions. Existing step actions keep their own channel unless you change them.")
                    bullet("Pad Control Card", "Changes pad behavior such as root, scale, glide, velocity mode, voice count, or note range when the step is selected. These actions reshape the pad rather than sending a dial MIDI message.")
                    bullet("Dial Card", "Send CC and Program Change actions fire when the step is selected. Toggle Glide and Toggle Perp→Velocity flip those pad settings on/off.")
                    bullet("Fader Card", "Choose the CC and channel controlled by the vertical fader while that step is selected. Selecting the step itself does not send a fader value.")
                    bullet("Multiple Dials", "Use + to add another dial/fader pair. On iPhone, scroll the dial row to reach additional pairs.")
                }

                Section("Vertical Fader") {
                    bullet("Assignment", "A step’s Fader Control action chooses the fader CC. If none is set, the fader can fall back to that step’s Send CC assignment; with neither assignment it is inactive.")
                    bullet("Feedback", "Incoming CC feedback moves the fader when both channel and CC match the current assignment.")
                    bullet("No Feedback Loop", "Incoming feedback is not retransmitted. Only direct finger movement sends fader MIDI.")
                    bullet("Stored Position", "Changing dial steps silently recalls the last known value. If no feedback has been received yet, the step’s stored CC value is the starting point.")
                }

                Section("Motion") {
                    bullet("Sources", "Map Roll, Pitch, Yaw, or Shake to any CC and MIDI channel.")
                    bullet("Processing", "Dead Zone ignores tiny motion. Sensitivity changes gain. Smoothing reduces jitter. Response Curve changes feel. Invert reverses direction. Output Range limits the sent values.")
                    bullet("Calibration", "Tap Center while holding the device naturally so that position becomes the neutral point.")
                    bullet("Background", "MotionMIDI can continue sending motion MIDI while another compatible app is in the foreground.")
                }

                Section("Buttons") {
                    bullet("CC or Note", "Each button can send either a MIDI CC or a MIDI Note on its own channel.")
                    bullet("Tap", "Tap sends the on event/value and then the off event/value automatically from one press.")
                    bullet("Momentary", "Momentary keeps the on event/value active while held and sends the off event/value on release.")
                    bullet("Glide Toggle", "A button can also be assigned to toggle XY Pad Glide when pressed.")
                    bullet("Button Order", "iPhone shows the first six buttons. On iPad you can add more, drag to reorder, and choose which six appear first.")
                }

                Section("MIDI Routing") {
                    bullet("Virtual Source", "MotionMIDI creates a virtual MIDI source named ‘Motion MIDI’ for same-device routing.")
                    bullet("Bluetooth", "Use Settings → Connection → Bluetooth MIDI to connect compatible external MIDI devices or computers.")
                    bullet("Destinations", "Settings shows the MIDI destinations MotionMIDI currently sees.")
                    bullet("Incoming CC", "MotionMIDI accepts CC feedback so the vertical fader can follow changes made in a host app.")
                    bullet("Channels", "Pad controls, buttons, motion mappings, dial actions, drawbars, and fader assignments can use their own MIDI channels as provided in their settings.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.headline)
                .foregroundColor(Theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Live engine status rows

/// Destination count, observing `MIDIEngine` directly.
///
/// Read through `app.midi` this row showed whatever the count happened to be
/// when the settings page was first built and never changed again —
/// `AppState` is an ObservableObject holding another ObservableObject, and
/// SwiftUI does not chain that. On a status readout that is worse than
/// useless: connecting a device while the page is open left it still saying
/// zero, which reads as a failed connection.
struct MIDIDestinationStatus: View {
    @ObservedObject var midi: MIDIEngine

    var body: some View {
        LabeledContent("Destinations") {
            if midi.destinationNames.isEmpty {
                Text("None")
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(midi.destinationNames, id: \.self) { name in
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }
}

/// Motion engine run state, observing the engine directly for the same
/// reason as above.
struct MotionEngineStatus: View {
    @ObservedObject var motion: MotionEngine

    var body: some View {
        LabeledContent("Motion Engine",
                       value: motion.running ? "Running · 100 Hz" : "Stopped")
    }
}
