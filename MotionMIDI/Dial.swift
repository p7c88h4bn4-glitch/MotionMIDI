import Foundation

// MARK: - Dial step actions

/// Everything one dial step can do when selected. MIDI actions go out the
/// wire; parameter actions reach into the current preset's XY pad config.
///
/// ── Channels ────────────────────────────────────────────────────────────
/// The three MIDI actions carry a PLAIN channel, not an optional override.
/// They used to store `channelOverride: Int?` behind an "Override Channel"
/// toggle, which meant a step's real channel could only be worked out by
/// checking whether the toggle was on and then looking up the dial's own
/// channel underneath. Now the number on the step is the number it sends on.
///
/// Presets saved before the change still load — see the hand-written
/// `Codable` below, and `DialPreset.init(from:)`, which together resolve a
/// legacy "inherit" into the dial's channel exactly once.
enum DialAction: Equatable {
    /// Send a CC with a fixed value on `channel`.
    case sendCC(cc: Int, value: Int, channel: Int)
    /// Send a Program Change on `channel`.
    case sendProgramChange(program: Int, channel: Int)
    /// Set the XY pad's root note.
    case setRootNote(Int)
    /// Set the XY pad's scale.
    case setScale(Scale)
    /// Flip the XY pad's glide (legato portamento) on/off.
    case toggleGlide
    /// Flip the XY pad's perpendicular→velocity mapping on/off.
    case togglePerpVelocity
    /// Set the XY pad's fixed velocity.
    case setFixedVelocity(Int)
    /// Set the XY pad's voice count (1, 2, or 3).
    case setVoiceCount(Int)
    /// Set the XY pad's note range in semitones.
    case setNoteRange(Int)
    /// Point the compact fader at a CC while this step is selected.
    ///
    /// DECLARATIVE, not executable: selecting the step does not transmit
    /// anything. The fader follows live feedback when available; otherwise
    /// it keeps its existing on-screen position.
    case setFaderCC(cc: Int, channel: Int)

    /// Sentinel written by the decoder when an old preset said "inherit the
    /// dial's channel". `DialPreset.init(from:)` replaces every one of these
    /// with the dial's actual channel as soon as it is known, so a value
    /// this low never survives past load and never reaches the wire.
    static let inheritChannel = -1

    /// Short human-readable summary for list rows and the knob caption.
    var summary: String {
        switch self {
        case .sendCC(let cc, let value, let channel):
            return "CC\(cc) → \(value) ch\(channel + 1)"
        case .sendProgramChange(let program, let channel):
            return "PC \(program) ch\(channel + 1)"
        case .setRootNote(let n):
            return "Root → \(DialAction.noteName(n))"
        case .setScale(let s):
            return "Scale → \(s.label)"
        case .toggleGlide:
            return "Toggle glide"
        case .togglePerpVelocity:
            return "Toggle perp→vel"
        case .setFixedVelocity(let v):
            return "Velocity → \(v)"
        case .setVoiceCount(let n):
            return "Voices → \(n)"
        case .setNoteRange(let r):
            return "Range → \(r)s"
        case .setFaderCC(let cc, let channel):
            return "Fader → CC\(cc) ch\(channel + 1)"
        }
    }

    /// The channel this action transmits on, or nil for actions that send
    /// nothing.
    var channel: Int? {
        switch self {
        case .sendCC(_, _, let channel):          return channel
        case .sendProgramChange(_, let channel):  return channel
        case .setFaderCC(_, let channel):         return channel
        default:                                  return nil
        }
    }

    /// The same action with its channel replaced. Actions that don't send
    /// are returned untouched.
    func withChannel(_ newChannel: Int) -> DialAction {
        let clamped = min(max(newChannel, 0), 15)
        switch self {
        case .sendCC(let cc, let value, _):
            return .sendCC(cc: cc, value: value, channel: clamped)
        case .sendProgramChange(let program, _):
            return .sendProgramChange(program: program, channel: clamped)
        case .setFaderCC(let cc, _):
            return .setFaderCC(cc: cc, channel: clamped)
        default:
            return self
        }
    }

    static func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = min(max(n, 0), 127)
        return "\(names[clamped % 12])\(clamped / 12 - 1)"
    }
}

// MARK: - DialAction persistence

