import Foundation

// MARK: - Central MIDI default allocation
//
// ONE place that decides which CC number every feature reaches for when it
// has no user-chosen value yet. Before this existed the numbers were typed
// inline at each site, and two of them collided: the stepped dial's default
// Send CC (20) and Fader CC (21) landed straight on top of morph corners A
// and B. Adding a dial step to a preset already using 4-Corner Morph meant
// two controls fighting over the same CC with no warning.
//
// ── The map ─────────────────────────────────────────────────────────────
//
//   CC 1    Roll → Mod Wheel            (MIDI standard)
//   CC 2    Shake → Breath              (MIDI standard)
//   CC 5    Glide time                  (MIDI standard: Portamento Time)
//   CC 11   Pitch → Expression          (MIDI standard)
//   CC 12   XY pad X                    (Effect Control 1)
//   CC 13   XY pad Y                    (Effect Control 2)
//   CC 20   Morph corner A              (spec-undefined)
//   CC 21   Morph corner B              (spec-undefined)
//   CC 22   Morph corner C              (spec-undefined)
//   CC 23   Morph corner D              (spec-undefined)
//   CC 65   Glide on/off                (MIDI standard: Portamento Switch)
//   CC 74   Yaw → Filter Cutoff         (MIDI standard: Brightness)
//   CC 102-110  Stepped dial Send CC    (spec-undefined block)
//   CC 111-119  Stepped dial Fader CC   (spec-undefined block)
//
// The dial moved into 102-119 rather than sitting next to the morph corners
// in the low twenties for two reasons. It is the largest block the MIDI
// spec leaves permanently undefined, so nothing else will ever claim it,
// and it is big enough that an iPad preset with several dial slots can hand
// every slot its own pair without running into the morph corners again.
//
// CC 32-63 is deliberately avoided everywhere. Those are the LSB partners
// of CC 0-31 under 14-bit CC, and while most iOS hosts treat all 128 as
// plain 7-bit, a host that does implement 14-bit would read a write to
// CC 34 as fine detail on CC 2 rather than as its own control.
enum MIDIDefaults {

    // ── Channel ─────────────────────────────────────────────────────────
    /// 0-based, so this is channel 1 as displayed everywhere in the UI.
    /// Every output in the app starts here.
    static let channel = 0

    // ── Motion sources ──────────────────────────────────────────────────
    static let rollCC  = 1
    static let shakeCC = 2
    static let pitchCC = 11
    static let yawCC   = 74

    // ── XY pad, standard mode ───────────────────────────────────────────
    static let xyXCC = 12
    static let xyYCC = 13

    // ── XY pad, 4-corner morph ──────────────────────────────────────────
    /// A/B/C/D in TL/TR/BL/BR order. Exactly four, always — the pad indexes
    /// this directly.
    static let morphCornerCCs = [20, 21, 22, 23]

    // ── XY pad, drawbars ─────────────────────────────────────────────────
    /// Nine spec-undefined controller numbers for a classic 9-drawbar bank.
    /// The order looks unusual because it deliberately avoids the factory
    /// motion, XY, morph, button and stepped-dial assignments above.
    static let drawbarCCs = [85, 86, 87, 88, 89, 90, 30, 31, 3]

    // ── Glide, fixed by the MIDI spec ───────────────────────────────────
    /// Not configurable and not part of the free-CC search: a synth looks
    /// for portamento on these two numbers or not at all.
    static let portamentoTimeCC   = 5
    static let portamentoSwitchCC = 65

    // ── Stepped dial ────────────────────────────────────────────────────
    static let dialSendCCBlock  = 102...110
    static let dialFaderCCBlock = 111...119

    /// Starting point when a step's Send CC action is first switched on.
    static var dialSendCC: Int { dialSendCCBlock.lowerBound }
    /// Starting point when a step's Fader Control action is first switched on.
    static var dialFaderCC: Int { dialFaderCCBlock.lowerBound }

    // ── Transport buttons ───────────────────────────────────────────────
    /// The six factory buttons, in order. Sits just above the morph corners
    /// in the block of controller numbers the MIDI spec leaves undefined,
    /// so nothing here collides with a standard meaning a synth might act
    /// on by itself.
    static let buttonCCs = [24, 25, 26, 27, 28, 29]

