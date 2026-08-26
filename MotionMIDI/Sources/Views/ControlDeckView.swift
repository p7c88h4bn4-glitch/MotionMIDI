import SwiftUI

/// Middle third: transport pads, meters, stepped dial, connection status.
struct ControlDeckView: View {
    @EnvironmentObject var app: AppState
    @Binding var showEditor: Bool

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 10)]

    /// iPhone shows the first 6 buttons only, matching the original fixed
    /// layout exactly — the array itself can hold more (iPad-only editing
    /// adds to it), but the phone never renders past its usual set. Order
    /// in the array (reorderable in the editor) decides which 6 those are.
    private var visibleButtons: [ButtonMapping] {
        isPadIdiom ? app.preset.buttons : Array(app.preset.buttons.prefix(6))
    }

    var body: some View {
        VStack(spacing: 8) {
            // Transport pads
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(visibleButtons) { button in
                    PadButton(mapping: button)
                }
            }

            // Mini motion meters — observing the engine DIRECTLY (see
            // MotionMetersRow) rather than reading through `app`.
            if app.preset.showMotionMeters {
                MotionMetersRow(motion: app.motion)
                    .frame(height: 30)
            }

            // Bottom row — dial slot(s) on the left, utility controls right.
            // Every slot in `dialSlots` sits side by side and slides
            // horizontally once they stop fitting, with a "+" at the end to
            // add another. Same on iPhone and iPad.
            HStack(spacing: 12) {
                // The cluster is the only fixed-width thing in this row.
                // dialSlotRow is a GeometryReader, which is greedy
                // horizontally, so it claims everything the cluster doesn't.
                if app.preset.showDialPanel {
                    dialSlotRow
                }

                utilityCluster
            }
        }
    }

    // MARK: - Dial slots

    /// Extra run-out at the end of the row, so the LAST dial+fader can
    /// travel fully into open space rather than stopping hard against the
    /// utility cluster.
    private let trailingScrollRunOut: CGFloat = 56

    /// How far the row is slid, in points. Positive scrolls left (later
    /// slots come into view).
    ///
    /// The row is offset by hand rather than living in a `ScrollView`, and
    /// that is deliberate. `SteppedDialView` and `DialFaderView` both need
    /// `DragGesture(minimumDistance: 0)` — a dial should turn the instant a
    /// finger moves, with no dead zone. A zero-distance child gesture beats
    /// `UIScrollView`'s pan recognizer, and attaching it as a
    /// `.simultaneousGesture` did not change that: the scroll never moved,
    /// and the controls' own gestures got cancelled mid-drag instead.
    ///
    /// Two SwiftUI gestures at different levels of the hierarchy DO both
    /// recognize when they are simultaneous, so driving the offset from a
    /// gesture on this container sidesteps the fight entirely. The dials
    /// ignore horizontal travel; this acts on it; nothing is contested.
    @State private var rowOffset: CGFloat = 0
    @State private var rowOffsetAtDragStart: CGFloat = 0
    @State private var rowContentWidth: CGFloat = 0
    @State private var rowViewportWidth: CGFloat = 0

    private var maxRowOffset: CGFloat {
        max(0, rowContentWidth - rowViewportWidth)
    }

    /// Height of the dial row. Fixed, because the `GeometryReader` below is
    /// greedy in both axes and would otherwise swallow every point the XY
    /// pad could be using. The tallest thing in the row is the dial at about
    /// 116pt — an 84pt knob in a 98pt frame, plus its name label — and the
    /// few points of margin here are deliberate: the row is `.clipped()`, so
    /// a font metric shifting under a Dynamic Type change would silently cut
    /// the bottom off that label rather than push the layout.
    private let dialRowHeight: CGFloat = 126

    private var dialSlotRow: some View {
        // A GeometryReader, specifically, because it REPORTS THE SIZE IT WAS
        // PROPOSED rather than the size of its contents. That is the whole
        // point here.
        //
        // The previous attempt used `.fixedSize(horizontal: true)` to stop
        // the HStack compressing its children, and that propagated the row's
        // full natural width — every slot laid end to end — back up through
        // the deck to the root. The button grid then had a screen-and-a-half
        // of width to lay out into and reflowed to more columns, the pad
        // stretched to match, and the header slid off the top edge. Nothing
        // there was clipped, because nothing knew it was too big.
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(app.preset.dialSlots.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        SteppedDialView(slot: index)
                        DialFaderView(slot: index)
                    }
                    .padding(.trailing, 16)
                }

                Button {
                    app.addDialSlot()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(Theme.accent)
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.trailing, trailingScrollRunOut)
            .background(
                GeometryReader { content in
                    Color.clear.preference(key: DialRowContentWidthKey.self,
                                           value: content.size.width)
                }
            )
            .offset(x: -rowOffset)
            // Clamps what this reports to the width actually available. The
            // HStack still lays out at its natural size internally; it just
            // can't tell anyone about it.
            .frame(width: geo.size.width, height: dialRowHeight, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(rowDragGesture)
            .onAppear { rowViewportWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in rowViewportWidth = width }
        }
        .frame(height: dialRowHeight)
        .onPreferenceChange(DialRowContentWidthKey.self) { rowContentWidth = $0 }
        // Adding or removing a slot changes how far the row can travel, and
        // an offset left beyond the new limit would strand it in blank space
        // with no way back.
        .onChange(of: maxRowOffset) { _, limit in
            rowOffset = min(rowOffset, limit)
            rowOffsetAtDragStart = rowOffset
        }
    }

    private var rowDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { g in
                let dx = g.translation.width
                let dy = g.translation.height

                // Sideways only. A vertical drag here belongs to whatever
                // dial or fader is under the finger.
                guard abs(dx) > abs(dy) else { return }

                if g.translation == .zero { rowOffsetAtDragStart = rowOffset }
                rowOffset = min(max(rowOffsetAtDragStart - dx, 0), maxRowOffset)
            }
            .onEnded { _ in
                rowOffsetAtDragStart = rowOffset
            }
    }

    // MARK: - Utility cluster (status · calibrate · editor)

    /// Calibrate and the editor gear, stacked as a compact utility cluster
    /// rather than spread across the row. The status dot used to sit here
    /// too but was eating into the width the dial scroll view needs — with
    /// two or more dial+fader combos on screen, the cluster was wide enough
    /// to push the rightmost fader out of reach with nothing left to scroll
    /// into. Connection status is still visible in Settings → Connection.
    /// Center and the editor toggle.
    ///
    /// A column while the dial panel is showing, because there the scarce
    /// resource is WIDTH — every point this gives back goes to the dial row
    /// beside it. With the panel hidden that trade disappears: there is
    /// nothing to the left to donate width to, and a tall narrow column just
    /// makes the deck taller for no gain. So the two lay out along the row
    /// instead, larger, and the deck gets shorter — which is the point of
    /// hiding the panel in the first place.
    @ViewBuilder
    private var utilityCluster: some View {
        if app.preset.showDialPanel {
            VStack(spacing: 6) {
                centerButton(size: 30)
                editorToggleButton(size: 30)
            }
        } else {
            HStack(spacing: 16) {
                centerButton(size: 38)
                editorToggleButton(size: 38)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func centerButton(size: CGFloat) -> some View {
        Button {
            app.calibrate()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            Image("CenterIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Center motion")
    }

    /// The lower settings button stays visually clean while the editor is
    /// closed, then gains the same bordered highlight the Center button used
    /// to have while the editor is open. That makes the close affordance
    /// obvious without adding permanent chrome to the utility cluster.
    @ViewBuilder
    private func editorToggleButton(size: CGFloat) -> some View {
        let button = Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showEditor.toggle()
            }
        } label: {
            Image("SettingsIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        }

        if showEditor {
            button
                .buttonStyle(.bordered)
                .tint(Theme.accent)
        } else {
            button
                .buttonStyle(.plain)
        }
    }
}

// MARK: - Dial row measurement

/// Natural width of the dial row's contents.
private struct DialRowContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Motion meters

/// The four motion meters, observing `MotionEngine` directly.
///
/// This exists as its own view for a specific reason. `MotionEngine` is an
/// ObservableObject held inside `AppState`, which is itself an
/// ObservableObject — and SwiftUI does NOT chain that. `AppState` only
/// publishes when its OWN properties change, so `motion.meterValues` could
/// update at its full 16 Hz and a view reading `app.motion.meterValues` was
/// never invalidated. The meters were live in the engine and frozen on
/// screen, which is exactly the symptom that showed up on device.
///
/// Declaring the engine as an `@ObservedObject` here subscribes to it
/// properly. Keeping that subscription in a SMALL leaf view also matters:
/// the alternative fix — forwarding the engine's `objectWillChange` up into
/// `AppState` — would work, but it would invalidate the entire screen
/// sixteen times a second, redrawing every pad, dial and fader to animate
/// four capsules.
struct MotionMetersRow: View {
    @ObservedObject var motion: MotionEngine

    private static let sources: [MotionSource] = [.pitch, .roll, .yaw, .magnitude]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.sources, id: \.self) { source in
                MeterBar(label: source.shortLabel,
                         value: motion.meterValues[source] ?? 0.5)
            }
        }
    }
}

