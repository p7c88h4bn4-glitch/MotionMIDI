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

    @State private var showSettings = false

    // ── Single-gesture state machine ────────────────────────────────────
    /// Which interpretation this drag settled into. Decided ONCE, the first
    /// time the finger travels past the slop threshold, so a curved swipe
    /// can't flip modes halfway through and fight itself.
    private enum DragMode { case undecided, rotary, vertical }

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

    private var dial: DialPreset { app.activeDial }

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
                if app.dialIsLinked {
                    Image(systemName: "link")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Theme.dim)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            DialSettingsSheet()
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, center: center) }
                    .onEnded { value in dragEnded(value, center: center) }
            )
        }
    }

    // MARK: - Gesture handling

    private func dragChanged(_ value: DragGesture.Value, center: CGPoint) {
        if !dragActive {
            dragActive = true
            dragMode = .undecided
            consumedHeight = 0
            handledByLongPress = false
            scheduleLongPress()
        }

        guard !handledByLongPress else { return }

        let dx = value.translation.width
        let dy = value.translation.height

        // Past the slop threshold this is a drag, not a hold.
        if sqrt(dx * dx + dy * dy) > slop {
            cancelLongPress()
            if dragMode == .undecided {
                // Lock the axis once: clearly-vertical travel scrolls,
                // anything else sweeps the dial.
                dragMode = abs(dy) > abs(dx) * 1.4 ? .vertical : .rotary
            }
        }

        switch dragMode {
        case .undecided:
            break
        case .rotary:
            selectStepUnder(location: value.location, center: center)
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
        app.selectDialStep(clamped)
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
                DialLibraryPicker()
            } label: {
                HStack {
                    Text("Dial Preset")
                    Spacer()
                    Text(app.dialIsLinked ? app.activeDial.name : "Local")
                        .foregroundColor(.secondary)
                }
            }

            if !app.dialIsLinked {
                Button("Save to Shared Library") {
                    app.saveActiveDialToLibrary()
                }
            }
        } footer: {
            Text(app.dialIsLinked
                 ? "Shared preset — edits here affect every preset linked to it."
                 : "Local dial — saved with this preset only.")
        }
    }

    // ── Name / channel ───────────────────────────────────────────────────

    private var dialSection: some View {
        Section("Dial") {
            TextField("Name", text: dialBinding(\.name))
            Stepper("MIDI Channel: \(app.activeDial.channel + 1)",
                    value: dialBinding(\.channel), in: 0...15)
        }
    }

    // ── Steps ────────────────────────────────────────────────────────────

    private var stepsSection: some View {
        Section {
            ForEach(app.activeDial.steps) { step in
                NavigationLink {
                    DialStepEditor(stepID: step.id)
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
                app.updateActiveDial { $0.steps.move(fromOffsets: from, toOffset: to) }
            }
            .onDelete { offsets in
                app.updateActiveDial { dial in
                    dial.steps.remove(atOffsets: offsets)
                    dial.currentStepIndex = min(dial.currentStepIndex,
                                                max(dial.steps.count - 1, 0))
                }
            }

            Button {
                app.updateActiveDial {
                    $0.steps.append(DialStep(label: "NEW \($0.steps.count + 1)"))
                }
            } label: {
                Label("Add Step", systemImage: "plus.circle.fill")
                    .foregroundColor(Theme.accent)
            }
        } header: {
            Text("Steps · \(app.activeDial.steps.count)")
        } footer: {
            Text("The knob shows the first four characters of each label. Steps run clockwise from the lower left. Swipe to delete, drag to reorder.")
        }
    }

    /// Binding into whichever DialPreset is active (local or linked).
    private func dialBinding<Value>(_ keyPath: WritableKeyPath<DialPreset, Value>) -> Binding<Value> {
        Binding(
            get: { app.activeDial[keyPath: keyPath] },
            set: { newValue in app.updateActiveDial { $0[keyPath: keyPath] = newValue } }
        )
    }
}

// MARK: - Library picker

