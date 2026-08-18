import SwiftUI
import UIKit

// MARK: - Pad surface mode (the three buttons)

/// What the pad is doing right now, as ONE choice out of three.
///
/// The underlying config still stores this as two independent flags —
/// `XYPadMode` (cc / notes) and `CCPadMode` (standard / morph) — which is
/// four combinations describing three real states: "notes + morph" is
/// meaningless, because morph only ever applied to the CC path. The old
/// header exposed both flags as separate segmented pickers, so reaching
/// 4-Corner meant setting two controls and knowing that one of them was
/// ignored in the other mode.
///
/// This collapses the pair into the three states that actually exist. The
/// stored flags are untouched — every preset on disk still decodes, and the
/// engine still reads `mode` and `ccMode` exactly as before.
enum XYSurfaceMode: String, CaseIterable, Identifiable {
    case standard
    case morph
    case notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "XY"
        case .morph:    return "4C"
        case .notes:    return "Notes"
        }
    }

    var longLabel: String {
        switch self {
        case .standard: return "Standard XY"
        case .morph:    return "4-Corner Morph"
        case .notes:    return "Notes"
        }
    }

    /// Drop a matching image into Assets with this name and the button uses
    /// it automatically — see `PadModeButton`, which checks at runtime and
    /// falls back to `symbol` until the asset exists.
    var imageName: String {
        switch self {
        case .standard: return "PadModeXY"
        case .morph:    return "PadModeMorph"
        case .notes:    return "PadModeNotes"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "circle.grid.cross"
        case .morph:    return "square.grid.2x2"
        case .notes:    return "music.note"
        }
    }
}

/// One of the three pad-mode buttons.
///
/// The image IS the button — no chip, no border, no background plate. Those
/// containers were costing width that the preset name needs, and once the
/// artwork carries the meaning the plate around it is just decoration.
///
/// Selection is therefore shown ON the artwork rather than around it:
/// the active mode sits at full opacity and full size, the inactive ones
/// are dimmed and fractionally smaller. That reads at a glance without
/// requiring the images themselves to have selected/unselected variants.
///
/// Uses the custom asset when it is present in the bundle and an SF Symbol
/// when it is not, so the layout is final before the artwork lands and
/// dropping the three images in later needs no code change.
struct PadModeButton: View {
    let mode: XYSurfaceMode
    let selected: Bool
    let action: () -> Void

    /// Visual size of the artwork. The tap target is padded out beyond this
    /// below, since a 34pt image is under the 44pt minimum a finger needs.
    private let side: CGFloat = 34

    private var customImage: UIImage? { UIImage(named: mode.imageName) }