// MARK: - Pad button

struct PadButton: View {
    let mapping: ButtonMapping
    @EnvironmentObject var app: AppState

    /// Finger is down RIGHT NOW. Separate from the latch below: this is
    /// touch feedback and lasts as long as the touch.
    @State private var pressed = false

    /// Latched ON by a `.toggle` press and still holding.
    private var latched: Bool { app.isButtonLatched(mapping.id) }

    /// Lit for either reason. A latched button has to stay lit after the
    /// finger lifts — the whole point of latching is that the state is now
    /// the button's to report, so if it went dark on release there would be
    /// nothing on screen saying the message is still out there.
    private var lit: Bool { pressed || latched }

    var body: some View {
        Text(mapping.name)
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundColor(lit ? Theme.bg : Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(lit ? Theme.accent : Theme.panel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent.opacity(latched ? 0.9 : 0.35),
                                  lineWidth: latched ? 2 : 1)
            )
            // Only the momentary press scales. A latched button holding at
            // 0.96 would read as permanently half-pressed.
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .animation(.easeOut(duration: 0.12), value: latched)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        press()
                    }
                    .onEnded { _ in
                        pressed = false
                        release()
                    }
            )
            .accessibilityAddTraits(latched ? [.isButton, .isSelected] : .isButton)
    }

    private func press() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // A button assigned as the glide toggle flips the XY pad's glide
        // in addition to sending its message.
        if app.preset.xyPad.glideToggleButtonId == mapping.id {
            app.preset.xyPad.glide.toggle()
        }

        switch mapping.behavior {
        case .momentary:
            // On now, off when the finger lifts.
            app.emitButton(mapping, on: true)

        case .tap:
            // Both halves from the press, since the host is expected to
            // toggle internally — this only nudges it.
            app.emitButton(mapping, on: true)
            let m = mapping
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                app.emitButton(m, on: false)
            }

        case .toggle:
            // We own the state, so we say what the value IS rather than
            // nudging the host and hoping. Release does nothing.
            let nowOn = app.toggleButtonLatch(mapping.id)
            app.emitButton(mapping, on: nowOn)
        }
    }

    private func release() {
        guard mapping.behavior == .momentary else { return }
        app.emitButton(mapping, on: false)
    }
}

