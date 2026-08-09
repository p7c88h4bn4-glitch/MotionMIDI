import Foundation

// MARK: - Dial step actions

/// Everything one dial step can do when selected. MIDI actions go out the
/// wire; parameter actions reach into the current preset's XY pad config.
enum DialAction: Codable, Equatable {
    /// Send a CC with a fixed value. `channelOverride` nil = use the dial's
    /// global channel.
    case sendCC(cc: Int, value: Int, channelOverride: Int?)
    /// Send a Program Change. `channelOverride` nil = dial's global channel.
    case sendProgramChange(program: Int, channelOverride: Int?)
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
    /// anything. `defaultValue` is only what the fader shows before any
    /// feedback for this CC has arrived during this session.
    case setFaderCC(cc: Int, defaultValue: Int, channelOverride: Int?)

    /// Short human-readable summary for list rows and the knob caption.
    var summary: String {
        switch self {
        case .sendCC(let cc, let value, let ch):
            let chText = ch.map { " ch\($0 + 1)" } ?? ""
            return "CC\(cc) → \(value)\(chText)"
        case .sendProgramChange(let program, let ch):
            let chText = ch.map { " ch\($0 + 1)" } ?? ""
            return "PC \(program)\(chText)"
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
        case .setFaderCC(let cc, _, let ch):
            let chText = ch.map { " ch\($0 + 1)" } ?? ""
            return "Fader → CC\(cc)\(chText)"
        }
    }

    static func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = min(max(n, 0), 127)
        return "\(names[clamped % 12])\(clamped / 12 - 1)"
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
    static func defaultAction(for kind: DialActionKind) -> DialAction {
        switch kind {
        case .cc:            return .sendCC(cc: 20, value: 64, channelOverride: nil)
        case .programChange: return .sendProgramChange(program: 0, channelOverride: nil)
        case .rootNote:      return .setRootNote(48)
        case .scale:         return .setScale(.chromatic)
        case .glide:         return .toggleGlide
        case .perpVelocity:  return .togglePerpVelocity
        case .fixedVelocity: return .setFixedVelocity(100)
        case .voiceCount:    return .setVoiceCount(1)
        case .noteRange:     return .setNoteRange(24)
        case .faderCC:       return .setFaderCC(cc: 21, defaultValue: 64, channelOverride: nil)
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

    mutating func toggle(kind: DialActionKind) {
        if action(ofKind: kind) == nil {
            set(.defaultAction(for: kind))
        } else {
            remove(kind: kind)
        }
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
struct DialPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var steps: [DialStep]
    /// 0-based global MIDI channel for steps without a channel override.
    var channel: Int = 0
    /// Persisted so the dial comes back where you left it.
    var currentStepIndex: Int = 0

    /// Current step, clamped safely against edits that shrank the list.
    var currentStep: DialStep? {
        guard !steps.isEmpty else { return nil }
        return steps[min(max(currentStepIndex, 0), steps.count - 1)]
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