/// Hand-written rather than synthesized, for one reason: renaming
/// `channelOverride: Int?` to `channel: Int` changes the JSON the compiler
/// would generate, and a synthesized decoder meeting an old blob would
/// THROW. That throw does not stay local — `DialStep` decodes its actions
/// with `decodeIfPresent`, which still propagates a failure from a key that
/// is present but malformed, so the failure climbs through `DialPreset` and
/// `Preset` until `PresetLibraryStore.load()` catches it with `try?` and
/// returns nil. One renamed field would have silently emptied the entire
/// preset library on first launch.
///
/// The shape written here matches what the compiler used to synthesize
/// (outer container keyed by case name, inner container keyed by the
/// associated value labels, `_0` for unlabeled ones), so files written by
/// this build and by older builds are mutually readable.
extension DialAction: Codable {
    private enum CaseKey: String, CodingKey {
        case sendCC, sendProgramChange, setRootNote, setScale
        case toggleGlide, togglePerpVelocity, setFixedVelocity
        case setVoiceCount, setNoteRange, setFaderCC
    }

    private enum SendCCKeys: String, CodingKey {
        case cc, value, channel
        case channelOverride            // legacy, decode-only
    }

    private enum ProgramKeys: String, CodingKey {
        case program, channel
        case channelOverride            // legacy, decode-only
    }

    private enum FaderKeys: String, CodingKey {
        case cc, channel
        case defaultValue               // legacy, decode-only
        case channelOverride            // legacy, decode-only
    }

    /// Swift names an unlabeled associated value `_0` when it synthesizes
    /// Codable, and old files were written that way.
    private enum SingleKeys: String, CodingKey {
        case _0
    }

    private enum EmptyKeys: String, CodingKey {
        case unused
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CaseKey.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "No DialAction case found.")
            )
        }

        switch key {
        case .sendCC:
            let n = try c.nestedContainer(keyedBy: SendCCKeys.self, forKey: .sendCC)
            self = .sendCC(
                cc: try n.decodeIfPresent(Int.self, forKey: .cc) ?? MIDIDefaults.dialSendCC,
                value: try n.decodeIfPresent(Int.self, forKey: .value) ?? 64,
                channel: try Self.decodeChannel(n, current: .channel, legacy: .channelOverride)
            )

        case .sendProgramChange:
            let n = try c.nestedContainer(keyedBy: ProgramKeys.self, forKey: .sendProgramChange)
            self = .sendProgramChange(
                program: try n.decodeIfPresent(Int.self, forKey: .program) ?? 0,
                channel: try Self.decodeChannel(n, current: .channel, legacy: .channelOverride)
            )

        case .setFaderCC:
            let n = try c.nestedContainer(keyedBy: FaderKeys.self, forKey: .setFaderCC)
            self = .setFaderCC(
                cc: try n.decodeIfPresent(Int.self, forKey: .cc) ?? MIDIDefaults.dialFaderCC,
                channel: try Self.decodeChannel(n, current: .channel, legacy: .channelOverride)
            )

        case .setRootNote:
            let n = try c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setRootNote)
            self = .setRootNote(try n.decodeIfPresent(Int.self, forKey: ._0) ?? 48)

        case .setScale:
            let n = try c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setScale)
            self = .setScale(try n.decodeIfPresent(Scale.self, forKey: ._0) ?? .chromatic)

        case .setFixedVelocity:
            let n = try c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setFixedVelocity)
            self = .setFixedVelocity(try n.decodeIfPresent(Int.self, forKey: ._0) ?? 100)

        case .setVoiceCount:
            let n = try c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setVoiceCount)
            self = .setVoiceCount(try n.decodeIfPresent(Int.self, forKey: ._0) ?? 1)

        case .setNoteRange:
            let n = try c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setNoteRange)
            self = .setNoteRange(try n.decodeIfPresent(Int.self, forKey: ._0) ?? 24)

        case .toggleGlide:
            self = .toggleGlide

        case .togglePerpVelocity:
            self = .togglePerpVelocity
        }
    }

    /// A channel written by this build wins. Failing that, a legacy override
    /// is honored as the explicit channel it always was. An absent or null
    /// legacy override meant "inherit the dial's channel", which is not
    /// knowable this far down, so it becomes the sentinel for `DialPreset`
    /// to resolve.
    private static func decodeChannel<K: CodingKey>(_ container: KeyedDecodingContainer<K>,
                                                    current: K,
                                                    legacy: K) throws -> Int {
        if let channel = try container.decodeIfPresent(Int.self, forKey: current) {
            return min(max(channel, 0), 15)
        }
        if let override = try container.decodeIfPresent(Int.self, forKey: legacy) {
            return min(max(override, 0), 15)
        }
        return DialAction.inheritChannel
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CaseKey.self)

        switch self {
        case .sendCC(let cc, let value, let channel):
            var n = c.nestedContainer(keyedBy: SendCCKeys.self, forKey: .sendCC)
            try n.encode(cc, forKey: .cc)
            try n.encode(value, forKey: .value)
            try n.encode(channel, forKey: .channel)

        case .sendProgramChange(let program, let channel):
            var n = c.nestedContainer(keyedBy: ProgramKeys.self, forKey: .sendProgramChange)
            try n.encode(program, forKey: .program)
            try n.encode(channel, forKey: .channel)

        case .setFaderCC(let cc, let channel):
            var n = c.nestedContainer(keyedBy: FaderKeys.self, forKey: .setFaderCC)
            try n.encode(cc, forKey: .cc)
            try n.encode(channel, forKey: .channel)

        case .setRootNote(let v):
            var n = c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setRootNote)
            try n.encode(v, forKey: ._0)

        case .setScale(let v):
            var n = c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setScale)
            try n.encode(v, forKey: ._0)

        case .setFixedVelocity(let v):
            var n = c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setFixedVelocity)
            try n.encode(v, forKey: ._0)

        case .setVoiceCount(let v):
            var n = c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setVoiceCount)
            try n.encode(v, forKey: ._0)

        case .setNoteRange(let v):
            var n = c.nestedContainer(keyedBy: SingleKeys.self, forKey: .setNoteRange)
            try n.encode(v, forKey: ._0)

        case .toggleGlide:
            _ = c.nestedContainer(keyedBy: EmptyKeys.self, forKey: .toggleGlide)

        case .togglePerpVelocity:
            _ = c.nestedContainer(keyedBy: EmptyKeys.self, forKey: .togglePerpVelocity)
        }
    }
}

