import Foundation

/// Pure four-corner morph mathematics for the CC XY pad.
///
/// Deliberately knows nothing about SwiftUI or CoreMIDI: it takes a
/// normalized position and returns four normalized weights. That keeps ONE
/// calculation path shared by touch, motion, or anything added later, and
/// makes the behavior testable without a running app or a MIDI connection.
///
/// Coordinate convention (note this differs from `TouchPoint`, which has y
/// pointing up — callers convert):
///   x: 0 = left,  1 = right
///   y: 0 = top,   1 = bottom
///
/// Corner order is always A, B, C, D = top-left, top-right, bottom-left,
/// bottom-right.
///
/// ── Processing order ────────────────────────────────────────────────────
///   1. Center Strength warps each axis
///   2. Bilinear weights from the warped position
///   3. Morph Curve exponent, then renormalize
///   4. Equal Power (square root), NOT renormalized afterwards
///
/// Center Strength runs on the POSITION rather than on the weights, which
/// departs from the obvious reading of "apply center strength to the
/// weights". Warping the axis keeps the weights separable, so exact
/// corners, symmetry, and sum-to-one all follow automatically. Applying it
/// to the weights afterwards would need explicit special-casing to keep the
/// corners at exactly 1/0/0/0 — the failure mode a naive wet/dry mix has.
struct MorphEngine {

    /// Four normalized corner weights, in A/B/C/D order.
    struct Weights: Equatable {
        var a: Double   // top-left
        var b: Double   // top-right
        var c: Double   // bottom-left
        var d: Double   // bottom-right

        var asArray: [Double] { [a, b, c, d] }

        static let even = Weights(a: 0.25, b: 0.25, c: 0.25, d: 0.25)
    }

    /// Peak sine amplitude for the Center Strength warp. Must stay below 1
    /// so the warp is strictly increasing (slope is 1 ± amplitude).
    private static let centerWarpAmplitude = 0.8

    /// Morph Curve exponent at the extremes: ±100 maps to p = 3 and p = 1/3.
    private static let morphExponentExtreme = 3.0

    // MARK: - Public entry point

    /// - Parameters:
    ///   - x: 0...1, left to right.
    ///   - y: 0...1, TOP to BOTTOM.
    ///   - morphCurve: -100...100. 0 is plain bilinear.
    ///   - centerStrength: 0...1 (i.e. 0%...100%). 0.5 is plain bilinear.
    ///   - equalPower: apply constant-power weighting.
    static func weights(x: Double,
                        y: Double,
                        morphCurve: Double,
                        centerStrength: Double,
                        equalPower: Bool) -> Weights {

        // Guard against NaN or out-of-range input reaching the math at all,
        // rather than trying to scrub the results afterwards.
        let px = clamp01(x.isFinite ? x : 0.5)
        let py = clamp01(y.isFinite ? y : 0.5)
        let curve = clamp(morphCurve.isFinite ? morphCurve : 0, -100, 100)
        let center = clamp01(centerStrength.isFinite ? centerStrength : 0.5)

        // 1. Center Strength — warp each axis.
        let wx = axisWarp(px, centerStrength: center)
        let wy = axisWarp(py, centerStrength: center)

        // 2. Bilinear weights. Sum is exactly 1 by construction.
        var a = (1 - wx) * (1 - wy)
        var b = wx * (1 - wy)
        var c = (1 - wx) * wy
        var d = wx * wy

        // 3. Morph Curve — exponent on the weights, then renormalize.
        //    p > 1 concentrates on the dominant corner, p < 1 spreads.
        //    Corners survive because 1^p = 1 and 0^p = 0 for any p > 0.
        let p = pow(morphExponentExtreme, curve / 100.0)
        if p != 1.0 {
            a = pow(max(a, 0), p)
            b = pow(max(b, 0), p)
            c = pow(max(c, 0), p)
            d = pow(max(d, 0), p)
            let total = a + b + c + d
            if total > 1e-12 {
                a /= total; b /= total; c /= total; d /= total
            } else {
                return .even
            }
        }

        // 4. Equal Power — amplitude = sqrt(weight).
        //    Since the weights sum to 1, the squares of the roots also sum
        //    to 1, so total power stays constant as the position moves.
        //    Deliberately NOT renormalized afterwards: rescaling back to a
        //    sum of 1 would undo exactly the compensation this provides.
        if equalPower {
            a = sqrt(max(a, 0))
            b = sqrt(max(b, 0))
            c = sqrt(max(c, 0))
            d = sqrt(max(d, 0))
        }

        return Weights(a: clamp01(a), b: clamp01(b),
                       c: clamp01(c), d: clamp01(d))
    }

    // MARK: - Center Strength

    /// Symmetric axis warp with BOUNDED slope everywhere:
    ///
    ///     warp(t) = t + amplitude · sin(2πt) / 2π
    ///     amplitude = 0.8 · (2·centerStrength − 1)
    ///
    /// Properties that matter here:
    ///   • warp(0) = 0, warp(1) = 1        → exact corners survive
    ///   • warp(1 − t) = 1 − warp(t)       → symmetry
    ///   • warp(0.5) = 0.5                 → center stays centered
    ///   • slope = 1 + amplitude·cos(2πt)  → within [0.2, 1.8], never
    ///                                        zero (monotonic) and never
    ///                                        infinite (no hot spots)
    ///   • amplitude = 0 → identity        → 50% is EXACTLY plain bilinear
    ///
    /// centerStrength < 0.5 makes it steep at the center and flat toward the
    /// edges, so the pad reads as four broad corner regions with a smooth
    /// crossover. Above 0.5 it flattens at the center and steepens near the
    /// edges, widening the four-way blend zone.
    ///
    /// The obvious alternative, `t^k`, is unusable: for k < 1 its slope at
    /// t = 0 is infinite, making the pad edges hypersensitive at high Center
    /// Strength — a single pixel near a corner could swing a CC by ~40.
    static func axisWarp(_ t: Double, centerStrength: Double) -> Double {
        let amplitude = centerWarpAmplitude * (2 * clamp01(centerStrength) - 1)
        guard amplitude != 0 else { return t }   // exact identity at 50%
        return t + amplitude * sin(2 * .pi * t) / (2 * .pi)
    }

    // MARK: - Helpers

    private static func clamp01(_ v: Double) -> Double { clamp(v, 0, 1) }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    /// Normalized weight to a 7-bit CC value.
    static func ccValue(_ weight: Double) -> Int {
        guard weight.isFinite else { return 0 }
        return min(max(Int((clamp01(weight) * 127).rounded()), 0), 127)
    }
}
