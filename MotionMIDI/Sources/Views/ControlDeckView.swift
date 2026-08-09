import SwiftUI

/// Middle third: transport pads, meters, stepped dial, connection status.
struct ControlDeckView: View {
    @EnvironmentObject var app: AppState
    @Binding var showEditor: Bool
    @State private var showBluetooth = false

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 10)]

    var body: some View {
        VStack(spacing: 12) {
            // Transport pads
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(app.preset.buttons) { button in
                    PadButton(mapping: button)
                }
            }

            // Mini motion meters
            HStack(spacing: 8) {
                ForEach([MotionSource.pitch, .roll, .yaw, .magnitude], id: \.self) { s in
                    MeterBar(label: s.shortLabel,
                             value: app.motion.meterValues[s] ?? 0.5)
                }
            }
            .frame(height: 34)

            // Bottom row — stepped dial anchors the lower-left; connection
            // status and utility buttons sit to the right. The Bluetooth
            // button's own appearance is the connection indicator (see
            // BluetoothStatusButton).
            HStack(spacing: 14) {
                SteppedDialView()

                // The fader's assignment IS the dial's selected step — they
                // sit together because they act together.
                DialFaderView()

                Spacer()

                ActivityDot(active: app.midi.activity)

                BluetoothStatusButton(
                    isConnected: !app.midi.destinationNames.isEmpty,
                    isConnecting: showBluetooth && app.midi.destinationNames.isEmpty
                ) {
                    showBluetooth = true
                }

                Button {
                    app.calibrate()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Image(systemName: "scope")
                        .font(.title2.weight(.bold))
                        .frame(width: 44, height: 44)
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
        .sheet(isPresented: $showBluetooth) {
            BluetoothMIDIView()
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
        // in addition to sending its note.
        if app.preset.xyPad.glideToggleButtonId == mapping.id {
            app.preset.xyPad.glide.toggle()
        }

        app.midi.noteOn(mapping.note, channel: mapping.channel)
        if mapping.behavior == .tap {
            let note = mapping.note
            let channel = mapping.channel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                app.midi.noteOff(note, channel: channel)
            }
        }
    }

    private func release() {
        if mapping.behavior == .momentary {
            app.midi.noteOff(mapping.note, channel: mapping.channel)
        }
    }
}

// MARK: - Bluetooth status button

/// The Bluetooth button doubles as the ONLY connection-status indicator on
/// the performance screen — there is no persistent destination text next
/// to it. Its appearance communicates state directly:
///
///   • Disconnected — subdued orange, no glow, static.
///   • Connecting   — subtle pulse (scale + opacity breathing) while the
///                    Bluetooth sheet is open and no destination has
///                    appeared yet.
///   • Connected    — bright orange fill with a soft glow, plus a brief
///                    checkmark flash the moment a destination appears.
///
/// The actual destination name(s) remain available inside the Bluetooth
/// sheet — just not on this screen.
struct BluetoothStatusButton: View {
    let isConnected: Bool
    let isConnecting: Bool
    let action: () -> Void

    @State private var pulse = false
    @State private var justConnected = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fillColor)
                    .frame(width: 44, height: 44)
                    .shadow(color: isConnected ? Theme.accent.opacity(0.85) : .clear,
                            radius: isConnected ? 12 : 0)

                if justConnected {
                    Image(systemName: "checkmark")
                        .font(.title3.weight(.bold))
                        .foregroundColor(Theme.bg)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2.weight(.bold))
                        .foregroundColor(isConnected ? Theme.bg : iconColor)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isConnecting && pulse ? 1.08 : 1.0)
        .opacity(isConnecting ? (pulse ? 1.0 : 0.55) : 1.0)
        .onAppear {
            if isConnecting { startPulsing() }
        }
        .onChange(of: isConnecting) { _, connecting in
            if connecting {
                startPulsing()
            } else {
                pulse = false
            }
        }
        .onChange(of: isConnected) { wasConnected, nowConnected in
            guard nowConnected, !wasConnected else { return }
            // Just connected — flash a checkmark briefly, then settle
            // into the steady "connected" glow state.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                justConnected = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeOut(duration: 0.25)) {
                    justConnected = false
                }
            }
        }
    }

    private func startPulsing() {
        pulse = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }

    private var fillColor: Color {
        if isConnected { return Theme.accent }
        return Color.clear
    }

    private var iconColor: Color {
        // Subdued orange when idle/disconnected; unaffected by pulse opacity
        // which is applied to the whole button.
        isConnecting ? Theme.accent : Theme.accent.opacity(0.55)
    }
}

// MARK: - Small widgets

struct ActivityDot: View {
    let active: Bool
    var body: some View {
        Circle()
            .fill(active ? Theme.good : Color.white.opacity(0.12))
            .frame(width: 10, height: 10)
            .shadow(color: active ? Theme.good.opacity(0.8) : .clear, radius: 5)
            .animation(.easeOut(duration: 0.1), value: active)
    }
}

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
    }
}