// MARK: - Kind (for the editor's action-type picker)

/// UI-level classification of DialAction, so the step editor can show a
/// simple type picker and then per-type parameter controls.
enum DialActionKind: String, CaseIterable, Identifiable {
    case cc, faderCC, programChange, rootNote, scale, glide, perpVelocity, fixedVelocity, voiceCount, noteRange

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cc:            return "Send CC"
        case .faderCC:       return "Fader Control"
        case .programChange: return "Program Change"
        case .rootNote:      return "Set Root Note"
        case .scale:         return "Set Scale"
        case .glide:         return "Toggle Glide"
        case .perpVelocity:  return "Toggle Perp→Vel"
        case .fixedVelocity: return "Set Velocity"
        case .voiceCount:    return "Voices"
        case .noteRange:     return "Note Range"
        }
    }

    /// Which collapsible step-editor card this action belongs to.
    var group: DialActionGroup {
        switch self {
        case .cc, .programChange:
            return .dial
        case .faderCC:
            return .fader
        case .rootNote, .scale, .glide, .perpVelocity,
             .fixedVelocity, .voiceCount, .noteRange:
            return .padControl
        }
    }
}

/// Three deliberately separate jobs in the step editor: reshaping the XY pad,
/// sending a message from the dial step itself, and assigning the companion
/// fader. Keeping them in separate collapsible cards makes the hierarchy clear.
enum DialActionGroup: String, CaseIterable, Identifiable {
    case padControl = "Pad Control"
    case dial       = "Dial"
    case fader      = "Fader"

    var id: String { rawValue }

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .padControl: return "square.grid.2x2"
        case .dial:       return "dial.medium.fill"
        case .fader:      return "slider.vertical.3"
        }
    }

    var footer: String {
        switch self {
        case .padControl:
            return "Reshapes the XY pad when this step is selected — key, scale, range and voicing. Nothing is transmitted."
        case .dial:
            return "MIDI messages sent when this dial step is selected."
        case .fader:
            return "Chooses the CC driven by the fader beside the dial while this step is selected."
        }
    }

    /// Action kinds in this group, in the app's fixed execution order.
    var kinds: [DialActionKind] {
        DialActionKind.allCases.filter { $0.group == self }
    }
}

extension DialAction {
    var kind: DialActionKind {
        switch self {
        case .sendCC:            return .cc
        case .sendProgramChange: return .programChange
        case .setRootNote:       return .rootNote
        case .setScale:          return .scale
        case .toggleGlide:       return .glide
        case .togglePerpVelocity: return .perpVelocity
        case .setFixedVelocity:  return .fixedVelocity
        case .setVoiceCount:     return .voiceCount
        case .setNoteRange:      return .noteRange
        case .setFaderCC:        return .faderCC
        }
    }

