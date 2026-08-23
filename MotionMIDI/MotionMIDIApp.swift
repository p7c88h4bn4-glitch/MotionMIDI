import SwiftUI
import UIKit

@main
struct MotionMIDIApp: App {

    // One engine each, shared by every surface.
    //
    // MIDI: one engine means one virtual port, so a host sees a single
    // instrument rather than one per surface. Both surfaces transmit down
    // it, separated by channel and CC rather than by port.
    //
    // Motion: there is one gyroscope. Two CMMotionManager consumers would
    // burn battery producing identical numbers.
    @StateObject private var shared = SharedEngines()

    var body: some Scene {
        WindowGroup {
            RootView(engines: shared)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

/// Owns the two engines and the per-surface `AppState`s built on top of them.
///
/// Exists as an ObservableObject purely so `@StateObject` keeps it alive for
/// the app's lifetime; nothing observes its published state.
@MainActor
final class SharedEngines: ObservableObject {
    let midi = MIDIEngine()
    let motion: MotionEngine

    /// Primary surface. Drives the motion engine and keeps the original
    /// storage keys, so an existing install is untouched by any of this.
    let surfaceA: AppState

    /// Second surface. Built lazily — someone running a single surface
    /// should not pay for a preset library load and a second set of state
    /// they will never see.
    private var _surfaceB: AppState?

    var surfaceB: AppState {
        if let _surfaceB { return _surfaceB }
        let state = AppState(surface: 1, midi: midi, motion: motion)
        _surfaceB = state
        return state
    }

    init() {
        let midi = self.midi
        let seed = PresetLibraryStore.load(surface: 0)?.presets.first
            ?? Preset.factoryDefault
        let motion = MotionEngine(midi: midi, preset: seed)
        self.motion = motion

        self.surfaceA = AppState(surface: 0, midi: midi, motion: motion)

        // Started here rather than inside AppState, because the engine now
        // outlives any single surface.
        motion.start()
        motion.preset = surfaceA.preset
    }
}

/// Chooses between one performer surface and two.
///
/// Each surface is a complete, independent `ContentView` — its own pad,
/// buttons, dials and preset — differing only in which `AppState` it is
/// handed. No view below this point knows or cares that a second surface
/// exists.
struct RootView: View {
    @ObservedObject var engines: SharedEngines

    @AppStorage("MotionMIDIPro.dualSurface") private var dualSurface = false

    /// Two full surfaces need width for two pads. On a phone that would
    /// leave each one too narrow to play, so the toggle simply doesn't
    /// apply there.
    private var canSplit: Bool { isPadIdiom }

    var body: some View {
        Group {
            if dualSurface && canSplit {
                HStack(spacing: 0) {
                    ContentView()
                        .environmentObject(engines.surfaceA)

                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                        .ignoresSafeArea(edges: .vertical)

                    ContentView()
                        .environmentObject(engines.surfaceB)
                }
            } else {
                ContentView()
                    .environmentObject(engines.surfaceA)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}
