import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {

    /// The whole preset library. Never empty — deletion refuses to remove
    /// the last entry, so the active-preset lookup always resolves.
    @Published var presets: [Preset] { didSet { persistPresets() } }

    /// Which preset is live. Persisted, so the app reopens where you left it.
    @Published var activePresetID: UUID { didSet { persistPresets() } }

    /// Shared, reusable dial presets. Any preset can link to one of these
    /// instead of carrying its own dial configuration.
    @Published var dialLibrary: [DialPreset] {
        didSet { DialLibraryStore.save(dialLibrary) }
    }

    let midi: MIDIEngine
    let motion: MotionEngine

    init() {
        let loaded = PresetLibraryStore.load()
        let initialPresets: [Preset]
        let initialActiveID: UUID

        if let loaded, !loaded.presets.isEmpty {
            initialPresets = loaded.presets
            initialActiveID = loaded.activeID
        } else {
            let seed = Preset.factoryDefault
            initialPresets = [seed]
            initialActiveID = seed.id
        }

        let midi = MIDIEngine()
        self.midi = midi
        self.presets = initialPresets
        self.activePresetID = initialActiveID
        self.dialLibrary = DialLibraryStore.load()

        let active = initialPresets.first { $0.id == initialActiveID } ?? initialPresets[0]
        self.motion = MotionEngine(midi: midi, preset: active)
        self.motion.start()

        // Feedback in: the engine parses on its own thread and calls this on
        // the main queue; the Task hop satisfies @MainActor isolation.
        midi.onControlChangeReceived = { [weak self] channel, cc, value in
            Task { @MainActor in
                self?.handleIncomingCC(channel: channel, cc: cc, value: value)
            }
        }
    }

    // MARK: - Active preset
    //
    // Everything in the app still reads and writes `app.preset`, exactly as
    // it did when there was only one. The difference is that this now reads
    // and writes through the library. Because the setter mutates the
    // @Published `presets` array, SwiftUI bindings like
    // `$app.preset.xyPad.glide` keep working untouched.

    var preset: Preset {
        get {
            presets.first { $0.id == activePresetID }
                ?? presets.first
                ?? .factoryDefault
        }
        set {
            guard let index = presets.firstIndex(where: { $0.id == activePresetID }) else { return }
            var updated = newValue
            updated.id = activePresetID   // an edit must never change identity
            presets[index] = updated
            motion.preset = updated
        }
    }

    /// Most recently used first — the order the picker shows.
    var presetsByRecency: [Preset] {
        presets.sorted { $0.lastUsed > $1.lastUsed }
    }

    func calibrate() {
        preset.calibration = motion.captureCalibration()
    }

    /// Restores factory values for the ACTIVE preset, keeping its identity
    /// and name so the picker entry and any dial link stay put.
    func resetActivePresetToDefault() {
        var fresh = Preset.factoryDefault
        fresh.id = preset.id
        fresh.name = preset.name
        fresh.lastUsed = Date()
        preset = fresh
    }

    // MARK: - Preset management

    func activatePreset(_ id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].lastUsed = Date()
        activePresetID = id
        motion.preset = presets[index]
    }

    @discardableResult
    func createPreset(named name: String) -> UUID {
        var new = Preset.factoryDefault
        new.name = uniqueName(from: name, ifEmpty: "New Preset")
        new.lastUsed = Date()
        presets.append(new)
        activatePreset(new.id)
        return new.id
    }

    /// Copies the active preset wholesale. Nested ids (mappings, buttons)
    /// are intentionally carried over — they're only ever resolved within
    /// their own preset, so the copy's glide-toggle button assignment keeps
    /// pointing at the copy's own button.
    @discardableResult
    func duplicateActivePreset() -> UUID {
        var copy = preset
        copy.id = UUID()
        copy.name = uniqueName(from: preset.name + " Copy", ifEmpty: "Copy")
        copy.lastUsed = Date()
        presets.append(copy)
        activatePreset(copy.id)
        return copy.id
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets[index].name = trimmed
    }

    /// Permanent. Refuses to remove the last preset so the app always has
    /// something active.
    func deletePreset(_ id: UUID) {
        guard presets.count > 1,
              let index = presets.firstIndex(where: { $0.id == id }) else { return }

        let wasActive = (id == activePresetID)
        presets.remove(at: index)

        if wasActive, let next = presetsByRecency.first {
            activatePreset(next.id)
        }
    }

    /// Appends a numeric suffix if the name is already taken, so the picker
    /// never shows two identical rows.
    private func uniqueName(from proposed: String, ifEmpty fallback: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        guard presets.contains(where: { $0.name == base }) else { return base }

        var suffix = 2
        while presets.contains(where: { $0.name == "\(base) \(suffix)" }) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func persistPresets() {
        PresetLibraryStore.save(presets: presets, activeID: activePresetID)
    }

    // MARK: - Stepped dial

    /// The dial currently shown on the deck: the linked library preset if
    /// the link resolves, otherwise this preset's own local dial.
    var activeDial: DialPreset {
        if let id = preset.linkedDialPresetID,
           let shared = dialLibrary.first(where: { $0.id == id }) {
            return shared
        }
        return preset.dial
    }

    /// True when the on-screen dial is a shared library preset.
    var dialIsLinked: Bool {
        guard let id = preset.linkedDialPresetID else { return false }
        return dialLibrary.contains { $0.id == id }
    }

    /// Mutate the active dial wherever it actually lives — the shared
    /// library entry when linked, the preset's local dial otherwise.
    /// A dangling link (library entry deleted) falls back to local.
    func updateActiveDial(_ mutate: (inout DialPreset) -> Void) {
        if let id = preset.linkedDialPresetID {
            if let index = dialLibrary.firstIndex(where: { $0.id == id }) {
                mutate(&dialLibrary[index])
                return
            }
            preset.linkedDialPresetID = nil   // dangling link — heal it
        }
        mutate(&preset.dial)
    }

    /// Select a dial step: persist the position, then fire every action the
    /// step carries. Actions are stored in kind order, so a step that both
    /// sends MIDI and changes a pad parameter always does so in the same
    /// sequence.
    func selectDialStep(_ index: Int) {
        let dial = activeDial
        guard dial.steps.indices.contains(index) else { return }
        updateActiveDial { $0.currentStepIndex = index }
        for action in dial.steps[index].actions {
            perform(action, dialChannel: dial.channel)
        }
    }

    /// Execute one dial action.
    func perform(_ action: DialAction, dialChannel: Int) {
        switch action {
        case .sendCC(let cc, let value, let channelOverride):
            midi.controlChange(cc, value: value,
                               channel: channelOverride ?? dialChannel)
        case .sendProgramChange(let program, let channelOverride):
            midi.programChange(program,
                               channel: channelOverride ?? dialChannel)
        case .setRootNote(let n):
            preset.xyPad.rootNote = min(max(n, 0), 120)
        case .setScale(let s):
            preset.xyPad.scale = s
        case .toggleGlide:
            preset.xyPad.glide.toggle()
        case .togglePerpVelocity:
            preset.xyPad.perpToVelocity.toggle()
        case .setFixedVelocity(let v):
            preset.xyPad.fixedVelocity = min(max(v, 1), 127)
        case .setVoiceCount(let n):
            preset.xyPad.voiceCount = min(max(n, 1), 3)
        case .setNoteRange(let r):
            preset.xyPad.rangeSemitones = min(max(r, 1), 60)

        case .setFaderCC:
            // Intentionally does nothing. This action is DECLARATIVE — it
            // states which CC the fader represents while this step is
            // selected, and `faderAssignment` reads it straight off the step.
            // Transmitting here would break the rule that selecting a step
            // never sends a fader message.
            break
        }
    }

    // MARK: - Fader (assignment follows the selected dial step)

    /// Identity of one controllable parameter: channel + controller number.
    /// Feedback matching uses BOTH, so a value arriving for ch1/CC21 can
    /// never land on a step assigned ch1/CC20 or ch2/CC21.
    struct CCKey: Hashable {
        let channel: Int
        let cc: Int
    }

    /// Session cache of the last KNOWN value per assignment — written by
    /// user fader movement and by incoming feedback, for inactive steps as
    /// much as the active one, so every step's value is ready the moment
    /// the dial returns to it. Deliberately not persisted: stale values
    /// from a previous session would masquerade as the host's live state.
    @Published var faderValueCache: [CCKey: Int] = [:]

    /// The active step's fader assignment. Two sources, in priority order:
    ///
    ///   1. An explicit **Fader Control** action — the step says outright
    ///      which CC the fader drives, independent of what else it does.
    ///   2. Otherwise its **Send CC** action, so steps configured before
    ///      Fader Control existed keep behaving exactly as they did.
    ///
    /// Read declaratively from the step rather than cached in a variable
    /// that `perform()` writes: a cached override would go stale the moment
    /// you selected a step that didn't set one, leaving the fader pointed at
    /// the previous step's CC.
    var faderAssignment: (key: CCKey, storedValue: Int)? {
        guard let step = activeDial.currentStep else { return nil }

        if case .setFaderCC(let cc, let defaultValue, let channelOverride)?
            = step.action(ofKind: .faderCC) {
            let key = CCKey(channel: channelOverride ?? activeDial.channel, cc: cc)
            return (key, defaultValue)
        }

        if case .sendCC(let cc, let value, let channelOverride)?
            = step.action(ofKind: .cc) {
            let key = CCKey(channel: channelOverride ?? activeDial.channel, cc: cc)
            return (key, value)
        }

        return nil
    }

    /// What the fader shows, fully DERIVED — never separately stored, so
    /// there is no second copy to fall out of sync:
    ///   1. cached feedback/user value for the assignment, else
    ///   2. the step's own stored Send CC value (the app already has it), else
    ///   3. nil — no Send CC on this step; the fader renders disabled.
    /// Because this recomputes when the selected step changes, "recall on
    /// step change" needs no code at all, and repositioning is inherently
    /// silent.
    var faderDisplayedValue: Int? {
        guard let assignment = faderAssignment else { return nil }
        return faderValueCache[assignment.key] ?? assignment.storedValue
    }

    /// USER fader movement — the ONLY path anywhere that transmits the
    /// fader's CC. Incoming feedback and step changes touch only the cache
    /// and derived state above, so loops are prevented structurally rather
    /// than by timing.
    func faderMoved(to rawValue: Int) {
        guard let assignment = faderAssignment else { return }
        let value = min(max(rawValue, 0), 127)
        guard value != faderDisplayedValue else { return }   // no repeats
        faderValueCache[assignment.key] = value
        midi.controlChange(assignment.key.cc, value: value,
                           channel: assignment.key.channel)
    }

    /// Incoming feedback (e.g. Loopy Pro echoing a parameter move). Cache
    /// only — if the assignment is currently selected the fader follows via
    /// `faderDisplayedValue`; if not, the value waits for its step. Nothing
    /// here can transmit.
    func handleIncomingCC(channel: Int, cc: Int, value: Int) {
        faderValueCache[CCKey(channel: channel, cc: cc)] = min(max(value, 0), 127)
    }

    // MARK: - Dial library management

    /// Copy the active dial into the shared library and link to the copy.
    func saveActiveDialToLibrary() {
        var copy = activeDial
        copy.id = UUID()
        if dialIsLinked { copy.name += " Copy" }
        dialLibrary.append(copy)
        preset.linkedDialPresetID = copy.id
    }

    func linkDial(to id: UUID?) {
        preset.linkedDialPresetID = id
    }

    func deleteDialPresets(at offsets: IndexSet) {
        let removedIDs = offsets.map { dialLibrary[$0].id }
        dialLibrary.remove(atOffsets: offsets)
        if let linked = preset.linkedDialPresetID,
           removedIDs.contains(linked) {
            preset.linkedDialPresetID = nil   // fall back to local dial
        }
    }
}
