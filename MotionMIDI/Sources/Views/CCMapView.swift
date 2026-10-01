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
    @Environment(\.theme) private var theme
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
    @Environment(\.theme) private var theme
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

    /// Which button row has its listen editor open. Shares the one-at-a-time
    /// rule with `editing`: opening either closes the other, since two sets
    /// of wheels open in one list fight over the same drag.
    @State private var listening: CCSlot? = nil

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
            .background(theme.bg)
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
            summaryItem("\(rows.count)", "assigned", theme.accent)
            summaryItem("\(128 - Set(rows.map(\.cc)).count)", "free", theme.dim)

            if conflicts.isEmpty {
                summaryItem("0", "conflicts", theme.good)
            } else {
                summaryItem("\(conflicts.count)", "conflicts", theme.danger)
            }

            Spacer()

            // Says what the button does before it is pressed. A learn sweep
            // moves whatever is already listening, which is worth knowing in
            // advance rather than discovering mid-set.
            Label("tap to send", systemImage: "dot.radiowaves.right")
                .font(.system(size: 10))
                .foregroundColor(theme.dim)
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
                .foregroundColor(theme.dim)
        }
    }

    // MARK: - By owner

    private var ownerList: some View {
        List {
            // Colour lives in the map rather than a screen of its own, so
            // every widget is named, numbered and coloured in one place.
            CCMapColorsSection(app: target, showsSurfaceRow: hasPeer)

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
                                        .listRowBackground(theme.panel2)
                                }
                            } else {
                                ForEach(groupRows) { row in
                                    assignmentRow(row)
                                        .listRowBackground(theme.panel2)
                                }
                            }

                            if group == .buttons {
                                addButtonRow
                                    .listRowBackground(theme.panel2)
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
        let groupRows = rows.filter { $0.group == group }
        let conflicted = groupRows.filter { conflicts.contains($0.ref) }.count

        // Split into three tap targets. The whole header used to be one
        // Button, and a Button nested inside another Button's label does not
        // reliably receive taps — the channel steppers would have collapsed
        // the section instead of shifting anything.
        return HStack(spacing: 6) {
            Button {
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
                        .foregroundColor(theme.dim)

                    Label(group.title, systemImage: group.symbol)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if conflicted > 0 {
                Text("\(conflicted)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.danger))
            }

            if collapsed {
                Text("\(rowCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.dim)
                    .monospacedDigit()
            }

            if let component = headerColor(for: group, rows: groupRows) {
                ColorChoiceMenu(app: target, component: component)
            }

            channelStepper(for: groupRows)
        }
    }

    /// Sections that are ONE widget get their colour in the header: the XY
    /// pad (both axes and the touch gate are the same pad) and each dial
    /// (every step belongs to the same knob). A dropdown on every row there
    /// would be several controls editing one colour.
    private func headerColor(for group: CCGroup, rows groupRows: [CCAssignment]) -> ColorComponent? {
        switch group {
        case .xyPad: return .pad
        case .dial:  return groupRows.first?.color
        default:     return nil
        }
    }

    /// Sections whose rows are separate widgets get a dropdown per row. The
    /// morph Touch row is the pad itself, so it gets none here.
    private func rowColor(for row: CCAssignment) -> ColorComponent? {
        guard let component = row.color, component != .pad else { return nil }
        switch row.group {
        case .motion, .morph, .drawbars, .buttons: return component
        default: return nil
        }
    }

    /// Move every channel in a section together.
    ///
    /// Shifts by one rather than setting them all equal, so a section whose
    /// rows sit on different channels keeps its spread. Setting them all to
    /// one number would be destructive in a way a single tap should not be.
    private func channelStepper(for groupRows: [CCAssignment]) -> some View {
        let editable = groupRows.filter(\.isEditable)

        // Disabled at the edges rather than clamping. Clamping would pile
        // rows onto channel 16 one at a time and quietly destroy the spacing
        // between them — and tapping back would not restore it.
        let canRaise = !editable.isEmpty && editable.allSatisfy { $0.channel < 15 }
        let canLower = !editable.isEmpty && editable.allSatisfy { $0.channel > 0 }

        return HStack(spacing: 2) {
            Button {
                shiftChannels(editable, by: -1)
            } label: {
                stepperGlyph("minus")
            }
            .buttonStyle(.plain)
            .disabled(!canLower)
            .opacity(canLower ? 1 : 0.3)

            Text("CH")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(theme.dim)

            Button {
                shiftChannels(editable, by: 1)
            } label: {
                stepperGlyph("plus")
            }
            .buttonStyle(.plain)
            .disabled(!canRaise)
            .opacity(canRaise ? 1 : 0.3)
        }
    }

    private func stepperGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(theme.accent)
            .frame(width: 22, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.accent.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    /// Applies the shift from a SNAPSHOT of each row's channel.
    ///
    /// Several rows can share one stored channel — both XY axes write
    /// `standardChannel`, every drawbar writes `drawbarChannel`. Reading the
    /// live value per row and adding one would apply the shift once per row
    /// and move a shared channel by four or nine instead of one. Computing
    /// from the snapshot makes those writes idempotent: each row asks for
    /// the same destination.
    private func shiftChannels(_ rowsToShift: [CCAssignment], by delta: Int) {
        for row in rowsToShift {
            target.setChannel(row.slot, to: min(max(row.channel + delta, 0), 15))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                .foregroundColor(theme.accent)
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
                    .foregroundColor(lead.isActive ? theme.text.opacity(0.9) : theme.dim)
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
                                .foregroundColor(theme.danger)
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    ForEach(rows) { row in
                        Button {
                            editing = (editing == row.slot) ? nil : row.slot
                            if editing != nil { listening = nil }
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
                        .foregroundColor(row.isActive ? theme.text.opacity(0.9) : theme.dim)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    } else {
                        Text(row.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.dim)
                    }

                    HStack(spacing: 6) {
                        if let component = rowColor(for: row) {
                            ColorChoiceMenu(app: target, component: component)
                        }
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
                                .foregroundColor(theme.dim)
                        }
                        if isConflicted {
                            Label(conflictText(for: row),
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.danger)
                        }
                    }

                    // Its own line rather than a fourth pill: it has to say
                    // WHAT it listens on to be useful, which is more than a
                    // pill holds, and the pill row is already full on a phone.
                    // Only for host-lit buttons — an Own State button never
                    // reads incoming MIDI.
                    if let info = row.button, info.light == .host {
                        listenLine(for: row, info: info)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if row.isEditable {
                        Button {
                            // Tapping the open row closes it, so the wheels
                            // can be dismissed without hunting for a Done.
                            editing = isOpen ? nil : row.slot
                            if editing != nil { listening = nil }
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
                        .foregroundColor(theme.dim)
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

            if listening == row.slot, let info = row.button, info.light == .host {
                listenEditor(for: row, info: info)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Listen target (host-lit buttons)

    private func targetText(_ t: ButtonListen) -> String {
        "\(t.message == .cc ? "CC" : "NOTE") \(t.number) · CH \(t.channel + 1)"
    }

    /// Tappable status line: what this button listens on, and whether that is
    /// its own send number or a separate one.
    private func listenLine(for row: CCAssignment, info: ButtonRowInfo) -> some View {
        let open = listening == row.slot

        return Button {
            listening = open ? nil : row.slot
            if listening != nil { editing = nil }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ear")
                    .font(.system(size: 9, weight: .semibold))
                Text(info.listen == nil
                     ? "listens on own · \(targetText(info.feedbackTarget))"
                     : "listens on \(targetText(info.feedbackTarget))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            // Accent when custom, dim when default: a separate target is the
            // thing worth noticing at a glance down a column of buttons.
            .foregroundColor(info.listen == nil ? theme.dim : theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func listenEditor(for row: CCAssignment, info: ButtonRowInfo) -> some View {
        VStack(spacing: 8) {
            Picker("Listen On", selection: Binding<Bool>(
                get: { info.listen != nil },
                set: { custom in
                    // Seeded from where it listens now, so choosing Custom
                    // changes nothing until a value is actually edited.
                    target.setButtonListen(row.slot, to: custom ? info.feedbackTarget : nil)
                }
            )) {
                Text("Own Number").tag(false)
                Text("Custom").tag(true)
            }
            .pickerStyle(.segmented)

            if let listen = info.listen {
                Picker("Message", selection: Binding<ButtonMessage>(
                    get: { listen.message },
                    set: { newValue in
                        var edited = listen
                        edited.message = newValue
                        target.setButtonListen(row.slot, to: edited)
                    }
                )) {
                    ForEach(ButtonMessage.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                // Same compact, right-aligned wheels as the number editor, so
                // the two read as one family and neither is a wide spin
                // target across the row.
                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    VStack(spacing: 2) {
                        Text(listen.message == .cc ? "CC" : "NOTE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.dim)
                        Picker("Number", selection: Binding<Int>(
                            get: { listen.number },
                            set: { newValue in
                                var edited = listen
                                edited.number = newValue
                                target.setButtonListen(row.slot, to: edited)
                            }
                        )) {
                            ForEach(0...127, id: \.self) { n in
                                Text(listen.message == .note ? MIDIWheelText.note(n) : "\(n)")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .tag(n)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: listen.message == .note ? 104 : 60, height: 96)
                        .clipped()
                    }

                    VStack(spacing: 2) {
                        Text("CH")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.dim)
                        Picker("Channel", selection: Binding<Int>(
                            get: { listen.channel },
                            set: { newValue in
                                var edited = listen
                                edited.channel = newValue
                                target.setButtonListen(row.slot, to: edited)
                            }
                        )) {
                            ForEach(0...15, id: \.self) { c in
                                Text("\(c + 1)")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .tag(c)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 48, height: 96)
                        .clipped()
                    }
                }
            }
        }
        .padding(.top, 2)
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
                .foregroundColor(sent ? theme.good : theme.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.bg.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(sent ? theme.good.opacity(0.6)
                                           : theme.line(0.08),
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
                    .foregroundColor(theme.dim)
                    .fixedSize()

                Divider().frame(height: 20)
            }

            VStack(spacing: 0) {
                // "NOTE" rather than "CC" when the button sends notes —
                // the number alone would read as a CC and mean the wrong
                // thing entirely.
                Text(row.isNote ? "NOTE" : "CC")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(theme.dim)
                Text("\(row.cc)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(minWidth: 34)

            Divider().frame(height: 20)

            VStack(spacing: 0) {
                Text("CH").font(.system(size: 8, weight: .semibold))
                    .foregroundColor(theme.dim)
                Text("\(row.channel + 1)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(minWidth: 22)
        }
        .foregroundColor(conflicted ? theme.danger : theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(open ? theme.accent.opacity(0.16) : theme.bg.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(open ? theme.accent.opacity(0.7)
                                   : theme.line(0.08),
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
        .foregroundColor(theme.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private func wheels(for row: CCAssignment) -> some View {
        // Note rows carry "C3 · 60"; CC rows carry at most "127". Sizing the
        // number wheel to its content keeps the spin target no bigger than
        // the thing being spun — a wheel stretched across the row is a wheel
        // your thumb lands on while reaching for something else.
        let numberWidth: CGFloat = row.isNote ? 104 : 60

        return HStack(spacing: 10) {
            // Pushed right so each wheel sits under the chip it edits,
            // instead of across the row from it.
            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(row.isNote ? "NOTE" : "CC")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.dim)

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
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .tag(n)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: numberWidth, height: 96)
                .clipped()
            }

            VStack(spacing: 2) {
                Text("CH")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.dim)

                Picker("Channel", selection: Binding(
                    get: { row.channel },
                    set: { target.setChannel(row.slot, to: $0) }
                )) {
                    ForEach(0...15, id: \.self) { c in
                        Text("\(c + 1)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .tag(c)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 48, height: 96)
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
                        .listRowBackground(theme.panel)
                } else {
                    numberRow(section)
                        .listRowBackground(theme.panel2)
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
                .foregroundColor(clash ? theme.danger : theme.accent)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(section.owners) { owner in
                    HStack(spacing: 6) {
                        Image(systemName: owner.group.symbol)
                            .font(.system(size: 9))
                            .foregroundColor(theme.dim)
                            .frame(width: 12)
                        Text(owner.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(owner.isActive ? theme.text.opacity(0.9)
                                                            : theme.dim)
                        // The channel is what makes a shared number safe, so
                        // it belongs on every row here, not just clashing ones.
                        Text("ch \(owner.channel + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.dim)
                            .monospacedDigit()
                        if !owner.isEditable {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundColor(theme.dim)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if clash {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.danger)
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
                .foregroundColor(theme.dim)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)

            Text(count == 1 ? "free" : "\(count) free")
                .font(.system(size: 12))
                .foregroundColor(theme.dim)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Colour dropdown

/// The colour choice for one widget or base role.
///
/// Reads the TARGET surface's palette, not the one the map is drawn in, so
/// with the map switched to the other surface the swatches offered are the
/// ones that surface will actually show.
struct ColorChoiceMenu: View {
    @ObservedObject private var app: AppState
    @ObservedObject private var palettes = PaletteLibrary.shared
    @AppStorage("MotionMIDIPro.dualSurface") private var dualSurface = false
    @Environment(\.theme) private var theme

    let component: ColorComponent

    init(app: AppState, component: ColorComponent) {
        _app = ObservedObject(wrappedValue: app)
        self.component = component
    }

    private var targetTheme: ThemeColors {
        palettes.theme(for: app.preset, surface: app.surface,
                       dual: dualSurface && isPadIdiom)
    }

    private var defaultLabel: String {
        switch component {
        case .background, .panel, .raised, .text, .grid, .accent:
            return "Palette Default"
        case .morphCorner, .drawbar:
            return "Same as Pad"
        default:
            return "Same as Accent"
        }
    }

    var body: some View {
        let palette = targetTheme.palette

        Menu {
            Picker("Color", selection: Binding<Int>(
                get: { app.colorChoice(component) ?? -1 },
                set: { app.setColor(component, to: $0 < 0 ? nil : $0) }
            )) {
                Label {
                    Text(defaultLabel)
                } icon: {
                    Image(uiImage: SwatchImage.make(targetTheme.fallbackRGBA(for: component)))
                }
                .tag(-1)

                ForEach(palette.swatches.indices, id: \.self) { index in
                    Label {
                        Text("Color \(index + 1)")
                    } icon: {
                        Image(uiImage: SwatchImage.make(palette.swatches[index]))
                    }
                    .tag(index)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(targetTheme.resolvedRGBA(for: component).color)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(theme.text.opacity(0.3), lineWidth: 1))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(theme.dim)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.bg.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(theme.line(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color")
    }
}

// MARK: - Colors section

/// The top section of the map: which palette, the base colours, the dice.
///
/// Folded away by default. Colour is set up once and then left alone, and
/// open by default it would push every MIDI row down the list on every visit.
struct CCMapColorsSection: View {
    @ObservedObject private var app: AppState
    @ObservedObject private var palettes = PaletteLibrary.shared
    @AppStorage("MotionMIDIPro.dualSurface") private var dualSurface = false
    @AppStorage("MotionMIDIPro.ccMapColorsOpen") private var isOpen = false
    @Environment(\.theme) private var theme

    @State private var showManager = false

    /// True only while a second surface is running — the surface palette
    /// row means nothing otherwise, so it isn't offered.
    let showsSurfaceRow: Bool

    init(app: AppState, showsSurfaceRow: Bool) {
        _app = ObservedObject(wrappedValue: app)
        self.showsSurfaceRow = showsSurfaceRow
    }

    private var dual: Bool { dualSurface && isPadIdiom }

    private var resolved: ColorPalette {
        palettes.resolvedPalette(for: app.preset, surface: app.surface, dual: dual)
    }

    private var resolvedStyle: SurfaceStyle {
        palettes.resolvedStyle(for: app.preset, surface: app.surface, dual: dual)
    }

    private var surfaceSide: String { app.surface == 0 ? "Left" : "Right" }

    var body: some View {
        Section {
            if isOpen {
                swatchStrip
                    .listRowBackground(theme.panel2)

                // One row per layer, palette and style side by side. A
                // layer that follows the one below shows what it inherits,
                // dimmed, so the row always says what you're looking at.
                layerRow(title: "This Preset",
                         palette: app.preset.colors.paletteID,
                         inheritedPalette: palettes.inheritedPalette(surface: app.surface, dual: dual),
                         setPalette: { app.setPresetPalette($0) },
                         style: app.preset.colors.style,
                         inheritedStyle: palettes.inheritedStyle(surface: app.surface, dual: dual),
                         setStyle: { app.setPresetStyle($0) },
                         followLabel: showsSurfaceRow ? "Follow Surface" : "Follow Global")
                    .listRowBackground(theme.panel2)

                if showsSurfaceRow {
                    layerRow(title: "\(surfaceSide) Surface",
                             palette: palettes.surfacePaletteID(for: app.surface),
                             inheritedPalette: palettes.global,
                             setPalette: { palettes.setSurfacePalette($0, for: app.surface) },
                             style: palettes.surfaceStyle(for: app.surface),
                             inheritedStyle: palettes.globalStyle,
                             setStyle: { palettes.setSurfaceStyle($0, for: app.surface) },
                             followLabel: "Follow Global")
                        .listRowBackground(theme.panel2)
                }

                layerRow(title: "Global",
                         palette: palettes.globalID,
                         inheritedPalette: palettes.global,
                         setPalette: { palettes.globalID = $0 ?? ColorPalette.classic.id },
                         style: palettes.globalStyle,
                         inheritedStyle: palettes.globalStyle,
                         setStyle: { palettes.globalStyle = $0 ?? .standard },
                         followLabel: nil)
                    .listRowBackground(theme.panel2)

                ForEach(ColorComponent.roles, id: \.self) { role in
                    HStack {
                        Text(role.roleLabel)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.text.opacity(0.9))
                        Spacer()
                        ColorChoiceMenu(app: app, component: role)
                    }
                    .listRowBackground(theme.panel2)
                }

                Button {
                    showManager = true
                } label: {
                    Label("Manage Palettes", systemImage: "swatchpalette")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
                .listRowBackground(theme.panel2)
                .sheet(isPresented: $showManager) {
                    PaletteManagerView()
                }
            }
        } header: {
            header
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundColor(theme.dim)

                    Label("Colors", systemImage: "paintpalette")

                    // Folded, the section still says which palette and
                    // style are live.
                    if !isOpen {
                        Text("\(resolved.name) · \(resolvedStyle.label)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.dim)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            diceMenu
        }
    }

    /// In the header, so it works with the section folded. Most people want
    /// variety, not a colour-by-colour session — one tap should get them it.
    private var diceMenu: some View {
        Menu {
            Button {
                app.surpriseColors()
            } label: {
                Label("Surprise Me", systemImage: "dice")
            }
            Button {
                app.randomPalette()
            } label: {
                Label("Random Palette", systemImage: "paintpalette")
            }
            Button {
                app.scatterColors()
            } label: {
                Label("Scatter Colors", systemImage: "sparkles")
            }
            Divider()
            Button(role: .destructive) {
                app.resetColors()
            } label: {
                Label("Reset Colors", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "dice.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.accent)
                .frame(width: 30, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(theme.accent.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Randomize colors")
    }

    // MARK: Rows

    /// The live palette's colours, numbered the way the dropdowns number
    /// them, so "Color 5" can be found without opening a menu.
    private var swatchStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(resolved.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.dim)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 6)], spacing: 6) {
                ForEach(resolved.swatches.indices, id: \.self) { index in
                    let swatch: RGBA = resolved.swatches[index]
                    let numberColor: Color = swatch.luminance > 0.6
                        ? Color.black.opacity(0.7)
                        : Color.white.opacity(0.9)
                    ZStack {
                        Circle()
                            .fill(swatch.color)
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(numberColor)
                    }
                    .frame(width: 26, height: 26)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// One layer — preset, surface or global — with its palette menu and
    /// its style menu. `followLabel` nil means the layer can't follow
    /// anything (Global), so no follow option is offered.
    private func layerRow(title: String,
                          palette: UUID?,
                          inheritedPalette: ColorPalette,
                          setPalette: @escaping (UUID?) -> Void,
                          style: SurfaceStyle?,
                          inheritedStyle: SurfaceStyle,
                          setStyle: @escaping (SurfaceStyle?) -> Void,
                          followLabel: String?) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.text.opacity(0.9))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            paletteMenu(title: title, current: palette, inherited: inheritedPalette,
                        followLabel: followLabel, set: setPalette)
            styleMenu(title: title, current: style, inherited: inheritedStyle,
                      followLabel: followLabel, set: setStyle)
        }
    }

    private func paletteMenu(title: String,
                             current: UUID?,
                             inherited: ColorPalette,
                             followLabel: String?,
                             set: @escaping (UUID?) -> Void) -> some View {
        let chosen: ColorPalette? = palettes.palette(current)
        let shownName: String = chosen?.name ?? inherited.name
        let following: Bool = chosen == nil && followLabel != nil

        return Menu {
            Picker(title, selection: Binding<UUID?>(
                get: { chosen == nil ? nil : current },
                set: { set($0) }
            )) {
                if let followLabel {
                    Text(followLabel).tag(UUID?.none)
                }
                ForEach(palettes.all) { palette in
                    Label {
                        Text(palette.name)
                    } icon: {
                        Image(uiImage: SwatchImage.strip(palette.swatches))
                    }
                    .tag(Optional(palette.id))
                }
            }
        } label: {
            menuLabel(shownName, following: following)
        }
        .buttonStyle(.plain)
    }

    private func styleMenu(title: String,
                           current: SurfaceStyle?,
                           inherited: SurfaceStyle,
                           followLabel: String?,
                           set: @escaping (SurfaceStyle?) -> Void) -> some View {
        let shown: SurfaceStyle = current ?? inherited
        let following: Bool = current == nil && followLabel != nil

        return Menu {
            Picker(title, selection: Binding<SurfaceStyle?>(
                get: { current },
                set: { set($0) }
            )) {
                if let followLabel {
                    Text(followLabel).tag(SurfaceStyle?.none)
                }
                Section("Flat") {
                    ForEach(SurfaceStyle.flatStyles) { style in
                        Label(style.label, systemImage: style.symbol)
                            .tag(Optional(style))
                    }
                }
                Section("Shaded") {
                    ForEach(SurfaceStyle.shadedStyles) { style in
                        Label(style.label, systemImage: style.symbol)
                            .tag(Optional(style))
                    }
                }
            }
        } label: {
            menuLabel(shown.label, following: following)
        }
        .buttonStyle(.plain)
    }

    /// Accent when this layer made the choice; dimmed when it is showing
    /// what it inherits from the layer below.
    private func menuLabel(_ text: String, following: Bool) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 13, weight: following ? .medium : .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundColor(following ? theme.dim : theme.accent)
    }
}

// MARK: - Palette manager

/// Every palette: pick the global one, open one to edit, make new ones.
struct PaletteManagerView: View {
    @ObservedObject private var palettes = PaletteLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(palettes.custom) { palette in
                        row(palette)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { palettes.custom[$0].id }
                        for id in ids { palettes.delete(id) }
                    }

                    Button {
                        path.append(palettes.createRandom())
                    } label: {
                        Label("New Random Palette", systemImage: "dice")
                            .foregroundColor(theme.accent)
                    }
                } header: {
                    Text("Yours")
                } footer: {
                    Text("Open any built-in palette and tap Duplicate to make a copy you can change.")
                }

                Section("Built-In") {
                    ForEach(ColorPalette.builtIns) { palette in
                        row(palette)
                    }
                }
            }
            .navigationTitle("Palettes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                PaletteEditorView(paletteID: id) { newID in
                    path.append(newID)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ palette: ColorPalette) -> some View {
        NavigationLink(value: palette.id) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(palette.name)
                    if palette.id == palettes.globalID {
                        Text("Global")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(theme.accent)
                    }
                }
                Spacer(minLength: 8)
                PalettePreview(palette: palette)
            }
        }
    }
}

/// Background plate with the component colours on it, so a palette reads
/// the way it will look rather than as loose dots.
struct PalettePreview: View {
    let palette: ColorPalette

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(palette.swatches.prefix(8).enumerated()), id: \.offset) { _, swatch in
                Circle()
                    .fill(swatch.color)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(palette.panel.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(palette.grid.color, lineWidth: 1)
        )
    }
}

// MARK: - Palette editor

struct PaletteEditorView: View {
    @ObservedObject private var palettes = PaletteLibrary.shared
    @Environment(\.theme) private var theme

    let paletteID: UUID
    /// Opens another palette — used after Duplicate, so the copy is where
    /// you land.
    let open: (UUID) -> Void

    init(paletteID: UUID, open: @escaping (UUID) -> Void) {
        self.paletteID = paletteID
        self.open = open
    }

    private var editable: Bool { !palettes.isBuiltIn(paletteID) }

    var body: some View {
        Group {
            if let palette = palettes.palette(paletteID) {
                form(palette)
            } else {
                // Deleted from under the editor.
                Text("This palette no longer exists.")
                    .foregroundColor(theme.dim)
            }
        }
        .navigationTitle(palettes.palette(paletteID)?.name ?? "Palette")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ palette: ColorPalette) -> some View {
        Form {
            Section {
                if editable {
                    TextField("Name", text: Binding(
                        get: { palette.name },
                        set: { newName in palettes.update(paletteID) { $0.name = newName } }
                    ))
                } else {
                    LabeledContent("Name", value: palette.name)
                }

                if palette.id == palettes.globalID {
                    Label("Global Palette", systemImage: "checkmark.circle.fill")
                        .foregroundColor(theme.accent)
                } else {
                    Button {
                        palettes.globalID = palette.id
                    } label: {
                        Label("Use as Global Palette", systemImage: "globe")
                    }
                }

                Button {
                    if let copy = palettes.duplicate(paletteID) { open(copy) }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            } footer: {
                if !editable {
                    Text("Built-in palettes can't be changed. Duplicate this one to make a copy you can edit.")
                }
            }

            Section {
                ForEach(ColorComponent.roles, id: \.self) { role in
                    colorRow(role.roleLabel,
                             value: palette.base(role),
                             supportsOpacity: role == .grid) { newValue in
                        palettes.update(paletteID) { $0.setBase(role, to: newValue) }
                    }
                }
            } header: {
                Text("Base")
            } footer: {
                Text("Grid Lines keeps its transparency, so lines stay faint over the panels.")
            }

            Section {
                ForEach(palette.swatches.indices, id: \.self) { index in
                    colorRow("Color \(index + 1)",
                             value: palette.swatches[index],
                             supportsOpacity: false) { newValue in
                        palettes.update(paletteID) { edited in
                            guard edited.swatches.indices.contains(index) else { return }
                            edited.swatches[index] = newValue
                        }
                    }
                    // Built-ins can't lose colours, and every palette keeps
                    // at least one for widgets to fall back on.
                    .deleteDisabled(!editable || palette.swatches.count <= 1)
                }
                .onDelete { offsets in
                    palettes.update(paletteID) { edited in
                        guard edited.swatches.count > offsets.count else { return }
                        edited.swatches.remove(atOffsets: offsets)
                    }
                }

                if editable {
                    Button {
                        palettes.update(paletteID) { edited in
                            edited.swatches.append(RGBA(hue: Double.random(in: 0..<1),
                                                        saturation: 0.7,
                                                        brightness: 0.95))
                        }
                    } label: {
                        Label("Add Color", systemImage: "plus.circle")
                    }
                    .disabled(palette.swatches.count >= ColorPalette.maxSwatches)

                    Button {
                        palettes.update(paletteID) { edited in
                            let fresh = ColorPalette.random()
                            edited.swatches = fresh.swatches
                            edited.accent = fresh.accent
                        }
                    } label: {
                        Label("Generate New Colors", systemImage: "dice")
                    }
                }
            } header: {
                Text("Component Colors")
            } footer: {
                Text("Widgets choose from these by number in the CC Map. Deleting a colour renumbers the ones after it.")
            }
        }
    }

    @ViewBuilder
    private func colorRow(_ title: String,
                          value: RGBA,
                          supportsOpacity: Bool,
                          set: @escaping (RGBA) -> Void) -> some View {
        if editable {
            ColorPicker(title,
                        selection: Binding(get: { value.color },
                                           set: { set(RGBA($0)) }),
                        supportsOpacity: supportsOpacity)
        } else {
            HStack {
                Text(title)
                Spacer()
                Circle()
                    .fill(value.color)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(theme.text.opacity(0.3), lineWidth: 1))
            }
        }
    }
}
