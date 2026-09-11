import SwiftUI

/// Every CC this preset sends, in one editable place.
///
/// Two views of the same data, because there are two different questions and
/// one layout cannot answer both. "What is Roll set to?" is an owner
/// question — you know the feature and want its number. "What is free?" and
/// "what is fighting?" are number questions — you know the range and want to
/// see the holes. Sorting by owner buries the holes; sorting by number
/// scatters each feature across the list.
struct CCMapView: View {
    @EnvironmentObject private var ownSurface: AppState

    var body: some View {
        // Both surfaces are handed in as observed objects so the map redraws
        // when either changes. When only one is running, the peer slot is
        // filled with the same object — one code path instead of two, and
        // the selector simply doesn't appear.
        CCMapBody(app: ownSurface, peer: ownSurface.peer ?? ownSurface)
    }
}

private struct CCMapBody: View {
    @ObservedObject var app: AppState
    @ObservedObject var peer: AppState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("MotionMIDIPro.dualSurface") private var dualSurface = false

    /// Which surface the list is showing and editing.
    @State private var viewingPeer = false

    /// True when there genuinely is a second surface on screen.
    private var hasPeer: Bool { dualSurface && peer !== app && isPadIdiom }

    /// The surface being edited. Every setter goes through this, so
    /// switching the selector switches what the wheels and menus write to.
    private var target: AppState { viewingPeer ? peer : app }

    enum Mode: String, CaseIterable, Identifiable {
        case owner  = "By Owner"
        case number = "By Number"
        var id: String { rawValue }
    }

    @AppStorage("MotionMIDIPro.ccMapMode") private var mode: Mode = .owner

    /// Which row has its picker open. One at a time — two open wheels in a
    /// list would fight for the same drag.
    @State private var editing: CCSlot? = nil

    /// Row that just sent a learn sweep, for a brief confirmation tick.
    /// Nothing comes BACK from a learn — the host either bound it or didn't
    /// — so the app can only confirm that it sent, and should be honest
    /// about confirming exactly that.
    @State private var justSent: CCSlot? = nil

    /// The rows on screen — the selected surface only.
    private var rows: [CCAssignment] { target.ccAssignments }

    /// Every row from BOTH surfaces, for conflict detection.
    ///
    /// The two surfaces share one MIDI port, so a CC sent by one lands in
    /// the same place as the same CC sent by the other. Checking a surface
    /// against itself alone would call a real collision clean.
    private var allRows: [CCAssignment] {
        guard hasPeer else { return rows }
        return app.ccAssignments + peer.ccAssignments
    }

