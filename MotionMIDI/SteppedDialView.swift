import SwiftUI

/// A stepped rotary selector for the lower-left of the control deck.
///
/// Steps sit around a 270° arc, like a real selector switch with the dead
/// gap at the bottom. One gesture handles everything, choosing its meaning
/// from how the finger moves:
///
///   • Tap a tick        — jump straight to that step.
///   • Drag around       — sweep through steps continuously.
///   • Swipe up / down   — advance or go back one step per detent.
///   • Press and hold    — open settings.
///
/// Every step change fires that step's action with a haptic detent, and the
/// position persists with the dial.
struct SteppedDialView: View {
    @EnvironmentObject var app: AppState

    /// Which dial+fader slot this instance shows. iPhone always passes 0.
    let slot: Int

    @State private var showSettings = false

    // ── Single-gesture state machine ────────────────────────────────────
    /// Locked once per drag, the first time the finger travels past the slop
    /// threshold, so a curved swipe can't flip modes mid-gesture.
    ///
    /// `horizontal` does nothing on purpose. It used to be `rotary` — a
    /// sideways sweep pointed the dial at whatever step sat under the finger
    /// — but the dial lives in a horizontally scrolling row of slots, and a
    /// control that reacts to sideways travel is a control that eats the
    /// gesture used to reach the slot beside it. Turning is vertical only
    /// now; sideways travel is recognized purely so it can be ignored, which
    /// leaves the scroll view free to act on it.
    private enum DragMode { case undecided, horizontal, vertical }

    @State private var dragActive = false
    @State private var dragMode: DragMode = .undecided
    /// Vertical travel already converted into step changes, so scrolling is
    /// incremental rather than one jump per gesture.
    @State private var consumedHeight: CGFloat = 0
    @State private var longPressWork: DispatchWorkItem?
    /// Set when the long press fires, so the finger lifting afterwards
    /// doesn't also register as a tap.
    @State private var handledByLongPress = false

    /// Outer diameter of the knob's touch area.
    private let knobSize: CGFloat = 84
    /// Travel required per step when swiping vertically.
    private let verticalDetent: CGFloat = 26
    /// Movement allowed before a press stops counting as "held still".
    private let slop: CGFloat = 10

    private var dial: DialPreset { app.dial(at: slot) }

    private var currentIndex: Int {
        guard !dial.steps.isEmpty else { return 0 }
        return min(max(dial.currentStepIndex, 0), dial.steps.count - 1)
    }

    /// Knob face shows a short abbreviation — four characters is enough to
    /// recognize a step at a glance without crowding the dial.
    private var faceLabel: String {
        guard let step = dial.currentStep else { return "SET" }
        let trimmed = step.label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "—" : String(trimmed.prefix(4)).uppercased()
    }

    var body: some View {
        VStack(spacing: 4) {
            knob
                .frame(width: knobSize + 14, height: knobSize + 14)

            HStack(spacing: 4) {
                Text(dial.name.uppercased())
                    .font(.system(size: 8, weight: .semibold).monospaced())
                    .foregroundColor(Theme.dim)
                    .lineLimit(1)
                if app.dialIsLinked(at: slot) {
                    Image(systemName: "link")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Theme.dim)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            DialSettingsSheet(slot: slot)
                .environmentObject(app)
        }
    }

    // MARK: - Knob

    private var knob: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let tickRadius = min(geo.size.width, geo.size.height) / 2 - 3
            let faceSize = knobSize - 20

            ZStack {
                // Tick ring — one mark per step.
                ForEach(Array(dial.steps.enumerated()), id: \.element.id) { index, _ in
                    let active = index == currentIndex
                    Capsule()
                        .fill(active ? Theme.accent : Color.white.opacity(0.18))
                        .frame(width: active ? 3 : 2, height: active ? 10 : 6)
                        .offset(y: -tickRadius)
                        .rotationEffect(.degrees(Self.stepAngle(index, count: dial.steps.count)))
                        .animation(.easeOut(duration: 0.12), value: currentIndex)
                }

                // Knob face.
                Circle()
                    .fill(Theme.panel2)
                    .frame(width: faceSize, height: faceSize)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 5, y: 2)

                // Pointer notch, rotating to the active step.
                if !dial.steps.isEmpty {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 3, height: 11)
                        .offset(y: -faceSize / 2 + 8)
                        .rotationEffect(.degrees(Self.stepAngle(currentIndex,
                                                                count: dial.steps.count)))
                        .animation(.spring(response: 0.22, dampingFraction: 0.75),
                                   value: currentIndex)
                }