    /// Ordered pool a newly added button draws from, longest run first.
    ///
    /// Deliberately not a single `ClosedRange` like the dial blocks: there
    /// is no run of undefined controller numbers long enough left over once
    /// the dial has taken 102–119, so this stitches together the spec's
    /// remaining undefined numbers instead. Everything here is undefined in
    /// the MIDI 1.0 spec — 96–101 are pointedly absent, since those carry
    /// data entry and RPN/NRPN and a button firing one would confuse a
    /// receiver mid-edit.
    static let buttonCCPool: [Int] = Array(24...31) + [85, 86, 87, 88, 89, 90]
                                                    + [3, 9, 14, 15]

    /// Lowest unclaimed CC in the button pool.
    static func firstFreeButtonCC(avoiding used: Set<Int>) -> Int {
        buttonCCPool.first { !used.contains($0) } ?? buttonCCPool[0]
    }

    /// Every CC this app hands out by itself. Useful as the starting set for
    /// a free-CC search, so a new assignment avoids the whole factory layout
    /// rather than only the feature it belongs to.
    static var reservedCCs: Set<Int> {
        var used: Set<Int> = [rollCC, shakeCC, pitchCC, yawCC,
                              xyXCC, xyYCC,
                              portamentoTimeCC, portamentoSwitchCC,
                              dialSendCC, dialFaderCC]
        used.formUnion(morphCornerCCs)
        used.formUnion(drawbarCCs)
        used.formUnion(buttonCCs)
        return used
    }

    /// Lowest CC in `block` not already in `used`. Falls back to the block's
    /// first entry when every slot is taken — a duplicate is better than a
    /// silent failure to assign, and the editor still lets it be changed.
    static func firstFree(in block: ClosedRange<Int>, avoiding used: Set<Int>) -> Int {
        block.first { !used.contains($0) } ?? block.lowerBound
    }
}

// MARK: - Response curves

enum ResponseCurve: String, Codable, CaseIterable, Identifiable {
    case linear, exponential, logarithmic, sCurve

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear:      return "Linear"
        case .exponential: return "Exponential"
        case .logarithmic: return "Logarithmic"
        case .sCurve:      return "S-Curve"
        }
    }

    /// Input and output are both 0...1.
    func apply(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        switch self {
        case .linear:      return c
        case .exponential: return c * c
        case .logarithmic: return c.squareRoot()
        case .sCurve:      return c * c * (3 - 2 * c)
        }
    }
}

// MARK: - Per-mapping motion processing

struct MotionProcessing: Codable, Equatable {
    /// Dead zone radius around center, 0...0.4 (normalized units).
    var deadZone: Double = 0.03
    /// Gain around center. 1.0 = full physical range maps to full MIDI range.
    var sensitivity: Double = 1.0
    /// 0 = raw, 0.95 = very heavy smoothing (one-pole filter).
    var smoothing: Double = 0.35
    var curve: ResponseCurve = .linear
    var invert: Bool = false
    var outMin: Int = 0
    var outMax: Int = 127
}

// MARK: - Continuous motion -> CC mapping

struct MotionMapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var enabled: Bool = true
    var source: MotionSource
    /// 0-based MIDI channel (displayed to the user as 1-16).
    var channel: Int = MIDIDefaults.channel
    var cc: Int
    var processing = MotionProcessing()
}

// MARK: - XY pad

/// What the XY pad transmits.
enum XYPadMode: String, Codable, CaseIterable, Identifiable {
    /// Classic: X drives one CC, Y drives another (independent).
    case cc
    /// Diagonal note mode: position along one diagonal chooses a pitch;
    /// touch = Note On, release = Note Off.
    case notes

    var id: String { rawValue }
    var label: String { self == .cc ? "CC" : "Notes" }
}

/// Which diagonal traversal maps low → high pitch. Only one is active at a
/// time. Note that the two pairs share the same geometric line but travel
/// it in opposite directions — that's a musically different mapping (the
/// "low" and "high" ends swap), so all four are selectable independently.
enum XYDiagonal: String, Codable, CaseIterable, Identifiable {
    /// "/" line, low at bottom-left, high at top-right.
    case bottomLeftToTopRight
    /// "\" line, low at top-left, high at bottom-right.
    case topLeftToBottomRight
    /// "\" line, low at bottom-right, high at top-left.
    case bottomRightToTopLeft
    /// "/" line, low at top-right, high at bottom-left.
    case topRightToBottomLeft