    var body: some View {
        Button(action: action) {
            Group {
                if let image = customImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
            }
            .frame(width: side, height: side)
            .opacity(selected ? 1 : 0.38)
            .scaleEffect(selected ? 1 : 0.88)
            .shadow(color: selected ? Theme.accent.opacity(0.45) : .clear, radius: 5)
            .animation(.easeOut(duration: 0.15), value: selected)
            // Keeps the finger target at 44pt without making the artwork
            // bigger or spacing the row out.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.longLabel)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The three buttons as a unit. Used in the pad header AND as the heading of
/// the config sheet, so the same control means the same thing in both places.
///
/// Spacing defaults to zero because each button already pads its artwork out
/// to a 44pt tap target — the gap is built in, and adding more on top just
/// spends width the preset name wants.
struct PadModeSelector: View {
    @Binding var selection: XYSurfaceMode
    var spacing: CGFloat = 0

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(XYSurfaceMode.allCases) { mode in
                PadModeButton(mode: mode, selected: selection == mode) {
                    guard selection != mode else { return }
                    selection = mode
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }
}

// MARK: - XY pad

/// Large expressive XY pad with three surface modes:
///
///   • Standard XY — X and Y each send an independent CC (uses the first touch).
///   • 4-Corner    — four CCs blended by proximity to each corner.
///   • Notes       — position ALONG the chosen diagonal selects a pitch.
///                   Supports 1, 2, or 3 simultaneous voices. Each finger is
///                   a voice: touch = Note On, release = Note Off.
///
/// ── Voice stealing and restore ──────────────────────────────────────────
/// When a finger lands beyond the voice limit, the OLDEST sounding voice is
/// silenced and that finger is SUSPENDED — still held, just not sounding.
/// The moment a slot frees up, the most recently suspended finger gets its
/// voice back at wherever it has since moved to.
///
/// So in 1-voice mode: hold finger A, drop finger B (jumps to B's note),
/// lift B, and A comes back. That's the note-priority behavior of a classic
/// mono synth, and it works the same way at 2 and 3 voices once full.
struct XYPadView: View {
    @EnvironmentObject var app: AppState

    // ── CC-mode change tracking ─────────────────────────────────────────
    @State private var lastX = -1
    @State private var lastY = -1

    /// Last transmitted 7-bit value per morph corner, for duplicate
    /// suppression. -1 means "nothing sent yet", so the first move always
    /// transmits.
    @State private var lastMorph: [Int] = [-1, -1, -1, -1]
    /// Current corner levels purely for the on-pad meters.
    @State private var morphLevels: [Int] = [0, 0, 0, 0]

    /// Sounding voices, always kept sorted by `id` (ascending = oldest first,
    /// since ids are handed out in contact order). Index 0 is stolen first.
    @State private var voices: [Voice] = []

    /// Fingers still on the glass whose voice was taken. Ordered by WHEN they
    /// were suspended, most recent LAST — so restoring pops from the end.
    @State private var suspended: [Voice] = []

    @State private var showConfig = false
    /// Preset library, opened from the chip in this view's header — it used
    /// to live on the app-title row in ContentView.
    @State private var showPresetPicker = false

    private var cfg: XYPadConfig { app.preset.xyPad }
    private var touching: Bool { !voices.isEmpty }

    /// One voice, tied to a specific finger.
    struct Voice: Identifiable, Equatable {
        /// Stable identifier for the finger that owns this voice.
        let id: Int
        var x: Double
        var y: Double
        var note: Int
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            padSurface
        }
        .sheet(isPresented: $showConfig) {
            XYPadConfigSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $showPresetPicker) {
            PresetPickerSheet()
                .environmentObject(app)
        }
        // Keep the receiving synth's portamento in sync with the toggle,
        // wherever it was flipped from — config sheet or an assigned button.
        .onChange(of: cfg.glide) { _, isOn in
            sendPortamentoState(on: isOn)
        }
        .onChange(of: cfg.glideTime) { _, _ in
            if cfg.glide { sendGlideTime() }
        }
        .onChange(of: cfg.ccMode) { _, _ in
            // Clear dedupe state both ways, so the first move after a mode
            // switch always transmits rather than being suppressed as a
            // "duplicate" of whatever was last sent in the other mode.
            lastMorph = [-1, -1, -1, -1]
            morphLevels = [0, 0, 0, 0]
            lastX = -1
            lastY = -1
        }
        .onAppear {
            sendPortamentoState(on: cfg.glide)
        }
    }

    // MARK: - Header (three mode buttons + preset + config) — outside the touch area

    private var header: some View {
        HStack(spacing: 6) {
            PadModeSelector(selection: surfaceModeBinding)

            Spacer(minLength: 4)

            // Moved here from the app-title row, which no longer exists. It
            // sits left of the gear because both are "leave the pad alone and
            // change something" controls, and keeping them adjacent means the
            // whole right edge of this row is settings rather than a target
            // you might hit while reaching for the pad.
            presetButton

            Button {
                showConfig = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Theme.accent)
                    .frame(width: 30, height: 30)
            }
        }
        .frame(height: 44)
    }

    private var presetButton: some View {
        Button {
            showPresetPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(app.preset.name.uppercased())
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(Theme.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.panel2))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        // A long preset name must not push the gear off the row, so the chip
        // gives way first.
        .layoutPriority(-1)
    }

    // MARK: - Pad surface

    private var padSurface: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(touching ? Theme.accent : Color.white.opacity(0.08),
                                          lineWidth: touching ? 2 : 1)
                    )

                // Decoration layer. Clipped to the pad's own rounded shape —
                // note bands and octave lines are built in diagonal space and
                // their corners genuinely fall outside the rectangle, so
                // without this they paint over the surrounding layout.
                Group {
                    if cfg.mode == .notes {
                        noteBands(size: size)
                        octaveLines(size: size)
                        diagonalGuide(size: size)
                    } else if cfg.ccMode == .morph {
                        morphCornerMeters(size: size)
                    } else {
                        crosshairGrid(size: size)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))

                // Suspended fingers get a dimmed, hollow puck so you can see
                // where a held-but-silent finger will come back at.
                ForEach(suspended) { voice in
                    suspendedPuck(for: voice, size: size)
                }

                // One solid puck per sounding voice.
                ForEach(voices) { voice in
                    puck(for: voice, size: size)
                }

            }
            // The touch layer sits ON TOP so nothing below can swallow taps.
            .overlay(
                MultitouchSurface(
                    onTouchesChanged: { points in handleTouches(points) },
                    onAllTouchesEnded: { handleAllTouchesEnded() }
                )
            )
            // The scale chip sits ABOVE the touch layer, because anything
            // under it is unreachable — the multitouch view takes every
            // event in its bounds. It costs a small corner of playable
            // surface, which is the trade for changing key without opening
            // a sheet mid-performance.
            .overlay(alignment: .topLeading) {
                if cfg.mode == .notes {
                    scaleChip
                        .padding(10)
                }
            }
        }
    }

    // MARK: - On-surface scale selector

    /// Root + scale, always visible in Notes mode, tap for the full menu.
    /// The same choice also lives at the bottom of the config sheet.
    private var scaleChip: some View {
        Menu {
            Section("Root") {
                Button {
                    setRootNote(cfg.rootNote - 12)
                } label: {
                    Label("Octave Down", systemImage: "arrow.down")
                }
                Button {
                    setRootNote(cfg.rootNote + 12)
                } label: {
                    Label("Octave Up", systemImage: "arrow.up")
                }
            }

            Menu("Root Note: \(noteName(cfg.rootNote))") {
                ForEach(0..<12, id: \.self) { pitchClass in
                    Button {
                        setRootNote(rootOctaveBase + pitchClass)
                    } label: {
                        if pitchClass == rootPitchClass {
                            Label(Self.pitchClassNames[pitchClass], systemImage: "checkmark")
                        } else {
                            Text(Self.pitchClassNames[pitchClass])
                        }
                    }
                }
            }

            ForEach(Scale.families) { family in
                Section(family.title) {
                    ForEach(family.scales) { scale in
                        Button {
                            app.preset.xyPad.scale = scale
                        } label: {
                            if scale == cfg.scale {
                                Label(scale.label, systemImage: "checkmark")
                            } else {
                                Text(scale.label)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(noteName(cfg.rootNote)) \(cfg.scale.label)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.bg.opacity(0.88)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
        }
    }

    private static let pitchClassNames = ["C", "C#", "D", "D#", "E", "F",
                                          "F#", "G", "G#", "A", "A#", "B"]

    private var rootPitchClass: Int { ((cfg.rootNote % 12) + 12) % 12 }
    private var rootOctaveBase: Int { cfg.rootNote - rootPitchClass }

    /// Changing key silences anything sounding — otherwise a held finger is
    /// left owning a note the pad can no longer produce, and nothing would
    /// ever send its Note Off.
    private func setRootNote(_ note: Int) {
        let clamped = min(max(note, 0), 120)
        guard clamped != cfg.rootNote else { return }
        releaseAllVoices()
        app.preset.xyPad.rootNote = clamped
    }

    // MARK: - Sub-views

    // MARK: - Scale range

    /// Every note actually laid out on the pad, low to high — the original
    /// root-to-range notes PLUS the same scale's notes descending below the
    /// root, so the root sits partway up the list instead of at the very
    /// bottom.
    ///
    /// This does NOT call `Scale.notes(root:rangeSemitones:)` for the lower
    /// portion, because that function always treats its `root` argument as
    /// the pitch-class anchor — feeding it a lower starting note would
    /// silently change which notes count as "in scale" (a real transposition,
    /// not a shift). Instead this checks scale membership directly against
    /// `cfg.scale.pitchClasses`, always anchored on the UNCHANGED root note,
    /// across an absolute range that extends below it. Same key, same exact
    /// notes above the root as before — just more of the same scale added
    /// underneath.
    private func scaleNotesInPlay() -> [Int] {
        let pcs = Set(cfg.scale.pitchClasses.map { (($0 % 12) + 12) % 12 })
        let below = cfg.rangeSemitones / 3
        let low = max(cfg.rootNote - below, 0)
        let high = min(cfg.rootNote + cfg.rangeSemitones, 127)
        guard low <= high else { return [cfg.rootNote] }

        var result: [Int] = []
        var candidate = low
        while candidate <= high {
            let pitchClass = (((candidate - cfg.rootNote) % 12) + 12) % 12
            if pcs.contains(pitchClass) { result.append(candidate) }
            candidate += 1
        }
        return result.isEmpty ? [cfg.rootNote] : result
    }

    private func noteBands(size: CGSize) -> some View {
        let scaleNotes = scaleNotesInPlay()
        let count = scaleNotes.count
        guard count > 0 else { return AnyView(Color.clear) }

        // Work out every band's fill color as plain Swift, BEFORE entering
        // the ForEach. Keeping the closure below to one expression sidesteps
        // a real SwiftUI ViewBuilder gotcha: a multi-statement closure that
        // declares `let fill: Color` and assigns it conditionally can make
        // the type-checker lose track of which ForEach overload it's
        // looking at, and it reports the failure against an unrelated
        // Binding-based overload instead of the actual line at fault.
        let bandFills: [Color] = (0..<count).map { i in
            if scaleNotes[i] == cfg.rootNote {
                return Theme.accent.opacity(0.16)   // brighter: the root note's band
            }
            return i % 2 == 0 ? Theme.accent.opacity(0.08) : Color.clear
        }

        return AnyView(
            ZStack {
                ForEach(0..<count, id: \.self) { (i: Int) in
                    bandShape(alongStart: Double(i) / Double(count),
                              alongEnd: Double(i + 1) / Double(count),
                              size: size)
                        .fill(bandFills[i])
                }
            }
        )
    }

    /// A faint dotted line at every octave of the root, drawn PERPENDICULAR
    /// to the pitch diagonal — so it crosses the dashed pitch line rather
    /// than running alongside it.
    ///
    /// Placed at the center of the octave note's own band, which is where
    /// that pitch visually sits, and drawn from perp 0 to perp 1 so it spans
    /// the full width of the playing area at that point on the diagonal.
    /// These are landmarks, not zones: at a glance you can see how far the
    /// next octave is without counting bands.
    private func octaveLines(size: CGSize) -> some View {
        let scaleNotes = scaleNotesInPlay()
        let count = scaleNotes.count
        guard count > 1 else { return AnyView(Color.clear) }

        // Swift's % keeps the sign of the dividend, but -12 % 12 is still 0,
        // so notes below the root are matched correctly without extra work.
        let alongs: [Double] = scaleNotes.enumerated().compactMap { index, note in
            guard (note - cfg.rootNote) % 12 == 0 else { return nil }
            return (Double(index) + 0.5) / Double(count)
        }

        return AnyView(
            ZStack {
                ForEach(Array(alongs.enumerated()), id: \.offset) { _, along in
                    perpendicularLine(at: along, size: size)
                        .stroke(Theme.accent.opacity(0.22),
                                style: StrokeStyle(lineWidth: 1.5,
                                                   lineCap: .round,
                                                   dash: [3, 6]))
                }
            }
        )
    }

    /// The full-width line across the pad at one position along the diagonal.
    private func perpendicularLine(at along: Double, size: CGSize) -> Path {
        let start = inverseProject(along: along, perp: 0)
        let end   = inverseProject(along: along, perp: 1)

        var path = Path()
        path.move(to: CGPoint(x: start.x * size.width,
                              y: (1 - start.y) * size.height))
        path.addLine(to: CGPoint(x: end.x * size.width,
                                 y: (1 - end.y) * size.height))
        return path
    }

    /// One note zone, drawn perpendicular to the active diagonal.
    private func bandShape(alongStart: Double, alongEnd: Double, size: CGSize) -> Path {
        let corners: [(along: Double, perp: Double)] = [
            (alongStart, 0), (alongEnd, 0), (alongEnd, 1), (alongStart, 1)
        ]

        let points = corners.map { corner -> CGPoint in
            let (x, y) = inverseProject(along: corner.along, perp: corner.perp)
            return CGPoint(x: x * size.width, y: (1 - y) * size.height)
        }

        var path = Path()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// Inverse of `XYDiagonal.project` — turns (along, perp) back into (x, y).
    private func inverseProject(along: Double, perp: Double) -> (x: Double, y: Double) {
        switch cfg.diagonal {
        case .bottomLeftToTopRight:
            return (along + perp - 0.5, along - perp + 0.5)
        case .topLeftToBottomRight:
            return (along + perp - 0.5, perp - along + 0.5)
        case .bottomRightToTopLeft:
            return (perp - along + 0.5, along + perp - 0.5)
        case .topRightToBottomLeft:
            return (1 - along + perp - 0.5, 1 - along - perp + 0.5)
        }
    }

    /// Corner meters: a quarter-arc in each corner whose brightness and
    /// sweep follow that corner's live output, plus a small numeric value.
    /// Kept inside the corner radius so nothing sits over the usable middle
    /// of the pad.
    private func morphCornerMeters(size: CGSize) -> some View {
        ZStack {
            crosshairGrid(size: size)

            ForEach(0..<4, id: \.self) { index in
                morphCornerMeter(index: index, size: size)
            }
        }
    }

    private func morphCornerMeter(index: Int, size: CGSize) -> some View {
        let level = index < morphLevels.count ? morphLevels[index] : 0
        let fraction = Double(level) / 127.0
        let label = index < cfg.morphCorners.count
            ? cfg.morphCorners[index].label
            : ["A", "B", "C", "D"][index]

        // A=TL, B=TR, C=BL, D=BR
        let isLeft = (index == 0 || index == 2)
        let isTop  = (index == 0 || index == 1)

        let inset: CGFloat = 26
        let x = isLeft ? inset : size.width - inset
        let y = isTop ? inset : size.height - inset

        return VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.001))
                    .stroke(Theme.accent.opacity(0.35 + 0.65 * fraction),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.accent.opacity(fraction * 0.8),
                            radius: 5 * fraction)

                Text(label.isEmpty ? " " : String(label.prefix(2)).uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.accent.opacity(0.4 + 0.6 * fraction))
            }
            .frame(width: 30, height: 30)

            Text("\(level)")
                .font(.system(size: 8, weight: .semibold).monospaced())
                .foregroundColor(Theme.dim)
        }
        .position(x: x, y: y)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func crosshairGrid(size: CGSize) -> some View {
        Path { p in
            p.move(to: CGPoint(x: size.width / 2, y: 0))
            p.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            p.move(to: CGPoint(x: 0, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        }
        .stroke(Color.white.opacity(0.07), lineWidth: 1)
    }

    private func diagonalGuide(size: CGSize) -> some View {
        Path { p in
            switch cfg.diagonal {
            case .bottomLeftToTopRight, .topRightToBottomLeft:
                p.move(to: CGPoint(x: 0, y: size.height))
                p.addLine(to: CGPoint(x: size.width, y: 0))
            case .topLeftToBottomRight, .bottomRightToTopLeft:
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: size.width, y: size.height))
            }
        }
        .stroke(Theme.accent.opacity(0.35),
                style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
    }

    private func puck(for voice: Voice, size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .frame(width: 44, height: 44)
                .shadow(color: Theme.accent.opacity(0.7), radius: 14)

            if cfg.mode == .notes {
                Text(noteName(voice.note))
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundColor(Theme.bg)
            }
        }
        .position(x: voice.x * size.width,
                  y: (1 - voice.y) * size.height)
    }

    /// Held but silent — hollow ring, no glow.
    private func suspendedPuck(for voice: Voice, size: CGSize) -> some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 2)
                .frame(width: 40, height: 40)

            Text(noteName(voice.note))
                .font(.caption2.monospaced())
                .foregroundColor(Theme.accent.opacity(0.5))
        }
        .position(x: voice.x * size.width,
                  y: (1 - voice.y) * size.height)
    }



    // MARK: - Touch handling

    /// Called on every touch begin / move / end with the CURRENT full set of
    /// fingers on the pad, already normalized to 0...1 with y pointing up.
    private func handleTouches(_ points: [TouchPoint]) {
        guard cfg.mode == .notes else {
            handleCCTouches(points)
            return
        }

        let liveIDs = Set(points.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })

        // 1. Lifted fingers: release sounding voices, drop suspended ones.
        for voice in voices where !liveIDs.contains(voice.id) {
            app.midi.noteOff(voice.note, channel: cfg.channel)
        }
        voices.removeAll { !liveIDs.contains($0.id) }
        suspended.removeAll { !liveIDs.contains($0.id) }

        // 2. Move the sounding voices, retriggering when they cross a zone.
        for index in voices.indices {
            guard let point = byID[voices[index].id] else { continue }
            voices[index].x = point.x
            voices[index].y = point.y

            let target = note(at: point)
            let previous = voices[index].note
            guard target != previous else { continue }

            let vel = velocity(at: point)
            if cfg.glide {
                // Legato ordering: the new note sounds before the old one
                // releases, so a portamento synth slides between them.
                app.midi.noteOn(target, velocity: vel, channel: cfg.channel)
                app.midi.noteOff(previous, channel: cfg.channel)
            } else {
                app.midi.noteOff(previous, channel: cfg.channel)
                app.midi.noteOn(target, velocity: vel, channel: cfg.channel)
            }
            voices[index].note = target
        }

        // 3. Suspended fingers keep tracking silently, so when they come back
        //    they sound wherever they've drifted to — not where they started.
        for index in suspended.indices {
            guard let point = byID[suspended[index].id] else { continue }
            suspended[index].x = point.x
            suspended[index].y = point.y
            suspended[index].note = note(at: point)
        }

        // 4. Brand-new fingers, stealing the oldest voice when at the limit.
        let knownIDs = Set(voices.map(\.id)).union(suspended.map(\.id))
        for point in points where !knownIDs.contains(point.id) {
            if voices.count >= cfg.voiceCount {
                guard !voices.isEmpty else { continue }
                let stolen = voices.removeFirst()          // lowest id = oldest
                app.midi.noteOff(stolen.note, channel: cfg.channel)
                suspended.append(stolen)                   // most recent last
            }
            let target = note(at: point)
            app.midi.noteOn(target, velocity: velocity(at: point), channel: cfg.channel)
            insertVoice(Voice(id: point.id, x: point.x, y: point.y, note: target))
        }

        // 5. Fill any free slot from the suspended stack, most recent first.
        while voices.count < cfg.voiceCount, let restored = suspended.popLast() {
            app.midi.noteOn(restored.note,
                            velocity: min(max(cfg.fixedVelocity, 1), 127),
                            channel: cfg.channel)
            insertVoice(restored)
        }
    }

    /// Keeps `voices` sorted by id so index 0 is always the oldest finger.
    private func insertVoice(_ voice: Voice) {
        let index = voices.firstIndex { $0.id > voice.id } ?? voices.count
        voices.insert(voice, at: index)
    }

    /// CC mode is single-touch: the first finger drives both CCs.
    private func handleCCTouches(_ points: [TouchPoint]) {
        guard let point = points.first else { return }
        voices = [Voice(id: point.id, x: point.x, y: point.y, note: -1)]
        suspended.removeAll()
        emitCC(x: point.x, y: point.y)
    }

    private func handleAllTouchesEnded() {
        if cfg.mode == .notes {
            releaseAllVoices()
        } else {
            voices.removeAll()
            suspended.removeAll()
            if cfg.snapBack { emitCC(x: 0.5, y: 0.5) }
        }
    }

    private func releaseAllVoices() {
        for voice in voices where voice.note >= 0 {
            app.midi.noteOff(voice.note, channel: cfg.channel)
        }
        voices.removeAll()
        suspended.removeAll()   // never sounded, so nothing to release
    }

    // MARK: - Note / velocity derivation

    private func note(at point: TouchPoint) -> Int {
        let (along, _) = cfg.diagonal.project(x: point.x, y: point.y)
        let scaleNotes = scaleNotesInPlay()
        guard !scaleNotes.isEmpty else { return cfg.rootNote }
        let index = min(max(Int((along * Double(scaleNotes.count - 1)).rounded()), 0),
                        scaleNotes.count - 1)
        return scaleNotes[index]
    }

    private func velocity(at point: TouchPoint) -> Int {
        guard cfg.perpToVelocity else {
            return min(max(cfg.fixedVelocity, 1), 127)
        }
        let (_, perp) = cfg.diagonal.project(x: point.x, y: point.y)
        return min(max(Int((perp * 127).rounded()), 1), 127)   // never 0 (= Note Off)
    }

    // MARK: - Portamento (glide) transmission

    /// The standard Portamento On/Off switch. Sending it means the receiving
    /// synth follows the toggle instead of needing it set by hand.
    private func sendPortamentoState(on: Bool) {
        app.midi.controlChange(MIDIDefaults.portamentoSwitchCC,
                               value: on ? 127 : 0,
                               channel: cfg.channel)
        if on { sendGlideTime() }
    }

    /// Portamento Time — how long the slide between notes takes.
    private func sendGlideTime() {
        let value = min(max(Int((cfg.glideTime * 127).rounded()), 0), 127)
        app.midi.controlChange(MIDIDefaults.portamentoTimeCC,
                               value: value,
                               channel: cfg.channel)
    }

    // MARK: - CC emission

    private func emitCC(x: Double, y: Double) {
        // Morph mode replaces the two-CC output entirely; the standard path
        // below is untouched so existing presets behave exactly as before.
        if cfg.ccMode == .morph {
            emitMorphCC(x: x, y: y)
            return
        }

        let xv = Int((x * 127).rounded())
        let yv = Int((y * 127).rounded())
        if xv != lastX {
            lastX = xv
            app.midi.controlChange(cfg.xCC, value: xv, channel: cfg.channel)
        }
        if yv != lastY {
            lastY = yv
            app.midi.controlChange(cfg.yCC, value: yv, channel: cfg.channel)
        }
    }

    /// Four-corner morph output. Weights come from the shared engine, so
    /// touch and any future motion source produce identical results.
    ///
    /// `TouchPoint.y` points UP (0 = bottom) but the engine expects y = 0 at
    /// the TOP, so it's flipped here — the one place that conversion lives.
    private func emitMorphCC(x: Double, y: Double) {
        let w = MorphEngine.weights(x: x,
                                    y: 1 - y,
                                    morphCurve: cfg.morphCurve,
                                    centerStrength: cfg.morphCenterStrength,
                                    equalPower: cfg.morphEqualPower)

        let values = w.asArray.map { MorphEngine.ccValue($0) }

        var changed = false
        for (index, corner) in cfg.morphCorners.enumerated() where index < values.count {
            let value = values[index]
            // Duplicate suppression per corner: only a changed 7-bit value
            // goes out, so holding still sends nothing at all.
            guard lastMorph[index] != value else { continue }
            lastMorph[index] = value
            changed = true
            app.midi.controlChange(corner.cc,
                                   value: value,
                                   channel: corner.channel)
        }

        // Only touch @State when something moved — otherwise a stationary
        // finger would redraw four animated meters on every touch event.
        if changed { morphLevels = values }
    }

    // MARK: - Bindings & helpers

    /// Reads and writes the two stored flags as one three-way choice.
    ///
    /// Switching always silences what is sounding first: leaving Notes mode
    /// with a finger down would otherwise strand a Note On that nothing is
    /// left to release.
    private var surfaceModeBinding: Binding<XYSurfaceMode> {
        Binding(
            get: {
                if app.preset.xyPad.mode == .notes { return .notes }
                return app.preset.xyPad.ccMode == .morph ? .morph : .standard
            },
            set: { newMode in
                releaseAllVoices()
                switch newMode {
                case .notes:
                    app.preset.xyPad.mode = .notes
                case .standard:
                    app.preset.xyPad.mode = .cc
                    app.preset.xyPad.ccMode = .standard
                case .morph:
                    app.preset.xyPad.mode = .cc
                    app.preset.xyPad.ccMode = .morph
                }
            }
        )
    }

    private func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = min(max(n, 0), 127)
        return "\(names[clamped % 12])\(clamped / 12 - 1)"
    }
}

