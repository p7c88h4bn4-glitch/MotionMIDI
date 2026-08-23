import Foundation
import Combine

/// Cross-surface notification constants.
///
/// Deliberately OUTSIDE `AppState`, which is `@MainActor`. Static members of
/// a main-actor-isolated type are themselves actor-isolated, and the closure
/// handed to `NotificationCenter.addObserver` is `@Sendable` — so reading
/// them from inside it is a concurrency violation ("main actor-isolated
/// static property can not be referenced from a Sendable closure"). Both
/// values are immutable and `Sendable`, so there is nothing for the actor to
/// protect; the isolation was incidental, inherited from where they happened
/// to be declared.
enum SurfaceSync {
    static let libraryDidChange = Notification.Name("MotionMIDIPro.libraryDidChange")
    static let surfaceKey = "surface"
}

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

    /// Which performer surface this instance drives. 0 is the primary.
    ///
    /// Two surfaces means two `AppState` objects, each injected into its own
    /// view subtree. Nothing in the view layer had to change for this: every
    /// view already reads `@EnvironmentObject var app: AppState`, so giving
    /// a subtree a different instance is enough to give it a different
    /// preset, dial, and set of buttons.
    let surface: Int

    /// Only the primary surface drives the motion engine.
    ///
    /// The engine is SHARED, so both surfaces show live meters, but it can
    /// only be pointed at one preset's mappings at a time. Letting the
    /// second surface repoint it would mean whichever surface was touched
    /// last silently stole gyro output from the other.
    var isPrimary: Bool { surface == 0 }

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - midi: Shared across surfaces on purpose. One engine means one
    ///     virtual MIDI port, so a host sees a single instrument rather than
    ///     one per surface, and both surfaces transmit down it.
    ///   - motion: Shared for the same reason, plus the hardware reason:
    ///     there is one gyroscope, and two `CMMotionManager` consumers is
    ///     wasted battery for identical numbers. Pass nil to have this
    ///     instance build and start its own.
    init(surface: Int = 0,
         midi sharedMIDI: MIDIEngine? = nil,
         motion sharedMotion: MotionEngine? = nil) {
        self.surface = surface

        let loaded = PresetLibraryStore.load(surface: surface)
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

        let midi = sharedMIDI ?? MIDIEngine()
        self.midi = midi
        self.presets = initialPresets
        self.activePresetID = initialActiveID
        self.dialLibrary = DialLibraryStore.load()

        let active = initialPresets.first { $0.id == initialActiveID } ?? initialPresets[0]

        if let sharedMotion {
            self.motion = sharedMotion
        } else {
            let engine = MotionEngine(midi: midi, preset: active)
            self.motion = engine
            engine.start()
        }

        // Feedback in: the engine parses on its own thread and calls this on
        // the main queue; the Task hop satisfies @MainActor isolation.
        //
        // Registered as an OBSERVER rather than assigned to a single
        // property, so a second surface adds itself alongside the first
        // instead of replacing it.
        midi.addControlChangeObserver { [weak self] channel, cc, value in
            Task { @MainActor in
                self?.handleIncomingCC(channel: channel, cc: cc, value: value)
            }
        }

        // The library is shared storage, so a write from the other surface
        // has to be picked up here — otherwise this instance keeps its stale
        // array and its next save silently reverts the other's edit.
        libraryObserver = NotificationCenter.default.addObserver(
            forName: SurfaceSync.libraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let sender = note.userInfo?[SurfaceSync.surfaceKey] as? Int
            guard sender != self.surface else { return }
            Task { @MainActor in self.reloadLibraryFromStore() }
        }
    }

    deinit {
        if let libraryObserver {
            NotificationCenter.default.removeObserver(libraryObserver)
        }
    }

    // MARK: - Cross-surface library sync

    /// `nonisolated(unsafe)` because `deinit` is not actor-isolated and has
    /// to read this to unregister. Safe in practice: it is written once
    /// during `init` and read once during `deinit`, with no window in which
    /// two threads could touch it.
    nonisolated(unsafe) private var libraryObserver: NSObjectProtocol?

    /// True while applying another surface's write, so re-persisting from
    /// the resulting `didSet` can't bounce a notification back and forth.
    private var applyingRemoteLibraryChange = false

    private func reloadLibraryFromStore() {
        guard let loaded = PresetLibraryStore.load(surface: surface),
              !loaded.presets.isEmpty else { return }

        applyingRemoteLibraryChange = true
        presets = loaded.presets
        // This surface's own active preset is deliberately left alone: the
        // other surface changing which preset IT is on must not drag this
        // one along with it.
        if !presets.contains(where: { $0.id == activePresetID }) {
            activePresetID = loaded.activeID
        }
        applyingRemoteLibraryChange = false
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
            // Only the primary surface points the shared motion engine at
            // its preset — see `isPrimary`.
            if isPrimary { motion.preset = updated }
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
        if isPrimary { motion.preset = presets[index] }
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

    @discardableResult
    func duplicateActivePreset(named newName: String? = nil) -> UUID {
        var copy = preset
        copy.id = UUID()
        copy.name = uniqueName(from: newName ?? (preset.name + " Copy"), ifEmpty: "Copy")
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
        PresetLibraryStore.save(presets: presets,
                                activeID: activePresetID,
                                surface: surface)

        // Don't echo a change that came FROM the other surface; it already
        // has it, and bouncing it back would have the two overwriting each
        // other in a loop.
        guard !applyingRemoteLibraryChange else { return }

        NotificationCenter.default.post(
            name: SurfaceSync.libraryDidChange,
            object: nil,
            userInfo: [SurfaceSync.surfaceKey: surface]
        )
    }

    // MARK: - Stepped dial(s)
    //
    // Every dial-related call now takes a `slot` index into
    // `preset.dialSlots`. iPhone always passes 0. iPad passes whichever
    // slot's dial/fader pair the person is touching. The shared library
    // (`dialLibrary`) is unchanged — any slot in any preset can still link
    // to a shared entry, independent of every other slot.

    /// The dial shown for a given slot: the linked library preset if the
    /// link resolves, otherwise that slot's own local dial. Out-of-range
    /// slot indices (e.g. a stale view after a slot was deleted) fall back
    /// to slot 0 rather than crashing.
    func dial(at slot: Int) -> DialPreset {
        guard preset.dialSlots.indices.contains(slot) else {
            return preset.dialSlots.first?.localDial ?? .factory
        }
        let entry = preset.dialSlots[slot]
        if let id = entry.linkedDialPresetID,
           let shared = dialLibrary.first(where: { $0.id == id }) {
            return shared
        }
        return entry.localDial
    }

    /// True when the given slot's on-screen dial is a shared library preset.
    func dialIsLinked(at slot: Int) -> Bool {
        guard preset.dialSlots.indices.contains(slot),
              let id = preset.dialSlots[slot].linkedDialPresetID else { return false }
        return dialLibrary.contains { $0.id == id }
    }

    /// Mutate a slot's dial wherever it actually lives — the shared library
    /// entry when linked, that slot's local dial otherwise. A dangling link
    /// (library entry deleted elsewhere) heals back to local.
    func updateDial(at slot: Int, _ mutate: (inout DialPreset) -> Void) {
        guard preset.dialSlots.indices.contains(slot) else { return }
        if let id = preset.dialSlots[slot].linkedDialPresetID {
            if let index = dialLibrary.firstIndex(where: { $0.id == id }) {
                mutate(&dialLibrary[index])
                return
            }
            preset.dialSlots[slot].linkedDialPresetID = nil   // heal
        }
        mutate(&preset.dialSlots[slot].localDial)
    }

    /// Select a step on a given slot's dial: persist the position, then fire
    /// every action the step carries, in the order they're stored.
    func selectDialStep(at slot: Int, _ stepIndex: Int) {
        let d = dial(at: slot)
        guard d.steps.indices.contains(stepIndex) else { return }
        updateDial(at: slot) { $0.currentStepIndex = stepIndex }
        for action in d.steps[stepIndex].actions {
            perform(action, dialChannel: d.channel)
        }
    }

    /// Appends a new dial+fader slot (iPad only, in practice — see
    /// `ControlDeckView`). No upper limit; the row that displays these
    /// scrolls horizontally once they no longer fit.
    func addDialSlot() {
        preset.dialSlots.append(DialSlot())
    }

    /// Removes a slot. Refuses to remove the last one, same guard as preset
    /// deletion, so there's always at least slot 0 for iPhone to show.
    func removeDialSlot(at slot: Int) {
        guard preset.dialSlots.count > 1,
              preset.dialSlots.indices.contains(slot) else { return }
        preset.dialSlots.remove(at: slot)
    }

    /// Execute one dial action.
    ///
    /// `dialChannel` is no longer consulted for the MIDI cases — every
    /// sending action now carries its own channel outright, resolved at load
    /// time for presets written before the change. It stays in the signature
    /// because callers pass it and a future action kind may want it.
    func perform(_ action: DialAction, dialChannel: Int) {
        switch action {
        case .sendCC(let cc, let value, let channel):
            midi.controlChange(cc, value: value, channel: channel)
        case .sendProgramChange(let program, let channel):
            midi.programChange(program, channel: channel)
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

    /// A slot's active step's fader assignment. Two sources, in priority
    /// order:
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
    ///
    /// The cache itself (`faderValueCache`) stays keyed by CC identity only,
    /// shared across every slot and every preset — if two slots happen to
    /// point at the same channel/CC, they show the same live value, which
    /// is the correct behavior for "this is the same host parameter".
    func faderAssignment(at slot: Int) -> (key: CCKey, storedValue: Int)? {
        let d = dial(at: slot)
        guard let step = d.currentStep else { return nil }

        if case .setFaderCC(let cc, let defaultValue, let channel)?
            = step.action(ofKind: .faderCC) {
            return (CCKey(channel: channel, cc: cc), defaultValue)
        }

        if case .sendCC(let cc, let value, let channel)?
            = step.action(ofKind: .cc) {
            return (CCKey(channel: channel, cc: cc), value)
        }

        return nil
    }

    /// What a slot's fader shows, fully DERIVED — never separately stored:
    ///   1. cached feedback/user value for the assignment, else
    ///   2. the step's own stored Send CC value, else
    ///   3. nil — no Send CC on this step; the fader renders disabled.
    /// Because this recomputes when the selected step changes, "recall on
    /// step change" needs no code at all, and repositioning is inherently
    /// silent.
    func faderDisplayedValue(at slot: Int) -> Int? {
        guard let assignment = faderAssignment(at: slot) else { return nil }
        return faderValueCache[assignment.key] ?? assignment.storedValue
    }

    /// USER fader movement — the ONLY path anywhere that transmits a
    /// fader's CC. Incoming feedback and step changes touch only the cache
    /// and derived state above, so loops are prevented structurally rather
    /// than by timing.
    func faderMoved(at slot: Int, to rawValue: Int) {
        guard let assignment = faderAssignment(at: slot) else { return }
        let value = min(max(rawValue, 0), 127)
        guard value != faderDisplayedValue(at: slot) else { return }   // no repeats
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

    /// Copy a slot's active dial into the shared library and link that slot
    /// to the copy.
    func saveDialToLibrary(at slot: Int) {
        guard preset.dialSlots.indices.contains(slot) else { return }
        var copy = dial(at: slot)
        copy.id = UUID()
        if dialIsLinked(at: slot) { copy.name += " Copy" }
        dialLibrary.append(copy)
        preset.dialSlots[slot].linkedDialPresetID = copy.id
    }

    func linkDial(at slot: Int, to id: UUID?) {
        guard preset.dialSlots.indices.contains(slot) else { return }
        preset.dialSlots[slot].linkedDialPresetID = id
    }

    /// Removing a shared preset can dangle links in ANY slot of the active
    /// preset (not just one), so every slot is checked and healed back to
    /// its local dial.
    func deleteDialPresets(at offsets: IndexSet) {
        let removedIDs = offsets.map { dialLibrary[$0].id }
        dialLibrary.remove(atOffsets: offsets)
        for index in preset.dialSlots.indices {
            if let linked = preset.dialSlots[index].linkedDialPresetID,
               removedIDs.contains(linked) {
                preset.dialSlots[index].linkedDialPresetID = nil
            }
        }
    }
}