    var id: String { rawValue }

    /// Compact glyph for space-constrained inline text (pad header, etc).
    var label: String {
        switch self {
        case .bottomLeftToTopRight: return "↗"
        case .topLeftToBottomRight: return "↘"
        case .bottomRightToTopLeft: return "↖"
        case .topRightToBottomLeft: return "↙"
        }
    }

    /// Full description for the config sheet caption.
    var description: String {
        switch self {
        case .bottomLeftToTopRight: return "Bottom-left → Top-right"
        case .topLeftToBottomRight: return "Top-left → Bottom-right"
        case .bottomRightToTopLeft: return "Bottom-right → Top-left"
        case .topRightToBottomLeft: return "Top-right → Bottom-left"
        }
    }

    /// Given normalized pad coordinates (x right-positive, y up-positive,
    /// both 0...1), return (along, perp) both 0...1.
    ///   • along = position on the pitch axis (0 = lowest, 1 = highest)
    ///   • perp  = position on the perpendicular axis (feeds velocity)
    func project(x: Double, y: Double) -> (along: Double, perp: Double) {
        switch self {
        case .bottomLeftToTopRight:
            return (along: (x + y) / 2, perp: (x - y + 1) / 2)
        case .topLeftToBottomRight:
            return (along: (x - y + 1) / 2, perp: (x + y) / 2)
        case .bottomRightToTopLeft:
            return (along: (y - x + 1) / 2, perp: (x + y) / 2)
        case .topRightToBottomLeft:
            return (along: (2 - x - y) / 2, perp: (x - y + 1) / 2)
        }
    }
}

/// Sub-mode of the CC pad. Deliberately separate from `XYPadMode` so Notes
/// mode is untouched and the top-level CC/Notes picker keeps two options.
enum CCPadMode: String, Codable, CaseIterable, Identifiable {
    case standard   // X and Y each drive one CC — the original behavior
    case morph      // four-corner blend driving four CCs at once
    case drawbars   // bank of independent one-dimensional CC controls

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard XY"
        case .morph:    return "4-Corner Morph"
        case .drawbars: return "Drawbars"
        }
    }
}

/// One corner destination of the morph pad. CC only, on purpose: notes,
/// pitch bend, RPN/NRPN and OSC are explicitly out of scope for this
/// feature, and the morph engine works in normalized weights so a richer
/// destination type can be introduced later without touching the math.
///
/// The channel is a PLAIN VALUE, not an optional override. Earlier builds
/// stored `channelOverride: Int?` behind an "Override Channel" toggle, so
/// reading a corner's channel meant knowing whether the toggle was on and
/// what the pad's channel was underneath. Every corner now simply has a
/// channel, starting on 1, always visible and always selectable — nothing
/// to switch on before it can be set.
struct MorphCorner: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var cc: Int
    /// 0-based (displayed as 1-16).
    var channel: Int = MIDIDefaults.channel

    init(id: UUID = UUID(),
         label: String,
         cc: Int,
         channel: Int = MIDIDefaults.channel) {
        self.id = id
        self.label = label
        self.cc = cc
        self.channel = channel
    }

    static func defaults() -> [MorphCorner] {
        let ccs = MIDIDefaults.morphCornerCCs
        return [
            MorphCorner(label: "A", cc: ccs[0]),
            MorphCorner(label: "B", cc: ccs[1]),
            MorphCorner(label: "C", cc: ccs[2]),
            MorphCorner(label: "D", cc: ccs[3])
        ]
    }
}

extension MorphCorner {
    enum CodingKeys: String, CodingKey {
        case id, label, cc, channel
    }

    /// Decode-only, and deliberately kept OUT of `CodingKeys`. The moment
    /// `CodingKeys` carries a case with no matching stored property the
    /// compiler stops synthesizing `encode(to:)` and the type quietly loses
    /// Encodable conformance — the same trap `Preset` documents for its own
    /// legacy dial keys.
    private enum LegacyCodingKeys: String, CodingKey {
        case channelOverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id    = try c.decodeIfPresent(UUID.self,   forKey: .id)    ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "A"
        cc    = try c.decodeIfPresent(Int.self,    forKey: .cc)
            ?? MIDIDefaults.morphCornerCCs[0]