// MARK: - Multitouch bridge (UIKit → SwiftUI)

/// One finger, normalized to the pad's coordinate space.
///   • x: 0 = left,   1 = right
///   • y: 0 = bottom, 1 = top   (flipped from UIKit, to match musical thinking)
struct TouchPoint: Equatable {
    let id: Int
    let x: Double
    let y: Double
}

/// SwiftUI has no multitouch gesture — `DragGesture` only ever reports one
/// finger. This wraps a plain UIView so we can use UIKit's raw touch
/// callbacks, which do report every finger independently.
///
/// The view normalizes coordinates against its OWN bounds before handing
/// them to SwiftUI, since that's the only place the pad's true frame is
/// known at touch time.
struct MultitouchSurface: UIViewRepresentable {
    var onTouchesChanged: ([TouchPoint]) -> Void
    var onAllTouchesEnded: () -> Void

    func makeUIView(context: Context) -> TouchTrackingView {
        let view = TouchTrackingView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.onTouchesChanged = onTouchesChanged
        view.onAllTouchesEnded = onAllTouchesEnded
        return view
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        // Closures capture current SwiftUI state, so refresh them each pass.
        uiView.onTouchesChanged = onTouchesChanged
        uiView.onAllTouchesEnded = onAllTouchesEnded
    }
}

