import SwiftUI
import UIKit

// MARK: - Colour system
//
// Colour is resolved in three layers, most specific first:
//
//   1. The PRESET's palette, when it names one.
//   2. The SURFACE's palette — only while two surfaces are running, so the
//      left and right halves of the glass can look different without every
//      preset having to say so.
//   3. The GLOBAL palette, which everything else falls back to.
//
// A palette is a set of six base colours (background, panels, raised
// surfaces, text, grid lines, accent) plus a row of component colours.
// Every widget — the pad, each morph corner, each drawbar, each button, each
// dial, each motion meter — can pick one of those component colours in the
// CC map. A widget that has not picked one follows the accent, which is why
// a fresh preset still looks like one piece.
//
// Assignments are stored as an INDEX into the palette, not as a colour.
// That is what lets the dice swap the whole palette and have every widget
// follow: button 3 is "palette colour 5", whatever palette colour 5 is today.

/// One colour, stored as plain numbers so it round-trips through JSON.
///
/// SwiftUI's `Color` is not Codable, and it is not guaranteed to be sRGB
/// underneath either — a colour picked from the system picker can arrive in
/// extended range. Everything is clamped to 0...1 on the way in.
struct RGBA: Codable, Equatable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = Self.clamp(r)
        self.g = Self.clamp(g)
        self.b = Self.clamp(b)
        self.a = Self.clamp(a)
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255,
                  g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255,
                  a: alpha)
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        let wrapped = hue - floor(hue)
        UIColor(hue: CGFloat(wrapped),
                saturation: CGFloat(Self.clamp(saturation)),
                brightness: CGFloat(Self.clamp(brightness)),
                alpha: CGFloat(Self.clamp(alpha)))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    var uiColor: UIColor {
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    /// Perceived brightness, 0...1. Decides whether a palette is "light".
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// Anything that can be given a colour.
///
/// The first six are the palette's base roles and colour the surface
/// itself. The rest are widgets. Keyed by stable identity — a button's id,
/// a dial slot's id — never by position, so reordering buttons or deleting a
/// dial does not hand one widget's colour to its neighbour.
enum ColorComponent: Hashable, Sendable {
    case background, panel, raised, text, grid, accent
    case pad
    case morphCorner(Int)
    case drawbar(Int)
    case button(UUID)
    case dial(UUID)
    case meter(MotionSource)

    /// The base roles, in the order the CC map lists them.
    static let roles: [ColorComponent] = [.background, .panel, .raised, .text, .grid, .accent]

    /// The motion sources that have a meter on the deck. A mapping on any
    /// other source has nothing on screen to colour.
    static let meterSources: [MotionSource] = [.pitch, .roll, .yaw, .magnitude]

    var isRole: Bool { Self.roles.contains(self) }

    /// Storage key in `PresetColors.assignments`.
    var key: String {
        switch self {
        case .background:          return "role.background"
        case .panel:               return "role.panel"
        case .raised:              return "role.raised"
        case .text:                return "role.text"
        case .grid:                return "role.grid"
        case .accent:              return "role.accent"
        case .pad:                 return "pad"
        case .morphCorner(let i):  return "morph.\(i)"
        case .drawbar(let i):      return "drawbar.\(i)"
        case .button(let id):      return "button.\(id.uuidString)"
        case .dial(let id):        return "dial.\(id.uuidString)"
        case .meter(let source):   return "meter.\(source.rawValue)"
        }
    }

    var roleLabel: String {
        switch self {
        case .background: return "Background"
        case .panel:      return "Panels"
        case .raised:     return "Raised"
        case .text:       return "Text"
        case .grid:       return "Grid Lines"
        case .accent:     return "Accent"
        case .pad:        return "Pad"
        default:          return "Color"
        }
    }
}

// MARK: - Styles
//
// A palette says WHAT colours things are. A style says how they are drawn:
// how round the corners are, how heavy the borders, whether lit things glow,
// whether a lit button fills solid or just lights its outline, what the
// lettering looks like. The two are independent — any palette works in any
// style — and they are chosen in the same three layers (preset, surface,
// global), so a preset can say "Neon" without also having to say which
// colours.
//
// The first five are FLAT: they change numbers the views already use
// (radius, line width, shadow radius, fill opacity), so none costs more to
// draw than the Standard look, and Flat, Graphic and Candy cost less — they
// switch the glows off, which is the most expensive thing the pad draws.
//
// The rest are SHADED: each has a `Finish`, drawn as a gradient overlay and
// a gradient rim on every widget. Gradients are cheap — no offscreen pass —
// so the finish itself costs about what a border does. What costs is blur,
// and the shaded styles are held to at most ONE shadow per moving widget:
// the puck, fader thumb and drawbar handles trade their glow for a drop
// shadow rather than carrying both.

/// How a surface is drawn, independent of its colours.
enum SurfaceStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard, flat, neon, graphic, candy
    case clay, glass, metal, soft, plastic

    var id: String { rawValue }

    /// For the style menu, which lists the two families in their own sections.
    static let flatStyles: [SurfaceStyle] = [.standard, .flat, .neon, .graphic, .candy]
    static let shadedStyles: [SurfaceStyle] = [.clay, .glass, .metal, .soft, .plastic]

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .flat:     return "Flat"
        case .neon:     return "Neon"
        case .graphic:  return "Graphic"
        case .candy:    return "Candy"
        case .clay:     return "Clay"
        case .glass:    return "Glass"
        case .metal:    return "Metal"
        case .soft:     return "Soft"
        case .plastic:  return "Plastic"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "circle.lefthalf.filled"
        case .flat:     return "square.fill"
        case .neon:     return "bolt.fill"
        case .graphic:  return "square.grid.2x2"
        case .candy:    return "capsule.fill"
        case .clay:     return "circle.circle.fill"
        case .glass:    return "drop.fill"
        case .metal:    return "gearshape.fill"
        case .soft:     return "cloud.fill"
        case .plastic:  return "button.programmable"
        }
    }

    var blurb: String {
        switch self {
        case .standard: return "Soft glows and rounded corners — the original look."
        case .flat:     return "No glows or shadows. Clean, quiet, cheapest to draw."
        case .neon:     return "Lit outlines that glow. Best on a dark palette."
        case .graphic:  return "Square corners and heavy borders in the text colour."
        case .candy:    return "Pill shapes and colour-washed controls."
        case .clay:     return "Puffy, rounded, matte — like modelling clay."
        case .glass:    return "See-through controls with a glossy top edge."
        case .metal:    return "Brushed steel knobs and anodised buttons."
        case .soft:     return "Controls pressed out of the surface itself. Presses sink in."
        case .plastic:  return "Glossy hardware buttons, like a drum machine."
        }
    }

    var traits: StyleTraits {
        switch self {
        case .standard:
            return StyleTraits(cornerScale: 1, borderScale: 1, glowScale: 1,
                               dropShadows: true, inkBorders: false,
                               outlined: false, tintedIdle: false,
                               fontDesign: .rounded, labelWeight: .bold)
        case .flat:
            return StyleTraits(cornerScale: 0.6, borderScale: 1, glowScale: 0,
                               dropShadows: false, inkBorders: false,
                               outlined: false, tintedIdle: false,
                               fontDesign: .default, labelWeight: .semibold)
        case .neon:
            return StyleTraits(cornerScale: 1, borderScale: 1.5, glowScale: 1.6,
                               dropShadows: false, inkBorders: false,
                               outlined: true, tintedIdle: false,
                               fontDesign: .monospaced, labelWeight: .bold)
        case .graphic:
            return StyleTraits(cornerScale: 0.15, borderScale: 2.5, glowScale: 0,
                               dropShadows: false, inkBorders: true,
                               outlined: false, tintedIdle: false,
                               fontDesign: .default, labelWeight: .heavy)
        case .candy:
            return StyleTraits(cornerScale: 1.8, borderScale: 1, glowScale: 0,
                               dropShadows: false, inkBorders: false,
                               outlined: false, tintedIdle: true,
                               fontDesign: .rounded, labelWeight: .heavy)
        case .clay:
            return StyleTraits(cornerScale: 1.6, borderScale: 1, glowScale: 0,
                               dropShadows: true, inkBorders: false,
                               outlined: false, tintedIdle: true,
                               fontDesign: .rounded, labelWeight: .heavy,
                               finish: .clay)
        case .glass:
            return StyleTraits(cornerScale: 1.2, borderScale: 1, glowScale: 0.8,
                               dropShadows: true, inkBorders: false,
                               outlined: false, tintedIdle: true,
                               fontDesign: .rounded, labelWeight: .semibold,
                               finish: .glass)
        case .metal:
            return StyleTraits(cornerScale: 0.45, borderScale: 1, glowScale: 0.5,
                               dropShadows: true, inkBorders: false,
                               outlined: false, tintedIdle: false,
                               fontDesign: .default, labelWeight: .bold,
                               finish: .metal)
        case .soft:
            return StyleTraits(cornerScale: 1.3, borderScale: 1, glowScale: 0,
                               dropShadows: true, inkBorders: false,
                               outlined: false, tintedIdle: false,
                               fontDesign: .rounded, labelWeight: .semibold,
                               finish: .soft)
        case .plastic:
            return StyleTraits(cornerScale: 0.7, borderScale: 1, glowScale: 0.7,
                               dropShadows: true, inkBorders: false,
                               outlined: false, tintedIdle: true,
                               fontDesign: .default, labelWeight: .heavy,
                               finish: .plastic)
        }
    }
}