// MARK: - MIDI status dot

/// Connection AND traffic in one 10pt dot, observing `MIDIEngine` directly
/// for the same reason `MotionMetersRow` observes the motion engine — a
/// nested ObservableObject read through `app` never invalidates the view,
/// which is why this dot previously sat inert no matter what was sent.
///
/// Three states, distinguishable at a glance from arm's length:
///   • No destination — dim grey, no glow. Nothing is listening.
///   • Connected, idle — steady orange with a soft glow.
///   • Sending — bright green flash on each message.
///
/// Colour carries connection, brightness carries traffic, so a glance
/// answers both "is anything listening" and "is it hearing me".
struct MIDIStatusDot: View {
    @ObservedObject var midi: MIDIEngine

    private var connected: Bool { !midi.destinationNames.isEmpty }

    private var fill: Color {
        if midi.activity { return Theme.good }
        return connected ? Theme.accent : Color.white.opacity(0.12)
    }

    private var glow: Color {
        if midi.activity { return Theme.good.opacity(0.85) }
        return connected ? Theme.accent.opacity(0.5) : .clear
    }

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 10, height: 10)
            .shadow(color: glow, radius: midi.activity ? 6 : 4)
            .animation(.easeOut(duration: 0.1), value: midi.activity)
            .animation(.easeOut(duration: 0.25), value: connected)
            .accessibilityLabel(connected ? "MIDI connected" : "No MIDI destination")
    }
}

// MARK: - Small widgets

struct MeterBar: View {
    let label: String
    let value: Double // 0...1

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(Theme.accent.opacity(0.85))
                        .frame(width: max(4, geo.size.width * value))
                }
            }
            .frame(height: 6)
            Text(label)
                .font(.system(size: 8, weight: .semibold).monospaced())
                .foregroundColor(Theme.dim)
        }
        // Meters arrive at 16 Hz; easing each step turns a stepped readout
        // into continuous movement without adding perceptible lag.
        .animation(.easeOut(duration: 0.06), value: value)
    }
}
