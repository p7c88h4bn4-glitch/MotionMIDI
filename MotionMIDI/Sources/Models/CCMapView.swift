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
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

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

    private var rows: [CCAssignment] { app.ccAssignments }
    private var conflicts: Set<CCSlot> { Preset.conflictingSlots(in: rows) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                    Section {
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
                    } header: {
                        Label(group.title, systemImage: group.symbol)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
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
        let conflicted = rows.filter { conflicts.contains($0.slot) }
        let openRow = rows.first { editing == $0.slot }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(lead.defaultName, text: Binding(
                        get: { lead.storedName },
                        set: { app.setName(lead.slot, to: $0) }
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
                                      conflicted: conflicts.contains(row.slot),
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
        let isConflicted = conflicts.contains(row.slot)
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
                            set: { app.setName(row.slot, to: $0) }
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
            app.sendForLearn(cc: row.cc, channel: row.channel, rest: row.restValue)

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
        .accessibilityLabel("Send CC \(row.cc) for MIDI learn")
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
                Text("CC").font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Theme.dim)
                Text("\(row.cc)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(minWidth: 30)

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
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("CC Number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.dim)

                Picker("CC", selection: Binding(
                    get: { row.cc },
                    set: { app.setCC(row.slot, to: $0) }
                )) {
                    ForEach(0...127, id: \.self) { n in
                        Text("\(n)")
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
                    set: { app.setChannel(row.slot, to: $0) }
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
        .padding(.top, 2)
    }

    /// Names the other owner rather than just flagging a clash, so the fix
    /// doesn't require hunting the rest of the list to find who you are
    /// fighting with.
    private func conflictText(for row: CCAssignment) -> String {
        let others = rows.filter {
            $0.cc == row.cc && $0.channel == row.channel
                && $0.slot != row.slot && conflicts.contains($0.slot)
        }
        guard let first = others.first else { return "conflict" }
        return others.count == 1
            ? "also \(first.displayName)"
            : "also \(first.displayName) +\(others.count - 1)"
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
        let byNumber = Dictionary(grouping: rows, by: \.cc)
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
        let clash = section.owners.contains { conflicts.contains($0.slot) }

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