/// The surface treatment of a shaded style. `.none` for every flat style.
enum Finish: Sendable {
    case none, clay, glass, metal, soft, plastic

    /// Clay and Soft read their shape from shading alone; a resting
    /// outline would flatten them back into a drawing. They still draw an
    /// edge while lit, which is how a touch shows.
    var hidesRestingEdge: Bool { self == .clay || self == .soft }
}

/// The numbers a style changes. Views never switch on the style itself —
/// they ask the theme for a radius, a line width, a glow — so adding a
/// style is adding a row here, not touching every view.
struct StyleTraits {
    /// Multiplies every corner radius. SwiftUI clamps a radius to half the
    /// shape's short side, so a large scale turns bars into pills rather
    /// than breaking them.
    var cornerScale: CGFloat
    /// Multiplies border widths.
    var borderScale: CGFloat
    /// Multiplies glow radii. Zero removes the shadow effect entirely rather
    /// than drawing a clear one, which is where the saving comes from.
    var glowScale: CGFloat
    /// The dial face's drop shadow.
    var dropShadows: Bool
    /// Borders in the text colour instead of the widget's own colour.
    var inkBorders: Bool
    /// Lit widgets light their outline and a faint wash instead of filling
    /// solid, and resting widgets show their outline.
    var outlined: Bool
    /// Resting widgets carry a wash of their own colour rather than sitting
    /// on the plain raised panel.
    var tintedIdle: Bool
    var fontDesign: Font.Design
    var labelWeight: Font.Weight
    /// Shading drawn over every widget. Defaulted, so the flat styles'
    /// rows above never mention it.
    var finish: Finish = .none

    var shaded: Bool { finish != .none }
}

/// A named set of colours.
struct ColorPalette: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var background: RGBA
    var panel: RGBA
    var raised: RGBA
    var text: RGBA
    /// Translucent on purpose: grid lines sit over panels and should read
    /// as texture, not as drawing.
    var grid: RGBA
    var accent: RGBA
    /// The component colours widgets choose from. Never empty.
    var swatches: [RGBA]

    static let maxSwatches = 16

    /// Wraps rather than failing, so a widget assigned colour 9 still gets a
    /// colour after switching to a palette with only 8 — and the palettes
    /// with fewer colours still give neighbouring widgets different ones.
    func swatch(_ index: Int) -> RGBA? {
        guard !swatches.isEmpty, index >= 0 else { return nil }
        return swatches[index % swatches.count]
    }

    func base(_ role: ColorComponent) -> RGBA {
        switch role {
        case .background: return background
        case .panel:      return panel
        case .raised:     return raised
        case .text:       return text
        case .grid:       return grid
        default:          return accent
        }
    }

    mutating func setBase(_ role: ColorComponent, to value: RGBA) {
        switch role {
        case .background: background = value
        case .panel:      panel = value
        case .raised:     raised = value
        case .text:       text = value
        case .grid:       grid = value
        case .accent:     accent = value
        default:          break
        }
    }

    var isLight: Bool { background.luminance > 0.5 }
}