        if let stored = try c.decodeIfPresent(Int.self, forKey: .channel) {
            channel = stored
        } else {
            // Pre-flattening preset. A corner that had the override switched
            // ON keeps the channel it was overriding to; one that had it off
            // was inheriting the pad's channel, and the pad's own default is
            // the same value this falls back to.
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            channel = try legacy.decodeIfPresent(Int.self, forKey: .channelOverride)
                ?? MIDIDefaults.channel
        }
        channel = min(max(channel, 0), 15)
    }
}


// MARK: - Drawbar pad

/// Direction in which a drawbar's MIDI value increases. The same choice also
/// determines whether the bank is arranged as vertical or horizontal bars.
enum DrawbarDirection: String, Codable, CaseIterable, Identifiable {
    case up, down, left, right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .up:    return "Up"
        case .down:  return "Down"
        case .left:  return "Left"
        case .right: return "Right"
        }
    }

    var arrow: String {
        switch self {
        case .up:    return "↑"
        case .down:  return "↓"
        case .left:  return "←"
        case .right: return "→"
        }
    }

    var isVertical: Bool { self == .up || self == .down }
}

/// How a finger is associated with drawbars while it moves across the pad.
enum DrawbarTouchMode: String, Codable, CaseIterable, Identifiable {
    /// A finger owns the drawbar it first touches until that finger lifts.
    case individual
    /// A finger controls whichever drawbar it is currently crossing, so one
    /// continuous swipe can reshape an entire bank.
    case sweep

    var id: String { rawValue }
    var label: String { self == .individual ? "Individual" : "Sweep" }
}

/// One MIDI destination in the drawbar bank. `value` is persisted so each
/// preset reopens with the same visual drawbar positions; live touch updates
/// are staged in the view and committed on release to avoid saving the whole
/// preset library on every single finger-move event.
struct DrawbarMapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var cc: Int
    var value: Int = 0

    init(id: UUID = UUID(), cc: Int, value: Int = 0) {
        self.id = id
        self.cc = min(max(cc, 0), 127)
        self.value = min(max(value, 0), 127)
    }

    static func defaults() -> [DrawbarMapping] {
        MIDIDefaults.drawbarCCs.map { DrawbarMapping(cc: $0) }
    }
}

struct XYPadConfig: Codable, Equatable {
    // ── CC mode ──────────────────────────────────────────────────────────
    var xCC: Int = MIDIDefaults.xyXCC
    var yCC: Int = MIDIDefaults.xyYCC

    // ── Shared ───────────────────────────────────────────────────────────
    /// 0-based channel.
    var channel: Int = MIDIDefaults.channel
    /// When true the puck springs back to center on release (Spring return).
    /// When false the puck holds its last position (Hold position).
    var snapBack: Bool = true

    // ── Note mode ────────────────────────────────────────────────────────
    var mode: XYPadMode = .cc
    var diagonal: XYDiagonal = .bottomLeftToTopRight
    /// Lowest MIDI note, emitted at the "low" end of the active diagonal.
    var rootNote: Int = 48            // C3
    /// Span in semitones from root to the "high" end of the diagonal.
    var rangeSemitones: Int = 24      // two octaves
    /// Scale used to quantize positions along the diagonal.
    var scale: Scale = .chromatic
    /// Legato ordering (Note On before Note Off) so a synth with portamento
    /// glides between pitches instead of hard-retriggering. Also drives
    /// CC 65 (Portamento On/Off) so the receiving synth is switched over
    /// automatically rather than by hand.
    var glide: Bool = false
    /// Portamento time, 0...1, sent as CC 5. 0 = instant, 1 = very slow slide.
    /// Only transmitted while `glide` is on.
    var glideTime: Double = 0.25
    /// Map the perpendicular axis to Note On velocity. When false, all notes
    /// use `fixedVelocity`.
    var perpToVelocity: Bool = false
    var fixedVelocity: Int = 100
    /// Which button (if any) toggles the XY pad's glide (legato portamento).
    /// Only one button can have this assignment; setting a new one clears
    /// the previous one.
    var glideToggleButtonId: UUID? = nil
    /// Number of simultaneous voices in note mode, up to `maxVoices`.
    /// When a new finger lands beyond this limit, the oldest voice is
    /// stolen and moves to the new finger.
    var voiceCount: Int = 1

