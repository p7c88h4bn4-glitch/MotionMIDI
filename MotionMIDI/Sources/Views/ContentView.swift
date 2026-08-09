import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var showEditor = false
    @State private var showPresetPicker = false

    var body: some View {
        VStack(spacing: 14) {
            // Header — the preset name doubles as the library button.
            HStack {
                Text("MOTION MIDI PRO")
                    .font(.system(.footnote, design: .rounded).weight(.heavy))
                    .tracking(2)
                    .foregroundColor(Theme.accent)

                Spacer()

                Button {
                    showPresetPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(app.preset.name.uppercased())
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(Theme.dim)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Theme.panel2)
                    )
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            // Top third: XY pad (grows to fill when editor is hidden)
            XYPadView()
                .frame(maxHeight: .infinity)

            // Middle third: performance controls
            ControlDeckView(showEditor: $showEditor)

            // Bottom third: collapsible editor
            if showEditor {
                EditorView()
                    .frame(height: 340)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showPresetPicker) {
            PresetPickerSheet()
                .environmentObject(app)
        }
    }
}