extension ColorPalette {
    enum CodingKeys: String, CodingKey {
        case id, name, background, panel, raised, text, grid, accent, swatches
    }

    /// Lenient, like every other stored type here, so a palette written by a
    /// later build with a field this one lacks still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ColorPalette.classic
        id         = try c.decodeIfPresent(UUID.self,   forKey: .id)         ?? UUID()
        name       = try c.decodeIfPresent(String.self, forKey: .name)       ?? "Palette"
        background = try c.decodeIfPresent(RGBA.self,   forKey: .background) ?? fallback.background
        panel      = try c.decodeIfPresent(RGBA.self,   forKey: .panel)      ?? fallback.panel
        raised     = try c.decodeIfPresent(RGBA.self,   forKey: .raised)     ?? fallback.raised
        text       = try c.decodeIfPresent(RGBA.self,   forKey: .text)       ?? fallback.text
        grid       = try c.decodeIfPresent(RGBA.self,   forKey: .grid)       ?? fallback.grid
        accent     = try c.decodeIfPresent(RGBA.self,   forKey: .accent)     ?? fallback.accent
        let decoded = try c.decodeIfPresent([RGBA].self, forKey: .swatches) ?? []
        swatches = decoded.isEmpty ? [accent] : Array(decoded.prefix(Self.maxSwatches))
    }
}

// MARK: - Built-in palettes

extension ColorPalette {
    /// Fixed ids, so a preset that picked "Neon" still finds it after an
    /// update, and so built-ins can be told apart from copies.
    private static func builtIn(_ suffix: String, _ name: String,
                                bg: UInt32, panel: UInt32, raised: UInt32,
                                text: UInt32, grid: RGBA? = nil,
                                accent: UInt32, swatches: [UInt32]) -> ColorPalette {
        ColorPalette(id: UUID(uuidString: "6D6F7469-6F6E-4D49-4449-0000000000" + suffix)!,
                     name: name,
                     background: RGBA(hex: bg),
                     panel: RGBA(hex: panel),
                     raised: RGBA(hex: raised),
                     text: RGBA(hex: text),
                     grid: grid ?? RGBA(r: 1, g: 1, b: 1, a: 0.08),
                     accent: RGBA(hex: accent),
                     swatches: swatches.map { RGBA(hex: $0) })
    }

    /// The look the app has always had. Every base value is exactly the
    /// old constant, so an install that never touches colour looks the
    /// same after this update as before it.
    static let classic = builtIn("01", "Classic",
        bg: 0x0B0C0F, panel: 0x14161B, raised: 0x1C1F26, text: 0xFFFFFF,
        accent: 0xF2A65A,
        swatches: [0xF2A65A, 0x5AB8F2, 0x7ED67E, 0xE86BA8,
                   0xB48CF2, 0xF2D35A, 0x4CC3A0, 0xF27A5A])

    static let neon = builtIn("02", "Neon",
        bg: 0x07060B, panel: 0x12101A, raised: 0x1B1826, text: 0xF4F0FF,
        accent: 0xFF3EA5,
        swatches: [0xFF3EA5, 0x00E5FF, 0xB6FF00, 0xFFE600,
                   0x9D4DFF, 0xFF6B00, 0x00FF9C, 0xFF1744])

    static let pastel = builtIn("03", "Pastel",
        bg: 0x16161C, panel: 0x1F1F28, raised: 0x292936, text: 0xF5F3FF,
        accent: 0xF7B2C4,
        swatches: [0xF7B2C4, 0xA8D8EA, 0xC3E6B0, 0xFFE3A3,
                   0xCDB4F6, 0xFFC9A9, 0xB5EAD7, 0xF6A6B2])

    static let ocean = builtIn("04", "Ocean",
        bg: 0x06121A, panel: 0x0C1C27, raised: 0x132835, text: 0xE6F6FF,
        accent: 0x3FC1E0,
        swatches: [0x3FC1E0, 0x2E86DE, 0x48E5C2, 0x7FDBFF,
                   0x5C7CFA, 0x9BE7FF, 0x1ABC9C, 0xA0C4FF])

    static let sunset = builtIn("05", "Sunset",
        bg: 0x140A0C, panel: 0x1E1114, raised: 0x2A181C, text: 0xFFF1E8,
        accent: 0xFF7B54,
        swatches: [0xFF7B54, 0xFFB26B, 0xFFD56F, 0xE84A5F,
                   0xC06C84, 0xF67280, 0xFF9A8B, 0x9D7BB0])

    static let forest = builtIn("06", "Forest",
        bg: 0x0A100C, panel: 0x121A15, raised: 0x1A251E, text: 0xEEF5EC,
        accent: 0x8BC34A,
        swatches: [0x8BC34A, 0xCDDC39, 0x4CAF50, 0xC4A484,
                   0xFFB74D, 0x26A69A, 0xDCE775, 0x81C784])

    static let mono = builtIn("07", "Mono",
        bg: 0x0B0B0B, panel: 0x161616, raised: 0x202020, text: 0xF2F2F2,
        accent: 0xE0E0E0,
        swatches: [0xF2F2F2, 0xBDBDBD, 0x9E9E9E, 0xE0E0E0,
                   0x757575, 0xD0D0D0, 0xAFAFAF, 0x8A8A8A])

    /// Light background, for outdoor stages where a dark screen washes out.
    static let daylight = builtIn("08", "Daylight",
        bg: 0xF2F0EB, panel: 0xFFFFFF, raised: 0xE8E5DE, text: 0x1C1C1E,
        grid: RGBA(r: 0, g: 0, b: 0, a: 0.10),
        accent: 0xE0692B,
        swatches: [0xE0692B, 0x2B7BE0, 0x2EA05A, 0xC93A7B,
                   0x7A4FD1, 0xC9960F, 0x1F9E9E, 0xD1452B])