final class TouchTrackingView: UIView {
    var onTouchesChanged: (([TouchPoint]) -> Void)?
    var onAllTouchesEnded: (() -> Void)?

    /// UITouch objects are recycled by UIKit, so we assign our own stable
    /// integer id for the lifetime of each finger's contact.
    private var touchIDs: [UITouch: Int] = [:]
    private var nextID = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touchIDs[touch] == nil {
            touchIDs[touch] = nextID
            nextID &+= 1
        }
        report()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        report()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { touchIDs.removeValue(forKey: touch) }
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { touchIDs.removeValue(forKey: touch) }
        finish()
    }

    private func finish() {
        if touchIDs.isEmpty {
            onAllTouchesEnded?()
        } else {
            report()
        }
    }

    /// Send the current full set of fingers, normalized to 0...1.
    private func report() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let points = touchIDs.map { touch, id -> TouchPoint in
            let location = touch.location(in: self)
            let x = min(max(location.x / bounds.width, 0), 1)
            // Flip Y so 0 is the bottom of the pad.
            let y = min(max(1 - location.y / bounds.height, 0), 1)
            return TouchPoint(id: id, x: Double(x), y: Double(y))
        }
        .sorted { $0.id < $1.id }   // stable order: oldest finger first

        onTouchesChanged?(points)
    }
}

