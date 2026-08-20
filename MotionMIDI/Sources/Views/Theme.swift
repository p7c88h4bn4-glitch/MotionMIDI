import SwiftUI

enum Theme {
    static let bg      = Color(red: 0x0B / 255, green: 0x0C / 255, blue: 0x0F / 255)
    static let panel   = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1B / 255)
    static let panel2  = Color(red: 0x1C / 255, green: 0x1F / 255, blue: 0x26 / 255)
    static let accent  = Color(red: 0xF2 / 255, green: 0xA6 / 255, blue: 0x5A / 255)
    static let good    = Color(red: 0x4C / 255, green: 0xC3 / 255, blue: 0x8A / 255)
    static let danger  = Color(red: 0xE5 / 255, green: 0x5A / 255, blue: 0x5A / 255)
    static let dim     = Color.white.opacity(0.45)
}

/// Reusable compact wheel for MIDI-sized integer settings.
///
/// Steppers made the editor feel like a series of +/- counters. This keeps
/// the label visible while giving every numeric MIDI setting the same direct,
/// scrollable wheel interaction.
struct IntWheelRow: View {
    let title: String
    @Binding var selection: Int
    let range: ClosedRange<Int>
    let text: (Int) -> String

    init(title: String,
         selection: Binding<Int>,
         range: ClosedRange<Int>,
         text: @escaping (Int) -> String = { String($0) }) {
        self.title = title
        self._selection = selection
        self.range = range
        self.text = text
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Picker(title, selection: $selection) {
                ForEach(Array(range), id: \.self) { value in
                    Text(text(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.wheel)
            .frame(width: 140, height: 92)
            .clipped()
        }
    }
}

/// Narrow variant used inside the 2x2 morph-corner cards.
struct CompactIntWheel: View {
    let title: String
    @Binding var selection: Int
    let range: ClosedRange<Int>
    let text: (Int) -> String

    init(title: String,
         selection: Binding<Int>,
         range: ClosedRange<Int>,
         text: @escaping (Int) -> String = { String($0) }) {
        self.title = title
        self._selection = selection
        self.range = range
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)

            Picker(title, selection: $selection) {
                ForEach(Array(range), id: \.self) { value in
                    Text(text(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .clipped()
        }
    }
}

enum MIDIWheelText {
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func note(_ value: Int) -> String {
        let clamped = min(max(value, 0), 127)
        return "\(noteNames[clamped % 12])\(clamped / 12 - 1)  ·  \(clamped)"
    }
}
