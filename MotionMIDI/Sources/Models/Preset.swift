import Foundation

struct Calibration: Codable, Equatable {
    var pitch: Double = 0
    var roll: Double = 0
    var yaw: Double = 0
}

/// One dial+fader combo. iPhone always shows exactly slot 0. iPad can show
/// as many as you add, side by side. Each slot behaves exactly like the
/// original single dial did: a local `DialPreset`, optionally overridden by
/// a link to a shared library entry.
struct DialSlot: Identifiable, Codable, Equatable {
    var id = UUID()
    var localDial: DialPreset = .factory
    /// When set, this slot shows the SHARED library preset with this id
    /// instead of `localDial`. Falls back to local if the id no longer
    /// exists in the library.
    var linkedDialPresetID: UUID? = nil
}

struct Preset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var motionMappings: [MotionMapping]
    var xyPad = XYPadConfig()
    var buttons: [ButtonMapping]
    var calibration = Calibration()

    /// Bumped every time this preset is activated. Drives the recents
    /// ordering in the preset picker.
    var lastUsed = Date()

    // ── Stepped dial(s) ─────────────────────────────────────────────────
    /// Always at least one slot — index 0 is what iPhone shows. iPad shows
    /// every slot in this array, in order, side by side.
    var dialSlots: [DialSlot] = [DialSlot()]

    // MARK: - Factory default
    //
    // COMPUTED, not a stored constant — every access must mint fresh UUIDs.
    // A `static let` would hand the same id to every preset created from it,
    // and the whole library is addressed by id.
    //
    // Note numbers follow the common MIDI conventions most hosts (Loopy Pro
    // included) learn instantly, so the layout works broadly.
    //   Note 36 RECORD   Note 37 PLAY/STOP   Note 38 OVERDUB
    //   Note 39 UNDO     Note 40 REDO        Note 41 TAP TEMPO
    //
    // CC numbers come from `MIDIDefaults`, which owns the whole allocation
    // in one place — see the map at the top of Mapping.swift. Nothing here
    // hard-codes a CC any more, so the four motion mappings, the XY pad,
    // the morph corners and the stepped dial can no longer drift into each
    // other the way the dial and morph corners once did.
    static var factoryDefault: Preset {
        Preset(
            name: "Default",
            motionMappings: [
                MotionMapping(
                    name: "Roll → FX",
                    source: .roll,
                    cc: MIDIDefaults.rollCC,
                    processing: MotionProcessing(deadZone: 0.04, sensitivity: 1.2,
                                                 smoothing: 0.35, curve: .sCurve)
                ),
                MotionMapping(
                    name: "Pitch → Volume",
                    source: .pitch,
                    cc: MIDIDefaults.pitchCC,
                    processing: MotionProcessing(deadZone: 0.04, sensitivity: 1.2,
                                                 smoothing: 0.4, curve: .sCurve)
                ),
                MotionMapping(
                    name: "Yaw → Filter",
                    enabled: false,
                    source: .yaw,
                    cc: MIDIDefaults.yawCC,
                    processing: MotionProcessing(deadZone: 0.03, sensitivity: 1.0,
                                                 smoothing: 0.3, curve: .linear)
                ),
                MotionMapping(
                    name: "Shake Energy",
                    enabled: false,
                    source: .magnitude,
                    cc: MIDIDefaults.shakeCC,
                    processing: MotionProcessing(deadZone: 0.02, sensitivity: 1.5,
                                                 smoothing: 0.5, curve: .exponential)
                )
            ],
            buttons: [
                ButtonMapping(name: "REC",  cc: MIDIDefaults.buttonCCs[0]),
                ButtonMapping(name: "PLAY", cc: MIDIDefaults.buttonCCs[1]),
                ButtonMapping(name: "DUB",  cc: MIDIDefaults.buttonCCs[2]),
                ButtonMapping(name: "UNDO", cc: MIDIDefaults.buttonCCs[3]),
                ButtonMapping(name: "REDO", cc: MIDIDefaults.buttonCCs[4]),
                ButtonMapping(name: "TAP",  cc: MIDIDefaults.buttonCCs[5])
            ]
        )
    }
}

// Lenient decoding so presets saved by earlier builds still load — missing
// keys fall back to defaults instead of failing the decode and silently
// wiping a configuration. Declared in an extension so the memberwise
// initializer and synthesized encoder are both preserved.
extension Preset {
    /// CCs the CC-sending buttons in this preset already claim, so adding a
    /// button picks a free number rather than doubling up on one that is
    /// already wired to something in the host. Note-mode buttons occupy no
    /// CC and are skipped.
    var usedButtonCCs: Set<Int> {
        Set(buttons.filter { $0.message == .cc }.map(\.cc))
    }
}