    /// Warm browns and greens. Pairs with Flat.
    static let earth = builtIn("09", "Earth",
        bg: 0x17130F, panel: 0x221C16, raised: 0x2D251D, text: 0xF1E9DC,
        accent: 0xD08C4F,
        swatches: [0xD08C4F, 0x8C9A5B, 0xD9A441, 0xB5654A,
                   0xA3B18A, 0xE3C79A, 0x6E7F4F, 0x9E4B2F])

    /// Purples and pinks. Pairs with Flat or Neon.
    static let plum = builtIn("0A", "Plum",
        bg: 0x150C18, panel: 0x201224, raised: 0x2B1830, text: 0xF6E9F7,
        accent: 0xC77DDB,
        swatches: [0xC77DDB, 0xE58FB7, 0x8E6CE0, 0xF2A2C0,
                   0xB35C9E, 0xD8B4F8, 0x7B4BA8, 0xF5C6E0])

    /// Bright colours on a light ground. Pairs with Candy.
    static let candy = builtIn("0B", "Candy",
        bg: 0xFFF4F8, panel: 0xFFFFFF, raised: 0xFFE6F0, text: 0x3A2140,
        grid: RGBA(r: 0, g: 0, b: 0, a: 0.08),
        accent: 0xFF5FA2,
        swatches: [0xFF5FA2, 0x2FB8F0, 0xF5B000, 0x3FC46A,
                   0xA070F5, 0xFF7A45, 0x19C2BF, 0xFF5A5A])

    /// Black ink on paper with a few spot colours. Pairs with Graphic.
    static let paper = builtIn("0C", "Paper",
        bg: 0xF5F5F0, panel: 0xFFFFFF, raised: 0xECECE6, text: 0x111111,
        grid: RGBA(r: 0, g: 0, b: 0, a: 0.12),
        accent: 0x111111,
        swatches: [0x111111, 0xE63946, 0x1D4ED8, 0xE8A400,
                   0x2A9D4B, 0x555555, 0xFF6F00, 0x7C3AED])

    static let builtIns: [ColorPalette] = [classic, neon, pastel, ocean,
                                           sunset, forest, mono, daylight,
                                           earth, plum, candy, paper]

    /// A fresh dark palette with evenly scattered hues.
    ///
    /// Golden-ratio hue steps: each colour lands as far as possible from the
    /// ones before it, so eight colours never bunch into two families the
    /// way random hues often do.
    static func random() -> ColorPalette {
        let base = Double.random(in: 0..<1)
        let saturation = Double.random(in: 0.55...0.8)
        let golden = 0.618_033_988_75

        // A plain loop with every value typed. As a single `map` expression
        // the two ternaries and the mixed literal arithmetic were more than
        // the type checker would solve in reasonable time.
        var swatches: [RGBA] = []
        for i in 0..<8 {
            let step: Double = Double(i)
            let hue: Double = base + step * golden
            let sat: Double = (i % 2 == 0) ? saturation : saturation - 0.12
            let bright: Double = (i % 3 == 2) ? 0.82 : 0.95
            swatches.append(RGBA(hue: hue, saturation: sat, brightness: bright))
        }

        let adjectives = ["Velvet", "Electric", "Midnight", "Candy", "Cosmic",
                          "Dusty", "Honey", "Glacier", "Ember", "Lunar"]
        let nouns = ["Groove", "Tide", "Garden", "Circuit", "Carnival",
                     "Orbit", "Lantern", "Parade", "Bloom", "Static"]
        let name = "\(adjectives.randomElement() ?? "New") \(nouns.randomElement() ?? "Palette")"

        return ColorPalette(id: UUID(),
                            name: name,
                            background: RGBA(hue: base, saturation: 0.35, brightness: 0.06),
                            panel: RGBA(hue: base, saturation: 0.30, brightness: 0.10),
                            raised: RGBA(hue: base, saturation: 0.26, brightness: 0.14),
                            text: RGBA(hue: base, saturation: 0.04, brightness: 0.97),
                            grid: RGBA(r: 1, g: 1, b: 1, a: 0.08),
                            accent: swatches[0],
                            swatches: swatches)
    }
}

// MARK: - Palette library

/// Every palette, plus the global and per-surface choices.
///
/// ONE instance for the whole app. Both surfaces observe the same object, so
/// editing a palette on one side repaints the other straight away — there is
/// no second copy to fall out of step, which is the problem the preset
/// library needs notifications to solve.
@MainActor
final class PaletteLibrary: ObservableObject {
    static let shared = PaletteLibrary()

    /// Palettes made or copied by the performer. Built-ins are not stored;
    /// they come from code, so an update can improve them.
    @Published private(set) var custom: [ColorPalette] {
        didSet { saveCustom() }
    }

    @Published var globalID: UUID {
        didSet { UserDefaults.standard.set(globalID.uuidString, forKey: Keys.global) }
    }

    /// Per-surface palettes. Only consulted while two surfaces are running.
    @Published private(set) var surfaceIDs: [Int: UUID] {
        didSet { saveSurfaces() }
    }

    @Published var globalStyle: SurfaceStyle {
        didSet { UserDefaults.standard.set(globalStyle.rawValue, forKey: Keys.globalStyle) }
    }

    /// Per-surface styles. Like surface palettes, only consulted while two
    /// surfaces are running.
    @Published private(set) var surfaceStyles: [Int: SurfaceStyle] {
        didSet { saveSurfaceStyles() }
    }

    private enum Keys {
        static let custom        = "MotionMIDIPro.customPalettes"
        static let global        = "MotionMIDIPro.globalPaletteID"
        static let surfaces      = "MotionMIDIPro.surfacePaletteIDs"
        static let globalStyle   = "MotionMIDIPro.globalStyle"
        static let surfaceStyles = "MotionMIDIPro.surfaceStyles"
    }

