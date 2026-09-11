import Foundation

/// Where a single CC assignment lives.
///
/// An address, not a value. Every CC in the app is stored somewhere different
/// — on a motion mapping, inside a dial step's action array, on a drawbar —
/// and this names the location so the map can read and write any of them
/// through one code path instead of a switch at every call site.
///
/// Dial slots are addressed by INDEX rather than by the dial preset's id,
/// because a slot can be linked to a shared library dial. The slot index is
/// what `AppState.updateDial(at:)` needs to route the write to the library
/// copy instead of the local one.
///
/// These addresses are valid for ONE snapshot of the preset. `DialStep`
/// keeps its actions sorted in `DialActionKind.allCases` order, so adding an
/// action renumbers the ones after it, and deleting a step shifts every
/// later step. The map rebuilds from scratch on every render, so nothing
/// holds a `CCSlot` across an edit — and nothing should.
enum CCSlot: Hashable {
    case motion(UUID)
    case xyX
    case xyY
    case morphCorner(Int)
    case drawbar(Int)
    case button(UUID)
    /// slot index, step index, action index within that step.
    case dialSend(slot: Int, step: Int, action: Int)
    case dialFader(slot: Int, step: Int, action: Int)
    /// Fixed by the MIDI spec — shown for completeness, never editable.
    case portamentoTime
    case portamentoSwitch
}

/// Which part of the app an assignment belongs to.
enum CCGroup: Hashable, Identifiable {
    case motion
    case xyPad
    case morph
    case drawbars
    case buttons
    /// One case per dial slot, so each dial gets its own section headed with
    /// its own name rather than all of them sharing a "Dials" heading.
    case dial(slot: Int, name: String)
    case fixed

    var id: String {
        switch self {
        case .motion:   return "motion"
        case .xyPad:    return "xy"
        case .morph:    return "morph"
        case .drawbars: return "drawbars"
        case .buttons:  return "buttons"
        case .dial(let slot, _): return "dial-\(slot)"
        case .fixed:    return "fixed"
        }
    }

    var title: String {
        switch self {
        case .motion:   return "Motion"
        case .xyPad:    return "XY Pad"
        case .morph:    return "Morph Corners"
        case .drawbars: return "Drawbars"
        case .buttons:  return "Buttons"
        case .dial(_, let name): return name
        case .fixed:    return "Fixed by Spec"
        }
    }

    var symbol: String {
        switch self {
        case .motion:   return "gyroscope"
        case .xyPad:    return "square.grid.2x2"
        case .morph:    return "circle.grid.2x2"
        case .drawbars: return "slider.vertical.3"
        case .buttons:  return "rectangle.grid.3x2"
        case .dial:     return "dial.medium"
        case .fixed:    return "lock"
        }
    }
}

/// Rows that can never be live at the same moment.
///
/// A stepped dial shows one step at a time, so two steps of the same dial
/// cannot both transmit — and giving four steps the same CC with four
/// different values is the ordinary way to build one, not a mistake. Without
/// this, the most natural dial setup there is would light the map up red.
///
/// Two rows are mutually exclusive when they share a `group` but differ in
/// `member`. Same group AND same member means the same step, whose Send and
/// Fader really can both be live, so that stays a conflict.
struct CCExclusion: Hashable {
    /// Which dial. Rows from different dials are never exclusive.
    let group: Int
    /// Which step within it.
    let member: Int
}

/// One row of the CC map.
/// The parts of a button that the CC map lets you edit in place.
///
/// Buttons are the only owner in the map with more than a number, a channel
/// and a name: what they put on the wire (CC or note) and how a press behaves
/// are both editable here, so you can wire a whole bank without leaving the
/// map for the button editor and back.
struct ButtonRowInfo: Equatable {
    var message: ButtonMessage
    var behavior: ButtonBehavior
    var light: ButtonLight
    /// Kept so switching CC -> Note -> CC returns the number you had rather
    /// than a default. The two numbering schemes are unrelated: CC 24 and
    /// note 24 mean nothing to each other, so each keeps its own.
    var cc: Int
    var note: Int
}

/// A row's identity across BOTH surfaces.
///
/// `CCSlot` alone is not unique once two surfaces are running: each has its
/// own `.xyX`, its own `.morphCorner(0)`, its own dial slot 0. Keying
/// conflicts on the slot alone would make surface A's X axis and surface B's
/// X axis the same row — one would mask the other's conflict, and clearing
/// the clash on one would appear to clear it on both.
struct CCSlotRef: Hashable {
    let surface: Int
    let slot: CCSlot
}

