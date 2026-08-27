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

        // Dials persist their position, so on launch they already sit on
        // steps whose declarations apply. Without this the pad would start on
        // master values and only snap to the dial's real state after the
        // first turn.
        refreshPadOverrides()

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
        // Before anything else: the outgoing preset's latched buttons are
        // still holding messages on the host, and in a moment their buttons
        // will be gone.
        releaseAllButtonLatches()

        activePresetID = id
        if isPrimary { motion.preset = presets[index] }
        // The incoming preset has its own dials on their own steps. Without
        // this the outgoing preset's overrides would linger and silently
        // reshape the pad just switched to.
        refreshPadOverrides()
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
        // What this step declares takes effect now, and what the PREVIOUS
        // step declared stops applying — including parameters this step says
        // nothing about, which revert to master.
        refreshPadOverrides()
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

        case .toggleGlide:
            // Toggles genuinely MUTATE the master, and should: "flip glide"
            // has no meaning as a value to hold and later revert. Selecting
            // the step flips it and it stays flipped.
            preset.xyPad.glide.toggle()
        case .togglePerpVelocity:
            preset.xyPad.perpToVelocity.toggle()

        case .setRootNote, .setScale, .setFixedVelocity,
             .setVoiceCount, .setNoteRange:
            // DECLARATIVE, exactly like `.setFaderCC` below. These describe
            // what the pad looks like while their step is selected;
            // `refreshPadOverrides()` reads them off the step instead of
            // writing them here. Writing them here is what used to destroy
            // the preset's own scale on the first turn of the dial.
            break

        case .setFaderCC:
            // Intentionally does nothing. This action is DECLARATIVE — it
            // states which CC the fader represents while this step is
            // selected, and `faderAssignment` reads it straight off the step.
            // Transmitting here would break the rule that selecting a step
            // never sends a fader message.
            break
        }
    }

    // MARK: - CC map

    /// Every CC this preset assigns, resolved through the dial library so
    /// linked dials report the numbers they actually send.
    var ccAssignments: [CCAssignment] {
        preset.ccAssignments(dialLibrary: dialLibrary)
    }

    /// Write a new number into whichever place the slot names.
    ///
    /// Routing dial writes through `updateDial(at:)` rather than touching
    /// `preset.dialSlots` directly is what makes this correct for a slot
    /// linked to a shared library dial — that helper already knows to edit
    /// the library copy, and going around it would silently write to a local
    /// dial the slot isn't even showing.
    func setCC(_ slot: CCSlot, to value: Int) {
        let cc = min(max(value, 0), 127)

        switch slot {
        case .motion(let id):
            guard let i = preset.motionMappings.firstIndex(where: { $0.id == id })
            else { return }
            preset.motionMappings[i].cc = cc

        case .xyX:
            preset.xyPad.xCC = cc
        case .xyY:
            preset.xyPad.yCC = cc

        case .morphCorner(let i):
            guard preset.xyPad.morphCorners.indices.contains(i) else { return }
            preset.xyPad.morphCorners[i].cc = cc

        case .drawbar(let i):
            guard preset.xyPad.drawbars.indices.contains(i) else { return }
            preset.xyPad.drawbars[i].cc = cc

        case .button(let id):
            guard let i = preset.buttons.firstIndex(where: { $0.id == id })
            else { return }
            // A latched button about to change number has to let go of the
            // old one first, or the off message lands somewhere else and the
            // original is left holding.
            if isButtonLatched(id) {
                emitButton(preset.buttons[i], on: false)
                clearButtonLatch(id)
            }
            preset.buttons[i].cc = cc

        case .dialSend(let slotIndex, let stepIndex, let actionIndex):
            updateDial(at: slotIndex) { dial in
                guard dial.steps.indices.contains(stepIndex),
                      dial.steps[stepIndex].actions.indices.contains(actionIndex),
                      case .sendCC(_, let value, let channel) =
                        dial.steps[stepIndex].actions[actionIndex]
                else { return }
                dial.steps[stepIndex].actions[actionIndex] =
                    .sendCC(cc: cc, value: value, channel: channel)
            }

        case .dialFader(let slotIndex, let stepIndex, let actionIndex):
            updateDial(at: slotIndex) { dial in
                guard dial.steps.indices.contains(stepIndex),
                      dial.steps[stepIndex].actions.indices.contains(actionIndex),
                      case .setFaderCC(_, let defaultValue, let channel) =
                        dial.steps[stepIndex].actions[actionIndex]
                else { return }
                dial.steps[stepIndex].actions[actionIndex] =
                    .setFaderCC(cc: cc, defaultValue: defaultValue, channel: channel)
            }

        case .portamentoTime, .portamentoSwitch:
            // Fixed by the MIDI spec. Reaching here means a locked row was
            // made editable by mistake; do nothing rather than write a
            // number a synth will never look for.
            return
        }
    }

    /// Change the MIDI channel of whatever the slot names.
    ///
    /// Mirrors `setCC` exactly, including routing dial writes through
    /// `updateDial(at:)` so a slot linked to a shared library dial is edited
    /// in the library rather than in a local copy it isn't showing.
    func setChannel(_ slot: CCSlot, to newChannel: Int) {
        let channel = min(max(newChannel, 0), 15)

        switch slot {
        case .motion(let id):
            guard let i = preset.motionMappings.firstIndex(where: { $0.id == id })
            else { return }
            preset.motionMappings[i].channel = channel

        case .xyX:
            preset.xyPad.xChannel = channel
        case .xyY:
            preset.xyPad.yChannel = channel

        case .morphCorner(let i):
            guard preset.xyPad.morphCorners.indices.contains(i) else { return }
            preset.xyPad.morphCorners[i].channel = channel

        case .drawbar(let i):
            guard preset.xyPad.drawbars.indices.contains(i) else { return }
            preset.xyPad.drawbars[i].channel = channel

        case .button(let id):
            guard let i = preset.buttons.firstIndex(where: { $0.id == id })
            else { return }
            // A latched button changing channel has to let go on the OLD one
            // first, or the off message goes somewhere else and the original
            // is left holding.
            if isButtonLatched(id) {
                emitButton(preset.buttons[i], on: false)
                clearButtonLatch(id)
            }
            preset.buttons[i].channel = channel

        case .dialSend(let slotIndex, let stepIndex, let actionIndex):
            updateDial(at: slotIndex) { dial in
                guard dial.steps.indices.contains(stepIndex),
                      dial.steps[stepIndex].actions.indices.contains(actionIndex),
                      case .sendCC(let cc, let value, _) =
                        dial.steps[stepIndex].actions[actionIndex]
                else { return }
                dial.steps[stepIndex].actions[actionIndex] =
                    .sendCC(cc: cc, value: value, channel: channel)
            }

        case .dialFader(let slotIndex, let stepIndex, let actionIndex):
            updateDial(at: slotIndex) { dial in
                guard dial.steps.indices.contains(stepIndex),
                      dial.steps[stepIndex].actions.indices.contains(actionIndex),
                      case .setFaderCC(let cc, let defaultValue, _) =
                        dial.steps[stepIndex].actions[actionIndex]
                else { return }
                dial.steps[stepIndex].actions[actionIndex] =
                    .setFaderCC(cc: cc, defaultValue: defaultValue, channel: channel)
            }

        case .portamentoTime, .portamentoSwitch:
            return
        }
    }

    /// Rename whatever the slot names.
    ///
    /// An empty string is stored as empty and MEANS "use the default" — the
    /// map shows the default as placeholder text rather than a blank row, so
    /// clearing a field reverts instead of leaving something nameless.
    ///
    /// Dial rows rename the STEP, which is the same label the knob face
    /// shows. A step carrying both a send and a fader action appears as two
    /// rows in the map, and renaming either renames both, because there is
    /// one label underneath. That is worth knowing before you use the map to
    /// tell two rows of the same step apart — you can't.
    func setName(_ slot: CCSlot, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)

        switch slot {
        case .motion(let id):
            guard let i = preset.motionMappings.firstIndex(where: { $0.id == id })
            else { return }
            preset.motionMappings[i].name = trimmed

        case .xyX:
            preset.xyPad.xAxisName = trimmed
        case .xyY:
            preset.xyPad.yAxisName = trimmed

        case .morphCorner(let i):
            guard preset.xyPad.morphCorners.indices.contains(i) else { return }
            preset.xyPad.morphCorners[i].label = trimmed

        case .drawbar(let i):
            guard preset.xyPad.drawbars.indices.contains(i) else { return }
            preset.xyPad.drawbars[i].name = trimmed.isEmpty ? nil : trimmed

        case .button(let id):
            guard let i = preset.buttons.firstIndex(where: { $0.id == id })
            else { return }
            preset.buttons[i].name = trimmed

        case .dialSend(let slotIndex, let stepIndex, _),
             .dialFader(let slotIndex, let stepIndex, _):
            updateDial(at: slotIndex) { dial in
                guard dial.steps.indices.contains(stepIndex) else { return }
                dial.steps[stepIndex].label = trimmed
            }

        case .portamentoTime, .portamentoSwitch:
            return
        }
    }

    /// Wiggle one CC so a host's MIDI Learn can catch it.
    ///
    /// Sends bottom, top, then the assignment's resting value. Three
    /// messages rather than one because learn implementations differ: some
    /// latch onto the first CC they see, others want to watch a control
    /// MOVE before they will bind it, and a single message loses the second
    /// kind. The spread is small enough to read as one gesture.
    ///
    /// Ending on `rest` matters. A sweep moves whatever is already listening
    /// on that number, so stopping at 127 would leave a filter wide open or
    /// a send fully up; stopping where the assignment would naturally sit
    /// puts it back.
    ///
    /// Deliberately NOT debounced or queued. Tapping several in a row sends
    /// several sweeps, which is what you want when teaching a host one
    /// control after another.
    func sendForLearn(cc: Int, channel: Int, rest: Int) {
        let ch = min(max(channel, 0), 15)
        let restValue = min(max(rest, 0), 127)

        midi.controlChange(cc, value: 0, channel: ch)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            midi.controlChange(cc, value: 127, channel: ch)
            try? await Task.sleep(nanoseconds: 50_000_000)
            midi.controlChange(cc, value: restValue, channel: ch)
        }
    }

    /// Lowest CC no assignment in this preset is using.
    ///
    /// Walks the spec-undefined numbers first, in the order they become
    /// useful, and only then falls back to any free number at all. Returns
    /// nil when all 128 are spoken for, so the caller can say so rather than
    /// hand out a duplicate and call it an allocation.
    func firstFreeCC() -> Int? {
        // Only numbers taken on the DEFAULT channel block a new assignment;
        // the same number on another channel is not a conflict.
        let taken = Set(ccAssignments
            .filter { $0.channel == MIDIDefaults.channel }
            .map(\.cc))
        let preferred = [9, 14, 15, 3] + Array(20...31)
                        + Array(85...90) + Array(102...119)
        if let free = preferred.first(where: { !taken.contains($0) }) { return free }
        return (0...127).first { !taken.contains($0) }
    }

    // MARK: - Latching buttons

    /// Buttons currently latched ON by a `.toggle` press.
    ///
    /// Held in AppState, not as `@State` inside `PadButton`, for two
    /// reasons. A latched button is a message already on the wire that
    /// something still has to take back, so the state has to outlive any
    /// view that might be torn down and rebuilt — and a stuck note is the
    /// failure mode if it doesn't. It also has to be reachable when the
    /// preset changes, so the outgoing preset's latches can be released
    /// rather than left hanging on the host with no button left to press.
    ///
    /// Not persisted. On a fresh launch nothing is holding anything, so a
    /// restored latch would be a lie about the state of the receiver.
    @Published private(set) var latchedButtons: Set<UUID> = []

    func isButtonLatched(_ id: UUID) -> Bool {
        latchedButtons.contains(id)
    }

    /// Flip a latching button and return the state it landed in, so the
    /// caller knows which message to send.
    func toggleButtonLatch(_ id: UUID) -> Bool {
        if latchedButtons.contains(id) {
            latchedButtons.remove(id)
            return false
        } else {
            latchedButtons.insert(id)
            return true
        }
    }

    /// Send the "off" half for every latched button and clear them.
    ///
    /// Called before the preset changes. Without it, a latched Note On would
    /// have no Note Off coming — the note would sound until the host was
    /// restarted, and the button that could have released it no longer
    /// exists on screen.
    func releaseAllButtonLatches() {
        guard !latchedButtons.isEmpty else { return }
        for button in preset.buttons where latchedButtons.contains(button.id) {
            emitButton(button, on: false)
        }
        latchedButtons.removeAll()
    }

    /// Clear a single latch without sending anything.
    ///
    /// For the editor: changing a button away from `.toggle` while it is lit
    /// should not leave a latch behind that nothing can now clear.
    func clearButtonLatch(_ id: UUID) {
        latchedButtons.remove(id)
    }

    /// Put one button's message on the wire.
    ///
    /// Takes the mapping by VALUE rather than looking it up by id, so a
    /// delayed or deferred send uses what was on screen when it was queued.
    /// Re-reading the preset later could pair a Note On with a Note Off for
    /// a different note, leaving the first stuck on with nothing left to
    /// release it.
    func emitButton(_ mapping: ButtonMapping, on: Bool) {
        switch mapping.message {
        case .note:
            if on {
                midi.noteOn(mapping.note,
                            velocity: max(mapping.onValue, 1),
                            channel: mapping.channel)
            } else {
                midi.noteOff(mapping.note, channel: mapping.channel)
            }
        case .cc:
            midi.controlChange(mapping.cc,
                               value: on ? mapping.onValue : mapping.offValue,
                               channel: mapping.channel)
        }
    }

    // MARK: - Master values vs. dial overrides

    /// What the selected dial steps are currently holding away from the
    /// preset's own values. Transient by design: never encoded, never
    /// persisted, rebuilt from the dials whenever they move.
    @Published private(set) var padOverrides = XYPadOverrides()

    /// The pad config to PLAY — master values with any dial overrides on top.
    ///
    /// The performance surface reads this. The config sheet keeps editing
    /// `preset.xyPad` directly, so it always shows and edits the master,
    /// which is what you want: editing a value you can see being overridden
    /// should change what it returns TO.
    var livePad: XYPadConfig {
        padOverrides.applied(to: preset.xyPad)
    }

    /// Set the master scale from a live control (the on-pad chip).
    ///
    /// Clears any scale override too. Without that, changing key mid-set
    /// while a dial step happened to be holding a scale would edit the
    /// master, produce no audible change, and look broken. An explicit touch
    /// wins — until the dial next moves and re-asserts.
    func setMasterScale(_ scale: Scale) {
        preset.xyPad.scale = scale
        if padOverrides.scale != nil { padOverrides.scale = nil }
    }

    /// Clear a range override after the master range is edited directly.
    ///
    /// Same rule as `setMasterScale`: an explicit edit should be audible
    /// straight away rather than sitting behind a dial step that happens to
    /// be holding a different range.
    func clearRangeOverride() {
        if padOverrides.rangeSemitones != nil { padOverrides.rangeSemitones = nil }
    }

    /// Master root note, same rule as `setMasterScale`.
    func setMasterRootNote(_ note: Int) {
        preset.xyPad.rootNote = min(max(note, 0), 120)
        if padOverrides.rootNote != nil { padOverrides.rootNote = nil }
    }

    /// Rebuild the override set from every dial's currently selected step.
    ///
    /// Reads ALL slots, not just the one that moved, because each dial can
    /// hold its own overrides at once. Later slots win a conflict: if two
    /// dials both name a scale, the rightmost is the one you hear. Arbitrary,
    /// but it has to be one of them, and "the last one you set up" is the
    /// more predictable rule.
    func refreshPadOverrides() {
        var next = XYPadOverrides()

        for slot in preset.dialSlots.indices {
            guard let step = dial(at: slot).currentStep else { continue }
            for action in step.actions {
                switch action {
                case .setScale(let s):          next.scale = s
                case .setRootNote(let n):       next.rootNote = n
                case .setFixedVelocity(let v):  next.fixedVelocity = v
                case .setVoiceCount(let n):     next.voiceCount = n
                case .setNoteRange(let r):      next.rangeSemitones = r
                default:                        break
                }
            }
        }

        // Guarded so an unchanged rebuild doesn't publish a no-op and redraw
        // the pad on every dial event.
        if next != padOverrides { padOverrides = next }
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