    private init() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Keys.custom),
           let decoded = try? JSONDecoder().decode([ColorPalette].self, from: data) {
            custom = decoded
        } else {
            custom = []
        }

        globalID = defaults.string(forKey: Keys.global).flatMap(UUID.init)
            ?? ColorPalette.classic.id

        var surfaces: [Int: UUID] = [:]
        if let raw = defaults.dictionary(forKey: Keys.surfaces) as? [String: String] {
            for (key, value) in raw {
                if let surface = Int(key), let id = UUID(uuidString: value) {
                    surfaces[surface] = id
                }
            }
        }
        surfaceIDs = surfaces

        // An unknown name — a style from a later build — falls back to
        // Standard rather than failing.
        globalStyle = defaults.string(forKey: Keys.globalStyle)
            .flatMap(SurfaceStyle.init(rawValue:)) ?? .standard

        var styles: [Int: SurfaceStyle] = [:]
        if let raw = defaults.dictionary(forKey: Keys.surfaceStyles) as? [String: String] {
            for (key, value) in raw {
                if let surface = Int(key), let style = SurfaceStyle(rawValue: value) {
                    styles[surface] = style
                }
            }
        }
        surfaceStyles = styles
    }

    private func saveSurfaceStyles() {
        var raw: [String: String] = [:]
        for (surface, style) in surfaceStyles { raw[String(surface)] = style.rawValue }
        UserDefaults.standard.set(raw, forKey: Keys.surfaceStyles)
    }

    private func saveCustom() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Keys.custom)
        }
    }

    private func saveSurfaces() {
        var raw: [String: String] = [:]
        for (surface, id) in surfaceIDs { raw[String(surface)] = id.uuidString }
        UserDefaults.standard.set(raw, forKey: Keys.surfaces)
    }

    // MARK: Lookup

    var all: [ColorPalette] { ColorPalette.builtIns + custom }

    func palette(_ id: UUID?) -> ColorPalette? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    var global: ColorPalette { palette(globalID) ?? .classic }

    func isBuiltIn(_ id: UUID) -> Bool {
        ColorPalette.builtIns.contains { $0.id == id }
    }

    func surfacePaletteID(for surface: Int) -> UUID? { surfaceIDs[surface] }

    func setSurfacePalette(_ id: UUID?, for surface: Int) {
        surfaceIDs[surface] = id
    }

    /// An id that points at a deleted palette simply falls through to the
    /// next layer, so deleting a palette never leaves anything uncoloured.
    func resolvedPalette(for preset: Preset, surface: Int, dual: Bool) -> ColorPalette {
        if let own = palette(preset.colors.paletteID) { return own }
        if dual, let side = palette(surfaceIDs[surface]) { return side }
        return global
    }

    /// What a preset that names no palette would get: the layers below it.
    func inheritedPalette(surface: Int, dual: Bool) -> ColorPalette {
        if dual, let side = palette(surfaceIDs[surface]) { return side }
        return global
    }

    func surfaceStyle(for surface: Int) -> SurfaceStyle? { surfaceStyles[surface] }

    func setSurfaceStyle(_ style: SurfaceStyle?, for surface: Int) {
        surfaceStyles[surface] = style
    }

    /// What a preset that names no style would get.
    func inheritedStyle(surface: Int, dual: Bool) -> SurfaceStyle {
        if dual, let side = surfaceStyles[surface] { return side }
        return globalStyle
    }

    /// Same order as palettes: preset, then surface (two surfaces only),
    /// then global.
    func resolvedStyle(for preset: Preset, surface: Int, dual: Bool) -> SurfaceStyle {
        preset.colors.style ?? inheritedStyle(surface: surface, dual: dual)
    }

    func theme(for preset: Preset, surface: Int, dual: Bool) -> ThemeColors {
        ThemeColors(palette: resolvedPalette(for: preset, surface: surface, dual: dual),
                    assignments: preset.colors.assignments,
                    style: resolvedStyle(for: preset, surface: surface, dual: dual))
    }

    // MARK: Editing

    /// Copies any palette — built-in or custom — into an editable one.
    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard var copy = palette(id) else { return nil }
        copy.id = UUID()
        copy.name = uniqueName(copy.name + " Copy")
        custom.append(copy)
        return copy.id
    }

    @discardableResult
    func createRandom() -> UUID {
        var fresh = ColorPalette.random()
        fresh.name = uniqueName(fresh.name)
        custom.append(fresh)
        return fresh.id
    }

    /// Built-ins are read-only: this silently does nothing for them, and the
    /// editor offers Duplicate instead of fields.
    func update(_ id: UUID, _ mutate: (inout ColorPalette) -> Void) {
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }
        var edited = custom[index]
        mutate(&edited)
        edited.id = id
        if edited.swatches.isEmpty { edited.swatches = [edited.accent] }
        if edited.swatches.count > ColorPalette.maxSwatches {
            edited.swatches = Array(edited.swatches.prefix(ColorPalette.maxSwatches))
        }
        guard edited != custom[index] else { return }
        custom[index] = edited
    }

    /// Anything pointing at the deleted palette falls back a layer.
    func delete(_ id: UUID) {
        guard !isBuiltIn(id) else { return }
        custom.removeAll { $0.id == id }
        if globalID == id { globalID = ColorPalette.classic.id }
        let orphaned = surfaceIDs.filter { $0.value == id }.map { $0.key }
        for surface in orphaned { surfaceIDs[surface] = nil }
    }

    func uniqueName(_ proposed: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Palette" : trimmed
        let taken = Set(all.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }
}

// MARK: - Resolved theme

/// The colours one part of the screen is actually drawn with.
///
/// Handed down through the environment rather than read from statics,
/// because two surfaces can be on screen at once in different colours — a
/// static has one value for the whole app. Each surface injects its own at
/// its root, and each widget narrows it further with `accented(_:)`.
struct ThemeColors: Sendable {
    let palette: ColorPalette
    let assignments: [String: Int]
    let style: SurfaceStyle

    private(set) var bg: Color
    private(set) var panel: Color
    private(set) var panel2: Color
    private(set) var text: Color
    private(set) var grid: Color
    private(set) var accent: Color

    /// Status colours. Deliberately NOT part of a palette: green means sent
    /// and red means conflict whatever the stage looks like.
    let good   = Color(red: 0x4C / 255, green: 0xC3 / 255, blue: 0x8A / 255)
    let danger = Color(red: 0xE5 / 255, green: 0x5A / 255, blue: 0x5A / 255)

    let isLight: Bool
    private let gridRGBA: RGBA

    var dim: Color { text.opacity(0.45) }