                // Abbreviated step name.
                Text(faceLabel)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(dial.steps.isEmpty ? Theme.dim : Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: faceSize - 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            // ONE gesture. Stacking several .gesture modifiers would let the
            // later one replace the earlier, and a zero-distance drag starves
            // any long press, so both behaviors are driven from here instead.
            //
            // SIMULTANEOUS, not exclusive. A plain .gesture claims the touch
            // outright, and a child gesture that engages at zero distance
            // beats the enclosing ScrollView every time — which meant a
            // sideways drag anywhere on the dial was swallowed and the row
            // of slots could not be scrolled from on top of one. Sharing the
            // gesture lets the scroll view act on horizontal travel while
            // this still handles vertical. The row scrolls horizontally
            // only, so there is nothing for it to do with a vertical drag
            // and the two never contradict each other.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, center: center) }
                    .onEnded { value in dragEnded(value, center: center) }
            )
        }
    }

    // MARK: - Gesture handling

    private func dragChanged(_ value: DragGesture.Value, center: CGPoint) {
        let dx = value.translation.width
        let dy = value.translation.height
        let distance = sqrt(dx * dx + dy * dy)

        // A fresh gesture always reports a fresh (near-zero) translation, so
        // that is what starts one — not a flag cleared in dragEnded. SwiftUI
        // cancels gestures when another recognizer takes the touch and then
        // dragEnded never runs, which left `dragActive` stuck true and the
        // dial unable to start a new drag at all.
        if distance < 0.5 {
            // `dragActive` alone isn't enough: a cancelled gesture leaves it
            // true, so a genuinely new touch would be mistaken for a
            // continuation and never re-arm the long press. A mode still set
            // from a previous gesture is the tell that this is new.
            let staleFromCancelledGesture = dragMode != .undecided
            if !dragActive || staleFromCancelledGesture {
                dragActive = true
                handledByLongPress = false
                scheduleLongPress()
            }
            dragMode = .undecided
            consumedHeight = 0
        }

        guard !handledByLongPress else { return }

        // Past the slop threshold this is a drag, not a hold.
        if distance > slop {
            cancelLongPress()
            if dragMode == .undecided {
                // Lock the axis once. Vertical wins ties and near-ties: the
                // dial only turns on up/down travel, so the bias should sit
                // with the axis that does something rather than with the one
                // whose whole job is to get out of the row's way.
                dragMode = abs(dy) >= abs(dx) ? .vertical : .horizontal
            }
        }

        switch dragMode {
        case .undecided:
            break
        case .horizontal:
            // Intentionally empty — see DragMode. The row scrolls on this
            // instead.
            break
        case .vertical:
            scrollVertically(translationHeight: dy)
        }
    }

    private func dragEnded(_ value: DragGesture.Value, center: CGPoint) {
        cancelLongPress()

        defer {
            dragActive = false
            dragMode = .undecided
            consumedHeight = 0
            handledByLongPress = false
        }

        guard !handledByLongPress else { return }

        // Never moved past slop — treat as a tap.
        if dragMode == .undecided {
            if dial.steps.isEmpty {
                showSettings = true
            } else {
                selectStepUnder(location: value.location, center: center)
            }
        }
    }

    // MARK: - Long press

    private func scheduleLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem {
            handledByLongPress = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showSettings = true
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    // MARK: - Step selection

    /// Rotary: map the finger's angle onto the 270° arc. Positions near the
    /// center are ignored (the angle there is too noisy to be meaningful),
    /// as is the dead gap along the bottom.
    private func selectStepUnder(location: CGPoint, center: CGPoint) {
        guard !dial.steps.isEmpty else { return }

        let dx = location.x - center.x
        let dy = location.y - center.y
        guard sqrt(dx * dx + dy * dy) > 14 else { return }

        // Degrees from 12 o'clock, clockwise positive.
        let theta = atan2(dx, -dy) * 180 / .pi
        guard abs(theta) <= 135 else { return }

        let count = dial.steps.count
        let target: Int
        if count == 1 {
            target = 0
        } else {
            let fraction = (theta + 135) / 270
            target = min(max(Int((fraction * Double(count - 1)).rounded()), 0), count - 1)
        }

        commit(target)
    }

    /// Vertical: every `verticalDetent` points of travel steps once. Up is
    /// forward. Consuming the travel as it's spent keeps a long swipe moving
    /// through several steps instead of jumping once.
    private func scrollVertically(translationHeight: CGFloat) {
        guard !dial.steps.isEmpty else { return }

        while translationHeight - consumedHeight <= -verticalDetent {
            consumedHeight -= verticalDetent
            commit(currentIndex + 1)
        }
        while translationHeight - consumedHeight >= verticalDetent {
            consumedHeight += verticalDetent
            commit(currentIndex - 1)
        }
    }

    /// Clamp, skip no-ops, then fire the action with a detent.
    private func commit(_ index: Int) {
        let count = dial.steps.count
        guard count > 0 else { return }
        let clamped = min(max(index, 0), count - 1)
        guard clamped != currentIndex else { return }

        let style: UIImpactFeedbackGenerator.FeedbackStyle =
            (clamped == 0 || clamped == count - 1) ? .medium : .light
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        app.selectDialStep(at: slot, clamped)
    }

    /// Angle in degrees (from 12 o'clock, clockwise) for step `index` of
    /// `count` steps spread across the -135°...+135° arc.
    static func stepAngle(_ index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return -135 + 270 * Double(index) / Double(count - 1)
    }
}