    /// A sensible starting action when the user switches a step to a new kind.
    ///
    /// `usedCCs` lets the caller pass every CC already spoken for — both the
    /// factory allocation (see `MIDIDefaults`) and whatever the surrounding
    /// dial's other steps have claimed — so a freshly enabled Send CC or
    /// Fader Control lands on a free number instead of doubling up on one
    /// that is already driving something. Left empty it still avoids the
    /// factory layout, which is what fixed the original collision: the dial
    /// used to default to CC 20 and CC 21, sitting exactly on morph corners
    /// A and B.
    static func defaultAction(for kind: DialActionKind,
                              usedCCs: Set<Int> = [],
                              channel: Int = MIDIDefaults.channel) -> DialAction {
        let taken = MIDIDefaults.reservedCCs
            .subtracting([MIDIDefaults.dialSendCC, MIDIDefaults.dialFaderCC])
            .union(usedCCs)
        let ch = min(max(channel, 0), 15)

        switch kind {
        case .cc:
            let cc = MIDIDefaults.firstFree(in: MIDIDefaults.dialSendCCBlock,
                                            avoiding: taken)
            return .sendCC(cc: cc, value: 64, channel: ch)
        case .faderCC:
            let cc = MIDIDefaults.firstFree(in: MIDIDefaults.dialFaderCCBlock,
                                            avoiding: taken)
            return .setFaderCC(cc: cc, channel: ch)
        case .programChange: return .sendProgramChange(program: 0, channel: ch)
        case .rootNote:      return .setRootNote(48)
        case .scale:         return .setScale(.chromatic)
        case .glide:         return .toggleGlide
        case .perpVelocity:  return .togglePerpVelocity
        case .fixedVelocity: return .setFixedVelocity(100)
        case .voiceCount:    return .setVoiceCount(1)
        case .noteRange:     return .setNoteRange(24)
        }
    }

    /// The CC this action occupies, if any. Feeds the free-CC search so one
    /// dial's steps never hand out the same number twice.
    var occupiedCC: Int? {
        switch self {
        case .sendCC(let cc, _, _):      return cc
        case .setFaderCC(let cc, _):     return cc
        default:                         return nil
        }
    }
}

// MARK: - Step & dial preset

/// One position on the dial. A step can fire ANY combination of actions —
/// send a CC, change the scale, and flip glide all from a single detent.
/// At most one action of each kind, which is what makes the editor a plain
/// checklist rather than a list you have to add rows to.
struct DialStep: Identifiable, Equatable {
    var id = UUID()
    /// Short label shown in the knob center — the face shows the first four
    /// characters, so front-load the distinguishing part.
    var label: String
    /// Kept sorted in `DialActionKind.allCases` order, so execution order is
    /// predictable and the summary text is stable across edits.
    var actions: [DialAction] = []

    func action(ofKind kind: DialActionKind) -> DialAction? {
        actions.first { $0.kind == kind }
    }

    var hasActions: Bool { !actions.isEmpty }

    /// How many of this step's actions live in one editor card, for the
    /// card's own header count.
    func actionCount(in group: DialActionGroup) -> Int {
        actions.filter { $0.kind.group == group }.count
    }

    /// Combined one-line description for list rows.
    var summary: String {
        actions.isEmpty ? "No action" : actions.map(\.summary).joined(separator: " · ")
    }

    /// Add or replace the action of this kind, keeping kind order.
    mutating func set(_ action: DialAction) {
        if let index = actions.firstIndex(where: { $0.kind == action.kind }) {
            actions[index] = action
        } else {
            actions.append(action)
            sortByKind()
        }
    }

    mutating func remove(kind: DialActionKind) {
        actions.removeAll { $0.kind == kind }
    }

    /// `usedCCs` and `channel` come from the surrounding dial, which is what
    /// makes two Send CC steps in the same dial come up on different numbers
    /// and start on the dial's own channel rather than always channel 1.
    mutating func toggle(kind: DialActionKind,
                         usedCCs: Set<Int> = [],
                         channel: Int = MIDIDefaults.channel) {
        if action(ofKind: kind) == nil {
            set(.defaultAction(for: kind,
                               usedCCs: usedCCs.union(occupiedCCs),
                               channel: channel))
        } else {
            remove(kind: kind)
        }
    }

    /// CCs this step's own actions already occupy.
    var occupiedCCs: Set<Int> {
        Set(actions.compactMap(\.occupiedCC))
    }