    init(palette: ColorPalette, assignments: [String: Int] = [:],
         style: SurfaceStyle = .standard) {
        self.palette = palette
        self.assignments = assignments
        self.style = style

        func pick(_ role: ColorComponent) -> RGBA {
            if let index = assignments[role.key], let swatch = palette.swatch(index) {
                return swatch
            }
            return palette.base(role)
        }

        let bgRGBA = pick(.background)

        // A component colour is opaque, and a grid drawn in it at full
        // strength would stop being a grid. Keep the hue, keep it faint.
        var gridPick = pick(.grid)
        if assignments[ColorComponent.grid.key] != nil {
            gridPick = gridPick.withAlpha(0.4)
        }

        bg       = bgRGBA.color
        panel    = pick(.panel).color
        panel2   = pick(.raised).color
        text     = pick(.text).color
        accent   = pick(.accent).color
        grid     = gridPick.color
        gridRGBA = gridPick
        isLight  = bgRGBA.luminance > 0.5
    }

    /// What a component is drawn in: its assigned palette colour, or the
    /// accent when it has none.
    func color(for component: ColorComponent) -> Color {
        switch component {
        case .background: return bg
        case .panel:      return panel
        case .raised:     return panel2
        case .text:       return text
        case .grid:       return grid
        case .accent:     return accent
        default:
            if let index = assignments[component.key],
               let swatch = palette.swatch(index) {
                return swatch.color
            }
            return accent
        }
    }

    private func assigned(_ component: ColorComponent) -> RGBA? {
        guard let index = assignments[component.key] else { return nil }
        return palette.swatch(index)
    }

    /// What a component shows when it has no colour of its own. Morph
    /// corners and drawbars sit on the pad, so they fall back to the pad's
    /// colour; every other widget falls back to the accent.
    func fallbackRGBA(for component: ColorComponent) -> RGBA {
        switch component {
        case .background, .panel, .raised, .text, .grid, .accent:
            return palette.base(component)
        case .morphCorner, .drawbar:
            return resolvedRGBA(for: .pad)
        default:
            return assigned(.accent) ?? palette.accent
        }
    }

    /// What a component is drawn in, as numbers — for the CC map's dots and
    /// menu swatches, which need a colour they can render as a bitmap.
    func resolvedRGBA(for component: ColorComponent) -> RGBA {
        assigned(component) ?? fallbackRGBA(for: component)
    }

    /// This theme with the accent replaced by a component's colour.
    ///
    /// How a widget gets its own colour without every line inside it
    /// changing: the button, dial and meter views still draw in "accent",
    /// and the parent hands them a theme whose accent IS their colour.
    func accented(_ component: ColorComponent) -> ThemeColors {
        var copy = self
        copy.accent = color(for: component)
        return copy
    }

    /// A grid line at the strength the old code drew `white.opacity(x)`.
    ///
    /// Scaled against the classic grid's 0.08, so every hairline, lane
    /// divider and track keeps its relative weight in any palette — and in
    /// Classic lands exactly where it always did.
    func line(_ whiteOpacity: Double) -> Color {
        let scaled: Double = gridRGBA.a * whiteOpacity / 0.08
        return Color(.sRGB, red: gridRGBA.r, green: gridRGBA.g, blue: gridRGBA.b,
                     opacity: min(1.0, scaled))
    }

    // MARK: Style

    var traits: StyleTraits { style.traits }

    /// A corner radius scaled for the style.
    func radius(_ base: CGFloat) -> CGFloat { base * traits.cornerScale }

    /// A border width scaled for the style.
    func stroke(_ base: CGFloat) -> CGFloat { base * traits.borderScale }

    /// The border of a widget at rest.
    ///
    /// `quiet` is what Standard has always drawn there — usually a faint
    /// grid line. Graphic draws it in ink; Neon shows the widget's outline
    /// in its own colour, which is what makes a dark Neon screen read as
    /// lit tubes rather than empty boxes.
    func restingEdge(_ widget: Color, quiet: Color) -> Color {
        if traits.finish.hidesRestingEdge { return Color.clear }
        if traits.finish == .glass { return widget.opacity(0.45) }
        if traits.inkBorders { return text }
        if traits.outlined { return widget.opacity(0.55) }
        return quiet
    }

    /// The border of a widget that is on. Ink in Graphic, the widget's own
    /// colour everywhere else.
    func activeEdge(_ widget: Color) -> Color {
        traits.inkBorders ? text : widget
    }

    /// What a lit widget is filled with.
    func litFill(_ widget: Color) -> Color {
        if traits.finish == .glass { return widget.opacity(0.6) }
        return traits.outlined ? widget.opacity(0.22) : widget
    }

    /// Lettering on a lit widget. On a solid fill that is the background
    /// colour, cut out of the widget; on Neon's faint wash it stays the
    /// widget's colour.
    func litForeground(_ widget: Color) -> Color {
        if traits.finish == .glass { return text }
        return traits.outlined ? widget : bg
    }

    /// What a resting widget is filled with.
    func restingFill(_ widget: Color) -> Color {
        switch traits.finish {
        case .clay:    return widget.opacity(isLight ? 0.35 : 0.4)
        case .glass:   return widget.opacity(0.14)
        case .metal:   return Color(white: isLight ? 0.80 : 0.30)
        case .soft:    return panel
        case .plastic: return widget.opacity(isLight ? 0.3 : 0.35)
        case .none:    break
        }
        if traits.tintedIdle { return widget.opacity(isLight ? 0.18 : 0.24) }
        if traits.outlined { return panel }
        return panel2
    }

    /// A label font in the style's lettering.
    func font(_ size: CGFloat, weight: Font.Weight? = nil) -> Font {
        .system(size: size, weight: weight ?? traits.labelWeight, design: traits.fontDesign)
    }

    func font(_ textStyle: Font.TextStyle) -> Font {
        .system(textStyle, design: traits.fontDesign).weight(traits.labelWeight)
    }

    static let classic = ThemeColors(palette: .classic)
}

