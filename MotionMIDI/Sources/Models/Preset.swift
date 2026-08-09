import Foundation

struct Calibration: Codable, Equatable {
    var pitch: Double = 0
    var roll: Double = 0
    var yaw: Double = 0
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

    // ── Stepped dial ─────────────────────────────────────────────────────
    /// This preset's own dial configuration, used when not linked.
    var dial: DialPreset = .factory
    /// When set, the dial on screen is the SHARED library preset with this
    /// id instead of the local `dial` above. If the id no longer exists in
    /// the library, the app falls back to the local dial.
    var linkedDialPresetID: UUID? = nil

    // MARK: - Factory default
    //
    // COMPUTED, not a stored constant — every access must mint fresh UUIDs.
    // A `static let` would hand the same id to every preset created from it,
    // and the whole library is addressed by id.
    //
    // These CC/note numbers follow the common MIDI conventions most hosts
    // (Loopy Pro included) learn instantly, so the layout works broadly.
    //   Note 36 RECORD   Note 37 PLAY/STOP   Note 38 OVERDUB
    //   Note 39 UNDO     Note 40 REDO        Note 41 TAP TEMPO
    //   CC 1  Roll   -> FX amount / mod
    //   CC 11 Pitch  -> volume / expression
    //   CC 74 Yaw    -> filter cutoff
    //   CC 12/13     -> XY effect pad
    static var factoryDefault: Preset {
        Preset(
            name: "Default",
            motionMappings: [
                MotionMapping(
                    name: "Roll → FX",
                    source: .roll,
                    cc: 1,
                    processing: MotionProcessing(deadZone: 0.04, sensitivity: 1.2,
                                                 smoothing: 0.35, curve: .sCurve)
                ),
                MotionMapping(
                    name: "Pitch → Volume",
                    source: .pitch,
                    cc: 11,
                    processing: MotionProcessing(deadZone: 0.04, sensitivity: 1.2,
                                                 smoothing: 0.4, curve: .sCurve)
                ),
                MotionMapping(
                    name: "Yaw → Filter",
                    enabled: false,
                    source: .yaw,
                    cc: 74,
                    processing: MotionProcessing(deadZone: 0.03, sensitivity: 1.0,
                                                 smoothing: 0.3, curve: .linear)
                ),
                MotionMapping(
                    name: "Shake Energy",
                    enabled: false,
                    source: .magnitude,
                    cc: 2,
                    processing: MotionProcessing(deadZone: 0.02, sensitivity: 1.5,
                                                 smoothing: 0.5, curve: .exponential)
                )
            ],
            buttons: [
                ButtonMapping(name: "REC",  note: 36),
                ButtonMapping(name: "PLAY", note: 37),
                ButtonMapping(name: "DUB",  note: 38),
                ButtonMapping(name: "UNDO", note: 39),
                ButtonMapping(name: "REDO", note: 40),
                ButtonMapping(name: "TAP",  note: 41)
            ]
        )
    }
}

// Lenient decoding so presets saved by earlier builds still load — missing
// keys fall back to defaults instead of failing the decode and silently
// wiping a configuration. Declared in an extension so the memberwise
// initializer and synthesized encoder are both preserved.
extension Preset {
    enum CodingKeys: String, CodingKey {
        case id, name, motionMappings, xyPad, buttons, calibration
        case lastUsed, dial, linkedDialPresetID
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
        dial           = try c.decodeIfPresent(DialPreset.self,      forKey: .dial)           ?? .factory
        linkedDialPresetID = try c.decodeIfPresent(UUID.self, forKey: .linkedDialPresetID) ?? nil
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
    private static let activeKey  = "MotionMIDIPro.activePresetID"
    private static let legacyKey  = "MotionMIDIPro.currentPreset"

    struct Library {
        var presets: [Preset]
        var activeID: UUID
    }

    static func save(presets: [Preset], activeID: UUID) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: libraryKey)
        }
        UserDefaults.standard.set(activeID.uuidString, forKey: activeKey)
    }

    static func load() -> Library? {
        if let data = UserDefaults.standard.data(forKey: libraryKey),
           let presets = try? JSONDecoder().decode([Preset].self, from: data),
           !presets.isEmpty {
            let stored = UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init)
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
