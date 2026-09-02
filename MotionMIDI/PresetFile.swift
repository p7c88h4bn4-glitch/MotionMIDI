import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The exported preset type.
    ///
    /// Declared as a JSON subtype rather than a bare data type so the Files
    /// app, Mail and Messages all know they are looking at text they can
    /// preview, and so a file that arrives with the wrong extension but the
    /// right content still opens.
    static let motionMIDIPreset = UTType(exportedAs: "com.mrbradsmusic.motionmidi.preset",
                                         conformingTo: .json)
}

/// A preset on its way to or from a file.
///
/// The file holds ONE preset and nothing else. Dials are flattened into it
/// on the way out — see `Preset.flattenedForExport(dialLibrary:)` — so there
/// is no library to merge, no ids to reconcile, and no way for the file to
/// arrive referring to something the receiving device has never heard of.
struct PresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.motionMIDIPreset, .json] }
    static var writableContentTypes: [UTType] { [.motionMIDIPreset] }

    var preset: Preset

    init(preset: Preset) {
        self.preset = preset
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw PresetFileError.unreadable
        }
        do {
            preset = try JSONDecoder().decode(Preset.self, from: data)
        } catch {
            // A decode failure here is nearly always the wrong kind of JSON
            // — a dial export, a settings backup, something from another app
            // — rather than a corrupt preset. Saying so is more use than
            // surfacing the raw decoding error.
            throw PresetFileError.notAPreset
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        // Sorted and indented so the file is diffable and readable. These
        // get shared by email and looked at by people; unsorted single-line
        // JSON would work but tells the reader nothing.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(preset))
    }
}

enum PresetFileError: LocalizedError {
    case unreadable
    case notAPreset

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file could not be read."
        case .notAPreset: return "That file isn't a Motion MIDI preset."
        }
    }
}

extension Preset {

    /// A copy of this preset with every dial owned outright.
    ///
    /// A dial slot can point at a shared library dial by id. That dial lives
    /// in a different store, so a preset exported as-is would arrive with an
    /// id resolving to nothing — the slot would fall back to its `localDial`,
    /// which is usually empty, and the rig would look fine in the library
    /// and be broken when played.
    ///
    /// Flattening copies the linked dial's steps into the slot and clears the
    /// link, so the file is self-contained. The receiver gets exactly what
    /// the sender had on screen.
    ///
    /// The trade is that the copy is a snapshot: it no longer follows edits
    /// to the shared dial. That is the right trade for sharing a rig — the
    /// alternative is a file that depends on state the receiving device has
    /// no way to obtain.
    func flattenedForExport(dialLibrary: [DialPreset]) -> Preset {
        var copy = self

        for index in copy.dialSlots.indices {
            guard let linkedID = copy.dialSlots[index].linkedDialPresetID
            else { continue }

            if let shared = dialLibrary.first(where: { $0.id == linkedID }) {
                copy.dialSlots[index].localDial = shared
            }
            // Cleared either way. A link to a dial that isn't in the library
            // is already broken here; carrying it into the file would only
            // move the breakage to the other device.
            copy.dialSlots[index].linkedDialPresetID = nil
        }

        return copy
    }

    /// Filename for export: the preset's name, stripped of anything a file
    /// system would object to.
    var exportFilename: String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Preset" : cleaned
    }
}