extension View {
    /// A coloured glow, scaled by the style.
    ///
    /// When the style has no glow the shadow modifier is left off entirely
    /// rather than drawn clear — an offscreen blur pass per frame is the
    /// cost being avoided, and a clear shadow still pays it. The branch only
    /// flips when the style changes, never mid-gesture, so the view identity
    /// change it causes is harmless.
    ///
    /// `when` narrows it further for widgets that only glow in some styles.
    /// It must depend on the style alone, never on touch state — a press
    /// that flipped it would rebuild the view and drop the gesture.
    @ViewBuilder
    func themeGlow(_ theme: ThemeColors, _ color: Color, radius: CGFloat,
                   when styleAllows: Bool = true) -> some View {
        let scale: CGFloat = theme.traits.glowScale
        if scale > 0 && styleAllows {
            self.shadow(color: color, radius: radius * scale)
        } else {
            self
        }
    }

    /// The raised-object drop shadow, for styles that have one.
    ///
    /// Soft draws it as a pair — a light one up and to the left, a dark one
    /// down and to the right — which is what makes a control look pushed out
    /// of the surface. Two blurs, so `single` drops the light one on
    /// anything that moves with a finger.
    @ViewBuilder
    func themeDropShadow(_ theme: ThemeColors, radius: CGFloat, y: CGFloat,
                         single: Bool = false) -> some View {
        if theme.traits.dropShadows {
            if theme.traits.finish == .soft && !single {
                self
                    .shadow(color: theme.softHighlight, radius: radius, x: -y, y: -y)
                    .shadow(color: theme.softShade, radius: radius, x: y, y: y)
            } else if theme.traits.finish == .soft {
                self.shadow(color: theme.softShade, radius: radius, x: y, y: y)
            } else {
                self.shadow(color: Color.black.opacity(theme.isLight ? 0.25 : 0.45),
                            radius: radius, y: y)
            }
        } else {
            self
        }
    }

    /// A drop shadow in the shaded styles only.
    ///
    /// For widgets that never had one in Standard — buttons, the puck,
    /// fader thumbs, drawbar handles — so adding depth to the shaded styles
    /// leaves the original look exactly as it was.
    @ViewBuilder
    func themeDepth(_ theme: ThemeColors, radius: CGFloat, y: CGFloat,
                    single: Bool = false) -> some View {
        if theme.traits.shaded {
            self.themeDropShadow(theme, radius: radius, y: y, single: single)
        } else {
            self
        }
    }

    /// The shaded styles' surface: a gradient over the fill and a gradient
    /// rim, clipped to `shape`. Nothing at all in the flat styles.
    ///
    /// `lit` is plain data inside the overlay, not a branch out here, so a
    /// press that flips it never changes the identity of the view carrying
    /// the gesture. `round` swaps Metal's straight banding for the circular
    /// brushing of a turned knob.
    @ViewBuilder
    func themeFinish<S: InsettableShape>(_ theme: ThemeColors, _ shape: S,
                                         lit: Bool = false, round: Bool = false,
                                         strength: Double = 1) -> some View {
        if theme.traits.shaded {
            self.overlay(
                FinishOverlay(finish: theme.traits.finish, shape: shape,
                              lit: lit, round: round, isLight: theme.isLight,
                              strength: strength)
                    .allowsHitTesting(false)
            )
        } else {
            self
        }
    }
}

extension ThemeColors {
    /// Soft's two shadows. On a light ground the highlight is near white;
    /// on a dark one it is barely there, or the controls look chalky.
    var softHighlight: Color {
        Color.white.opacity(isLight ? 0.85 : 0.07)
    }

    var softShade: Color {
        Color.black.opacity(isLight ? 0.18 : 0.55)
    }
}

/// The shading a `Finish` lays over a widget.
///
/// All of it is gradients — no blur, no material — so it redraws at touch
/// rate on the puck for about the price of a stroke.
struct FinishOverlay<S: InsettableShape>: View {
    let finish: Finish
    let shape: S
    let lit: Bool
    let round: Bool
    let isLight: Bool
    let strength: Double

    var body: some View {
        ZStack {
            shape.fill(surface(for: finish))
            shape.strokeBorder(rim(for: finish), lineWidth: rimWidth)
        }
    }

    private var rimWidth: CGFloat {
        switch finish {
        case .clay:  return 1.5
        case .glass: return 1
        default:     return 1
        }
    }

    private func white(_ a: Double) -> Color { Color.white.opacity(a * strength) }
    private func black(_ a: Double) -> Color { Color.black.opacity(a * strength) }

    private func linear(_ stops: [Gradient.Stop],
                        _ start: UnitPoint, _ end: UnitPoint) -> AnyShapeStyle {
        AnyShapeStyle(LinearGradient(stops: stops, startPoint: start, endPoint: end))
    }

    private func surface(for finish: Finish) -> AnyShapeStyle {
        switch finish {
        case .clay:
            // A soft lump: light falls on the top left and rolls off. Pressed,
            // the highlight flattens as if squashed.
            let top: Double = lit ? 0.10 : 0.28
            let bottom: Double = lit ? 0.28 : 0.22
            return linear([.init(color: white(top), location: 0),
                           .init(color: Color.clear, location: 0.45),
                           .init(color: black(bottom), location: 1)],
                          .topLeading, .bottomTrailing)

        case .glass:
            // The hard-edged gloss of a glass bead: a bright upper half
            // that stops at a line, then almost nothing.
            let gloss: Double = isLight ? 0.45 : 0.32
            return linear([.init(color: white(gloss), location: 0),
                           .init(color: white(0.08), location: 0.48),
                           .init(color: Color.clear, location: 0.5),
                           .init(color: white(0.06), location: 1)],
                          .top, .bottom)

        case .metal:
            if round {
                // Turned metal: bright and dark sectors around the centre.
                let colors: [Color] = [white(0.35), black(0.25), white(0.30),
                                       black(0.30), white(0.35), black(0.25),
                                       white(0.30), black(0.30), white(0.35)]
                return AnyShapeStyle(AngularGradient(gradient: Gradient(colors: colors),
                                                     center: .center,
                                                     startAngle: .degrees(0),
                                                     endAngle: .degrees(360)))
            }
            return linear([.init(color: white(0.45), location: 0),
                           .init(color: white(0.10), location: 0.35),
                           .init(color: black(0.10), location: 0.5),
                           .init(color: white(0.15), location: 0.62),
                           .init(color: black(0.30), location: 1)],
                          .top, .bottom)

        case .soft:
            // Raised: lit from the top left. Pressed: the same light now
            // falls into a hollow, so the gradient runs the other way.
            let light: Color = white(isLight ? 0.35 : 0.08)
            let dark: Color = black(isLight ? 0.08 : 0.22)
            let stops: [Gradient.Stop] = lit
                ? [.init(color: dark, location: 0), .init(color: light, location: 1)]
                : [.init(color: light, location: 0), .init(color: dark, location: 1)]
            return linear(stops, .topLeading, .bottomTrailing)

        case .plastic:
            // Moulded, glossy: a bright band along the top, darker toward
            // the base. A lit key keeps its gloss — it is the LED inside
            // that changes, not the plastic.
            return linear([.init(color: white(0.50), location: 0),
                           .init(color: white(0.15), location: 0.46),
                           .init(color: Color.clear, location: 0.5),
                           .init(color: black(0.18), location: 1)],
                          .top, .bottom)

        case .none:
            return AnyShapeStyle(Color.clear)
        }
    }

