import Foundation

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
    var channel: Int = 0
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard XY"
        case .morph:    return "4-Corner Morph"
        }
    }
}

/// One corner destination of the morph pad. CC only, on purpose: notes,
/// pitch bend, RPN/NRPN and OSC are explicitly out of scope for this
/// feature, and the morph engine works in normalized weights so a richer
/// destination type can be introduced later without touching the math.
struct MorphCorner: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var cc: Int
    /// nil = inherit the XY pad's channel.
    var channelOverride: Int? = nil

    func channel(padChannel: Int) -> Int { channelOverride ?? padChannel }

    static func defaults() -> [MorphCorner] {
        [
            MorphCorner(label: "A", cc: 20),
            MorphCorner(label: "B", cc: 21),
            MorphCorner(label: "C", cc: 22),
            MorphCorner(label: "D", cc: 23)
        ]
    }
}

struct XYPadConfig: Codable, Equatable {
    // ── CC mode ──────────────────────────────────────────────────────────
    var xCC: Int = 12
    var yCC: Int = 13

    // ── Shared ───────────────────────────────────────────────────────────
    /// 0-based channel.
    var channel: Int = 0
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
    /// Number of simultaneous voices in note mode (1, 2, or 3).
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
}

// Lenient decoding so presets saved before new fields existed still load.
extension XYPadConfig {
    enum CodingKeys: String, CodingKey {
        case xCC, yCC, channel, snapBack
        case mode, diagonal, rootNote, rangeSemitones, scale
        case glide, glideTime, perpToVelocity, fixedVelocity
        case glideToggleButtonId, voiceCount
        case ccMode, morphCorners, morphCurve, morphCenterStrength, morphEqualPower
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        xCC            = try c.decodeIfPresent(Int.self,        forKey: .xCC)            ?? 12
        yCC            = try c.decodeIfPresent(Int.self,        forKey: .yCC)            ?? 13
        channel        = try c.decodeIfPresent(Int.self,        forKey: .channel)        ?? 0
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
    }
}

// MARK: - Buttons

enum ButtonBehavior: String, Codable, CaseIterable, Identifiable {
    /// Note On while held, Note Off on release.
    case momentary
    /// Short Note On + Off tap per press (Loopy Pro toggles internally).
    case tap

    var id: String { rawValue }
    var label: String { self == .momentary ? "Momentary" : "Tap" }
}

struct ButtonMapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var note: Int
    /// 0-based channel.
    var channel: Int = 0
    var behavior: ButtonBehavior = .tap
}