// MARK: - Config sheet

/// Full editor for the XY pad: mode, voices, CC numbers, diagonal, scale,
/// note range, glide, velocity source, channel, and return behavior.
///
/// Headed by the same three pad-mode buttons that sit in the pad header, so
/// the sheet opens showing which of the three surfaces it is configuring and
/// can switch between them without closing.
struct XYPadConfigSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private var cfg: XYPadConfig { app.preset.xyPad }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PadModeSelector(selection: surfaceModeBinding, spacing: 8)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)

                    Text(surfaceMode.longLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                switch surfaceMode {
                case .standard:
                    Section("CC Assignments") {
                        Stepper("X → CC \(cfg.xCC)", value: bind(\.xCC), in: 0...127)
                        Stepper("Y → CC \(cfg.yCC)", value: bind(\.yCC), in: 0...127)
                    }

                case .morph:
                    morphCornerSection
                    morphShapeSection

                case .notes:
                    notesSections
                }

                Section("Shared") {
                    Stepper("MIDI Channel: \(cfg.channel + 1)",
                            value: bind(\.channel), in: 0...15)
                    Toggle("Spring return to center", isOn: bind(\.snapBack))
                        .tint(Theme.accent)
                }

                // Scale lives on the pad surface now — a tap on the chip in
                // the top-left corner opens the same list. It stays here at
                // the bottom for setup work, where reaching for a menu on a
                // pad you are not currently playing is the awkward path.
                if surfaceMode == .notes {
                    Section {
                        Picker("Scale", selection: bind(\.scale)) {
                            ForEach(Scale.families) { family in
                                Section(family.title) {
                                    ForEach(family.scales) { Text($0.label).tag($0) }
                                }
                            }
                        }
                    } header: {
                        Text("Scale")
                    } footer: {
                        Text("Also available on the pad itself — tap the key name in the top-left corner.")
                    }
                }
            }
            .navigationTitle("XY Pad")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Notes sections

    @ViewBuilder
    private var notesSections: some View {
        Section("Voices") {
            Picker("Voices", selection: bind(\.voiceCount)) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
            }
            .pickerStyle(.segmented)

            Text("A finger beyond the limit takes over the oldest voice. Lift it and that voice comes back.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("Diagonal") {
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                ForEach(XYDiagonal.allCases) { d in
                    Button {
                        app.preset.xyPad.diagonal = d
                    } label: {
                        DiagonalArrowIcon(diagonal: d,
                                          selected: cfg.diagonal == d)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)

            Text(cfg.diagonal.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }

        Section {
            Stepper("Root: \(noteName(cfg.rootNote))",
                    value: bind(\.rootNote), in: 0...120)
            Stepper("Range: \(cfg.rangeSemitones) semitones (\(String(format: "%.1f", Double(cfg.rangeSemitones) / 12.0)) oct)",
                    value: bind(\.rangeSemitones), in: 1...60)
            Text("Low \(noteName(cfg.rootNote)) → High \(noteName(cfg.rootNote + cfg.rangeSemitones))")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("Note Range")
        } footer: {
            Text("A dotted line crosses the pad at every octave of the root, so you can see where the next octave falls without counting bands.")
        }

        Section("Glide") {
            Toggle("Glide (legato portamento)", isOn: bind(\.glide))
                .tint(Theme.accent)

            if cfg.glide {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Glide Time")
                        Spacer()
                        Text("CC\(MIDIDefaults.portamentoTimeCC) · \(Int(cfg.glideTime * 127))")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: bind(\.glideTime), in: 0...1)
                        .tint(Theme.accent)
                }

                Text("Sends CC \(MIDIDefaults.portamentoSwitchCC) to switch portamento on, and CC \(MIDIDefaults.portamentoTimeCC) for slide time. Left = instant, right = slow.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        Section("Velocity") {
            Toggle("Perpendicular → Velocity", isOn: bind(\.perpToVelocity))
                .tint(Theme.accent)
            if !cfg.perpToVelocity {
                Stepper("Fixed velocity: \(cfg.fixedVelocity)",
                        value: bind(\.fixedVelocity), in: 1...127)
            }
        }
    }

    // MARK: - Morph sections

    private static let cornerPositions = ["Top Left", "Top Right",
                                          "Bottom Left", "Bottom Right"]

    /// Laid out as an actual 2×2 grid rather than a four-row list, because
    /// the corners ARE a 2×2 arrangement — index order is TL, TR, BL, BR, so
    /// each card sits where its corner sits on the pad. Finding "the one at
    /// the bottom right" stops being a reading exercise.
    private var morphCornerSection: some View {
        Section {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    cornerCard(0)
                    cornerCard(1)
                }
                GridRow {
                    cornerCard(2)
                    cornerCard(3)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Corner Outputs")
        } footer: {
            Text("Each corner sends its own CC on its own channel. At a corner that output is 127 and the other three are 0; between corners they blend.")
        }
    }

    private func cornerCard(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.cornerPositions[index])
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(Theme.accent.opacity(0.8))

            TextField("Label", text: cornerLabelBinding(index))
                .font(.subheadline.weight(.semibold))
                .autocorrectionDisabled()
                .textFieldStyle(.plain)

            Divider().opacity(0.4)

            Stepper(value: cornerCCBinding(index), in: 0...127) {
                Text("CC \(app.preset.xyPad.morphCorners[index].cc)")
                    .font(.caption.monospaced())
            }

            Stepper(value: cornerChannelBinding(index), in: 0...15) {
                Text("Ch \(app.preset.xyPad.morphCorners[index].channel + 1)")
                    .font(.caption.monospaced())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.panel2.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var morphShapeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Morph Curve")
                    Spacer()
                    Text(morphCurveDescription)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Slider(value: bind(\.morphCurve), in: -100...100, step: 1)
                    .tint(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Center Strength")
                    Spacer()
                    Text("\(Int(cfg.morphCenterStrength * 100))%")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Slider(value: bind(\.morphCenterStrength), in: 0...1)
                    .tint(Theme.accent)
            }

            Toggle("Equal Power", isOn: bind(\.morphEqualPower))
                .tint(Theme.accent)
        } header: {
            Text("Morph Shape")
        } footer: {
            Text("Curve: left spreads influence across corners, right concentrates it. Center Strength: 0% gives four broad corner regions, 50% is plain blending, 100% widens the four-way mix. Equal Power keeps total level steadier when several clips are partly down.")
        }
    }

    private var morphCurveDescription: String {
        let v = Int(cfg.morphCurve.rounded())
        if v == 0 { return "0 · linear" }
        return v > 0 ? "+\(v) · focused" : "\(v) · spread"
    }

    // MARK: - Bindings

    private var surfaceMode: XYSurfaceMode {
        if cfg.mode == .notes { return .notes }
        return cfg.ccMode == .morph ? .morph : .standard
    }

    /// The sheet is never the thing being played, so unlike the pad's own
    /// binding this has no voices to release.
    private var surfaceModeBinding: Binding<XYSurfaceMode> {
        Binding(
            get: { surfaceMode },
            set: { newMode in
                switch newMode {
                case .notes:
                    app.preset.xyPad.mode = .notes
                case .standard:
                    app.preset.xyPad.mode = .cc
                    app.preset.xyPad.ccMode = .standard
                case .morph:
                    app.preset.xyPad.mode = .cc
                    app.preset.xyPad.ccMode = .morph
                }
            }
        )
    }

    // Corner bindings write through the array by index. The decoder
    // guarantees exactly four entries, and these are only reachable from
    // the fixed 2×2 grid above, so the index is always valid.

    private func cornerLabelBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { app.preset.xyPad.morphCorners[index].label },
            set: { app.preset.xyPad.morphCorners[index].label = $0 }
        )
    }

    private func cornerCCBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { app.preset.xyPad.morphCorners[index].cc },
            set: { app.preset.xyPad.morphCorners[index].cc = min(max($0, 0), 127) }
        )
    }

    private func cornerChannelBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { app.preset.xyPad.morphCorners[index].channel },
            set: { app.preset.xyPad.morphCorners[index].channel = min(max($0, 0), 15) }
        )
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<XYPadConfig, Value>) -> Binding<Value> {
        Binding(
            get: { app.preset.xyPad[keyPath: keyPath] },
            set: { app.preset.xyPad[keyPath: keyPath] = $0 }
        )
    }

    private func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = min(max(n, 0), 127)
        return "\(names[clamped % 12])\(clamped / 12 - 1)"
    }
}