    // ── 4-Corner Morph (CC mode only) ────────────────────────────────────
    /// Defaults to `.standard`, so an existing pad never starts emitting
    /// four CCs until the mode is switched deliberately.
    var ccMode: CCPadMode = .standard
    /// Always four entries, in A/B/C/D = TL/TR/BL/BR order.
    var morphCorners: [MorphCorner] = MorphCorner.defaults()
    /// -100 (spread influence) ... 0 (linear) ... +100 (concentrate).
    var morphCurve: Double = 0
    /// 0 (four broad corner regions) ... 0.5 (plain bilinear) ... 1 (wide
    /// central blend). Stored 0...1; shown as a percentage.
    var morphCenterStrength: Double = 0.5
    /// Constant-power weighting, for driving several clip volumes at once.
    var morphEqualPower: Bool = false

    // ── Drawbars (CC mode only) ─────────────────────────────────────────
    /// 1...9 visible bars. The full nine mappings are retained even when the
    /// visible count is reduced, so shrinking and re-expanding the bank does
    /// not throw away CC assignments or held positions.
    var drawbarCount: Int = 4
    var drawbarDirection: DrawbarDirection = .up
    var drawbarTouchMode: DrawbarTouchMode = .individual
    /// Sweep-only glide amount in 100 ms steps: 0 = instant, 10 = 1 second.
    var drawbarRamp: Int = 0
    var drawbars: [DrawbarMapping] = DrawbarMapping.defaults()
}

// Lenient decoding so presets saved before new fields existed still load.
extension XYPadConfig {
    /// Upper limit for `voiceCount`.
    ///
    /// Defined once so the pad's picker, the dial step's picker, and the
    /// clamp in `AppState.perform` cannot drift apart. They already had:
    /// raising only the pad's picker to 5 looked like it did nothing,
    /// because a dial step still clamped the value back down to 3.
    static let maxVoices = 5

    enum CodingKeys: String, CodingKey {
        case xCC, yCC, channel, snapBack
        case mode, diagonal, rootNote, rangeSemitones, scale
        case glide, glideTime, perpToVelocity, fixedVelocity
        case glideToggleButtonId, voiceCount
        case ccMode, morphCorners, morphCurve, morphCenterStrength, morphEqualPower
        case drawbarCount, drawbarDirection, drawbarTouchMode, drawbarRamp, drawbars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        xCC            = try c.decodeIfPresent(Int.self,        forKey: .xCC)            ?? MIDIDefaults.xyXCC
        yCC            = try c.decodeIfPresent(Int.self,        forKey: .yCC)            ?? MIDIDefaults.xyYCC
        channel        = try c.decodeIfPresent(Int.self,        forKey: .channel)        ?? MIDIDefaults.channel
        snapBack       = try c.decodeIfPresent(Bool.self,       forKey: .snapBack)       ?? true
        mode           = try c.decodeIfPresent(XYPadMode.self,  forKey: .mode)           ?? .cc
        diagonal       = try c.decodeIfPresent(XYDiagonal.self, forKey: .diagonal)       ?? .bottomLeftToTopRight
        rootNote       = try c.decodeIfPresent(Int.self,        forKey: .rootNote)       ?? 48
        rangeSemitones = try c.decodeIfPresent(Int.self,        forKey: .rangeSemitones) ?? 24
        scale          = try c.decodeIfPresent(Scale.self,      forKey: .scale)          ?? .chromatic
        glide          = try c.decodeIfPresent(Bool.self,       forKey: .glide)          ?? false
        glideTime      = try c.decodeIfPresent(Double.self,     forKey: .glideTime)      ?? 0.25
        perpToVelocity = try c.decodeIfPresent(Bool.self,       forKey: .perpToVelocity) ?? false
        fixedVelocity  = try c.decodeIfPresent(Int.self,        forKey: .fixedVelocity)  ?? 100
        glideToggleButtonId = try c.decodeIfPresent(UUID.self,  forKey: .glideToggleButtonId) ?? nil
        voiceCount     = try c.decodeIfPresent(Int.self,        forKey: .voiceCount)     ?? 1

