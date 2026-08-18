import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var showEditor = false

    // The app-title header row is gone deliberately. It spent a full row of
    // height telling you which app you had open — something you already know
    // — on the one screen where vertical space is the scarce resource. The
    // preset selector it shared that row with moved into the XY pad's own
    // header, beside the settings button, so nothing was lost but the title.
    var body: some View {
        VStack(spacing: 0) {
            // XY pad (grows to fill when the editor is hidden)
            XYPadView()
                .frame(maxHeight: .infinity)

            // Performance controls, pushed down slightly to give the pad
            // more room to breathe at the top.
            ControlDeckView(showEditor: $showEditor)
                .padding(.top, 8)

            // Collapsible editor
            if showEditor {
                EditorView()
                    .frame(height: 340)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }
}