struct CCAssignment: Identifiable, Equatable {
    let slot: CCSlot
    let group: CCGroup
    /// Resolved base name — the stored one, or the default when unset.
    /// Never includes `roleSuffix`.
    let name: String
    /// The RAW stored value, empty when the owner has never been named.
    ///
    /// Separate from `name` because the text field has to edit exactly what
    /// is stored and nothing else. Binding it to `name` is what appended
    /// " — Send" to a dial step every time it was typed in: the field held
    /// the composed display string, wrote the whole thing back into
    /// `DialStep.label`, and the suffix was then composed onto it again on
    /// the next render.
    let storedName: String
    /// "Send" or "Fader" for dial rows, nil everywhere else. Shown beside
    /// the field, never inside it.
    let roleSuffix: String?
    let cc: Int
    /// 0-based. Every owner now carries one.
    let channel: Int
    /// False only for spec-fixed numbers.
    let isEditable: Bool
    /// False for a motion mapping that is switched off, a drawbar beyond
    /// `drawbarCount`, or a dial step that isn't the selected one. Still
    /// listed — the number is spoken for the moment it becomes active, and
    /// hiding it would make the map lie about what is free.
    let isActive: Bool
    /// What the name reverts to when cleared. Shown as placeholder text.
    let defaultName: String
    /// False where the owner has no name of its own to edit.
    let isRenamable: Bool
    /// Nil where the row can always fire. See `CCExclusion`.
    let exclusion: CCExclusion?

    /// Which performer surface this row belongs to. 0 when only one is
    /// running.
    var surface: Int = 0

    /// Set only for button rows, which are the one owner whose message type
    /// and press behavior are editable from the map. Nil everywhere else —
    /// a drawbar has no behavior and a motion axis has no note number.
    let button: ButtonRowInfo?

    /// Where to leave the parameter after a learn sweep.
    ///
    /// A sweep has to move to be learnable, which means it moves whatever is
    /// listening. Ending on the value this assignment would naturally send —
    /// a drawbar's stored level, a dial step's own value, a button's off
    /// value — puts the receiver back where it was instead of parking it at
    /// an extreme. Where nothing is stored, centre is the least surprising
    /// place to stop.
    let restValue: Int

    var ref: CCSlotRef { CCSlotRef(surface: surface, slot: slot) }

    /// True when this row's number is a note rather than a CC.
    ///
    /// A note row still occupies the `cc` field — it is the row's number,
    /// whatever kind — but it must never be counted as a CC conflict, and
    /// the chip has to say "NOTE" rather than "CC".
    var isNote: Bool { button?.message == .note }

    /// The number with its kind, e.g. "CC 24" or "NOTE 60".
    var numberLabel: String {
        isNote ? "NOTE \(cc)" : "CC \(cc)"
    }

    /// Name with its role, for places that show a row as one string.
    var displayName: String {
        guard let roleSuffix else { return name }
        return "\(name) — \(roleSuffix)"
    }

    var id: CCSlot { slot }
}

extension Preset {