        // Morph settings absent from presets saved before this feature.
        ccMode         = try c.decodeIfPresent(CCPadMode.self, forKey: .ccMode) ?? .standard
        morphCurve     = try c.decodeIfPresent(Double.self,    forKey: .morphCurve) ?? 0
        morphCenterStrength = try c.decodeIfPresent(Double.self, forKey: .morphCenterStrength) ?? 0.5
        morphEqualPower = try c.decodeIfPresent(Bool.self,     forKey: .morphEqualPower) ?? false

        // Corner count is load-bearing — the pad indexes 0..<4 directly.
        // Pad or trim anything malformed rather than trusting the file.
        let decodedCorners = try c.decodeIfPresent([MorphCorner].self,
                                                   forKey: .morphCorners) ?? []
        var corners = decodedCorners
        let fallback = MorphCorner.defaults()
        if corners.count > 4 { corners = Array(corners.prefix(4)) }
        while corners.count < 4 { corners.append(fallback[corners.count]) }
        morphCorners = corners

        // Drawbar settings absent from presets saved before this feature.
        drawbarCount = min(max(try c.decodeIfPresent(Int.self, forKey: .drawbarCount) ?? 4, 1), 9)
        drawbarDirection = try c.decodeIfPresent(DrawbarDirection.self, forKey: .drawbarDirection) ?? .up
        drawbarTouchMode = try c.decodeIfPresent(DrawbarTouchMode.self, forKey: .drawbarTouchMode) ?? .individual
        drawbarRamp = min(max(try c.decodeIfPresent(Int.self, forKey: .drawbarRamp) ?? 0, 0), 10)

        let decodedDrawbars = try c.decodeIfPresent([DrawbarMapping].self, forKey: .drawbars) ?? []
        var bars = decodedDrawbars
        let fallbackBars = DrawbarMapping.defaults()
        if bars.count > 9 { bars = Array(bars.prefix(9)) }
        while bars.count < 9 { bars.append(fallbackBars[bars.count]) }
        for index in bars.indices {
            bars[index].cc = min(max(bars[index].cc, 0), 127)
            bars[index].value = min(max(bars[index].value, 0), 127)
        }
        drawbars = bars
    }
}

// MARK: - Transient dial overrides

/// Pad parameters the currently selected dial step is temporarily holding
/// away from their preset values.
///
/// The preset holds the MASTER values — what the pad returns to. A step
/// carrying `.setScale` or `.setRootNote` overrides that master for exactly
/// as long as it stays selected; turn the dial to a step that says nothing
/// about scale and the master comes back on its own.
///
/// Before this existed, `perform()` wrote straight into `preset.xyPad`, so a
/// step did not override the scale, it REPLACED it. One turn of the dial and
/// the preset's own scale was gone — nothing remembered what it had been, and
/// the write dirtied the preset and persisted it, so the loss survived a
/// relaunch. Keeping overrides separate and unsaved is what makes "return to
/// master" possible at all.
///
/// `nil` means "this step has no opinion", which is deliberately different
/// from any value the field could hold.
struct XYPadOverrides: Equatable {
    var scale: Scale?
    var rootNote: Int?
    var fixedVelocity: Int?
    var voiceCount: Int?
    var rangeSemitones: Int?

    var isActive: Bool {
        scale != nil || rootNote != nil || fixedVelocity != nil
            || voiceCount != nil || rangeSemitones != nil
    }

    /// The config the pad should actually play, given these overrides.
    ///
    /// Note mode parameters only. Drawbar and morph settings are never
    /// overridden here — no dial action targets them, and a bank of drawbars
    /// silently rearranging itself as the dial turns would be a surprise
    /// rather than a feature.
    func applied(to base: XYPadConfig) -> XYPadConfig {
        var cfg = base
        if let scale          { cfg.scale = scale }
        if let rootNote       { cfg.rootNote = min(max(rootNote, 0), 120) }
        if let fixedVelocity  { cfg.fixedVelocity = min(max(fixedVelocity, 1), 127) }
        if let voiceCount     { cfg.voiceCount = min(max(voiceCount, 1), XYPadConfig.maxVoices) }
        if let rangeSemitones { cfg.rangeSemitones = min(max(rangeSemitones, 1), 60) }
        return cfg
    }
}

// MARK: - Buttons

