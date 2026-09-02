import SwiftUI

/// Bottom third: collapsible editor. Fully hidden during performance.
struct EditorView: View {
    @EnvironmentObject var app: AppState
    @State private var page: Page = .mappings

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

                Section {
                    Toggle("Show Meters on Deck", isOn: $app.preset.showMotionMeters)
                        .tint(Theme.accent)
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
                                    // Avoids every CC the preset assigns —
                                    // drawbars, morph corners, dial steps and
                                    // motion included — not just other
                                    // buttons. Only avoiding buttons is what
                                    // let a new one land on a drawbar.
                                    cc: app.firstFreeCC()
                                        ?? MIDIDefaults.firstFreeButtonCC(
                                            avoiding: app.preset.usedButtonCCs)
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

                    if isAssigned {
                        Text("This button will toggle glide (legato portamento) on the XY pad when pressed.")
                            .font(.caption)
                            .foregroundColor(Theme.dim)
                    }
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
    private var channelBinding: Binding<Int> { bind(\.channel, default: 0) }
    /// Wraps the plain binding to clear a latch left behind when a lit
    /// toggle button is changed to some other behavior.
    ///
    /// Without this the button would stay lit with no way to turn it off:
    /// only `.toggle` presses clear a latch, and it just stopped being one.
    /// The "off" message goes out too, so the host isn't left holding a
    /// value nothing on screen still claims to be sending.
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
                            .filter { $0.slot != .button(self.buttonID) }
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
    @State private var expandedSection: String? = nil
    @State private var showBluetooth = false
    @State private var showCCMap = false

    private var ccConflictCount: Int {
        Preset.conflictingSlots(in: app.ccAssignments).count
    }

    /// Same key RootView reads. Toggling it from either surface's settings
    /// changes the layout for both, which is correct — it's an app-level
    /// choice, not a property of one surface.
    @AppStorage("MotionMIDIPro.dualSurface") private var dualSurface = false

    var body: some View {
        Form {
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
                        .foregroundColor(Theme.accent)
                }

                MIDIDestinationStatus(midi: app.midi)
            } header: {
                Text("Connection")
            }

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
                                .foregroundColor(Theme.bg)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.danger))
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.dim)
                    }
                }
                .tint(Theme.accent)
            } header: {
                Text("MIDI")
            }

            Section {
                Toggle("Show Dial / Fader Panel", isOn: $app.preset.showDialPanel)
                    .tint(Theme.accent)

                // iPad only. Two surfaces need width for two pads; on a phone
                // each would be too narrow to play, so it isn't offered.
                if isPadIdiom {
                    Toggle("Second Performer Surface", isOn: $dualSurface)
                        .tint(Theme.accent)
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
                         "Turns the pad into a bank of drawbars — up to nine, each sending its own CC. Drag across several at once to sweep the bank, or set Touch Mode to Individual to move one at a time. Direction flips which end of the pad is full level. Ramp smooths the sweep as your finger crosses bars, so a fast drag doesn't jump values.")
                helpItem("MIDI Channel Per Mode",
                         "Standard, Drawbars, and Notes each carry their own channel, so switching mode doesn't retarget whatever the last one was driving. Morph is the exception: each of the four corners has its own channel, which is finer than a mode channel could be. Everything defaults to channel 1.")
                helpItem("On Release (Standard Mode)",
                         "Where the puck goes when your finger lifts. Hold Position sends nothing and leaves it where you left it. Center returns to the middle of both axes. Left Center and Right Center pin X to one end while centering Y — useful when X is a sweep you want parked open or closed. Bottom Left returns both axes to zero. Morph has its own toggle for returning to an even four-corner blend; Notes has none, since the notes already ended on release.")
                helpItem("Master Scale",
                         "The scale the pad returns to. A dial step carrying Set Scale overrides it for as long as that step is selected; turn the dial off that step and the master scale comes back.")
            }

            helpSection("Stepped Dial", icon: "dial.low.fill") {
                helpItem("Basic Operation",
                         "Drag around the knob to sweep through steps. Swipe up to advance one step; swipe down to go back. Long-press for 0.5 seconds to open dial settings.")
                helpItem("Steps and Actions",
                         "Each step can fire any combination of actions: Send CC, Program Change, Set Root Note, Set Scale, Toggle Glide, Toggle Perp→Velocity, Set Fixed Velocity, Set Voice Count, Set Note Range, and Fader Control. Tap a step in dial settings to edit it.")
                helpItem("Program Change",
                         "Each step can send a Program Change to switch patches, scenes, or presets on any connected device or app. Combine with Send CC or Fader Control on the same step to set up a complete scene in one detent.")
                helpItem("Fader Control Action",
                         "Assigns the vertical fader beside the dial to a specific CC while that step is selected. If a step has no Fader Control action, the fader falls back to that step's Send CC assignment. If neither exists, the fader is dimmed.")
                helpItem("Shared Dial Presets",
                         "Any dial configuration can be saved to the shared library and linked from multiple presets. Changes to a shared dial affect all presets using it. Tap Dial Preset in dial settings to manage this.")
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
                helpItem("iPad: More Buttons",
                         "On iPad, the Buttons tab allows adding buttons without limit. iPhone always shows the first six — reorder them on iPad to choose which six appear on iPhone.")
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

            helpSection("MIDI Routing", icon: "cable.connector") {
                helpItem("Virtual MIDI Source",
                         "Motion MIDI creates a CoreMIDI virtual source named 'Motion MIDI'. Any app on the same device can receive from it without a physical connection. Look for 'Motion MIDI' in your host app's MIDI input source list.")
                helpItem("Bluetooth MIDI",
                         "Settings → Connection → Bluetooth MIDI opens the browser. Connect to a Bluetooth MIDI peripheral, a Mac, or another iOS device. Motion MIDI broadcasts to all connected destinations simultaneously, so one device can drive multiple apps or hardware at once.")
                helpItem("Wired Connection",
                         "Connecting the iPhone to a Mac via USB also exposes Motion MIDI as a MIDI source over the wired connection. No additional setup is required.")
                helpItem("MIDI Feedback / Incoming CC",
                         "Motion MIDI creates a virtual MIDI destination named 'Motion MIDI'. Any app that supports MIDI feedback output can send CC values back here, and the vertical fader will update to reflect them. Only CC messages are processed; all other message types are ignored.")
                helpItem("MIDI Channels",
                         "Every output in Motion MIDI — XY pad, buttons, motion mappings, dial steps, and fader — has its own MIDI channel setting. Use different channels to route to different instruments or parameters in the same app without conflicts.")
                helpItem("CC Map",
                         "Settings → MIDI → CC Map lists every CC this preset sends in one place: motion, pad, morph corners, drawbars, buttons, and every dial step. Numbers, channels, and names are editable there. View it by owner to see what each control sends, or by number to see what is free. A red badge on the way in counts conflicts — two controls on the same CC and channel that can both be active at once.")
                helpItem("Send for MIDI Learn",
                         "Each row in the CC Map has a send button. Tapping it sweeps that CC from 0 to 127 and back to its resting value, which is what most hosts need to latch onto during MIDI learn. Put the host in learn mode, tap send, and the parameter binds without you having to move the control on the pad.")
                helpItem("One Source, Two Surfaces",
                         "Motion MIDI appears to hosts as a single source no matter how many performer surfaces are on screen. Both surfaces send down the same port, so keep them on different channels or CCs if you are driving separate instruments.")
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
                .foregroundColor(Theme.accent)
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
