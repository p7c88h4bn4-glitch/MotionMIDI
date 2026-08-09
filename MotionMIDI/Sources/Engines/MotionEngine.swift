import Foundation
import CoreMotion
import Combine

/// Reads device motion at 100 Hz, runs every enabled mapping through
/// its processing chain (dead zone → sensitivity → invert → curve →
/// smoothing → range), and emits CCs only when the 7-bit value changes.
///
/// MIDI is sent directly from the motion callback thread for minimum
/// latency; only the low-rate meter values touch the main thread.
final class MotionEngine: ObservableObject {

    /// Normalized 0...1 values for the on-screen meters (~16 Hz).
    @Published private(set) var meterValues: [MotionSource: Double] = [:]
    @Published private(set) var running = false

    /// Updated by AppState whenever the preset changes.
    var preset: Preset {
        didSet {
            if preset.motionMappings != oldValue.motionMappings ||
               preset.calibration != oldValue.calibration {
                stateQueue.async { [self] in
                    smoothed.removeAll()
                    lastSent.removeAll()
                }
            }
        }
    }

    private let midi: MIDIEngine
    private let manager = CMMotionManager()
    private let motionQueue = OperationQueue()
    /// Serializes access to smoothing/last-sent state (motion callbacks
    /// arrive on motionQueue; preset changes arrive from main).
    private let stateQueue = DispatchQueue(label: "com.mrbrad.motionmidi.state",
                                           qos: .userInteractive)

    private var smoothed: [UUID: Double] = [:]
    private var lastSent: [UUID: Int] = [:]
    private var lastAttitude: (pitch: Double, roll: Double, yaw: Double) = (0, 0, 0)
    private var frame = 0

    init(midi: MIDIEngine, preset: Preset) {
        self.midi = midi
        self.preset = preset
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
        DispatchQueue.main.async { self.running = true }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        DispatchQueue.main.async { self.running = false }
    }

    /// Captures the current orientation as the new neutral position.
    /// Returns the calibration for AppState to store in the preset.
    func captureCalibration() -> Calibration {
        Calibration(pitch: lastAttitude.pitch,
                    roll: lastAttitude.roll,
                    yaw: lastAttitude.yaw)
    }

    // MARK: - Pipeline

    private func handle(_ motion: CMDeviceMotion) {
        lastAttitude = (motion.attitude.pitch, motion.attitude.roll, motion.attitude.yaw)

        stateQueue.sync { [self] in
            for mapping in preset.motionMappings where mapping.enabled {
                let raw = normalizedValue(for: mapping.source, motion: motion)
                let value = process(raw, mapping: mapping)
                if lastSent[mapping.id] != value {
                    lastSent[mapping.id] = value
                    midi.controlChange(mapping.cc, value: value, channel: mapping.channel)
                }
            }
        }

        // Meters at ~16 Hz so SwiftUI never fights the 100 Hz stream.
        frame += 1
        if frame % 6 == 0 {
            var meters: [MotionSource: Double] = [:]
            let sources: Set<MotionSource> = Set(preset.motionMappings.map(\.source))
                .union([.pitch, .roll, .yaw, .magnitude])
            for s in sources {
                meters[s] = normalizedValue(for: s, motion: motion)
            }
            DispatchQueue.main.async { self.meterValues = meters }
        }
    }

    private func process(_ raw: Double, mapping: MotionMapping) -> Int {
        let p = mapping.processing
        var v = raw

        // Dead zone around center, rescaled so the remaining travel
        // still reaches the full 0...1 range.
        let dz = min(max(p.deadZone, 0), 0.4)
        if dz > 0 {
            let offset = v - 0.5
            if abs(offset) <= dz {
                v = 0.5
            } else {
                let sign = offset > 0 ? 1.0 : -1.0
                v = 0.5 + sign * (abs(offset) - dz) / (0.5 - dz) * 0.5
            }
        }

        // Sensitivity (gain around center).
        v = 0.5 + (v - 0.5) * p.sensitivity
        v = min(max(v, 0), 1)

        if p.invert { v = 1 - v }
        v = p.curve.apply(v)

        // One-pole smoothing.
        let alpha = 1 - min(max(p.smoothing, 0), 0.95)
        let prev = smoothed[mapping.id] ?? v
        let s = prev + (v - prev) * alpha
        smoothed[mapping.id] = s

        let lo = min(max(p.outMin, 0), 127)
        let hi = min(max(p.outMax, 0), 127)
        return Int((Double(lo) + s * Double(hi - lo)).rounded())
    }

    // MARK: - Source normalization (everything lands in 0...1)

    private func normalizedValue(for source: MotionSource, motion: CMDeviceMotion) -> Double {
        let cal = preset.calibration
        switch source {
        case .pitch:
            return norm(motion.attitude.pitch - cal.pitch, -.pi / 2, .pi / 2)
        case .roll:
            return norm(wrap(motion.attitude.roll - cal.roll), -.pi / 2, .pi / 2)
        case .yaw:
            return norm(wrap(motion.attitude.yaw - cal.yaw), -.pi, .pi)
        case .gravityX:
            return norm(motion.gravity.x, -1, 1)
        case .gravityY:
            return norm(motion.gravity.y, -1, 1)
        case .gravityZ:
            return norm(motion.gravity.z, -1, 1)
        case .rotationX:
            return norm(motion.rotationRate.x, -8, 8)
        case .rotationY:
            return norm(motion.rotationRate.y, -8, 8)
        case .rotationZ:
            return norm(motion.rotationRate.z, -8, 8)
        case .accelX:
            return norm(motion.userAcceleration.x, -2, 2)
        case .accelY:
            return norm(motion.userAcceleration.y, -2, 2)
        case .accelZ:
            return norm(motion.userAcceleration.z, -2, 2)
        case .magnitude:
            let a = motion.userAcceleration
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            return min(mag / 2.5, 1) // unipolar: rest = 0, hard shake ≈ 1
        }
    }

    private func norm(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max((v - lo) / (hi - lo), 0), 1)
    }

    /// Wraps an angle into -π...π after calibration offsets.
    private func wrap(_ angle: Double) -> Double {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