    /// Every CC this preset assigns, in map order.
    ///
    /// Built from the preset itself, never from `MIDIDefaults`. The constants
    /// are only starting values; once a preset has been edited they describe
    /// nothing.
    ///
    /// Dials are walked as they ACTUALLY EXIST — the slots this preset has,
    /// each with its real steps, and only the steps carrying a Send or Fader
    /// action. Nothing hypothetical is listed, so every index inside a
    /// `CCSlot` addresses something real at the moment it is built.
    func ccAssignments(dialLibrary: [DialPreset] = [],
                       surface: Int = 0) -> [CCAssignment] {
        var rows: [CCAssignment] = []

        // ── Motion ──────────────────────────────────────────────────────
        for mapping in motionMappings {
            rows.append(CCAssignment(
                slot: .motion(mapping.id),
                group: .motion,
                name: mapping.name.isEmpty ? mapping.source.shortLabel : mapping.name,
                storedName: mapping.name,
                roleSuffix: nil,
                cc: mapping.cc,
                channel: mapping.channel,
                isEditable: true,
                isActive: mapping.enabled,
                defaultName: mapping.source.shortLabel,
                isRenamable: true,
                exclusion: nil,
                button: nil,
                restValue: 64
            ))
        }

        // ── XY pad ──────────────────────────────────────────────────────
        // Listed whatever the pad mode is: switching mode doesn't release
        // the number, and a map that hid it would report a free CC that
        // isn't.
        rows.append(CCAssignment(
            slot: .xyX, group: .xyPad,
            name: xyPad.xAxisName.isEmpty ? "X Axis" : xyPad.xAxisName,
            storedName: xyPad.xAxisName, roleSuffix: nil,
            cc: xyPad.xCC, channel: xyPad.standardChannel, isEditable: true,
            isActive: xyPad.ccMode == .standard,
            defaultName: "X Axis", isRenamable: true, exclusion: nil,
            button: nil, restValue: 64))
        rows.append(CCAssignment(
            slot: .xyY, group: .xyPad,
            name: xyPad.yAxisName.isEmpty ? "Y Axis" : xyPad.yAxisName,
            storedName: xyPad.yAxisName, roleSuffix: nil,
            cc: xyPad.yCC, channel: xyPad.standardChannel, isEditable: true,
            isActive: xyPad.ccMode == .standard,
            defaultName: "Y Axis", isRenamable: true, exclusion: nil,
            button: nil, restValue: 64))

        // ── Morph corners ───────────────────────────────────────────────
        for (i, corner) in xyPad.morphCorners.enumerated() {
            rows.append(CCAssignment(
                slot: .morphCorner(i),
                group: .morph,
                name: corner.label,
                storedName: corner.label,
                roleSuffix: nil,
                cc: corner.cc,
                channel: corner.channel,
                isEditable: true,
                isActive: xyPad.ccMode == .morph,
                defaultName: Self.defaultCornerLabel(i),
                isRenamable: true,
                exclusion: nil,
                button: nil,
                restValue: 0
            ))
        }

        // ── Drawbars ────────────────────────────────────────────────────
        for (i, bar) in xyPad.drawbars.enumerated() {
            rows.append(CCAssignment(
                slot: .drawbar(i),
                group: .drawbars,
                name: (bar.name?.isEmpty ?? true) ? "Drawbar \(i + 1)" : bar.name!,
                storedName: bar.name ?? "",
                roleSuffix: nil,
                cc: bar.cc,
                channel: xyPad.drawbarChannel,
                isEditable: true,
                isActive: xyPad.ccMode == .drawbars && i < xyPad.drawbarCount,
                defaultName: "Drawbar \(i + 1)",
                isRenamable: true,
                exclusion: nil,
                button: nil,
                restValue: bar.value
            ))
        }

        // ── Buttons ─────────────────────────────────────────────────────
        // Every button is listed, note-mode included. They used to be
        // filtered to CC only, on the reasoning that a note button holds no
        // CC number to conflict with — true, but it meant flipping a button
        // to Note made its row vanish from the map, which is exactly the
        // wrong response to an edit made IN the map. A note row carries its
        // note number in `cc` and is excluded from conflict checks instead.
        for button in buttons {
            rows.append(CCAssignment(
                slot: .button(button.id),
                group: .buttons,
                name: button.name.isEmpty ? "Button" : button.name,
                storedName: button.name,
                roleSuffix: nil,
                cc: button.message == .note ? button.note : button.cc,
                channel: button.channel,
                isEditable: true,
                isActive: true,
                defaultName: "Button",
                isRenamable: true,
                exclusion: nil,
                button: ButtonRowInfo(message: button.message,
                                      behavior: button.behavior,
                                      light: button.light,
                                      cc: button.cc,
                                      note: button.note),
                restValue: button.offValue
            ))
        }

        // ── Stepped dials ───────────────────────────────────────────────
        for slotIndex in dialSlots.indices {
            let entry = dialSlots[slotIndex]
            let dial: DialPreset = {
                if let id = entry.linkedDialPresetID,
                   let shared = dialLibrary.first(where: { $0.id == id }) {
                    return shared
                }
                return entry.localDial
            }()

            let heading = dialSlots.count > 1
                ? "Dial \(slotIndex + 1) — \(dial.name)"
                : dial.name
            let group = CCGroup.dial(slot: slotIndex, name: heading)

            for stepIndex in dial.steps.indices {
                let step = dial.steps[stepIndex]
                let exclusion = CCExclusion(group: slotIndex, member: stepIndex)
                let isSelected = stepIndex == dial.currentStepIndex

                for actionIndex in step.actions.indices {
                    switch step.actions[actionIndex] {
                    case .sendCC(let cc, let value, let channel):
                        rows.append(CCAssignment(
                            slot: .dialSend(slot: slotIndex, step: stepIndex,
                                            action: actionIndex),
                            group: group,
                            // Bare label. The " — Send" lives in
                            // roleSuffix so the text field never sees it.
                            name: step.label,
                            storedName: step.label,
                            roleSuffix: "Send",
                            cc: cc,
                            channel: channel,
                            isEditable: true,
                            isActive: isSelected,
                            defaultName: "Step",
                            isRenamable: true,
                            exclusion: exclusion,
                            button: nil,
                            restValue: value
                        ))
                    case .setFaderCC(let cc, let defaultValue, let channel):
                        rows.append(CCAssignment(
                            slot: .dialFader(slot: slotIndex, step: stepIndex,
                                             action: actionIndex),
                            group: group,
                            name: step.label,
                            storedName: step.label,
                            roleSuffix: "Fader",
                            cc: cc,
                            channel: channel,
                            isEditable: true,
                            isActive: isSelected,
                            defaultName: "Step",
                            isRenamable: true,
                            exclusion: exclusion,
                            button: nil,
                            restValue: defaultValue
                        ))
                    default:
                        break
                    }
                }
            }
        }

        // ── Spec-fixed ──────────────────────────────────────────────────
        // Shown and locked rather than offered: a synth looks for portamento
        // on these two numbers or not at all.
        if xyPad.glide {
            rows.append(CCAssignment(
                slot: .portamentoTime, group: .fixed, name: "Portamento Time",
                storedName: "Portamento Time", roleSuffix: nil,
                cc: MIDIDefaults.portamentoTimeCC, channel: xyPad.notesChannel,
                isEditable: false, isActive: true,
                defaultName: "Portamento Time", isRenamable: false,
                // glideTime is seconds, not a CC value — same 0...1 to
                // 0...127 conversion the pad uses when it sends it.
                exclusion: nil,
                button: nil,
                restValue: min(max(Int((xyPad.glideTime * 127).rounded()), 0), 127)))
            rows.append(CCAssignment(
                slot: .portamentoSwitch, group: .fixed, name: "Portamento Switch",
                storedName: "Portamento Switch", roleSuffix: nil,
                cc: MIDIDefaults.portamentoSwitchCC, channel: xyPad.notesChannel,
                isEditable: false, isActive: true,
                defaultName: "Portamento Switch", isRenamable: false,
                exclusion: nil, button: nil, restValue: xyPad.glide ? 127 : 0))
        }

        // Stamped once here rather than at each of the ten construction
        // sites, which is one place to get wrong instead of ten.
        return rows.map { row in
            var copy = row
            copy.surface = surface
            return copy
        }
    }

