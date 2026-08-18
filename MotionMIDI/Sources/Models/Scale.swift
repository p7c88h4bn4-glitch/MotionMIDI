import Foundation

/// A scale used to quantize the XY pad's diagonal note axis.
///
/// Each case stores its pitch classes as semitone offsets FROM THE ROOT
/// (not from C) — so the pattern applies correctly no matter what root
/// note is configured. All included scales are octave-periodic (their
/// pattern repeats every 12 semitones), which covers every scale here,
/// including the 8-note bebop/diminished scales and the 6-note whole tone
/// scale.
enum Scale: String, Codable, CaseIterable, Identifiable {
    case chromatic

    // Church modes
    case ionian
    case dorian
    case phrygian
    case lydian
    case mixolydian
    case aeolian

    // Minor variants
    case harmonicMinor
    case melodicMinor
    case phrygianDominant

    // Barry Harris bebop scales (6th diminished family)
    case barryMajor6Diminished
    case barryMinor6Diminished
    case barryDominantBebop

    // Symmetric / other jazz scales
    case wholeTone
    case diminishedWholeHalf
    case diminishedHalfWhole
    case altered
    case blues

    // Pentatonics
    case majorPentatonic
    case minorPentatonic

    // Hexatonics
    case augmented
    case prometheus
    case tritoneScale

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chromatic:              return "Chromatic"
        case .ionian:                 return "Ionian"
        case .dorian:                 return "Dorian"
        case .phrygian:               return "Phrygian"
        case .lydian:                 return "Lydian"
        case .mixolydian:             return "Mixolydian"
        case .aeolian:                return "Aeolian"
        case .harmonicMinor:          return "Harm Minor"
        case .melodicMinor:           return "Mel Minor"
        case .phrygianDominant:       return "Phryg Dom"
        case .barryMajor6Diminished:  return "BH Major 6dim"
        case .barryMinor6Diminished:  return "BH Minor 6dim"
        case .barryDominantBebop:     return "BH Dom Bebop"
        case .wholeTone:              return "Whole Tone"
        case .diminishedWholeHalf:    return "Dim W-H"
        case .diminishedHalfWhole:    return "Dim H-W"
        case .altered:                return "Altered"
        case .blues:                  return "Blues"
        case .majorPentatonic:        return "Major Pent"
        case .minorPentatonic:        return "Minor Pent"
        case .augmented:              return "Augmented"
        case .prometheus:             return "Prometheus"
        case .tritoneScale:           return "Tritone"
        }
    }

    /// Semitone offsets from the root, ascending, within one octave (0...11).
    var pitchClasses: [Int] {
        switch self {
        case .chromatic:             return Array(0...11)

        case .ionian:                return [0, 2, 4, 5, 7, 9, 11]
        case .dorian:                return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian:              return [0, 1, 3, 5, 7, 8, 10]
        case .lydian:                return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian:            return [0, 2, 4, 5, 7, 9, 10]
        case .aeolian:               return [0, 2, 3, 5, 7, 8, 10]

        case .harmonicMinor:         return [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor:          return [0, 2, 3, 5, 7, 9, 11]
        case .phrygianDominant:      return [0, 1, 4, 5, 7, 8, 10]

        // 1 2 3 4 5 #5 6 7 — major scale with a chromatic passing tone
        // between the 5th and 6th degrees.
        case .barryMajor6Diminished: return [0, 2, 4, 5, 7, 8, 9, 11]
        // 1 2 b3 4 5 b6 6 7 — minor with a natural 6 and the same
        // passing tone, per Barry Harris's minor 6th-diminished scale.
        case .barryMinor6Diminished: return [0, 2, 3, 5, 7, 8, 9, 11]
        // Mixolydian with an added major-7th passing tone — the
        // "dominant 7th bebop" scale used to keep 8th-note lines
        // landing on chord tones on the beat.
        case .barryDominantBebop:    return [0, 2, 4, 5, 7, 9, 10, 11]

        case .wholeTone:             return [0, 2, 4, 6, 8, 10]
        case .diminishedWholeHalf:   return [0, 2, 3, 5, 6, 8, 9, 11]
        case .diminishedHalfWhole:   return [0, 1, 3, 4, 6, 7, 9, 10]
        case .altered:               return [0, 1, 3, 4, 6, 8, 10]
        case .blues:                 return [0, 3, 5, 6, 7, 10]

        case .majorPentatonic:       return [0, 2, 4, 7, 9]
        case .minorPentatonic:       return [0, 3, 5, 7, 10]

        // Symmetric, built from two augmented triads a whole step apart
        // (alternating minor-3rd / half-step intervals). Very "outside"
        // — a Scriabin/late-Coltrane color.
        case .augmented:             return [0, 3, 4, 7, 8, 11]
        // Scriabin's "mystic chord" scale — whole tone with a raised 4th
        // treatment; a modern-jazz-voicing staple (Corea, Metheny circles).
        case .prometheus:            return [0, 2, 4, 6, 9, 10]
        // Two major triads a tritone apart — classic altered-dominant
        // color, common over 7#11/7b5 sounds.
        case .tritoneScale:          return [0, 1, 4, 6, 7, 10]
        }
    }

    /// Builds the ascending list of MIDI note numbers, starting at `root`,
    /// that belong to this scale, up to `root + rangeSemitones`.
    ///
    /// This is what the XY pad's diagonal indexes into — position 0...1
    /// along the diagonal maps to an INDEX in this array (a scale degree),
    /// not a raw semitone offset. That's what makes fewer-note scales
    /// (like a 5-note blues scale) spread across bigger, easier-to-hit
    /// zones on the pad than a 7- or 8-note scale in the same space.
    func notes(root: Int, rangeSemitones: Int) -> [Int] {
        let span = max(rangeSemitones, 0)
        let pcs = Set(pitchClasses.map { (($0 % 12) + 12) % 12 })

        var result: [Int] = []
        var offset = 0
        while offset <= span {
            let candidate = root + offset
            let pc = (((candidate - root) % 12) + 12) % 12
            if pcs.contains(pc), candidate >= 0, candidate <= 127 {
                result.append(candidate)
            }
            offset += 1
        }
        // Safety net: even a degenerate root/range combo must return
        // something playable, so the pad never silently goes dead.
        return result.isEmpty ? [min(max(root, 0), 127)] : result
    }
}

// MARK: - Menu grouping

/// Twenty-four scales in one flat picker is a scroll, not a choice. These
/// families are the same groupings the case list above is already organized
/// into, promoted to something the UI can iterate so the on-pad menu and the
/// config sheet present an identical, sectioned list.
extension Scale {
    struct Family: Identifiable {
        let id = UUID()
        let title: String
        let scales: [Scale]
    }

    static let families: [Family] = [
        Family(title: "Chromatic", scales: [.chromatic]),
        Family(title: "Pentatonic", scales: [.majorPentatonic, .minorPentatonic]),
        Family(title: "Church Modes", scales: [.ionian, .dorian, .phrygian,
                                               .lydian, .mixolydian, .aeolian]),
        Family(title: "Minor Variants", scales: [.harmonicMinor, .melodicMinor,
                                                 .phrygianDominant]),
        Family(title: "Bebop (Barry Harris)", scales: [.barryMajor6Diminished,
                                                       .barryMinor6Diminished,
                                                       .barryDominantBebop]),
        Family(title: "Symmetric & Jazz", scales: [.wholeTone, .diminishedWholeHalf,
                                                   .diminishedHalfWhole, .altered,
                                                   .blues]),
        Family(title: "Hexatonic", scales: [.augmented, .prometheus, .tritoneScale])
    ]
}
