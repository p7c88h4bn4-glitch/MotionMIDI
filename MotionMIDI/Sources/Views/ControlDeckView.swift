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
            MotionMetersRow(motion: app.motion)
                .frame(height: 30)

            // Bottom row — dial slot(s) on the left, utility controls right.
            // Every slot in `dialSlots` sits side by side and slides
            // horizontally once they stop fitting, with a "+" at the end to
            // add another. Same on iPhone and iPad.
            HStack(spacing: 12) {
                // The cluster is the only fixed-width thing in this row.
                // dialSlotRow is a GeometryReader, which is greedy
                // horizontally, so it claims everything the cluster doesn't.
                dialSlotRow

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
    private var utilityCluster: some View {
        VStack(spacing: 6) {
            Button {
                app.calibrate()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                Image(systemName: "scope")
                    .font(.callout.weight(.bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showEditor.toggle()
                }
            } label: {
                Image(systemName: showEditor ? "chevron.down.circle.fill"
                                             : "slider.horizontal.3")
                    .font(.title3)
            }
            .tint(Theme.accent)
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
    @State private var pressed = false

    var body: some View {
        Text(mapping.name)
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundColor(pressed ? Theme.bg : Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(pressed ? Theme.accent : Theme.panel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
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
    }

    private func press() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // A button assigned as the glide toggle flips the XY pad's glide
        // in addition to sending its message.
        if app.preset.xyPad.glideToggleButtonId == mapping.id {
            app.preset.xyPad.glide.toggle()
        }

        send(on: true)

        // Tap fires both halves from the press, since the host is expected
        // to toggle internally. Momentary waits for the finger to lift.
        if mapping.behavior == .tap {
            let m = mapping
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Self.emit(m, on: false, midi: app.midi)
            }
        }
    }

    private func release() {
        guard mapping.behavior == .momentary else { return }
        send(on: false)
    }

    private func send(on: Bool) {
        Self.emit(mapping, on: on, midi: app.midi)
    }

    /// Static, and takes an explicit mapping, so the delayed "off" half of a
    /// tap sends what was on screen at PRESS time. Capturing `self` instead
    /// would re-read `mapping` 50ms later, and an edit landing inside that
    /// window could pair a Note On with a Note Off for a different note —
    /// leaving the first one stuck on with nothing left to release it.
    private static func emit(_ mapping: ButtonMapping, on: Bool, midi: MIDIEngine) {
        switch mapping.message {
        case .note:
            if on {
                midi.noteOn(mapping.note,
                            velocity: max(mapping.onValue, 1),
                            channel: mapping.channel)
            } else {
                midi.noteOff(mapping.note, channel: mapping.channel)
            }
        case .cc:
            midi.controlChange(mapping.cc,
                               value: on ? mapping.onValue : mapping.offValue,
                               channel: mapping.channel)
        }
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
