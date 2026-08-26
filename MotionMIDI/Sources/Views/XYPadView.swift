import SwiftUI
import UIKit

// MARK: - Pad surface mode (the four buttons)

/// What the pad is doing right now, as ONE choice out of four.
///
/// The underlying config stores this as two flags — `XYPadMode` chooses
/// CC vs Notes, while `CCPadMode` chooses Standard, Morph, or Drawbars inside
/// the CC path. Combinations such as "Notes + Morph" are meaningless because
/// the CC sub-mode is ignored whenever Notes is active.
///
/// This exposes only the four real surfaces as one performer-facing choice.
/// Existing presets remain compatible because the original `mode` and
/// `ccMode` fields are still what gets persisted.
enum XYSurfaceMode: String, CaseIterable, Identifiable {
    case standard
    case morph
    case drawbars
    case notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "XY"
        case .morph:    return "4C"
        case .drawbars: return "Drawbars"
        case .notes:    return "Notes"
        }
    }

    var longLabel: String {
        switch self {
        case .standard: return "Standard XY"
        case .morph:    return "4-Corner Morph"
        case .drawbars: return "Drawbars"
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
        case .drawbars: return "PadModeDrawbars"
        case .notes:    return "PadModeNotes"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "circle.grid.cross"
        case .morph:    return "square.grid.2x2"
        case .drawbars: return "slider.vertical.3"
        case .notes:    return "music.note"
        }
    }
}

/// One of the four pad-mode buttons.
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

/// The four buttons as a unit. Used in the pad header AND as the heading of
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