// MARK: - Visual diagonal direction selector

/// A small square showing a diagonal arrow from the "low" corner to the
/// "high" corner for one XYDiagonal case. Selected state is shown with
/// accent fill/border rather than relying on text — a performer should
/// recognize the direction at a glance, not decode an abbreviation.
struct DiagonalArrowIcon: View {
    let diagonal: XYDiagonal
    let selected: Bool

    /// Normalized (0...1) start point — the LOW-pitch corner — using
    /// standard screen coordinates (y increases downward).
    private var start: CGPoint {
        switch diagonal {
        case .bottomLeftToTopRight: return CGPoint(x: 0.14, y: 0.86)
        case .topLeftToBottomRight: return CGPoint(x: 0.14, y: 0.14)
        case .bottomRightToTopLeft: return CGPoint(x: 0.86, y: 0.86)
        case .topRightToBottomLeft: return CGPoint(x: 0.86, y: 0.14)
        }
    }

    /// Normalized (0...1) end point — the HIGH-pitch corner — arrowhead here.
    private var end: CGPoint {
        switch diagonal {
        case .bottomLeftToTopRight: return CGPoint(x: 0.86, y: 0.14)
        case .topLeftToBottomRight: return CGPoint(x: 0.86, y: 0.86)
        case .bottomRightToTopLeft: return CGPoint(x: 0.14, y: 0.14)
        case .topRightToBottomLeft: return CGPoint(x: 0.14, y: 0.86)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let p0 = CGPoint(x: start.x * w, y: start.y * h)
            let p1 = CGPoint(x: end.x * w, y: end.y * h)
            let color = selected ? Theme.accent : Theme.dim

            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Theme.accent.opacity(0.18) : Theme.panel2)
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.12),
                                  lineWidth: selected ? 2 : 1)

                Path { path in
                    path.move(to: p0)
                    path.addLine(to: p1)
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

                Arrowhead(tip: p1, tailDirectionFrom: p0)
                    .fill(color)

                // Small dot marks the "low" starting corner.
                Circle()
                    .fill(color.opacity(0.7))
                    .frame(width: 5, height: 5)
                    .position(p0)
            }
        }
        .frame(width: 46, height: 46)
    }
}

/// A filled triangular arrowhead pointing from `tailDirectionFrom` toward `tip`.
struct Arrowhead: Shape {
    let tip: CGPoint
    let tailDirectionFrom: CGPoint

    func path(in rect: CGRect) -> Path {
        let angle = atan2(tip.y - tailDirectionFrom.y, tip.x - tailDirectionFrom.x)
        let length: CGFloat = 7
        let spread: CGFloat = 0.5 // radians

        let left = CGPoint(x: tip.x - length * cos(angle - spread),
                           y: tip.y - length * sin(angle - spread))
        let right = CGPoint(x: tip.x - length * cos(angle + spread),
                            y: tip.y - length * sin(angle + spread))

        var path = Path()
        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
    }
}