// MARK: - Settings sheet

struct DialSettingsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let slot: Int

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                dialSection
                stepsSection
            }
            .navigationTitle("Stepped Dial")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // ── Which dial: local or a shared library preset ─────────────────────

    private var sourceSection: some View {
        Section {
            NavigationLink {
                DialLibraryPicker(slot: slot)
            } label: {
                HStack {
                    Text("Dial Preset")
                    Spacer()
                    Text(app.dialIsLinked(at: slot) ? app.dial(at: slot).name : "Local")
                        .foregroundColor(.secondary)
                }
            }

            if !app.dialIsLinked(at: slot) {
                Button("Save to Shared Library") {
                    app.saveDialToLibrary(at: slot)
                }
            }

            if app.preset.dialSlots.count > 1 {
                Button("Delete This Dial + Fader", role: .destructive) {
                    app.removeDialSlot(at: slot)
                    dismiss()
                }
            }
        }
    }

    // ── Name / channel ───────────────────────────────────────────────────

    private var dialSection: some View {
        Section {
            TextField("Name", text: dialBinding(\.name))
            IntWheelRow(title: "MIDI Channel",
                        selection: dialBinding(\.channel),
                        range: 0...15) { String($0 + 1) }
        } header: {
            Text("Dial")
        }
    }

    // ── Steps ────────────────────────────────────────────────────────────

    private var stepsSection: some View {
        Section {
            ForEach(app.dial(at: slot).steps) { step in
                NavigationLink {
                    DialStepEditor(slot: slot, stepID: step.id)
                } label: {
                    HStack {
                        Text(step.label)
                            .font(.subheadline.bold())
                            .frame(minWidth: 52, alignment: .leading)
                        Text(step.summary)
                            .font(.caption.monospaced())
                            .foregroundColor(step.hasActions ? .secondary : Theme.dim)
                            .lineLimit(1)
                    }
                }
            }
            .onMove { from, to in
                app.updateDial(at: slot) { $0.steps.move(fromOffsets: from, toOffset: to) }
            }
            .onDelete { offsets in
                app.updateDial(at: slot) { dial in
                    dial.steps.remove(atOffsets: offsets)
                    dial.currentStepIndex = min(dial.currentStepIndex,
                                                max(dial.steps.count - 1, 0))
                }
            }

            Button {
                app.updateDial(at: slot) {
                    $0.steps.append(DialStep(label: "NEW \($0.steps.count + 1)"))
                }
            } label: {
                Label("Add Step", systemImage: "plus.circle.fill")
                    .foregroundColor(Theme.accent)
            }
        } header: {
            Text("Steps · \(app.dial(at: slot).steps.count)")
        }
    }

    /// Binding into whichever DialPreset is active (local or linked).
    private func dialBinding<Value>(_ keyPath: WritableKeyPath<DialPreset, Value>) -> Binding<Value> {
        Binding(
            get: { app.dial(at: slot)[keyPath: keyPath] },
            set: { newValue in app.updateDial(at: slot) { $0[keyPath: keyPath] = newValue } }
        )
    }
}

// MARK: - Library picker