enum ButtonBehavior: String, Codable, CaseIterable, Identifiable {
    /// Held: the "on" message on press, the "off" message on release.
    case momentary
    /// Short on + off per press (Loopy Pro toggles internally).
    case tap
    /// Latching: "on" on the first press, "off" on the next. The state lives
    /// HERE rather than in the host, which is the difference from `tap` —
    /// tap assumes the receiver flips something internally and just nudges
    /// it, while toggle decides what the value is and says so outright.
    /// Use it for a host parameter that has no toggle of its own, or where
    /// you want the button's lit state to be the truth.
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .momentary: return "Momentary"
        case .tap:       return "Tap"
        case .toggle:    return "Toggle"
        }
    }
}

/// What a transport button puts on the wire.
///
/// CC is the default for new buttons. Notes work fine for triggering clips,
/// but a CC can be MIDI-learned to anything a host exposes — a mixer send,
/// a plugin parameter, a transport control — whereas a note is only ever
/// heard by something listening for notes.
enum ButtonMessage: String, Codable, CaseIterable, Identifiable {
    case cc
    case note

    var id: String { rawValue }
    var label: String { self == .cc ? "CC" : "Note" }
}

struct ButtonMapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// New buttons send CC. Buttons restored from a preset saved before this
    /// existed stay on notes — see the decoder below.
    var message: ButtonMessage = .cc
    /// Used when `message` is `.note`.
    var note: Int = 60
    /// Used when `message` is `.cc`.
    var cc: Int = MIDIDefaults.buttonCCPool[0]
    /// Sent on press. Also the note velocity when sending notes.
    var onValue: Int = 127
    /// Sent on release (momentary) or straight after the on value (tap).
    var offValue: Int = 0
    /// 0-based channel.
    var channel: Int = MIDIDefaults.channel
    var behavior: ButtonBehavior = .tap

    init(id: UUID = UUID(),
         name: String,
         message: ButtonMessage = .cc,
         note: Int = 60,
         cc: Int = MIDIDefaults.buttonCCPool[0],
         onValue: Int = 127,
         offValue: Int = 0,
         channel: Int = MIDIDefaults.channel,
         behavior: ButtonBehavior = .tap) {
        self.id = id
        self.name = name
        self.message = message
        self.note = note
        self.cc = cc
        self.onValue = onValue
        self.offValue = offValue
        self.channel = channel
        self.behavior = behavior
    }

    /// One-line description for the editor list.
    var summary: String {
        switch message {
        case .cc:
            return "CC\(cc) → \(onValue)/\(offValue) · CH \(channel + 1) · \(behavior.label)"
        case .note:
            return "Note \(note) · CH \(channel + 1) · \(behavior.label)"
        }
    }
}

extension ButtonMapping {
    enum CodingKeys: String, CodingKey {
        case id, name, message, note, cc, onValue, offValue, channel, behavior
    }

    /// The default in the memberwise init above is `.cc`, but the default
    /// HERE is `.note`, and the difference is deliberate.
    ///
    /// A missing `message` key means the file predates this feature, and
    /// back then every button sent a note. Defaulting a decode to `.cc`
    /// would silently repoint every button in every saved preset at a
    /// controller number — the buttons would still light up and still send
    /// something, so nothing would look broken until a live set didn't
    /// trigger. New buttons get the new default; existing ones keep doing
    /// exactly what they were built to do.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decodeIfPresent(UUID.self,   forKey: .id)   ?? UUID()
        name     = try c.decodeIfPresent(String.self, forKey: .name) ?? "BTN"
        note     = try c.decodeIfPresent(Int.self,    forKey: .note) ?? 60
        message  = try c.decodeIfPresent(ButtonMessage.self, forKey: .message) ?? .note
        cc       = try c.decodeIfPresent(Int.self, forKey: .cc)
            ?? MIDIDefaults.buttonCCPool[0]
        onValue  = try c.decodeIfPresent(Int.self, forKey: .onValue)  ?? 127
        offValue = try c.decodeIfPresent(Int.self, forKey: .offValue) ?? 0
        channel  = try c.decodeIfPresent(Int.self, forKey: .channel)
            ?? MIDIDefaults.channel
        behavior = try c.decodeIfPresent(ButtonBehavior.self, forKey: .behavior) ?? .tap

        note     = min(max(note, 0), 127)
        cc       = min(max(cc, 0), 127)
        onValue  = min(max(onValue, 0), 127)
        offValue = min(max(offValue, 0), 127)
        channel  = min(max(channel, 0), 15)
    }
}
