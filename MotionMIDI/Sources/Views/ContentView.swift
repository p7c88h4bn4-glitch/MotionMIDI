import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var showEditor = false

    /// Observed here, at the root of each surface, so editing a palette or
    /// switching the global one repaints this surface immediately.
    @ObservedObject private var palettes = PaletteLibrary.shared

    /// Surface palettes only apply while two surfaces are showing.
    @AppStorage("MotionMIDIPro.dualSurface") private var dualSurface = false

    /// This surface's colours, resolved once here and handed down through
    /// the environment. Every view below reads `@Environment(\.theme)`, which
    /// is what lets two surfaces on screen at once be different colours.
    private var theme: ThemeColors {
        palettes.theme(for: app.preset, surface: app.surface,
                       dual: dualSurface && isPadIdiom)
    }

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
        .background(theme.bg.ignoresSafeArea())
        .environment(\.theme, theme)
        // Lists, forms, pickers and plain text follow the system scheme.
        // Matching it to the palette keeps them readable on a light one.
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
        // The environment above covers this surface's own views; sheets are
        // separate presentations and take the window's scheme, which this
        // sets. With two surfaces in opposite schemes one of them wins —
        // mixing a light and a dark palette across surfaces is the one case
        // where a sheet can come up in the other surface's scheme.
        .preferredColorScheme(theme.isLight ? .light : .dark)
    }
}
