import SwiftUI

/// Bottom third: collapsible editor. Fully hidden during performance.
struct EditorView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var app: AppState
    /// Opens on Settings. It is the page with the CC map, the destinations
    /// and the layout switches — the things reached mid-setup — where
    /// Mappings is somewhere you go deliberately.
    @State private var page: Page = .settings

    /// The XY Pad page is deliberately absent. Everything it held now lives
    /// in the pad's own config sheet, reachable from the gear in the pad
    /// header — one place to configure the pad instead of two that showed
    /// overlapping subsets of the same settings.
    enum Page: String, CaseIterable, Identifiable {
        case mappings = "Mappings"
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
                case .mappings: MappingListView()
                case .buttons:  ButtonListView()
                case .settings: SettingsPageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20).fill(theme.panel)
        )
    }
}

// MARK: - Mappings list

struct MappingListView: View {
    @Environment(\.theme) private var theme
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
                            .tint(theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mapping.name)
                                    .font(.subheadline.bold())
                                Text("\(mapping.source.shortLabel) → CC\(mapping.cc) · CH \(mapping.channel + 1)")
                                    .font(.caption.monospaced())
                                    .foregroundColor(theme.dim)
                            }
                        }
                    }
                    .listRowBackground(theme.panel2)
                }

                Section {
                    Toggle("Show Meters on Deck", isOn: $app.preset.showMotionMeters)
                        .tint(theme.accent)
                        .listRowBackground(theme.panel2)
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
    @Environment(\.theme) private var theme
    @EnvironmentObject var app: AppState

    /// Edit mode is driven from here rather than by an `EditButton` in the
    /// toolbar.
    ///
    /// This list sets `navigationBarHidden(true)` — it lives inside the
    /// bottom-third editor panel, where a navigation bar would eat height
    /// that belongs to the list. A toolbar item placed in the navigation bar
    /// therefore has nowhere to render, which is why reordering was
    /// unreachable even on iPad, despite the help text saying otherwise. The
    /// toggle lives in a section header instead, which always renders.
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                // First, because it is the switch you reach for mid-set when
                // the pad needs the room. Stored on the preset like the other
                // deck toggles, so a pad-only preset and a button-heavy one
                // can sit side by side in the library.
                Section {
                    Toggle("Show Buttons on Deck", isOn: $app.preset.showButtons)
                        .tint(theme.accent)
                        .listRowBackground(theme.panel2)
                }

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
                                    .foregroundColor(theme.dim)

                            }
                        }
                        .listRowBackground(theme.panel2)
                    }
                    .onMove { from, to in
                        app.preset.buttons.move(fromOffsets: from, toOffset: to)
                    }
                    .onDelete { offsets in
                        app.preset.buttons.remove(atOffsets: offsets)
                    }
                } header: {
                    // The reorder toggle lives in the HEADER, not in a row.
                    // A plain Button inside a list row can stop responding
                    // once the list enters edit mode, which would leave no
                    // way back out of reordering. A header is outside the
                    // rows and keeps working either way.
                    HStack {
                        Text("Buttons")
                        Spacer()
                        if app.preset.buttons.count > 1 {
                            Button {
                                withAnimation {
                                    editMode = editMode.isEditing ? .inactive : .active
                                }
                            } label: {
                                Text(editMode.isEditing ? "Done" : "Reorder")
                                    .font(.caption.bold())
                                    .foregroundColor(theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button {
                        app.addButton()
                    } label: {
                        Label("Add Button", systemImage: "plus.circle.fill")
                            .foregroundColor(theme.accent)
                    }
                } footer: {
                    Text("Swipe a button left to delete it.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationBarHidden(true)
            .environment(\.editMode, $editMode)
        }
    }
}

// MARK: - Mapping detail editor

struct MappingEditorView: View {
    @Environment(\.theme) private var theme
    @Binding var mapping: MotionMapping

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $mapping.name)
                Toggle("Enabled", isOn: $mapping.enabled)
                    .tint(theme.accent)
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
                    .tint(theme.accent)
            }

            Section("Output Range") {
                Stepper("Min: \(mapping.processing.outMin)",
                        value: $mapping.processing.outMin, in: 0...127)
                Stepper("Max: \(mapping.processing.outMax)",
                        value: $mapping.processing.outMax, in: 0...127)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.panel)
        .navigationTitle(mapping.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Button detail editor

/// Looked up by ID on every render, matching the pattern in
/// `DialStepEditor` — so a delete or reorder elsewhere can never leave this
/// editor pointed at a stale array position.
struct ButtonEditorView: View {
    @Environment(\.theme) private var theme
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
                        Stepper("CC Number: \(button.cc)", value: ccBinding, in: 0...127)
                        Stepper("On Value: \(button.onValue)",
                                value: onValueBinding, in: 0...127)
                        Stepper("Off Value: \(button.offValue)",
                                value: offValueBinding, in: 0...127)
                    case .note:
                        Stepper("Note: \(button.note)", value: noteBinding, in: 0...127)
                        Stepper("Velocity: \(max(button.onValue, 1))",
                                value: onValueBinding, in: 1...127)
                    }

                    Stepper("Channel: \(button.channel + 1)", value: channelBinding, in: 0...15)
                    Picker("Behavior", selection: behaviorBinding) {
                        ForEach(ButtonBehavior.allCases) { b in
                            Text(b.label).tag(b)
                        }
                    }
                    Picker("Lit From", selection: lightBinding) {
                        ForEach(ButtonLight.allCases) { l in
                            Text(l.label).tag(l)
                        }
                    }
                } header: {
                    Text("MIDI")
                }

                // Only when the light actually comes from the host. A button
                // lit from its own state never reads incoming MIDI, so a
                // listen target here would be a setting with no effect.
                if button.light == .host {
                    Section {
                        Toggle("Listen on a Different Message", isOn: listenEnabledBinding)
                            .tint(theme.accent)

                        if let listen = button.listen {
                            Picker("Message", selection: listenMessageBinding) {
                                ForEach(ButtonMessage.allCases) { m in
                                    Text(m.label).tag(m)
                                }
                            }
                            .pickerStyle(.segmented)

                            IntWheelRow(title: listen.message == .cc ? "CC" : "Note",
                                        selection: listenNumberBinding,
                                        range: 0...127,
                                        wheelWidth: listen.message == .cc ? 140 : 170) { n in
                                listen.message == .cc ? String(n) : MIDIWheelText.note(n)
                            }

                            IntWheelRow(title: "Channel",
                                        selection: listenChannelBinding,
                                        range: 0...15) { String($0 + 1) }
                        } else {
                            // Says where it listens now, so the default is
                            // visible rather than implied.
                            let target = button.feedbackTarget
                            LabeledContent("Listening On",
                                           value: "\(target.message == .cc ? "CC" : "Note") \(target.number) · CH \(target.channel + 1)")
                        }
                    } header: {
                        Text("Host Feedback")
                    }
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
                    .tint(theme.accent)

                    if isAssigned {
                        Text("This button will toggle glide (legato portamento) on the XY pad when pressed.")
                            .font(.caption)
                            .foregroundColor(theme.dim)
                    }
                }

                // The only guard that matters is the last one: a preset with
                // no buttons has nothing to press. Device idiom never had a
                // bearing on whether a button should be deletable.
                if app.preset.buttons.count > 1 {
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
        .background(theme.panel)
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

    // ── Listen target ─────────────────────────────────────────────────
    //
    // Every edit clears the button's host-lit state. Whatever lit it came in
    // on the OLD target; keeping it would show a status the new target has
    // never reported.

    private func editListen(_ change: (inout ButtonListen?) -> Void) {
        guard let i = app.preset.buttons.firstIndex(where: { $0.id == buttonID }) else { return }
        change(&app.preset.buttons[i].listen)
        app.clearHostLit(buttonID)
    }

    private var listenEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.button?.listen != nil },
            set: { isOn in
                guard let current = self.button else { return }
                // Seeded with what the button already listens on, so turning
                // this on changes nothing until a value is actually edited.
                self.editListen { $0 = isOn ? current.feedbackTarget : nil }
            }
        )
    }

    private var listenMessageBinding: Binding<ButtonMessage> {
        Binding(
            get: { self.button?.listen?.message ?? .cc },
            set: { newValue in self.editListen { $0?.message = newValue } }
        )
    }

    private var listenNumberBinding: Binding<Int> {
        Binding(
            get: { self.button?.listen?.number ?? 0 },
            set: { newValue in
                self.editListen { $0?.number = min(max(newValue, 0), 127) }
            }
        )
    }

    private var listenChannelBinding: Binding<Int> {
        Binding(
            get: { self.button?.listen?.channel ?? 0 },
            set: { newValue in
                self.editListen { $0?.channel = min(max(newValue, 0), 15) }
            }
        )
    }

    private var nameBinding: Binding<String> { bind(\.name, default: "") }
    private var noteBinding: Binding<Int> { bind(\.note, default: 60) }
    private var ccBinding: Binding<Int> { bind(\.cc, default: MIDIDefaults.buttonCCPool[0]) }
    private var onValueBinding: Binding<Int> { bind(\.onValue, default: 127) }
    private var offValueBinding: Binding<Int> { bind(\.offValue, default: 0) }
    private var channelBinding: Binding<Int> { bind(\.channel, default: 0) }
    /// Wraps the plain binding to clear a latch left behind when a lit
    /// toggle button is changed to some other behavior.
    ///
    /// Without this the button would stay lit with no way to turn it off:
    /// only `.toggle` presses clear a latch, and it just stopped being one.
    /// The "off" message goes out too, so the host isn't left holding a
    /// value nothing on screen still claims to be sending.
    private var lightBinding: Binding<ButtonLight> {
        Binding(
            get: { self.button?.light ?? .local },
            set: { newValue in
                guard let i = self.app.preset.buttons
                    .firstIndex(where: { $0.id == self.buttonID }) else { return }

                // Leaving host mode strands nothing: the host's report is
                // dropped, and a stale latch from before would otherwise
                // reappear as a lit button nothing is driving.
                if newValue == .local {
                    self.app.clearHostLit(self.buttonID)
                } else if self.app.isButtonLatched(self.buttonID) {
                    // Entering host mode with a latch still set would show
                    // the button lit on this app's say-so while claiming to
                    // report the host's state.
                    self.app.emitButton(self.app.preset.buttons[i], on: false)
                    self.app.clearButtonLatch(self.buttonID)
                }

                self.app.preset.buttons[i].light = newValue
            }
        )
    }

    private var behaviorBinding: Binding<ButtonBehavior> {
        let raw = bind(\.behavior, default: .tap)
        return Binding(
            get: { raw.wrappedValue },
            set: { newValue in
                if newValue != .toggle,
                   let current = self.button,
                   self.app.isButtonLatched(current.id) {
                    self.app.emitButton(current, on: false)
                    self.app.clearButtonLatch(current.id)
                }
                raw.wrappedValue = newValue
            }
        )
    }

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
                    // Everything the preset already sends, this button
                    // excepted — its own stored CC is fine to keep if
                    // nothing else took it while it was a note button.
                    let others = Set(
                        self.app.ccAssignments
                            .filter { $0.slot != .button(self.buttonID) && !$0.isNote }
                            .map(\.cc)
                    )
                    if others.contains(self.app.preset.buttons[i].cc) {
                        self.app.preset.buttons[i].cc =
                            self.app.firstFreeCC()
                            ?? MIDIDefaults.firstFreeButtonCC(avoiding: others)
                    }
                }
                self.app.preset.buttons[i].message = newValue
            }
        )
    }
}