    private func rim(for finish: Finish) -> AnyShapeStyle {
        switch finish {
        case .clay:
            return linear([.init(color: white(0.40), location: 0),
                           .init(color: Color.clear, location: 0.5),
                           .init(color: black(0.18), location: 1)],
                          .topLeading, .bottomTrailing)
        case .glass:
            return linear([.init(color: white(0.70), location: 0),
                           .init(color: white(0.10), location: 0.5),
                           .init(color: white(0.30), location: 1)],
                          .top, .bottom)
        case .metal:
            return linear([.init(color: white(0.60), location: 0),
                           .init(color: black(0.50), location: 1)],
                          .top, .bottom)
        case .soft:
            let light: Color = white(isLight ? 0.6 : 0.10)
            let dark: Color = black(isLight ? 0.10 : 0.30)
            let stops: [Gradient.Stop] = lit
                ? [.init(color: dark, location: 0), .init(color: light, location: 1)]
                : [.init(color: light, location: 0), .init(color: dark, location: 1)]
            return linear(stops, .topLeading, .bottomTrailing)
        case .plastic:
            return linear([.init(color: white(0.35), location: 0),
                           .init(color: black(0.40), location: 1)],
                          .top, .bottom)
        case .none:
            return AnyShapeStyle(Color.clear)
        }
    }
}

private struct ThemeColorsKey: EnvironmentKey {
    static let defaultValue = ThemeColors.classic
}

extension EnvironmentValues {
    var theme: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }
}

/// Coloured dots for menus.
///
/// Menus render SF Symbols as monochrome templates, so a tinted
/// `circle.fill` shows up grey. A bitmap marked `.alwaysOriginal` keeps its
/// colour.
enum SwatchImage {
    static func make(_ rgba: RGBA, diameter: CGFloat = 18) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            rgba.uiColor.setFill()
            context.cgContext.fillEllipse(in: rect)
            UIColor.gray.withAlphaComponent(0.6).setStroke()
            context.cgContext.setLineWidth(1)
            context.cgContext.strokeEllipse(in: rect)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// The first few colours of a palette side by side, for palette menus.
    static func strip(_ colors: [RGBA], count: Int = 4, diameter: CGFloat = 14) -> UIImage {
        let shown: [RGBA] = Array(colors.prefix(count))
        let overlap: CGFloat = diameter * 0.3
        let advance: CGFloat = diameter - overlap
        let gaps: CGFloat = CGFloat(max(shown.count - 1, 0))
        let width: CGFloat = diameter + gaps * advance
        let size = CGSize(width: max(width, diameter), height: diameter)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            for (index, rgba) in shown.enumerated() {
                let x: CGFloat = CGFloat(index) * advance
                let rect = CGRect(x: x, y: 0, width: diameter, height: diameter).insetBy(dx: 0.5, dy: 0.5)
                rgba.uiColor.setFill()
                context.cgContext.fillEllipse(in: rect)
                UIColor.gray.withAlphaComponent(0.6).setStroke()
                context.cgContext.setLineWidth(1)
                context.cgContext.strokeEllipse(in: rect)
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

/// Reusable compact wheel for MIDI-sized integer settings.
///
/// Steppers made the editor feel like a series of +/- counters. This keeps
/// the label visible while giving every numeric MIDI setting the same direct,
/// scrollable wheel interaction.
struct IntWheelRow: View {
    let title: String
    @Binding var selection: Int
    let range: ClosedRange<Int>
    let text: (Int) -> String
    /// Wheel width. Rows whose text is longer than a bare number need more
    /// than the default, or the label truncates to an ellipsis and the wheel
    /// stops saying what it is showing.
    let wheelWidth: CGFloat

    init(title: String,
         selection: Binding<Int>,
         range: ClosedRange<Int>,
         wheelWidth: CGFloat = 140,
         text: @escaping (Int) -> String = { String($0) }) {
        self.title = title
        self._selection = selection
        self.range = range
        self.wheelWidth = wheelWidth
        self.text = text
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Picker(title, selection: $selection) {
                ForEach(Array(range), id: \.self) { value in
                    Text(text(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.wheel)
            .frame(width: wheelWidth, height: 92)
            .clipped()
        }
    }
}

/// Narrow variant used inside the 2x2 morph-corner cards.
struct CompactIntWheel: View {
    let title: String
    @Binding var selection: Int
    let range: ClosedRange<Int>
    let text: (Int) -> String

    init(title: String,
         selection: Binding<Int>,
         range: ClosedRange<Int>,
         text: @escaping (Int) -> String = { String($0) }) {
        self.title = title
        self._selection = selection
        self.range = range
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)

            Picker(title, selection: $selection) {
                ForEach(Array(range), id: \.self) { value in
                    Text(text(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .clipped()
        }
    }
}

enum MIDIWheelText {
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func note(_ value: Int) -> String {
        let clamped = min(max(value, 0), 127)
        return "\(noteNames[clamped % 12])\(clamped / 12 - 1)  ·  \(clamped)"
    }
}