    private mutating func sortByKind() {
        let order = DialActionKind.allCases
        actions.sort {
            (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0)
        }
    }
}

// Hand-written Codable so dials saved when a step held exactly ONE action
// still load — the old `action` key is read into the new array. Encoding
// only ever writes the array, so the legacy key fades out on first save.
extension DialStep: Codable {
    enum CodingKeys: String, CodingKey {
        case id, label, actions
        case action   // legacy, decode-only
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id    = try c.decodeIfPresent(UUID.self,   forKey: .id)    ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "STEP"

        if let list = try c.decodeIfPresent([DialAction].self, forKey: .actions) {
            actions = list
        } else if let single = try c.decodeIfPresent(DialAction.self, forKey: .action) {
            actions = [single]
        } else {
            actions = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(actions, forKey: .actions)
    }
}

/// A complete, named dial configuration. Used in two places:
///   • Embedded in the main `Preset` as its LOCAL dial.
///   • Stored in the shared `DialLibraryStore` as a reusable dial preset
///     that any number of main presets can link to.
struct DialPreset: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [DialStep]
    /// 0-based MIDI channel. New MIDI actions on this dial start here.
    var channel: Int = MIDIDefaults.channel
    /// Persisted so the dial comes back where you left it.
    var currentStepIndex: Int = 0

    init(id: UUID = UUID(),
         name: String,
         steps: [DialStep],
         channel: Int = MIDIDefaults.channel,
         currentStepIndex: Int = 0) {
        self.id = id
        self.name = name
        self.steps = steps
        self.channel = channel
        self.currentStepIndex = currentStepIndex
    }

    /// Current step, clamped safely against edits that shrank the list.
    var currentStep: DialStep? {
        guard !steps.isEmpty else { return nil }
        return steps[min(max(currentStepIndex, 0), steps.count - 1)]
    }

    /// Every CC any step in this dial already sends or points the fader at.
    /// Passed into `DialStep.toggle` so a newly enabled CC action picks a
    /// number no other step here is using.
    var usedCCs: Set<Int> {
        steps.reduce(into: Set<Int>()) { $0.formUnion($1.occupiedCCs) }
    }

    /// Demo-friendly factory dial: four scale selections, no MIDI Learn
    /// needed to feel it working.
    ///
    /// COMPUTED so every new preset's local dial gets its own id, rather
    /// than every preset in the library sharing one.
    static var factory: DialPreset { DialPreset(
        name: "Scales",
        steps: [
            DialStep(label: "CHRM", actions: [.setScale(.chromatic)]),
            DialStep(label: "MAJ",  actions: [.setScale(.ionian)]),
            DialStep(label: "PENT", actions: [.setScale(.minorPentatonic)]),
            DialStep(label: "BLUE", actions: [.setScale(.blues)])
        ]
    ) }
}

extension DialPreset: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, steps, channel, currentStepIndex
    }

    /// This is where a legacy "inherit the dial's channel" finally resolves.
    ///
    /// `DialAction`'s decoder cannot do it: an action sitting several levels
    /// down has no way to see the channel it was inheriting FROM, so it
    /// leaves `DialAction.inheritChannel` behind as a marker. Here both
    /// halves are in hand at once, so every marker becomes this dial's own
    /// channel — which is precisely what the old override toggle meant when
    /// it was switched off. Resolving it any higher would be too late, since
    /// the dial's channel is what gets lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decodeIfPresent(UUID.self,   forKey: .id) ?? UUID()
        name             = try c.decodeIfPresent(String.self, forKey: .name) ?? "Dial"
        currentStepIndex = try c.decodeIfPresent(Int.self,    forKey: .currentStepIndex) ?? 0

        let storedChannel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? MIDIDefaults.channel
        let dialChannel = min(max(storedChannel, 0), 15)
        channel = dialChannel

        let decodedSteps = try c.decodeIfPresent([DialStep].self, forKey: .steps) ?? []
        steps = decodedSteps.map { step in
            var resolved = step
            resolved.actions = step.actions.map { action in
                guard let actionChannel = action.channel,
                      actionChannel == DialAction.inheritChannel else { return action }
                return action.withChannel(dialChannel)
            }
            return resolved
        }
    }
}

// MARK: - Shared dial library persistence

enum DialLibraryStore {
    private static let key = "MotionMIDIPro.dialPresets"

    static func save(_ presets: [DialPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [DialPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let presets = try? JSONDecoder().decode([DialPreset].self, from: data)
        else { return [] }
        return presets
    }
}