/// Large expressive XY pad with four surface modes:
///
///   • Standard XY — X and Y each send an independent CC (uses the first touch).
///   • 4-Corner    — four CCs blended by proximity to each corner.
///   • Drawbars    — a configurable bank of one-dimensional CC controls.
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

    // ── Drawbar-mode state ──────────────────────────────────────────────
    /// Live values are kept locally while a finger is moving. They are
    /// committed to the preset when the gesture ends, avoiding a full preset
    /// save for every high-frequency touch update.
    @State private var drawbarLevels: [Int] = Array(repeating: 0, count: 9)
    /// In Individual mode, each finger is locked to the bar it touched first.
    @State private var drawbarFingerBars: [Int: Int] = [:]
    /// In Sweep mode, previous finger positions let us interpolate across
    /// fast swipes so narrow bars cannot be skipped between touch events.
    @State private var drawbarPreviousPoints: [Int: TouchPoint] = [:]
    /// One cancellable glide per drawbar. New sweep input retargets that bar
    /// from its current live value instead of stacking competing ramps.
    @State private var drawbarRampTasks: [Int: Task<Void, Never>] = [:]

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

    /// Blank space held to the LEFT of the pad mode buttons.
    ///
    /// App-wide rather than per-preset, and deliberately so: what it makes
    /// room for is the iPad's own window furniture, which depends on how the
    /// app is being RUN, not on which preset is loaded. Storing it on the
    /// preset would mean setting it again on every preset in the library and
    /// having it come and go as you switched between them, while the window
    /// controls it dodges stayed exactly where they were.
    @AppStorage("MotionMIDIPro.padModeIndent") private var padModeIndent: Double = 0

    /// Master values with any dial-step overrides applied — the config the
    /// pad PLAYS, not the one stored on the preset.
    ///
    /// The config sheet deliberately reads the stored one instead (see
    /// `XYPadConfigSheet.cfg`), so editing a value there sets what the pad
    /// returns to once no step is overriding it.
    private var cfg: XYPadConfig { app.livePad }
    private var touching: Bool {
        !voices.isEmpty || !drawbarFingerBars.isEmpty || !drawbarPreviousPoints.isEmpty
    }

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
            cancelDrawbarRamps(commit: true)
            // Clear dedupe state both ways, so the first move after a mode
            // switch always transmits rather than being suppressed as a
            // "duplicate" of whatever was last sent in the other mode.
            lastMorph = [-1, -1, -1, -1]
            morphLevels = [0, 0, 0, 0]
            lastX = -1
            lastY = -1
            drawbarFingerBars.removeAll()
            drawbarPreviousPoints.removeAll()
            syncDrawbarLevelsFromPreset()
        }
        .onChange(of: app.activePresetID) { _, _ in
            cancelDrawbarRamps(commit: false)
            drawbarFingerBars.removeAll()
            drawbarPreviousPoints.removeAll()
            syncDrawbarLevelsFromPreset()
        }
        .onAppear {
            sendPortamentoState(on: cfg.glide)
            syncDrawbarLevelsFromPreset()
        }
        .onDisappear {
            cancelDrawbarRamps(commit: true)
        }
    }

    // MARK: - Header (four mode buttons + preset + config) — outside the touch area

    private var header: some View {
        HStack(spacing: 6) {
            PadModeSelector(selection: surfaceModeBinding)
                // Clears the iPad window controls in multi-window mode. See
                // `padModeIndent`.
                .padding(.leading, padModeIndent)

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
                Image("SettingsIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
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
                    } else if cfg.ccMode == .drawbars {
                        drawbarBank(size: size)
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
                            app.setMasterScale(scale)
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
        app.setMasterRootNote(clamped)
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

    // MARK: - Drawbar surface

    private var visibleDrawbarCount: Int {
        min(max(cfg.drawbarCount, 1), min(drawbarLevels.count, cfg.drawbars.count))
    }

    /// Draws a bank of fader-like drawbars. The selected direction is the
    /// direction in which the MIDI value increases toward 127.
    @ViewBuilder
    private func drawbarBank(size: CGSize) -> some View {
        let count = visibleDrawbarCount
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                drawbarLane(index: index, count: count, size: size)
            }
        }
    }

    @ViewBuilder
    private func drawbarLane(index: Int, count: Int, size: CGSize) -> some View {
        let level = drawbarLevels.indices.contains(index) ? drawbarLevels[index] : 0
        let fraction = CGFloat(level) / 127.0
        let inset: CGFloat = 24

        if cfg.drawbarDirection.isVertical {
            let laneWidth = size.width / CGFloat(max(count, 1))
            let x = laneWidth * (CGFloat(index) + 0.5)
            let top = inset
            let bottom = max(size.height - inset, top + 1)
            let travel = bottom - top
            let y = cfg.drawbarDirection == .up
                ? bottom - travel * fraction
                : top + travel * fraction
            let zeroY = cfg.drawbarDirection == .up ? bottom : top
            let fillHeight = max(abs(zeroY - y), 1)
            let handleWidth = max(16, min(42, laneWidth * 0.66))

            Rectangle()
                .fill(Color.white.opacity(0.045))
                .frame(width: 1, height: size.height)
                .position(x: laneWidth * CGFloat(index + 1), y: size.height / 2)

            Capsule()
                .fill(Color.white.opacity(0.13))
                .frame(width: 4, height: travel)
                .position(x: x, y: (top + bottom) / 2)

            Capsule()
                .fill(Theme.accent.opacity(0.42))
                .frame(width: 4, height: fillHeight)
                .position(x: x, y: (zeroY + y) / 2)

            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.accent)
                .frame(width: handleWidth, height: 18)
                .shadow(color: Theme.accent.opacity(0.45), radius: 5)
                .overlay(
                    Text("\(level)")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.bg.opacity(0.9))
                )
                .position(x: x, y: y)

            Text("\(index + 1)")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.dim)
                .position(x: x,
                          y: cfg.drawbarDirection == .up ? size.height - 9 : 9)
        } else {
            let laneHeight = size.height / CGFloat(max(count, 1))
            let y = laneHeight * (CGFloat(index) + 0.5)
            let left = inset
            let right = max(size.width - inset, left + 1)
            let travel = right - left
            let x = cfg.drawbarDirection == .right
                ? left + travel * fraction
                : right - travel * fraction
            let zeroX = cfg.drawbarDirection == .right ? left : right
            let fillWidth = max(abs(zeroX - x), 1)
            let handleHeight = max(16, min(42, laneHeight * 0.66))

            Rectangle()
                .fill(Color.white.opacity(0.045))
                .frame(width: size.width, height: 1)
                .position(x: size.width / 2, y: laneHeight * CGFloat(index + 1))

            Capsule()
                .fill(Color.white.opacity(0.13))
                .frame(width: travel, height: 4)
                .position(x: (left + right) / 2, y: y)

            Capsule()
                .fill(Theme.accent.opacity(0.42))
                .frame(width: fillWidth, height: 4)
                .position(x: (zeroX + x) / 2, y: y)

            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.accent)
                .frame(width: 18, height: handleHeight)
                .shadow(color: Theme.accent.opacity(0.45), radius: 5)
                .overlay(
                    Text("\(level)")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.bg.opacity(0.9))
                        .rotationEffect(.degrees(-90))
                )
                .position(x: x, y: y)

            Text("\(index + 1)")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.dim)
                .position(x: cfg.drawbarDirection == .right ? 9 : size.width - 9,
                          y: y)
        }
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
        if cfg.mode != .notes {
            if cfg.ccMode == .drawbars {
                handleDrawbarTouches(points)
            } else {
                handleCCTouches(points)
            }
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

    // MARK: - Drawbar touch handling

    private func handleDrawbarTouches(_ points: [TouchPoint]) {
        // Drawbars do not use the XY puck/voice state.
        voices.removeAll()
        suspended.removeAll()

        let liveIDs = Set(points.map(\.id))
        for id in Array(drawbarFingerBars.keys) where !liveIDs.contains(id) {
            drawbarFingerBars.removeValue(forKey: id)
        }
        for id in Array(drawbarPreviousPoints.keys) where !liveIDs.contains(id) {
            drawbarPreviousPoints.removeValue(forKey: id)
        }

        switch cfg.drawbarTouchMode {
        case .individual:
            drawbarPreviousPoints.removeAll()
            for point in points {
                let index: Int
                if let captured = drawbarFingerBars[point.id] {
                    index = captured
                } else {
                    index = drawbarIndex(at: point)
                    drawbarFingerBars[point.id] = index
                }
                setDrawbar(index: index, value: drawbarValue(at: point))
            }

        case .sweep:
            drawbarFingerBars.removeAll()
            for point in points {
                if let previous = drawbarPreviousPoints[point.id] {
                    applyDrawbarSweep(from: previous, to: point)
                } else {
                    setDrawbar(index: drawbarIndex(at: point),
                               value: drawbarValue(at: point))
                }
                drawbarPreviousPoints[point.id] = point
            }
        }
    }

    /// Index of the lane under a point. Vertical drawbars are arranged left
    /// to right; horizontal drawbars are arranged top to bottom.
    private func drawbarIndex(at point: TouchPoint) -> Int {
        let count = visibleDrawbarCount
        guard count > 1 else { return 0 }
        let raw: Int
        if cfg.drawbarDirection.isVertical {
            raw = Int(point.x * Double(count))
        } else {
            raw = Int((1 - point.y) * Double(count))
        }
        return min(max(raw, 0), count - 1)
    }

    /// 0...127 value at a point, with 127 lying in the selected direction.
    private func drawbarValue(at point: TouchPoint) -> Int {
        let normalized: Double
        switch cfg.drawbarDirection {
        case .up:    normalized = point.y
        case .down:  normalized = 1 - point.y
        case .left:  normalized = 1 - point.x
        case .right: normalized = point.x
        }
        return min(max(Int((normalized * 127).rounded()), 0), 127)
    }

    /// Update every lane crossed between two touch samples. Intermediate
    /// values are taken from the actual finger path at each lane center, so a
    /// diagonal sweep naturally paints a rising/falling shape across the bank.
    private func applyDrawbarSweep(from start: TouchPoint, to end: TouchPoint) {
        let startIndex = drawbarIndex(at: start)
        let endIndex = drawbarIndex(at: end)

        guard startIndex != endIndex else {
            setDrawbar(index: endIndex, value: drawbarValue(at: end))
            return
        }

        let count = visibleDrawbarCount
        let low = min(startIndex, endIndex)
        let high = max(startIndex, endIndex)

        for index in low...high {
            let t: Double
            if cfg.drawbarDirection.isVertical {
                let targetX = (Double(index) + 0.5) / Double(count)
                let delta = end.x - start.x
                t = abs(delta) < 0.000_001 ? 1 : (targetX - start.x) / delta
            } else {
                // Lane index 0 is the TOP lane, while TouchPoint.y points up.
                let targetY = 1 - (Double(index) + 0.5) / Double(count)
                let delta = end.y - start.y
                t = abs(delta) < 0.000_001 ? 1 : (targetY - start.y) / delta
            }

            let clampedT = min(max(t, 0), 1)
            let interpolated = TouchPoint(
                id: end.id,
                x: start.x + (end.x - start.x) * clampedT,
                y: start.y + (end.y - start.y) * clampedT
            )
            setDrawbar(index: index, value: drawbarValue(at: interpolated))
        }

        // The final lane follows the actual current finger position rather
        // than only its center-line crossing.
        setDrawbar(index: endIndex, value: drawbarValue(at: end))
    }

    private func setDrawbar(index: Int, value: Int) {
        guard drawbarLevels.indices.contains(index),
              cfg.drawbars.indices.contains(index) else { return }
        let target = min(max(value, 0), 127)

        // Ramp is deliberately a Sweep-only behavior. Individual drawbars
        // remain directly attached to the finger regardless of this setting.
        if cfg.drawbarTouchMode == .sweep && cfg.drawbarRamp > 0 {
            rampDrawbar(index: index, to: target)
        } else {
            drawbarRampTasks[index]?.cancel()
            sendDrawbarValue(index: index, value: target)
        }
    }

    /// Glide one swept drawbar from its CURRENT live value to the new target.
    /// The setting is stored as 0...10, with each step representing 100 ms.
    /// Retargeting cancels the previous glide and starts from wherever the bar
    /// has actually reached, which keeps repeated sweeps smooth and predictable.
    private func rampDrawbar(index: Int, to target: Int) {
        guard drawbarLevels.indices.contains(index),
              cfg.drawbars.indices.contains(index) else { return }

        let start = drawbarLevels[index]
        guard start != target else { return }

        drawbarRampTasks[index]?.cancel()

        let duration = Double(min(max(cfg.drawbarRamp, 0), 10)) * 0.1
        guard duration > 0 else {
            sendDrawbarValue(index: index, value: target)
            return
        }

        // 100 Hz gives a visibly smooth glide without flooding 7-bit MIDI.
        // Duplicate integer values are suppressed by sendDrawbarValue().
        let steps = max(1, Int((duration * 100).rounded()))
        let sleepNs = UInt64((duration / Double(steps)) * 1_000_000_000)

        drawbarRampTasks[index] = Task { @MainActor in
            for step in 1...steps {
                do {
                    try await Task.sleep(nanoseconds: sleepNs)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(steps)
                let value = Int((Double(start) + Double(target - start) * progress).rounded())
                sendDrawbarValue(index: index, value: value)
            }

            // A ramp may finish after the finger has lifted, so persist the
            // completed value here rather than leaving the preset at the
            // intermediate position captured by handleAllTouchesEnded().
            commitDrawbarLevel(index)
        }
    }

    private func sendDrawbarValue(index: Int, value: Int) {
        guard drawbarLevels.indices.contains(index),
              cfg.drawbars.indices.contains(index) else { return }
        let clamped = min(max(value, 0), 127)
        guard drawbarLevels[index] != clamped else { return }
        drawbarLevels[index] = clamped
        app.midi.controlChange(cfg.drawbars[index].cc,
                               value: clamped,
                               channel: cfg.channel)
    }

    private func cancelDrawbarRamps(commit: Bool) {
        for task in drawbarRampTasks.values { task.cancel() }
        drawbarRampTasks.removeAll()
        if commit { commitDrawbarLevels() }
    }

    private func commitDrawbarLevel(_ index: Int) {
        guard app.preset.xyPad.drawbars.indices.contains(index),
              drawbarLevels.indices.contains(index) else { return }
        app.preset.xyPad.drawbars[index].value = drawbarLevels[index]
    }

    private func syncDrawbarLevelsFromPreset() {
        let stored = cfg.drawbars.map { min(max($0.value, 0), 127) }
        var levels = Array(stored.prefix(9))
        while levels.count < 9 { levels.append(0) }
        drawbarLevels = levels
    }

    private func commitDrawbarLevels() {
        var mappings = app.preset.xyPad.drawbars
        guard !mappings.isEmpty else { return }
        for index in mappings.indices where drawbarLevels.indices.contains(index) {
            mappings[index].value = drawbarLevels[index]
        }
        app.preset.xyPad.drawbars = mappings
    }

    private func handleAllTouchesEnded() {
        if cfg.mode == .notes {
            releaseAllVoices()
        } else if cfg.ccMode == .drawbars {
            commitDrawbarLevels()
            drawbarFingerBars.removeAll()
            drawbarPreviousPoints.removeAll()
            voices.removeAll()
            suspended.removeAll()
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
        if cfg.ccMode == .drawbars {
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

    /// Reads and writes the two stored flags as one four-way choice.
    ///
    /// Switching always silences what is sounding first: leaving Notes mode
    /// with a finger down would otherwise strand a Note On that nothing is
    /// left to release.
    private var surfaceModeBinding: Binding<XYSurfaceMode> {
        Binding(
            get: {
                if app.preset.xyPad.mode == .notes { return .notes }
                switch app.preset.xyPad.ccMode {
                case .standard: return .standard
                case .morph:    return .morph
                case .drawbars: return .drawbars
                }
            },
            set: { newMode in
                if app.preset.xyPad.ccMode == .drawbars {
                    cancelDrawbarRamps(commit: true)
                }
                releaseAllVoices()
                drawbarFingerBars.removeAll()
                drawbarPreviousPoints.removeAll()
                switch newMode {
                case .notes:
                    app.preset.xyPad.mode = .notes
                case .standard:
                    app.preset.xyPad.mode = .cc
                    app.preset.xyPad.ccMode = .standard
                case .morph:
                    app.preset.xyPad.mode = .cc
                    app.preset.xyPad.ccMode = .morph
                case .drawbars:
                    app.preset.xyPad.mode = .cc
                    app.preset.xyPad.ccMode = .drawbars
                    syncDrawbarLevelsFromPreset()
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
/// Headed by the same four pad-mode buttons that sit in the pad header, so
/// the sheet opens showing which of the four surfaces it is configuring and
/// can switch between them without closing.
struct XYPadConfigSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// Same key `XYPadView` reads — see its declaration for why this is
    /// app-wide rather than part of the preset.
    @AppStorage("MotionMIDIPro.padModeIndent") private var padModeIndent: Double = 0

    /// The STORED config, not the playing one.
    ///
    /// Everything in this sheet edits master values. When a dial step is
    /// overriding one of them the control still shows and edits the master —
    /// `overrideNote` says so underneath — because the useful edit while
    /// something is overridden is to the value it will return to.
    private var cfg: XYPadConfig { app.preset.xyPad }

    /// Caption shown under a control a dial step is currently holding.
    @ViewBuilder
    private func overrideNote<V>(for override: V?,
                                 _ message: (V) -> String) -> some View {
        if let override {
            Label(message(override), systemImage: "dial.medium.fill")
                .font(.caption)
                .foregroundColor(Theme.accent)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PadModeSelector(selection: surfaceModeBinding, spacing: 8)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)

                }

                Section {
                    // A live preview of the real thing, at the real offset,
                    // because the useful question here is "do the buttons
                    // clear the window controls yet" and that is answered by
                    // looking, not by reading a number.
                    HStack(spacing: 6) {
                        PadModeSelector(selection: surfaceModeBinding)
                            .padding(.leading, padModeIndent)
                            .allowsHitTesting(false)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 44)
                    .listRowBackground(Theme.panel2)

                    Slider(value: $padModeIndent, in: 0...140, step: 2) {
                        Text("Indent")
                    } minimumValueLabel: {
                        Text("0").font(.caption2.monospaced())
                    } maximumValueLabel: {
                        Text("140").font(.caption2.monospaced())
                    }
                    .tint(Theme.accent)

                    LabeledContent("Indent") {
                        Text("\(Int(padModeIndent)) pt")
                            .font(.callout.monospaced())
                            .foregroundColor(Theme.dim)
                    }

                    if padModeIndent > 0 {
                        Button("Remove Indent") { padModeIndent = 0 }
                            .tint(Theme.accent)
                    }
                } header: {
                    Text("Mode Button Indent")
                } footer: {
                    Text("Holds blank space to the left of the pad mode buttons, so the iPad's window controls don't sit on top of them in Split View or Stage Manager.\n\nThis one applies to every preset and both performer surfaces, unlike the settings below it — the window controls it dodges don't move when you change preset.")
                }

                switch surfaceMode {
                case .standard:
                    Section("CC Assignments") {
                        IntWheelRow(title: "X → CC", selection: bind(\.xCC), range: 0...127)
                        IntWheelRow(title: "Y → CC", selection: bind(\.yCC), range: 0...127)
                    }

                case .morph:
                    morphCornerSection
                    morphShapeSection

                case .drawbars:
                    drawbarSections

                case .notes:
                    notesSections
                }

                Section("Shared") {
                    IntWheelRow(title: "MIDI Channel", selection: bind(\.channel), range: 0...15) { String($0 + 1) }
                    if surfaceMode != .drawbars {
                        Toggle("Spring return to center", isOn: bind(\.snapBack))
                            .tint(Theme.accent)
                    }
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

                        overrideNote(for: app.padOverrides.scale) {
                            "A dial step is holding this at \($0.label)."
                        }
                    } header: {
                        Text("Master Scale")
                    } footer: {
                        Text("The scale the pad returns to. A dial step carrying Set Scale overrides it for as long as that step is selected; turn the dial off it and this comes back.")
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
                // Driven by the shared constant so this can't fall behind
                // the clamp in AppState.perform again.
                ForEach(1...XYPadConfig.maxVoices, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)

            overrideNote(for: app.padOverrides.voiceCount) {
                "A dial step is holding this at \($0)."
            }
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

        }

        Section {
            IntWheelRow(title: "Root", selection: bind(\.rootNote), range: 0...120) { MIDIWheelText.note($0) }
            IntWheelRow(title: "Range", selection: bind(\.rangeSemitones), range: 1...60) { value in
                "\(value) st  ·  \(String(format: "%.1f", Double(value) / 12.0)) oct"
            }
            Text("Low \(noteName(cfg.rootNote)) → High \(noteName(cfg.rootNote + cfg.rangeSemitones))")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("Note Range")
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

            }
        }

        Section("Velocity") {
            Toggle("Perpendicular → Velocity", isOn: bind(\.perpToVelocity))
                .tint(Theme.accent)
            if !cfg.perpToVelocity {
                IntWheelRow(title: "Fixed Velocity", selection: bind(\.fixedVelocity), range: 1...127)
            }
        }
    }

    // MARK: - Drawbar sections

    @ViewBuilder
    private var drawbarSections: some View {
        Section {
            Stepper("Number of Drawbars: \(cfg.drawbarCount)",
                    value: drawbarCountBinding, in: 1...9)

            Picker("Direction", selection: bind(\.drawbarDirection)) {
                ForEach(DrawbarDirection.allCases) { direction in
                    Text("\(direction.arrow) \(direction.label)").tag(direction)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Layout")
        }

        Section {
            Picker("Touch Behavior", selection: bind(\.drawbarTouchMode)) {
                ForEach(DrawbarTouchMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if cfg.drawbarTouchMode == .sweep {
                IntWheelRow(title: "Ramp",
                            selection: drawbarRampBinding,
                            range: 0...10)
            }
        } header: {
            Text("Playing Style")
        }

        Section {
            ForEach(0..<cfg.drawbarCount, id: \.self) { index in
                IntWheelRow(title: "Drawbar \(index + 1) · CC",
                            selection: drawbarCCBinding(index),
                            range: 0...127)
            }
        } header: {
            Text("Drawbar Outputs")
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

            CompactIntWheel(title: "CC",
                            selection: cornerCCBinding(index),
                            range: 0...127)

            CompactIntWheel(title: "Channel",
                            selection: cornerChannelBinding(index),
                            range: 0...15) { String($0 + 1) }
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
        switch cfg.ccMode {
        case .standard: return .standard
        case .morph:    return .morph
        case .drawbars: return .drawbars
        }
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
                case .drawbars:
                    app.preset.xyPad.mode = .cc
                    app.preset.xyPad.ccMode = .drawbars
                }
            }
        )
    }

    private var drawbarCountBinding: Binding<Int> {
        Binding(
            get: { app.preset.xyPad.drawbarCount },
            set: { app.preset.xyPad.drawbarCount = min(max($0, 1), 9) }
        )
    }

    private var drawbarRampBinding: Binding<Int> {
        Binding(
            get: { app.preset.xyPad.drawbarRamp },
            set: { app.preset.xyPad.drawbarRamp = min(max($0, 0), 10) }
        )
    }

    private func drawbarCCBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { app.preset.xyPad.drawbars[index].cc },
            set: { app.preset.xyPad.drawbars[index].cc = min(max($0, 0), 127) }
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