struct LabeledSlider: View {
    @Environment(\.theme) private var theme
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
                    .foregroundColor(theme.dim)
            }
            Slider(value: $value, in: range)
                .tint(theme.accent)
        }
    }
}

// MARK: - Settings

struct SettingsPageView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var app: AppState
    @State private var confirmReset = false
    @State private var expandedSection: String? = nil
    @State private var showBluetooth = false
    @State private var showCCMap = false

    private var ccConflictCount: Int {
        // Counts across BOTH surfaces when two are running. The badge is the
        // only warning before you open the map, so a clash with the other
        // surface has to raise it — otherwise the map opens showing a
        // conflict the badge said was not there.
        var rows = app.ccAssignments
        if dualSurface, isPadIdiom, let peer = app.peer {
            rows += peer.ccAssignments
        }
        return Preset.conflictingSlots(in: rows).count
    }

    /// Same key RootView reads. Toggling it from either surface's settings
    /// changes the layout for both, which is correct — it's an app-level
    /// choice, not a property of one surface.
    @AppStorage("MotionMIDIPro.dualSurface") private var dualSurface = false

    var body: some View {
        Form {
            Section {
                Button {
                    showCCMap = true
                } label: {
                    HStack {
                        Label("CC Map", systemImage: "tablecells")
                        Spacer()
                        // The conflict count is the reason to open it, so it
                        // belongs on the way in rather than inside.
                        if ccConflictCount > 0 {
                            Text("\(ccConflictCount)")
                                .font(.caption.bold())
                                .foregroundColor(theme.bg)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.danger))
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.dim)
                    }
                }
                .tint(theme.accent)
            } header: {
                Text("MIDI")
            }

            Section("Preset") {
                // With two surfaces on screen, both editors look identical.
                // This says which one is being edited.
                if dualSurface && isPadIdiom {
                    LabeledContent("Surface",
                                   value: app.isPrimary ? "Left" : "Right")
                }
                TextField("Preset Name", text: $app.preset.name)
                LabeledContent("In Library", value: "\(app.presets.count) preset\(app.presets.count == 1 ? "" : "s")")
                Button("Reset This Preset to Default", role: .destructive) {
                    confirmReset = true
                }
            }

            // Bluetooth moved off the performance screen and landed here.
            // Pairing is something done once before a show, not mid-set, and
            // it was occupying a 44pt target on the row you reach across
            // while playing.
            Section {
                Button {
                    showBluetooth = true
                } label: {
                    Label("Bluetooth MIDI", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundColor(theme.accent)
                }

                MIDIDestinationStatus(midi: app.midi)
            } header: {
                Text("Connection")
            }

            Section {
                Toggle("Show Dial / Fader Panel", isOn: $app.preset.showDialPanel)
                    .tint(theme.accent)

                // iPad only. Two surfaces need width for two pads; on a phone
                // each would be too narrow to play, so it isn't offered.
                if isPadIdiom {
                    Toggle("Second Performer Surface", isOn: $dualSurface)
                        .tint(theme.accent)
                }
            } header: {
                Text("Layout")
            }

            Section("Status") {
                MotionEngineStatus(motion: app.motion)
                LabeledContent("Virtual Source", value: "Motion MIDI")
            }

            helpSection("Getting Started", icon: "star.fill") {
                helpItem("Connect to a MIDI Host",
                         "Open Settings → Connection → Bluetooth MIDI. Connect to any app or device that receives MIDI — on the same iPhone, on an iPad, a Mac, or hardware. Motion MIDI appears as a source named 'Motion MIDI' in any compatible app's MIDI input settings. Popular hosts include Loopy Pro, AUM, GarageBand, Drambo, and any AUv3-compatible app.")
                helpItem("Same-Device Use",
                         "Open Motion MIDI first, then switch to your target app. Motion MIDI keeps running in the background. In your host app's MIDI settings, select 'Motion MIDI' as an input source.")
                helpItem("Calibrate Motion",
                         "Hold the device in your normal playing position, then tap the crosshair button. This zeros pitch, roll, and yaw so your natural hold position sends center values. Recalibrate any time your playing position changes.")
                helpItem("Switch Presets",
                         "Tap the preset name in the top-right of the screen. Presets are listed most-recently-used first. Tap any preset to switch instantly. Use Save As New Preset to copy the current state with a new name.")
            }

            helpSection("XY Pad", icon: "square.grid.2x2") {
                helpItem("CC Mode vs Notes Mode",
                         "Use the CC / Notes toggle in the pad header. CC mode sends two MIDI control change values — X and Y independently — to any parameter in any app that responds to MIDI CC. Notes mode turns the pad into a polyphonic instrument using the scale and diagonal you configure.")
                helpItem("Standard XY vs 4-Corner Morph",
                         "Use the XY / 4C toggle in the pad header. Standard XY sends two CCs (X and Y). 4-Corner Morph sends four CCs simultaneously — one per corner — blended smoothly as you move. Useful for controlling four independent parameters at once, such as clip volumes, send levels, or filter cutoffs.")
                helpItem("4-Corner Morph Controls",
                         "Morph Curve (-100 to +100): negative values spread influence broadly across corners; positive values concentrate it on the nearest corner. Center Strength: at 0% the pad feels like four distinct regions; at 100% the center creates a wide four-way blend. Equal Power: reduces perceived level drop when multiple destinations are partly attenuated.")
                helpItem("Notes Mode: Scale and Root",
                         "The root note sits about one-third of the way along the diagonal, with lower scale notes below it. The root band is highlighted brighter than the others. Change root and scale in the XY pad config sheet (tap the sliders icon in the pad header).")
                helpItem("Notes Mode: Diagonals",
                         "The diagonal determines which direction pitch increases as you move across the pad. Four orientations are available. The dashed line shows the pitch direction; the perpendicular bands are individual scale steps.")
                helpItem("Glide",
                         "Glide (legato portamento) makes notes slide between pitches instead of retriggering. Enable it in the config sheet or assign it to a pad button. The glide time sends CC 5; the on/off toggle sends CC 65. The receiving synth must respond to these standard portamento CCs — some instruments expose portamento only in their own UI.")
                helpItem("Voice Count",
                         "1, 2, or 3 simultaneous touches in Notes mode. When a new finger exceeds the limit, the oldest voice is stolen. Lift a finger and its stolen voice returns at its current position — the same note-priority behavior as a classic mono synth.")
                helpItem("Drawbars",
                         "Turns the pad into a bank of drawbars — up to nine, each sending its own CC. Drag across several at once to sweep the bank, or set Touch Mode to Individual to move one at a time. Direction flips which end of the pad is full level. Invert Values, just below it, leaves the bars looking and moving the same but sends the opposite value — a full bar sends 0 and an empty one sends 127 — for a host parameter that works backwards. The number on each handle is always the value being sent. Ramp smooths the sweep as your finger crosses bars, so a fast drag doesn't jump values.")
                helpItem("Held Notes: Release, Latch, Carry",
                         "Pad settings → Notes → Held Notes decides what happens to a note once its finger is no longer driving it. Release is the original behaviour: lifting a finger ends its note, and switching to another pad ends them all. Latch keeps every note sounding after you lift; the next fresh touch — a finger landing when none are down — clears the chord and starts a new one, while fingers added during a held chord join it. Carry plays like Release in Notes, but switching to another pad keeps whatever you were holding; the finger is then free to work the new pad, and back in Notes your first touch lets the carried notes go. While anything is held, a HOLD chip with a count appears in the pad header on every mode — tap it to release everything. Held notes also end when you switch preset or turn off the second surface. They keep sounding if you switch to another app, so a drone can ring on while you work in your host.")
                helpItem("MIDI Channel Per Mode",
                         "Standard, Drawbars, and Notes each carry their own channel, so switching mode doesn't retarget whatever the last one was driving. Morph is the exception: each of the four corners has its own channel, which is finer than a mode channel could be. Everything defaults to channel 1.")
                helpItem("On Release (Standard Mode)",
                         "Where the puck goes when your finger lifts. Hold Position sends nothing and leaves it where you left it. Center returns to the middle of both axes. Left Center and Right Center pin X to one end while centering Y — useful when X is a sweep you want parked open or closed. Bottom Left returns both axes to zero. Morph has its own separate list of targets; Notes has none, since the notes already ended on release.")
                helpItem("On Release: Master and Dial Steps",
                         "The On Release choice in pad settings is the master, for Standard XY and 4-Corner separately. A dial step with an XY On Release or Morph On Release action overrides it while that step is selected, and a note under the picker says so. Any step that says nothing about release leaves the master in charge. Changing the master takes effect straight away, taking over from the step that was holding it until that dial is turned again.")
                helpItem("Smooth",
                         "Standard XY and 4-Corner each have a Smooth switch in pad settings under Output. Without it, a fast swipe can jump several values between finger readings, which some synths let you hear as stepping. With it on, the pad reads the extra finger positions iOS records between screen updates and spreads each change across the few milliseconds before the next reading, so the host receives a run of steps instead of one jump. It never falls behind your finger by more than one reading — about 8 ms on a 120 Hz iPad — so it is not a glide or a lag. A finger landing and the release spring still jump straight to their value. Smooth cannot go finer than the 128 steps of a standard CC, and a synth that smooths its own controls may not need it.")
                helpItem("Touch CC",
                         "Standard XY and 4-Corner each have their own Touch CC, in pad settings under Touch. When on, it sends 127 as the first finger lands and 0 as the last one lifts — once per gesture, however many fingers. The 0 goes out after the pad has sprung to its release position, and always reaches the same CC and channel the 127 went to, even if you change the setting or switch modes mid-touch. Use it to engage an effect only while you are touching the pad. Both default to off; each appears in the CC Map while switched on.")
                helpItem("On Release (Morph Mode)",
                         "Where the blend lands when your finger lifts, chosen separately from Standard mode. Hold Position leaves it where you left it. Center returns to an even four-corner blend. Corner A, B, C or D snap to full weight on that one corner — and when you have named a corner, the picker shows that name. Center Top, Center Bottom, Center Left and Center Right park on an edge.")
                helpItem("Master Scale",
                         "The scale the pad uses unless a dial says otherwise. The dial you last turned is the one that describes the pad: what its current step declares applies, and anything its step says nothing about falls back to the master value. So turning a dial with no Set Scale on it returns the pad to the master scale, even if another dial is parked on a step that carries one. Editing the master scale, root or range from Settings or the on-pad chip takes effect immediately and overrules the step that was holding it, until that dial moves again.")
            }

            helpSection("Stepped Dial", icon: "dial.low.fill") {
                helpItem("Basic Operation",
                         "Drag around the knob to sweep through steps. Swipe up to advance one step; swipe down to go back. Long-press for 0.5 seconds to open dial settings.")
                helpItem("Steps and Actions",
                         "Each step can fire any combination of actions: Send CC, Program Change, Set Root Note, Set Scale, Toggle Glide, Toggle Perp→Velocity, Set Fixed Velocity, Set Voice Count, Set Note Range, and Fader Control. Tap a step in dial settings to edit it.")
                helpItem("Reshaping the Pad from a Step",
                         "A step can also change what the pad itself is. Set Pad Mode switches between Standard XY, 4-Corner Morph, Drawbars and Notes. Set X Axis CC and Set Y Axis CC retarget the axes, each with its own channel. Set Corner CC retargets one morph corner without disturbing the other three, and Set Morph Channel moves all four corners at once. XY On Release and Morph On Release set the spring target per step. All of these are declarative: they describe the pad while the step is selected and transmit nothing by themselves.")
                helpItem("Program Change",
                         "Each step can send a Program Change to switch patches, scenes, or presets on any connected device or app. Combine with Send CC or Fader Control on the same step to set up a complete scene in one detent.")
                helpItem("Fader Control Action",
                         "Assigns the vertical fader beside the dial to a specific CC while that step is selected. If a step has no Fader Control action, the fader falls back to that step's Send CC assignment. If neither exists, the fader is dimmed.")
                helpItem("Shared Dial Presets",
                         "Any dial configuration can be saved to the shared library and linked from multiple presets. Changes to a shared dial affect all presets using it. Tap Dial Preset in dial settings to manage this.")
                helpItem("Saving a Dial",
                         "Dial settings has two save paths. Save as New Dial asks for a name, adds a fresh entry to the shared library and links this slot to it — nothing existing is touched. Save to Existing Dial replaces a library dial's steps while keeping its name and identity, so every preset linked to it picks up the change. That second one asks first and tells you how many presets are affected.")
                helpItem("Opening Dial Settings",
                         "Tap the dial's name under the knob, or long-press the knob itself for half a second.")
                helpItem("Pairing Dials Across Surfaces",
                         "With two performer surfaces running, a dial on the left can be paired with any dial on the right. Turn either one and the other moves to the same step number. Names do not need to match — you pick the partner from a list. Each dial keeps its own steps, so step 3 on the left and step 3 on the right can do entirely different things. Pairing is set from the left surface; the right surface shows what it is paired with.")
                helpItem("Multiple Dials",
                         "Tap the + button at the end of the dial row to add another dial+fader combo. Each operates independently. On iPhone, scroll the row to reach dials past the first. Long-press any dial to open its settings, where you can delete it.")
            }

            helpSection("Vertical Fader", icon: "slider.vertical.3") {
                helpItem("Assignment",
                         "The fader has no fixed assignment. The selected dial step determines what it controls. Turn the dial and the fader silently re-points to the new step's CC, recalling that CC's last known value — like a motorized fader changing duty between parameters.")
                helpItem("MIDI Feedback",
                         "When a connected app sends CC feedback (for example, when you move a parameter directly in the host), the fader follows automatically. Feedback is matched on both MIDI channel and CC number, so messages for one step never update another.")
                helpItem("No Feedback Loops",
                         "Incoming feedback never re-transmits. Only direct finger movement on the fader sends MIDI. Changing steps never sends MIDI from the fader — the silent repositioning prevents runaway feedback with any host that echoes parameter changes.")
                helpItem("Unknown Value",
                         "If a step has never received feedback during this session, the fader shows the step's own stored Send CC value as a starting point. It does not assume zero and does not automatically query the host for the current value.")
            }

            helpSection("Motion Control", icon: "gyroscope") {
                helpItem("Available Sources",
                         "Roll, Pitch, Yaw, and Shake (acceleration magnitude). Each can be independently mapped to any CC number on any MIDI channel, targeting any parameter in any connected app or device.")
                helpItem("Calibration",
                         "Hold the device in playing position and tap the crosshair button. This zeros the current orientation so your natural hold sends center values (approximately CC 64). Recalibrate whenever your playing position changes.")
                helpItem("Response Curve",
                         "Each mapping has a dead zone, sensitivity, smoothing, and curve type (linear, S-curve, exponential). S-curve gives expressive control with a stable center; exponential suits dramatic gestures. Adjust in the Mappings tab.")
                helpItem("Background Operation",
                         "Motion MIDI keeps running when backgrounded, so any foreground app continues to receive MIDI from device motion. The audio background mode entitlement is already enabled.")
            }

            helpSection("Pad Buttons", icon: "rectangle.grid.3x2") {
                helpItem("Behavior",
                         "Momentary sends the on message while held and the off message on release — for sustained triggers. Tap sends both halves from one press, for hosts that toggle internally, and suits one-shots like scene launches or transport commands. Toggle latches: the first press sends on and the button stays lit, the next press sends off. Use Toggle when the host has no toggle of its own, or when you want the button's lit state to be the record of what is on. Switching preset releases any latched button, so nothing is left hanging.")
                helpItem("MIDI Assignment",
                         "Each button sends either a CC or a note, on its own number and channel. CC is the default for new buttons: it can be MIDI-learned to anything a host exposes — a mixer send, a plugin parameter, a transport control — while a note is only heard by something listening for notes. Common uses: transport control, clip launching, mute toggles, and patch changes.")
                helpItem("Glide Toggle",
                         "One button can be assigned as a glide toggle for the XY pad. Pressing it flips glide on or off in addition to sending its note. Assign it in the button editor under the Buttons tab.")
                helpItem("Adding, Deleting and Reordering",
                         "The Buttons tab adds and deletes buttons on iPhone and iPad alike, with no limit on how many a preset holds. Add Button claims the first free CC. Swipe a button left to delete it, or open it and use Delete Button — the last one cannot be deleted, since a preset with no buttons has nothing to press. Reorder Buttons lets you drag them into the order you want.")
                helpItem("How Many Buttons Show",
                         "Every button in the preset appears on the deck, on iPhone and iPad alike. Past what fits on one row they wrap onto another, and the XY pad above gives up the height. Reorder them to decide which sit at the top.")
                helpItem("Hiding the Buttons",
                         "Show Buttons on Deck, at the top of the Buttons tab, removes the whole button grid from the performance screen and gives its height to the XY pad. Nothing about the buttons changes while they are hidden: assignments stay, a latched button stays latched, and one set to follow host feedback keeps tracking it. The setting belongs to the preset, so a pad-only preset and a button-heavy one can sit side by side.")
                helpItem("Lit From: Own State or Host Feedback",
                         "Own State is the original behavior: the button lights from its own press, so a Toggle stays lit because it latched. Host Feedback lights it from incoming MIDI on the button's own number and channel instead. That matters for anything the host can also change on its own — a looper clip started from the host's own screen, stopped by a scene change, or run to the end. With Own State the button would go on claiming it is playing; with Host Feedback it follows what is actually happening. Set it in the button editor or from the button's row in the CC Map.")
                helpItem("Listen on a Different Message",
                         "By default a Host Feedback button watches the number and channel it sends on. Turn on Listen on a Different Message in the button editor to watch something else instead — a CC or note, any number, any channel. That lets the host report status on its own message: in Loopy Pro, for example, a widget can take CC 24 from the button and send its on/off state out on CC 90. Keeping status separate from control means the host never mistakes its own report for a press. Motion MIDI never sends anything in response to what it receives, so this cannot create a feedback loop on its side; just make sure the host's status message is sent only to Motion MIDI and cannot find its way back into the host's own input.")
                helpItem("Host Feedback Requirements",
                         "The host has to report the state over MIDI on the number and channel the button listens on — its own, unless you set a different one. Any value at or above 64 counts as on, since hosts differ about which value they reply with. For note buttons, a Note On with velocity above zero is on, and both Note Off and Note On with velocity zero are off. If your host only reports state over OSC rather than MIDI, this will not light — Motion MIDI speaks MIDI only.")
            }

            helpSection("Presets & Files", icon: "square.and.arrow.up") {
                helpItem("Export a Preset",
                         "Swipe right on any preset in the preset list and tap Export. The file is saved wherever you choose — Files, iCloud Drive, or straight into a Mail or Messages thread. Use it to back up a rig before a gig, move one between iPhone and iPad, or hand a setup to another performer.")
                helpItem("Import a Preset",
                         "Tap Import Preset at the bottom of the preset list, or open a .motionmidi file from Files, Mail, or AirDrop. Importing always adds — it never overwrites a preset you already have. If the name is taken, the new one gets a number appended. You can select several files at once; if one of them isn't a preset, the rest still import and Motion MIDI tells you which failed.")
                helpItem("Linked Dials Travel With It",
                         "A dial slot can link to a shared dial in the library. On export, that dial's steps are copied into the preset so the file is self-contained — the person receiving it gets exactly what you had, even though their library has never seen that dial. The copy is a snapshot: it no longer follows later edits to the shared dial. If you want it in your own library, save it there from the dial's settings.")
                helpItem("Reset to Default",
                         "Settings → Reset returns the active preset to the default layout while keeping its name and its place in the library. You are asked to confirm first, since it discards the preset's current mappings.")
            }

            helpSection("Screen Layout", icon: "rectangle.split.2x1") {
                helpItem("Show Meters on Deck",
                         "Hides the pitch, roll, yaw, and magnitude bars from the performance screen. The mappings above them keep running and keep sending — this only takes back the space the bars occupy.")
                helpItem("Show Dial / Fader Panel",
                         "Hiding the dial panel gives its height back to the XY pad and moves Center and the settings button side by side. Dial steps keep their assignments and keep applying; the row is only hidden.")
                helpItem("Second Performer Surface",
                         "On iPad, splits the screen into two independent performers, each with its own preset, pad, buttons, and dials. Both send down the same MIDI port, so keep them on different channels or CCs. The gyro drives the left surface only — there is one sensor, and it can follow one preset's mappings at a time.")
                helpItem("Mode Button Indent",
                         "Holds blank space to the left of the pad mode buttons so the iPad's window controls don't sit on top of them in Split View or Stage Manager. This one applies to every preset and both surfaces, unlike the other layout settings — the window controls it dodges don't move when you change preset.")
            }

            helpSection("Playing Live", icon: "music.mic") {
                helpItem("Stop iPadOS Swiping Between Apps",
                         "Four and five finger gestures switch apps and can fire while you are playing a chord on the pad. No app can turn that off, but you can: Settings → General → Gestures, and switch off the four and five finger gestures. Do this once and it stays off.")
                helpItem("Guided Access for Shows",
                         "For a stronger lock, turn on Settings → Accessibility → Guided Access, then triple-click the side button once you are inside Motion MIDI. Nothing can leave the app — no switching, no Control Centre, no notifications landing on your pad mid-song. Triple-click again to exit.")
            }

            helpSection("MIDI Routing", icon: "cable.connector") {
                helpItem("Virtual MIDI Source",
                         "Motion MIDI creates a CoreMIDI virtual source named 'Motion MIDI'. Any app on the same device can receive from it without a physical connection. Look for 'Motion MIDI' in your host app's MIDI input source list.")
                helpItem("Bluetooth MIDI",
                         "Settings → Connection → Bluetooth MIDI opens the browser. Connect to a Bluetooth MIDI peripheral, a Mac, or another iOS device. Motion MIDI broadcasts to all connected destinations simultaneously, so one device can drive multiple apps or hardware at once.")
                helpItem("Wired Connection",
                         "Connecting the iPhone to a Mac via USB also exposes Motion MIDI as a MIDI source over the wired connection. No additional setup is required.")
                helpItem("MIDI Feedback / Incoming MIDI",
                         "Motion MIDI creates a virtual MIDI destination named 'Motion MIDI'. Any app that supports MIDI feedback output can send messages back here. Incoming CC updates the vertical fader, and both CC and notes can drive pad buttons set to Host Feedback. Other message types are ignored. Motion MIDI never hears its own output, so a button lighting from feedback is always reporting the host, not itself.")
                helpItem("MIDI Channels",
                         "Every output in Motion MIDI — XY pad, buttons, motion mappings, dial steps, and fader — has its own MIDI channel setting. Use different channels to route to different instruments or parameters in the same app without conflicts.")
                helpItem("CC Map",
                         "Settings → MIDI → CC Map lists everything this preset sends in one place: motion, pad, morph corners, drawbars, buttons, and every dial step. Numbers, channels, and names are editable there. View it by owner to see what each control sends, or by number to see what is free. A red badge on the way in counts conflicts — two controls on the same number and channel that can both be active at once.")
                helpItem("Editing Buttons in the Map",
                         "Button rows carry three menus the other rows do not: CC or Note, the press behavior (Momentary, Tap, Toggle), and whether the button lights from its own state or from host feedback. Add Button at the foot of the Buttons section creates one without leaving the map, on the first free CC. Note buttons appear in the map alongside CC buttons, showing NOTE and their note number. A button lit from Host Feedback also shows a line saying what it listens on; tap it to switch between its own number and a custom CC or note on any channel.")
                helpItem("Colors",
                         "Colors live at the top of the CC Map. A palette is a set of base colors — background, panels, raised surfaces, text, grid lines and accent — plus a row of numbered component colors. Every widget picks one of those numbers: the XY pad and each dial in their section headers, and each morph corner, drawbar, button and motion meter on its own row. A widget left on its default follows the accent, and morph corners and drawbars follow the pad. The dice in the Colors header does the work for you: Surprise Me picks a new palette and spreads its colors across everything, Random Palette swaps only the palette, Scatter Colors re-spreads the current one, and Reset puts every widget back on its default. Because widgets store a color's number rather than the color itself, changing the palette restyles the whole surface at once.")
                helpItem("Global, Surface and Preset Palettes",
                         "The Global palette applies everywhere. A preset can choose its own, which wins while that preset is loaded. With a second surface running, each surface can also have its own palette, sitting between the two: a preset that follows the surface gets the surface's palette, and a surface that follows global gets the global one. A row that is following shows what it inherits in grey; a row that made its own choice shows it in the accent color. Manage Palettes lists the built-ins and your own. Duplicate any palette to edit it, or start from a random one. Daylight, Candy and Paper are light palettes for bright rooms and outdoor stages.")
                helpItem("Styles",
                         "Beside each palette menu is a style menu. A palette decides what color things are; a style decides how they are drawn, and any palette works in any style. Standard is the original look with soft glows. Flat drops every glow and shadow for a clean, quiet surface. Neon draws controls as lit outlines that glow when on — best on a dark palette. Graphic uses square corners and heavy borders in the text color — try it with Paper or Mono. Candy uses pill shapes and color-washed controls — try it with Candy or Pastel. Styles follow the same layers as palettes: Global, then each surface, then the preset. Flat, Graphic and Candy are also the lightest to draw, which can help on older devices with several fingers on the pad.")
                helpItem("Shaded Styles",
                         "The style menu's second section holds the shaded looks. Clay is puffy and matte, with pressed buttons squashing flat — try it with Candy or Pastel. Glass makes controls see-through with a glossy top edge — best on a dark palette like Ocean or Neon. Metal turns knobs and the puck into brushed steel and colors buttons like anodized aluminum — try Mono or Classic. Soft presses every control out of the surface itself, and a pressed button sinks in — it looks best on Daylight or Mono. Plastic gives glossy hardware keys like a drum machine, with the color lighting up inside. Shaded styles draw with gradients rather than blur, and anything that follows your finger carries a single shadow, so they cost about the same to draw as Standard.")
                helpItem("Collapsing Sections and Shifting Channels",
                         "Tap any section header to fold it away; a collapsed section still shows its row count and any conflicts inside it. The − CH + buttons on the right of each header move every channel in that section together by one, keeping the spread between rows that sit on different channels. They stop at the edges rather than piling rows onto the last channel.")
                helpItem("Notes and CCs Do Not Collide",
                         "A note number and a CC number are separate namespaces. Note 24 and CC 24 on the same channel are unrelated messages and are never reported as a conflict. Two notes on the same number and channel still are. Note rows are also left out of the by-number view and out of the free-CC search, so a note never makes a CC look taken.")
                helpItem("Send for MIDI Learn",
                         "Each row in the CC Map has a send button. Tapping it sweeps that CC from 0 to 127 and back to its resting value, which is what most hosts need to latch onto during MIDI learn. Put the host in learn mode, tap send, and the parameter binds without you having to move the control on the pad. On a note row it plays the note on and off instead, since a host waiting to learn a note hears nothing from a stream of controller values.")
                helpItem("One Source, Two Surfaces",
                         "Motion MIDI appears to hosts as a single source no matter how many performer surfaces are on screen. Both surfaces send down the same port, so keep them on different channels or CCs if you are driving separate instruments.")
                helpItem("The CC Map with Two Surfaces",
                         "With a second surface running, the map gains a Left / Right selector above the view picker. Rows and edits follow the selector, so you can retarget the other surface without leaving the pad you are standing at. Conflict detection always spans both surfaces, because they share one port — and when the clash is with the other surface, the row names it, for example 'also Right: Drawbar 3'. The badge in Settings counts both surfaces too.")
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showBluetooth) {
            BluetoothMIDIView()
        }
        // Full screen rather than a sheet: the editor is a bottom-third
        // panel, so a pushed page would inherit that height and the map is a
        // table you need to see a lot of at once.
        .fullScreenCover(isPresented: $showCCMap) {
            CCMapView()
                .environmentObject(app)
        }
        .confirmationDialog("Reset this preset to the default layout? Its name and place in the library are kept.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { app.resetActivePresetToDefault() }
        }
    }

    // MARK: - Help section builder

    private func helpSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedSection == title },
                    set: { expandedSection = $0 ? title : nil }
                )
            ) {
                content()
            } label: {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
            }
        }
    }

    private func helpItem(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(theme.accent)
            Text(body)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    @Environment(\.theme) private var theme
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
    @Environment(\.theme) private var theme
    @ObservedObject var motion: MotionEngine

    var body: some View {
        LabeledContent("Motion Engine",
                       value: motion.running ? "Running · 100 Hz" : "Stopped")
    }
}