struct DialLibraryPicker: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    app.linkDial(to: nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("Local (this preset)")
                            .foregroundColor(.primary)
                        Spacer()
                        if !app.dialIsLinked {
                            Image(systemName: "checkmark")
                                .foregroundColor(Theme.accent)
                        }
                    }
                }
            } footer: {
                Text("The local dial is saved inside the current preset.")
            }

            Section("Shared Library") {
                if app.dialLibrary.isEmpty {
                    Text("No shared dial presets yet. Save the current dial to the library to create one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(app.dialLibrary) { preset in
                    Button {
                        app.linkDial(to: preset.id)
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
                            if app.preset.linkedDialPresetID == preset.id {
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
    let stepID: UUID

    private var step: DialStep? {
        app.activeDial.steps.first { $0.id == stepID }
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

                Section {
                    ForEach(DialActionKind.allCases) { kind in
                        actionBlock(kind: kind, step: step)
                    }
                } header: {
                    Text(step.actions.isEmpty
                         ? "Actions"
                         : "Actions · \(step.actions.count) on")
                } footer: {
                    Text("Turn on any combination. Selecting this step fires them all, in the order listed here.")
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

    // MARK: - One checklist entry, plus its controls when enabled

    @ViewBuilder
    private func actionBlock(kind: DialActionKind, step: DialStep) -> some View {
        let existing = step.action(ofKind: kind)

        Button {
            mutateStep { $0.toggle(kind: kind) }
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
            controls(for: existing)
        }
    }

    // ── Per-kind parameter controls ──────────────────────────────────────

    @ViewBuilder
    private func controls(for action: DialAction) -> some View {
        switch action {
        case .sendCC(let cc, let value, let channelOverride):
            Stepper("CC Number: \(cc)", value: Binding(
                get: { cc },
                set: { setAction(.sendCC(cc: $0, value: value, channelOverride: channelOverride)) }
            ), in: 0...127)
            Stepper("Value: \(value)", value: Binding(
                get: { value },
                set: { setAction(.sendCC(cc: cc, value: $0, channelOverride: channelOverride)) }
            ), in: 0...127)
            channelOverrideControls(current: channelOverride) { newOverride in
                setAction(.sendCC(cc: cc, value: value, channelOverride: newOverride))
            }

        case .sendProgramChange(let program, let channelOverride):
            Stepper("Program: \(program)", value: Binding(
                get: { program },
                set: { setAction(.sendProgramChange(program: $0, channelOverride: channelOverride)) }
            ), in: 0...127)
            channelOverrideControls(current: channelOverride) { newOverride in
                setAction(.sendProgramChange(program: program, channelOverride: newOverride))
            }

        case .setRootNote(let n):
            Stepper("Root: \(DialAction.noteName(n))", value: Binding(
                get: { n },
                set: { setAction(.setRootNote($0)) }
            ), in: 0...120)

        case .setScale(let s):
            Picker("Scale", selection: Binding(
                get: { s },
                set: { setAction(.setScale($0)) }
            )) {
                ForEach(Scale.allCases) { Text($0.label).tag($0) }
            }

        case .setFixedVelocity(let v):
            Stepper("Velocity: \(v)", value: Binding(
                get: { v },
                set: { setAction(.setFixedVelocity($0)) }
            ), in: 1...127)

        case .toggleGlide:
            Text("Flips the XY pad's glide on or off each time this step is selected.")
                .font(.caption)
                .foregroundColor(.secondary)

        case .togglePerpVelocity:
            Text("Flips the perpendicular-to-velocity mapping on or off each time this step is selected.")
                .font(.caption)
                .foregroundColor(.secondary)

        case .setVoiceCount(let n):
            Picker("Voices", selection: Binding(
                get: { n },
                set: { setAction(.setVoiceCount($0)) }
            )) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
            }

        case .setNoteRange(let r):
            Stepper("Range: \(r) semitones", value: Binding(
                get: { r },
                set: { setAction(.setNoteRange($0)) }
            ), in: 1...60)

        case .setFaderCC(let cc, let defaultValue, let channelOverride):
            Stepper("Fader CC: \(cc)", value: Binding(
                get: { cc },
                set: { setAction(.setFaderCC(cc: $0, defaultValue: defaultValue,
                                             channelOverride: channelOverride)) }
            ), in: 0...127)
            Stepper("Start at: \(defaultValue)", value: Binding(
                get: { defaultValue },
                set: { setAction(.setFaderCC(cc: cc, defaultValue: $0,
                                             channelOverride: channelOverride)) }
            ), in: 0...127)
            channelOverrideControls(current: channelOverride) { newOverride in
                setAction(.setFaderCC(cc: cc, defaultValue: defaultValue,
                                      channelOverride: newOverride))
            }
            Text("The fader drives this CC while the step is selected. Selecting the step sends nothing; “Start at” is only what the fader shows until feedback for this CC arrives.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func channelOverrideControls(current: Int?,
                                         apply: @escaping (Int?) -> Void) -> some View {
        Toggle("Override Channel", isOn: Binding(
            get: { current != nil },
            set: { apply($0 ? app.activeDial.channel : nil) }
        ))
        .tint(Theme.accent)

        if let channel = current {
            Stepper("Channel: \(channel + 1)", value: Binding(
                get: { channel },
                set: { apply($0) }
            ), in: 0...15)
        }
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
        app.updateActiveDial { dial in
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

    /// Visible track height — shorter than the dial's knob for visual balance.
    private let trackHeight: CGFloat = 80
    /// Full touch width; the VISIBLE track is far narrower. A performer
    /// aiming sideways at a 5-point line needs the forgiveness.
    private let touchWidth: CGFloat = 44

    private var value: Int? { app.faderDisplayedValue }
    private var enabled: Bool { value != nil }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                track
                thumb
            }
            .frame(width: touchWidth, height: trackHeight)
            .contentShape(Rectangle())          // the whole area drags
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        let fraction = 1 - min(max(g.location.y / trackHeight, 0), 1)
                        // faderMoved de-duplicates: repeated identical
                        // rounded values transmit nothing.
                        app.faderMoved(to: Int((fraction * 127).rounded()))
                    }
            )

            Text(enabled ? "\(value ?? 0)" : "—")
                .font(.system(size: 8, weight: .semibold).monospaced())
                .foregroundColor(Theme.dim)
                .frame(width: touchWidth)
        }
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