extension Preset {
    enum CodingKeys: String, CodingKey {
        case id, name, motionMappings, xyPad, buttons, calibration
        case lastUsed, dialSlots
    }

    /// Pre-iPad-multi-dial presets stored a single dial under these keys.
    /// Kept SEPARATE from `CodingKeys` on purpose: once `CodingKeys` has a
    /// case with no matching stored property, the compiler can't synthesize
    /// `encode(to:)` from it any more and the whole type silently stops
    /// conforming to Encodable. A dedicated decode-only enum keeps the main
    /// one an exact match to the real properties.
    private enum LegacyCodingKeys: String, CodingKey {
        case dial, linkedDialPresetID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Preset.factoryDefault
        id             = try c.decodeIfPresent(UUID.self,            forKey: .id)             ?? UUID()
        name           = try c.decodeIfPresent(String.self,          forKey: .name)           ?? "Default"
        motionMappings = try c.decodeIfPresent([MotionMapping].self, forKey: .motionMappings) ?? fallback.motionMappings
        xyPad          = try c.decodeIfPresent(XYPadConfig.self,     forKey: .xyPad)          ?? XYPadConfig()
        buttons        = try c.decodeIfPresent([ButtonMapping].self, forKey: .buttons)        ?? fallback.buttons
        calibration    = try c.decodeIfPresent(Calibration.self,     forKey: .calibration)    ?? Calibration()
        lastUsed       = try c.decodeIfPresent(Date.self,            forKey: .lastUsed)       ?? Date()

        if let slots = try c.decodeIfPresent([DialSlot].self, forKey: .dialSlots), !slots.isEmpty {
            dialSlots = slots
        } else {
            // Pre-iPad-multi-dial preset: fold the old single dial + link
            // into a one-element array, so nothing a person configured is
            // lost by upgrading.
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let legacyDial = try legacy.decodeIfPresent(DialPreset.self, forKey: .dial) ?? .factory
            let legacyLink = try legacy.decodeIfPresent(UUID.self, forKey: .linkedDialPresetID) ?? nil
            dialSlots = [DialSlot(localDial: legacyDial, linkedDialPresetID: legacyLink)]
        }
    }
}

// MARK: - Persistence

/// Stores the whole preset library plus which one was last active.
///
/// Older builds saved a single preset under `legacyKey`. On first launch of
/// a build with the library, that preset is migrated in as the first entry
/// rather than being discarded — the legacy copy is left in place as a
/// safety net in case a downgrade is ever needed.
enum PresetLibraryStore {
    private static let libraryKey = "MotionMIDIPro.presetLibrary"
    private static let activeKeyBase = "MotionMIDIPro.activePresetID"
    private static let legacyKey  = "MotionMIDIPro.currentPreset"

    /// The LIBRARY is shared by every performer surface — build a preset
    /// once and either surface can load it. The ACTIVE POINTER is per
    /// surface, so two surfaces can sit on different presets at the same
    /// time, which is the entire point of having two.
    ///
    /// Surface 0 keeps the original, unsuffixed key, so an existing install
    /// reopens on exactly the preset it was left on rather than resetting
    /// the moment this shipped.
    private static func activeKey(surface: Int) -> String {
        surface == 0 ? activeKeyBase : "\(activeKeyBase).surface\(surface)"
    }

    struct Library {
        var presets: [Preset]
        var activeID: UUID
    }

    static func save(presets: [Preset], activeID: UUID, surface: Int = 0) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: libraryKey)
        }
        UserDefaults.standard.set(activeID.uuidString, forKey: activeKey(surface: surface))
    }

    static func load(surface: Int = 0) -> Library? {
        if let data = UserDefaults.standard.data(forKey: libraryKey),
           let presets = try? JSONDecoder().decode([Preset].self, from: data),
           !presets.isEmpty {
            let stored = UserDefaults.standard
                .string(forKey: activeKey(surface: surface)).flatMap(UUID.init)
            // A stored id that no longer matches anything falls back to the
            // most recently used preset rather than leaving nothing active.
            let activeID = presets.contains { $0.id == stored }
                ? stored!
                : (presets.max { $0.lastUsed < $1.lastUsed }?.id ?? presets[0].id)
            return Library(presets: presets, activeID: activeID)
        }
        return migrateLegacy()
    }

    /// Pull forward the single preset saved by pre-library builds.
    private static func migrateLegacy() -> Library? {
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              var legacy = try? JSONDecoder().decode(Preset.self, from: data)
        else { return nil }

        legacy.lastUsed = Date()
        let library = Library(presets: [legacy], activeID: legacy.id)
        save(presets: library.presets, activeID: library.activeID)
        return library
    }
}