    /// A/B/C/D, matching `MorphCorner.defaults()`.
    static func defaultCornerLabel(_ index: Int) -> String {
        let letters = ["A", "B", "C", "D"]
        return letters.indices.contains(index) ? letters[index] : "Corner"
    }

    /// Rows that genuinely fight each other.
    ///
    /// Two rows conflict when they share a CC AND a channel AND can be live
    /// at the same time. All three matter:
    ///
    /// - Same number on DIFFERENT channels is not a conflict. Separate
    ///   channels is the normal way to reuse a controller number, and
    ///   flagging it would make the map cry wolf on a correct rig.
    /// - Mutually exclusive rows never collide — see `CCExclusion`. Four
    ///   steps of one dial sharing CC 102 with four different values is how
    ///   a stepped dial is meant to be built, not a mistake to warn about.
    ///
    /// Inactive rows still count. A drawbar hidden by the current pad mode
    /// holds its number the instant the mode changes, and a conflict that
    /// only appears mid-set is worse than one visible now.
    static func conflictingSlots(in rows: [CCAssignment]) -> Set<CCSlotRef> {
        var clashing: Set<CCSlotRef> = []

        for i in rows.indices {
            for j in rows.index(after: i)..<rows.endIndex {
                let a = rows[i], b = rows[j]

                // A note number and a CC number are different namespaces.
                // Note 24 and CC 24 on the same channel are unrelated
                // messages and never collide; two notes on the same number
                // and channel genuinely do.
                guard a.isNote == b.isNote else { continue }
                guard a.cc == b.cc, a.channel == b.channel else { continue }

                // Same dial, different step — can never both be live.
                //
                // Surface-qualified: exclusion groups are numbered per
                // preset, so surface A's dial 0 and surface B's dial 0 both
                // carry group 0. Without this check they would look mutually
                // exclusive and a genuine cross-surface clash would be
                // silently dismissed — the one kind of conflict neither
                // surface could otherwise see.
                if a.surface == b.surface,
                   let ea = a.exclusion, let eb = b.exclusion,
                   ea.group == eb.group, ea.member != eb.member {
                    continue
                }

                clashing.insert(a.ref)
                clashing.insert(b.ref)
            }
        }
        return clashing
    }

    /// CC numbers involved in at least one real conflict.
    static func conflictingCCs(in rows: [CCAssignment]) -> Set<Int> {
        let slots = conflictingSlots(in: rows)
        // Note rows are excluded: this drives the by-number CC list, and a
        // note number has no place on a chart of CCs 0-127.
        return Set(rows.filter { slots.contains($0.ref) && !$0.isNote }.map(\.cc))
    }
}
