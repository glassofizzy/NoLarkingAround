import SwiftUI

/// The dropdown card: paper, thick ink border, hard offset ink shadow — the
/// takeover's visual language at menu size. Hosted by MenuPanelController.
struct MenuPanelView: View {
    @ObservedObject var model: MenuViewModel

    static let width: CGFloat = 380
    static let shadowOffset: CGFloat = 6
    static let radius: CGFloat = 14
    static let border: CGFloat = 2.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(DS.ink)
                .offset(x: Self.shadowOffset, y: Self.shadowOffset)
            card
        }
        .padding(.trailing, Self.shadowOffset)
        .padding(.bottom, Self.shadowOffset)
    }

    private var snap: MenuSnapshot { model.snapshot }

    private var card: some View {
        VStack(spacing: 0) {
            meetings
            Rule()
            section {
                if snap.isPaused {
                    PanelRow(id: .resume, label: "Resume alerts", model: model)
                } else {
                    PanelRow(id: .pauseHour, label: "Pause for 1 hour", model: model) {
                        HStack(spacing: 4) { KeyCap("⌥"); KeyCap("⌘"); KeyCap("P") }
                    }
                    PanelRow(id: .pauseTomorrow, label: "Pause until tomorrow", model: model)
                }
                leadTime
            }
            Rule()
            section {
                PanelRow(id: .testTakeover, label: "Test takeover now", model: model)
                PanelRow(id: .refresh, label: "Refresh calendar", model: model)
                PanelRow(id: .openConfig, label: "Open config…", model: model)
            }
            Rule()
            section {
                PanelRow(id: .quit, label: "Quit No Larking Around", model: model) {
                    HStack(spacing: 4) { KeyCap("⌘"); KeyCap("Q") }
                }
            }
        }
        .frame(width: Self.width)
        .background(DS.paper)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius)
                    .strokeBorder(DS.ink, lineWidth: Self.border))
    }

    // MARK: Meetings

    @ViewBuilder private var meetings: some View {
        VStack(alignment: .leading, spacing: 2) {
            if snap.authExpired {
                Notice(text: "⚠  Lark sign-in expired")
                PanelRow(id: .reauth, label: "Re-authenticate Lark…", model: model)
                    .padding(.bottom, 6)
            } else if let err = snap.errorText {
                Notice(text: "⚠  \(err)")
                    .padding(.bottom, 6)
            }

            if snap.groups.isEmpty {
                SectionHeader(text: "NEXT 18 HOURS")
                Text("No meetings in the next 18 hours")
                    .font(DS.display(15, 500))
                    .foregroundColor(DS.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
            }
            ForEach(Array(snap.groups.enumerated()), id: \.offset) { gi, group in
                SectionHeader(text: group.header)
                    .padding(.top, gi == 0 ? 0 : 8)
                ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                    MeetingRowView(row: row)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: Lead time

    @ViewBuilder private var leadTime: some View {
        PanelRow(id: .leadTime, label: "Lead time", model: model) {
            HStack(spacing: 8) {
                ValuePill(text: "\(snap.leadMinutes) MIN", filled: true)
                Text("›")
                    .font(DS.display(18, 800))
                    .foregroundColor(DS.ink)
                    .rotationEffect(.degrees(model.leadExpanded ? 90 : 0))
                    .frame(width: 10)
            }
        }
        .accessibilityValue("\(snap.leadMinutes) minutes")
        if model.leadExpanded {
            ForEach(MenuSnapshot.leadChoices, id: \.self) { m in
                PanelRow(id: .lead(m), label: "\(m) min", model: model, indent: 18) {
                    if m == snap.leadMinutes {
                        ValuePill(text: "CURRENT", filled: true)
                    }
                }
            }
        }
    }

    private func section<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
    }
}

// MARK: - Pieces

private struct Rule: View {
    var body: some View {
        Rectangle().fill(DS.ink).frame(height: 2)
    }
}

private struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.mono(11, 700))
            .tracking(DS.tracking(0.18, 11))
            .foregroundColor(DS.ink)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct Notice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.display(14, 600))
            .foregroundColor(DS.ink)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.accent))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.ink, lineWidth: 2))
    }
}

private struct MeetingRowView: View {
    let row: MenuMeetingRow
    var body: some View {
        HStack(spacing: 12) {
            Text(row.time)
                .font(DS.mono(14, 600))
            Text(row.title)
                .font(DS.display(15, 600))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundColor(row.isNext ? DS.ink : DS.muted)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(row.isNext ? DS.ground : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DS.ink, lineWidth: row.isNext ? 2 : 0)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.time) \(row.title)\(row.isNext ? ", next" : "")")
    }
}

/// A selectable row. Hover and keyboard share `model.highlighted`, so the two
/// can never show different rows lit.
private struct PanelRow<Trailing: View>: View {
    let id: MenuRowID
    let label: String
    @ObservedObject var model: MenuViewModel
    var indent: CGFloat = 0
    @ViewBuilder var trailing: () -> Trailing

    init(id: MenuRowID, label: String, model: MenuViewModel, indent: CGFloat = 0,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.id = id
        self.label = label
        self.model = model
        self.indent = indent
        self.trailing = trailing
    }

    var body: some View {
        let lit = model.highlighted == id
        HStack(spacing: 8) {
            Text(label)
                .font(DS.display(15, 600))
                .foregroundColor(DS.ink)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 14 + indent)
        .padding(.trailing, 14)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DS.ink.opacity(lit ? 0.09 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.highlighted = id }
            else if model.highlighted == id { model.highlighted = nil }
        }
        .onTapGesture { model.activate(id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.activate(id) }
    }
}

extension PanelRow where Trailing == EmptyView {
    init(id: MenuRowID, label: String, model: MenuViewModel, indent: CGFloat = 0) {
        self.init(id: id, label: label, model: model, indent: indent) { EmptyView() }
    }
}

private struct KeyCap: View {
    let glyph: String
    init(_ glyph: String) { self.glyph = glyph }
    var body: some View {
        Text(glyph)
            .font(DS.mono(11, 700))
            .foregroundColor(DS.ink)
            .frame(minWidth: 22, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(DS.paper))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.ink, lineWidth: 1.5))
    }
}

private struct ValuePill: View {
    let text: String
    let filled: Bool
    var body: some View {
        Text(text)
            .font(DS.mono(11, 700))
            .tracking(DS.tracking(0.08, 11))
            .foregroundColor(DS.ink)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(filled ? DS.ground : DS.paper))
            .overlay(Capsule().strokeBorder(DS.ink, lineWidth: 1.5))
    }
}