    /// Section ids currently folded away.
    ///
    /// Keyed on the group's id string rather than the group itself so a dial
    /// keeps its collapsed state when an unrelated dial is added or removed
    /// and the section order shifts underneath it.
    @State private var collapsedGroups: Set<String> = []
    private var conflicts: Set<CCSlotRef> { Preset.conflictingSlots(in: allRows) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if hasPeer {
                    // Ordered by surface index, NOT by which one is local.
                    // Opening the map from the right-hand surface makes
                    // `app` the right one, and listing it first would put
                    // "Right" on the left of the control.
                    Picker("Surface", selection: $viewingPeer) {
                        // tag is "am I the peer?", which flips depending on
                        // which surface opened the map.
                        Text(surfaceName(leftSurface)).tag(leftSurface === peer)
                        Text(surfaceName(rightSurface)).tag(rightSurface === peer)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

                summaryStrip

                Group {
                    switch mode {
                    case .owner:  ownerList
                    case .number: numberList
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle("CC Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Summary

    private var summaryStrip: some View {
        HStack(spacing: 14) {
            summaryItem("\(rows.count)", "assigned", Theme.accent)
            summaryItem("\(128 - Set(rows.map(\.cc)).count)", "free", Theme.dim)

            if conflicts.isEmpty {
                summaryItem("0", "conflicts", Theme.good)
            } else {
                summaryItem("\(conflicts.count)", "conflicts", Theme.danger)
            }

            Spacer()

            // Says what the button does before it is pressed. A learn sweep
            // moves whatever is already listening, which is worth knowing in
            // advance rather than discovering mid-set.
            Label("tap to send", systemImage: "dot.radiowaves.right")
                .font(.system(size: 10))
                .foregroundColor(Theme.dim)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func summaryItem(_ value: String, _ label: String,
                             _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.dim)
        }
    }

    // MARK: - By owner

    private var ownerList: some View {
        List {
            ForEach(orderedGroups, id: \.id) { group in
                let groupRows = rows.filter { $0.group == group }
                if !groupRows.isEmpty {
                    let isCollapsed = collapsedGroups.contains(group.id)

                    Section {
                        if !isCollapsed {
                            if case .dial = group {
                                // One row per STEP, not per action. A step is
                                // named once and can carry both a Send and a
                                // Fader, so two rows sharing one name field was
                                // always going to look like a duplicate — and
                                // was, since both wrote the same DialStep.label.
                                ForEach(stepGroups(in: groupRows), id: \.key) { step in
                                    dialStepRow(step.rows)
                                        .listRowBackground(Theme.panel2)
                                }
                            } else {
                                ForEach(groupRows) { row in
                                    assignmentRow(row)
                                        .listRowBackground(Theme.panel2)
                                }
                            }

                            if group == .buttons {
                                addButtonRow
                                    .listRowBackground(Theme.panel2)
                            }
                        }
                    } header: {
                        sectionHeader(group,
                                      rowCount: groupRows.count,
                                      collapsed: isCollapsed)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }

    /// Tappable header that folds its section away.
    ///
    /// A collapsed section still reports how many rows it holds and whether
    /// any of them conflict — folding a section must not hide a problem, or
    /// the badge on the way in would count something you cannot find.
    private func sectionHeader(_ group: CCGroup,
                               rowCount: Int,
                               collapsed: Bool) -> some View {
        let conflicted = rows.filter {
            $0.group == group && conflicts.contains($0.ref)
        }.count

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsed {
                    collapsedGroups.remove(group.id)
                } else {
                    collapsedGroups.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundColor(Theme.dim)

                Label(group.title, systemImage: group.symbol)

                Spacer(minLength: 4)

                if conflicted > 0 {
                    Text("\(conflicted)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.danger))
                }

                if collapsed {
                    Text("\(rowCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.dim)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Adds a button without leaving the map.
    ///
    /// Sits inside the Buttons section rather than in a toolbar, so it adds
    /// to the thing it is next to. The new button takes the first free CC by
    /// the same rule the editor uses — they share one helper on AppState, so
    /// the two cannot drift apart.
    private var addButtonRow: some View {
        Button {
            target.addButton()
        } label: {
            Label("Add Button", systemImage: "plus.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    /// Sections in a stable order, with each dial getting its own.
    private var orderedGroups: [CCGroup] {
        var seen: [CCGroup] = []
        for row in rows where !seen.contains(row.group) {
            seen.append(row.group)
        }
        return seen
    }

    /// Dial rows bundled by the step they belong to.
    ///
    /// Keyed on `exclusion`, which already carries (dial slot, step index) —
    /// the same pairing that decides mutual exclusion. Reusing it means the
    /// grouping and the conflict rule can never disagree about what "the
    /// same step" means.
    private struct StepGroup {
        let key: String
        let rows: [CCAssignment]
    }

    private func stepGroups(in rows: [CCAssignment]) -> [StepGroup] {
        var order: [String] = []
        var buckets: [String: [CCAssignment]] = [:]

        for row in rows {
            guard let ex = row.exclusion else { continue }
            let key = "\(ex.group)-\(ex.member)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }

        return order.map { key in
            // Send left, Fader right — a fixed order, so the columns line
            // up down the section however the actions happen to be stored.
            // `DialStep.actions` is kept in DialActionKind order, which is
            // not this order, and sorting the labels alphabetically would
            // put Fader first. Both are reasons to state the order outright
            // rather than let it fall out of something else.
            let order = ["Send", "Fader"]
            let sorted = (buckets[key] ?? []).sorted {
                let a = order.firstIndex(of: $0.roleSuffix ?? "") ?? order.count
                let b = order.firstIndex(of: $1.roleSuffix ?? "") ?? order.count
                return a < b
            }
            return StepGroup(key: key, rows: sorted)
        }
    }

    /// One step: name left, its chips right — the same shape as every other
    /// row in the map.
    ///
    /// The step is named ONCE because there is one `DialStep.label`
    /// underneath. Send and Fader are roles of that step, so they sit in the
    /// value column beside each other rather than claiming a row each.
    private func dialStepRow(_ rows: [CCAssignment]) -> some View {
        // Any row of the step will do for the name — they all read and write
        // the same label.
        let lead = rows[0]
        let conflicted = rows.filter { conflicts.contains($0.ref) }
        let openRow = rows.first { editing == $0.slot }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(lead.defaultName, text: Binding(
                        get: { lead.storedName },
                        set: { target.setName(lead.slot, to: $0) }
                    ))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(lead.isActive ? .white.opacity(0.9) : Theme.dim)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                    HStack(spacing: 6) {
                        // No "inactive" caption here, unlike other rows.
                        // On a dial, exactly one step is ever selected, so
                        // being unselected is the normal state for almost
                        // every row — captioning all of them would be noise
                        // saying nothing. The dimmed name carries it, and
                        // the one live step is the one at full strength.
                        ForEach(conflicted) { row in
                            Label("\(row.roleSuffix ?? "CC"): \(conflictText(for: row))",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.danger)
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    ForEach(rows) { row in
                        Button {
                            editing = (editing == row.slot) ? nil : row.slot
                        } label: {
                            valueChip(row,
                                      conflicted: conflicts.contains(row.ref),
                                      open: editing == row.slot)
                        }
                        .buttonStyle(.plain)

                        learnButton(for: row)
                    }
                }
            }

            if let openRow {
                wheelPair(for: openRow)
            }
        }
        .padding(.vertical, 2)
    }

    private func assignmentRow(_ row: CCAssignment) -> some View {
        let isConflicted = conflicts.contains(row.ref)
        let isOpen = editing == row.slot

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if row.isRenamable {
                        // Bound to storedName — the RAW value — not to the
                        // resolved one. The field must write back exactly
                        // what it holds, so it can only ever hold what is
                        // actually stored. Dial rows never reach here; they
                        // go through `dialStepRow`, which shows one name for
                        // the whole step.
                        TextField(row.defaultName, text: Binding(
                            get: { row.storedName },
                            set: { target.setName(row.slot, to: $0) }
                        ))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(row.isActive ? .white.opacity(0.9) : Theme.dim)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    } else {
                        Text(row.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.dim)
                    }

                    HStack(spacing: 6) {
                        if let info = row.button {
                            // Choosable on the row itself, not behind the
                            // number editor. Message type and behavior are
                            // what you come to a button row to change; making
                            // them a caption you had to open a wheel sheet to
                            // reach put them further away than the numbers.
                            messageMenu(for: row, info: info)
                            behaviorMenu(for: row, info: info)
                            lightMenu(for: row, info: info)
                        }
                        if !row.isActive {
                            // Reserved-but-idle needs saying outright,
                            // otherwise the number looks free.
                            Text("inactive · still reserved")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.dim)
                        }
                        if isConflicted {
                            Label(conflictText(for: row),
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.danger)
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if row.isEditable {
                        Button {
                            // Tapping the open row closes it, so the wheels
                            // can be dismissed without hunting for a Done.
                            editing = isOpen ? nil : row.slot
                        } label: {
                            valueChip(row, conflicted: isConflicted, open: isOpen)
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.fill").font(.system(size: 9))
                            Text("CC \(row.cc)  ·  Ch \(row.channel + 1)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundColor(Theme.dim)
                    }

                    // Locked rows get one too. The number can't be changed,
                    // but it is still a real CC this app sends, and a host
                    // still has to be taught where portamento lives.
                    learnButton(for: row)
                }
            }

            if isOpen {
                wheelPair(for: row)
            }
        }
        .padding(.vertical, 2)
    }

    /// Fires a learn sweep for one assignment.
    ///
    /// Every row gets its own, including each half of a dial step: Send and
    /// Fader are separate numbers a host has to learn separately, so one
    /// button between them would only ever teach half the step.
    private func learnButton(for row: CCAssignment) -> some View {
        let sent = justSent == row.slot

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // A note row has to be taught with a note. A CC sweep would
            // teach the host nothing — it is listening for note on/off.
            if row.isNote {
                target.sendNoteForLearn(note: row.cc, channel: row.channel)
            } else {
                target.sendForLearn(cc: row.cc, channel: row.channel, rest: row.restValue)
            }

            justSent = row.slot
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                if justSent == row.slot { justSent = nil }
            }
        } label: {
            Image(systemName: sent ? "checkmark" : "dot.radiowaves.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(sent ? Theme.good : Theme.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.bg.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(sent ? Theme.good.opacity(0.6)
                                           : Color.white.opacity(0.08),
                                      lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send \(row.numberLabel) for MIDI learn")
    }

    /// The CC/CH chip used by EVERY row.
    ///
    /// Dial rows pass a role, which adds a leading column but changes
    /// nothing else — a dial's numbers should read exactly like a button's,
    /// since they are the same kind of thing and get edited the same way.
    private func valueChip(_ row: CCAssignment,
                           conflicted: Bool, open: Bool) -> some View {
        HStack(spacing: 6) {
            if let role = row.roleSuffix {
                Text(role.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.dim)
                    .fixedSize()

                Divider().frame(height: 20)
            }

            VStack(spacing: 0) {
                // "NOTE" rather than "CC" when the button sends notes —
                // the number alone would read as a CC and mean the wrong
                // thing entirely.
                Text(row.isNote ? "NOTE" : "CC")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Theme.dim)
                Text("\(row.cc)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(minWidth: 34)

            Divider().frame(height: 20)

            VStack(spacing: 0) {
                Text("CH").font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Theme.dim)
                Text("\(row.channel + 1)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(minWidth: 22)
        }
        .foregroundColor(conflicted ? Theme.danger : Theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(open ? Theme.accent.opacity(0.16) : Theme.bg.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(open ? Theme.accent.opacity(0.7)
                                   : Color.white.opacity(0.08),
                              lineWidth: 1)
        )
    }

    /// Two wheels side by side.
    ///
    /// Wheels rather than steppers because 128 numbers is far too many to
    /// tap through — a flick covers the range, and the wheel keeps spinning
    /// so a long move costs one gesture instead of a hundred.
    private func wheelPair(for row: CCAssignment) -> some View {
        VStack(spacing: 10) {
            wheels(for: row)
        }
        .padding(.top, 2)
    }

    /// CC or Note, chosen from the row.
    private func messageMenu(for row: CCAssignment, info: ButtonRowInfo) -> some View {
        Menu {
            Picker("Message", selection: Binding(
                get: { info.message },
                set: { target.setButtonMessage(row.slot, to: $0) }
            )) {
                ForEach(ButtonMessage.allCases) { message in
                    Text(message.label).tag(message)
                }
            }
        } label: {
            pill(info.message.label.uppercased())
        }
        .buttonStyle(.plain)
    }

    /// Momentary, Tap or Toggle, chosen from the row.
    private func behaviorMenu(for row: CCAssignment, info: ButtonRowInfo) -> some View {
        Menu {
            Picker("Behavior", selection: Binding(
                get: { info.behavior },
                set: { target.setButtonBehavior(row.slot, to: $0) }
            )) {
                ForEach(ButtonBehavior.allCases) { behavior in
                    Text(behavior.label).tag(behavior)
                }
            }
        } label: {
            pill(info.behavior.label.uppercased())
        }
        .buttonStyle(.plain)
    }

    /// Own state or host feedback, chosen from the row.
    private func lightMenu(for row: CCAssignment, info: ButtonRowInfo) -> some View {
        Menu {
            Picker("Lit From", selection: Binding(
                get: { info.light },
                set: { target.setButtonLight(row.slot, to: $0) }
            )) {
                ForEach(ButtonLight.allCases) { light in
                    Text(light.label).tag(light)
                }
            }
        } label: {
            pill(info.light == .host ? "HOST" : "OWN")
        }
        .buttonStyle(.plain)
    }

    /// Small tappable label. Bordered rather than bare text, so it reads as
    /// a control instead of a caption — the difference between seeing the
    /// behavior and knowing you can change it.
    private func pill(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 9, weight: .bold))
            Image(systemName: "chevron.down")
                .font(.system(size: 6, weight: .bold))
        }
        .foregroundColor(Theme.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private func wheels(for row: CCAssignment) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(row.isNote ? "Note Number" : "CC Number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.dim)

                Picker(row.isNote ? "Note" : "CC", selection: Binding(
                    get: { row.cc },
                    set: { target.setCC(row.slot, to: $0) }
                )) {
                    ForEach(0...127, id: \.self) { n in
                        // Note rows get the name too. "60" is a number you
                        // have to translate; "C3 · 60" is the one you can
                        // check against the part you are playing.
                        // MIDIWheelText.note already appends the number.
                        Text(row.isNote ? MIDIWheelText.note(n) : "\(n)")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .tag(n)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 110)
                .clipped()
            }

            VStack(spacing: 2) {
                Text("Channel")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.dim)

                Picker("Channel", selection: Binding(
                    get: { row.channel },
                    set: { target.setChannel(row.slot, to: $0) }
                )) {
                    ForEach(0...15, id: \.self) { c in
                        Text("\(c + 1)")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .tag(c)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 110)
                .clipped()
            }
        }
    }

    private var leftSurface: AppState { app.surface == 0 ? app : peer }
    private var rightSurface: AppState { app.surface == 0 ? peer : app }

    /// Short tag for the surface you are NOT looking at.
    private var otherSurfaceLabel: String {
        (viewingPeer ? app.surface : peer.surface) == 0 ? "Left:" : "Right:"
    }

    /// "Left" and "Right" rather than "A" and "B", because that is where
    /// they are on screen. The preset name comes along so the row says which
    /// rig you are looking at, not just which half of the glass.
    private func surfaceName(_ state: AppState) -> String {
        let side = state.surface == 0 ? "Left" : "Right"
        let name = state.preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? side : "\(side) · \(name)"
    }

    /// Names the other owner rather than just flagging a clash, so the fix
    /// doesn't require hunting the rest of the list to find who you are
    /// fighting with.
    private func conflictText(for row: CCAssignment) -> String {
        // Searches BOTH surfaces. A row whose only opponent is on the other
        // surface would otherwise show a conflict badge with no explanation
        // — the list it was searching does not contain the culprit.
        let others = allRows.filter {
            // isNote has to match, exactly as in conflictingSlots. Without
            // it a note row would name a CC row on the same number as its
            // opponent, when the two never collide in the first place.
            $0.isNote == row.isNote
                && $0.cc == row.cc && $0.channel == row.channel
                && $0.ref != row.ref && conflicts.contains($0.ref)
        }
        guard let first = others.first else { return "conflict" }

        // Named when it is on the other surface. "also Drawbar 3" sends you
        // hunting through a list that does not contain it.
        let name = first.surface == row.surface
            ? first.displayName
            : "\(otherSurfaceLabel) \(first.displayName)"

        return others.count == 1
            ? "also \(name)"
            : "also \(name) +\(others.count - 1)"
    }

    // MARK: - By number

    /// Only numbers actually spoken for, plus the runs between them
    /// collapsed into a single "free" row.
    ///
    /// A full 0–127 list would be 128 rows to scroll for maybe twenty that
    /// matter. Collapsing the gaps keeps the useful information — where the
    /// holes are and how big — without the scrolling.
    private var numberList: some View {
        List {
            ForEach(numberSections, id: \.start) { section in
                if section.isFree {
                    freeRunRow(section)
                        .listRowBackground(Theme.panel)
                } else {
                    numberRow(section)
                        .listRowBackground(Theme.panel2)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private struct NumberSection {
        let start: Int
        let end: Int
        let isFree: Bool
        let owners: [CCAssignment]
    }

    private var numberSections: [NumberSection] {
        // Note rows carry a note number, not a CC, so they have no place on
        // a 0-127 CC chart — listing them would claim a CC is spoken for
        // when it is still free.
        let byNumber = Dictionary(grouping: rows.filter { !$0.isNote }, by: \.cc)
        var sections: [NumberSection] = []
        var runStart: Int? = nil

        for cc in 0...127 {
            if let owners = byNumber[cc] {
                if let start = runStart {
                    sections.append(NumberSection(start: start, end: cc - 1,
                                                  isFree: true, owners: []))
                    runStart = nil
                }
                sections.append(NumberSection(start: cc, end: cc,
                                              isFree: false,
                                              owners: owners.sorted { $0.channel < $1.channel }))
            } else if runStart == nil {
                runStart = cc
            }
        }
        if let start = runStart {
            sections.append(NumberSection(start: start, end: 127,
                                          isFree: true, owners: []))
        }
        return sections
    }

    private func numberRow(_ section: NumberSection) -> some View {
        let clash = section.owners.contains { conflicts.contains($0.ref) }

        return HStack(alignment: .top, spacing: 12) {
            Text("\(section.start)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(clash ? Theme.danger : Theme.accent)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(section.owners) { owner in
                    HStack(spacing: 6) {
                        Image(systemName: owner.group.symbol)
                            .font(.system(size: 9))
                            .foregroundColor(Theme.dim)
                            .frame(width: 12)
                        Text(owner.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(owner.isActive ? .white.opacity(0.9)
                                                            : Theme.dim)
                        // The channel is what makes a shared number safe, so
                        // it belongs on every row here, not just clashing ones.
                        Text("ch \(owner.channel + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.dim)
                            .monospacedDigit()
                        if !owner.isEditable {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundColor(Theme.dim)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if clash {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.danger)
            }
        }
        .padding(.vertical, 3)
    }

    private func freeRunRow(_ section: NumberSection) -> some View {
        let count = section.end - section.start + 1
        let label = section.start == section.end
            ? "\(section.start)"
            : "\(section.start)–\(section.end)"

        return HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(Theme.dim)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)

            Text(count == 1 ? "free" : "\(count) free")
                .font(.system(size: 12))
                .foregroundColor(Theme.dim)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}