struct DialLibraryPicker: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let slot: Int

    var body: some View {
        List {
            Section {
                Button {
                    app.linkDial(at: slot, to: nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("Local (this preset)")
                            .foregroundColor(.primary)
                        Spacer()
                        if !app.dialIsLinked(at: slot) {
                            Image(systemName: "checkmark")
                                .foregroundColor(Theme.accent)
                        }
                    }
                }
            }

            Section("Shared Library") {
                if app.dialLibrary.isEmpty {
                    Text("No shared dial presets yet. Save the current dial to the library to create one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(app.dialLibrary) { preset in
                    Button {
                        app.linkDial(at: slot, to: preset.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .foregroundColor(.primary)
                                Text("\(preset.steps.count) steps")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if app.preset.dialSlots.indices.contains(slot),
                               app.preset.dialSlots[slot].linkedDialPresetID == preset.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    app.deleteDialPresets(at: offsets)
                }
            }
        }
        .navigationTitle("Dial Preset")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Step editor

/// Edits one step as a CHECKLIST: every action kind is listed, and any
/// combination can be switched on. A single detent can therefore send a CC,
/// swap the scale, and flip glide all at once.
///
/// The step is looked up by ID on every render, so no binding can capture a
/// stale index across deletes or reorders.
struct DialStepEditor: View {
    @EnvironmentObject var app: AppState
    let slot: Int
    let stepID: UUID
    @State private var expandedGroups: Set<DialActionGroup> = Set(DialActionGroup.allCases)

    private var step: DialStep? {
        app.dial(at: slot).steps.first { $0.id == stepID }
    }

    var body: some View {
        Form {
            if let step = step {
                Section("Label") {
                    TextField("Label", text: labelBinding)
                        .autocorrectionDisabled()
                    Text("Knob shows: \(knobPreview(step.label))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Three collapsible cards separate the three jobs clearly:
                // Pad Control reshapes the XY instrument, Dial sends messages
                // when the step is selected, and Fader assigns the companion
                // fader. Flat, they read as interchangeable checkboxes.
                ForEach(DialActionGroup.allCases) { group in
                    actionCard(group: group, step: step)
                }
            } else {
                Text("This step was deleted.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(step?.label ?? "Step")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func knobPreview(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "—" : String(trimmed.prefix(4)).uppercased()
    }

    // MARK: - One card

    private func actionCard(group: DialActionGroup, step: DialStep) -> some View {
        let count = step.actionCount(in: group)
        let isExpanded = Binding(
            get: { expandedGroups.contains(group) },
            set: { expanded in
                if expanded {
                    expandedGroups.insert(group)
                } else {
                    expandedGroups.remove(group)
                }
            }
        )

        return Section {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(group.kinds) { kind in
                    actionBlock(kind: kind, step: step)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: group.icon)
                        .font(.caption)
                    Text(group.title)
                    if count > 0 {
                        Text("· \(count) on")
                            .foregroundColor(Theme.accent)
                    }
                }
                .font(.headline)
            }
            .tint(Theme.accent)
        }
    }

    // MARK: - One checklist entry, plus its controls when enabled

    @ViewBuilder
    private func actionBlock(kind: DialActionKind, step: DialStep) -> some View {
        let existing = step.action(ofKind: kind)

        Button {
            // Hand the surrounding dial's state down, so switching on a
            // second Send CC picks the next free number in the dial block
            // rather than repeating the first one, and starts on the dial's
            // channel rather than always channel 1.
            let dial = app.dial(at: slot)
            mutateStep {
                $0.toggle(kind: kind,
                          usedCCs: dial.usedCCs,
                          channel: dial.channel)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: existing == nil ? "circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(existing == nil ? Theme.dim : Theme.accent)

                Text(kind.label)
                    .foregroundColor(.primary)

                Spacer()

                if let existing = existing {
                    Text(existing.summary)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let existing = existing {
            Group {
                controls(for: existing)
            }
            .padding(.leading, 32)
        }
    }

    // ── Per-kind parameter controls ──────────────────────────────────────

    @ViewBuilder
    private func controls(for action: DialAction) -> some View {
        switch action {
        case .sendCC(let cc, let value, let channel):
            IntWheelRow(title: "CC Number", selection: Binding(
                get: { cc },
                set: { setAction(.sendCC(cc: $0, value: value, channel: channel)) }
            ), range: 0...127)
            IntWheelRow(title: "Value", selection: Binding(
                get: { value },
                set: { setAction(.sendCC(cc: cc, value: $0, channel: channel)) }
            ), range: 0...127)
            channelWheel(channel) { newChannel in
                setAction(.sendCC(cc: cc, value: value, channel: newChannel))
            }

        case .sendProgramChange(let program, let channel):
            Stepper("Program: \(program)", value: Binding(
                get: { program },
                set: { setAction(.sendProgramChange(program: $0, channel: channel)) }
            ), in: 0...127)
            channelWheel(channel) { newChannel in
                setAction(.sendProgramChange(program: program, channel: newChannel))
            }

        case .setRootNote(let n):
            IntWheelRow(title: "Root", selection: Binding(
                get: { n },
                set: { setAction(.setRootNote($0)) }
            ), range: 0...120) { MIDIWheelText.note($0) }

        case .setScale(let s):
            Picker("Scale", selection: Binding(
                get: { s },
                set: { setAction(.setScale($0)) }
            )) {
                ForEach(Scale.families) { family in
                    Section(family.title) {
                        ForEach(family.scales) { Text($0.label).tag($0) }
                    }
                }
            }

        case .setFixedVelocity(let v):
            IntWheelRow(title: "Velocity", selection: Binding(
                get: { v },
                set: { setAction(.setFixedVelocity($0)) }
            ), range: 1...127)

        case .toggleGlide:
            EmptyView()

        case .togglePerpVelocity:
            EmptyView()

        case .setVoiceCount(let n):
            Picker("Voices", selection: Binding(
                get: { n },
                set: { setAction(.setVoiceCount($0)) }
            )) {
                // Driven by the shared constant so this cannot fall behind
                // the pad's own limit again.
                ForEach(1...XYPadConfig.maxVoices, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }

        case .setNoteRange(let r):
            IntWheelRow(title: "Range", selection: Binding(
                get: { r },
                set: { setAction(.setNoteRange($0)) }
            ), range: 1...60) { "\($0) semitones" }

        // `defaultValue` is carried through untouched rather than edited
        // here. It only decides what the fader READS before any feedback
        // for this CC has arrived in the session, so it earns no wheel of
        // its own — but it must still be threaded through every rebuild,
        // or changing the CC would quietly reset it.
        case .setFaderCC(let cc, let defaultValue, let channel):
            IntWheelRow(title: "Fader CC", selection: Binding(
                get: { cc },
                set: { setAction(.setFaderCC(cc: $0,
                                             defaultValue: defaultValue,
                                             channel: channel)) }
            ), range: 0...127)
            channelWheel(channel) { newChannel in
                setAction(.setFaderCC(cc: cc,
                                      defaultValue: defaultValue,
                                      channel: newChannel))
            }
        }
    }

    /// Every sending action carries its own channel now, always visible.
    /// There is no override toggle to switch on first — the number shown is
    /// the number it sends on.
    private func channelWheel(_ channel: Int,
                                apply: @escaping (Int) -> Void) -> some View {
        IntWheelRow(title: "Channel", selection: Binding(
            get: { channel },
            set: { apply(min(max($0, 0), 15)) }
        ), range: 0...15) { String($0 + 1) }
    }

    // ── ID-based mutation helpers ────────────────────────────────────────

    private var labelBinding: Binding<String> {
        Binding(
            get: { step?.label ?? "" },
            set: { newValue in mutateStep { $0.label = newValue } }
        )
    }

    private func setAction(_ action: DialAction) {
        mutateStep { $0.set(action) }
    }

    private func mutateStep(_ mutate: (inout DialStep) -> Void) {
        app.updateDial(at: slot) { dial in
            guard let index = dial.steps.firstIndex(where: { $0.id == stepID }) else { return }
            mutate(&dial.steps[index])
        }
    }
}

// MARK: - Dial fader

/// Compact vertical fader living immediately right of the stepped dial.
///
/// It has NO assignment of its own: the dial's selected step is the single
/// authoritative source. Whatever Send CC that step carries (its channel
/// override or the dial's channel, plus its CC number) is what this fader
/// speaks — turn the dial and the fader silently becomes that step's
/// control, recalled at its last known value, like one motorized fader
/// changing duty.
///
/// Only a finger on this fader ever transmits (see AppState.faderMoved).
/// Feedback from the host and dial-step changes reposition it silently.
/// Steps without a Send CC action render it dimmed and inert.
struct DialFaderView: View {
    @EnvironmentObject var app: AppState

    /// Which dial+fader slot this fader follows. Must match the
    /// `SteppedDialView` it sits beside.
    let slot: Int

    /// Visible track height — shorter than the dial's knob for visual balance.
    private let trackHeight: CGFloat = 80
    /// Full touch width; the VISIBLE track is far narrower. A performer
    /// aiming sideways at a 5-point line needs the forgiveness.
    private let touchWidth: CGFloat = 44

    private var value: Int? { app.faderDisplayedValue(at: slot) }
    private var enabled: Bool { value != nil }

    // ── Axis lock ───────────────────────────────────────────────────────
    /// Mirrors the dial's state machine, and for the same reason: this
    /// fader sits in a horizontally scrolling row, so a sideways drag
    /// across it has to mean "move the row", not "set this value".
    private enum FaderDragMode { case undecided, horizontal, vertical }
    @State private var dragMode: FaderDragMode = .undecided

    /// Travel needed before the drag commits to an axis. Under this, the
    /// gesture is still a tap.
    private let slop: CGFloat = 10

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                track
                thumb
            }
            .frame(width: touchWidth, height: trackHeight)
            .contentShape(Rectangle())          // the whole area drags
            // Simultaneous, so the enclosing scroll view sees this touch
            // too — an exclusive zero-distance drag would claim it outright
            // and the slot row could never be scrolled from on top of a
            // fader.
            //
            // The axis lock below is the other half of that. This fader is
            // an ABSOLUTE control: it reads the finger's Y position rather
            // than accumulating movement, so without a lock the very first
            // event of any drag — including a purely sideways one — snapped
            // the value to wherever the finger happened to land vertically.
            // Grabbing a fader to slide the row would yank its value on the
            // way past.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }

                        let dx = g.translation.width
                        let dy = g.translation.height
                        let distance = sqrt(dx * dx + dy * dy)

                        // Every new gesture starts at ~zero translation, so
                        // that is the reset — NOT an `if !dragActive` flag
                        // cleared in onEnded.
                        //
                        // onEnded is not guaranteed to run: SwiftUI cancels a
                        // gesture when another recognizer takes the touch, and
                        // a flag-based reset then latches. One sideways drag
                        // left the mode stuck on `.horizontal`, and from that
                        // point the fader ignored every vertical drag forever.
                        // Deriving the reset from the gesture's own translation
                        // cannot get stuck, because a fresh gesture always
                        // reports a fresh translation.
                        if distance < 0.5 { dragMode = .undecided }

                        if dragMode == .undecided, distance > slop {
                            // Vertical wins ties: it's the axis that does
                            // something here.
                            dragMode = abs(dy) >= abs(dx) ? .vertical : .horizontal
                        }

                        // Undecided is still a possible tap; horizontal belongs
                        // to the row. Only commit once this is definitely a
                        // vertical drag.
                        guard dragMode == .vertical else { return }
                        commit(locationY: g.location.y)
                    }
                    .onEnded { g in
                        defer { dragMode = .undecided }

                        // Never passed slop — a tap. Absolute controls are
                        // expected to jump to where they were tapped, so that
                        // behavior is preserved rather than lost to the lock.
                        guard enabled, dragMode == .undecided else { return }
                        commit(locationY: g.location.y)
                    }
            )

            Text(enabled ? "\(value ?? 0)" : "—")
                .font(.system(size: 8, weight: .semibold).monospaced())
                .foregroundColor(Theme.dim)
                .frame(width: touchWidth)
        }
    }

    /// faderMoved de-duplicates: repeated identical rounded values
    /// transmit nothing.
    private func commit(locationY: CGFloat) {
        let fraction = 1 - min(max(locationY / trackHeight, 0), 1)
        app.faderMoved(at: slot, to: Int((fraction * 127).rounded()))
    }

    private var track: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Theme.panel2)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))

            // Filled portion, bottom up to the current value.
            if let value {
                Capsule()
                    .fill(Theme.accent.opacity(0.45))
                    .frame(height: max(fillHeight(for: value), 5))
            }
        }
        .frame(width: 5, height: trackHeight)
    }

    private var thumb: some View {
        Circle()
            .fill(enabled ? Theme.accent : Theme.panel2)
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(Color.white.opacity(enabled ? 0.25 : 0.1),
                                           lineWidth: 1))
            .shadow(color: enabled ? Theme.accent.opacity(0.4) : .clear, radius: 5)
            .offset(y: thumbOffset)
            .animation(.easeOut(duration: 0.1), value: value)
    }

    private func fillHeight(for value: Int) -> CGFloat {
        trackHeight * CGFloat(value) / 127
    }

    /// Thumb center from +trackHeight/2 (value 0, bottom) up to
    /// -trackHeight/2 (value 127, top). Disabled parks at center.
    private var thumbOffset: CGFloat {
        guard let value else { return 0 }
        let fraction = CGFloat(value) / 127
        return trackHeight / 2 - fraction * trackHeight
    }
}
