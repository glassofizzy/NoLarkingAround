import AppKit
import SwiftUI

enum TakeoverAction {
    case join(URL)
    case dismiss
    case snoozeUntilStart
}

/// The desktop takeover, recreated natively from
/// design_handoff_takeover_reminder/Takeover Reminder.dc.html.
struct TakeoverView: View {
    let alert: MeetingAlert
    let leadMinutes: Int
    let onAction: (TakeoverAction) -> Void

    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            drainingWall
            content
        }
        .background(DS.ground)
        .foregroundStyle(DS.ink)
        .clipped()
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Draining wall
    //
    // Passive time gauge: fills upward with yellow as the start approaches, so the
    // remaining time is legible without reading a number.

    private var drainingWall: some View {
        GeometryReader { geo in
            let pct = alert.progressPercent(now: now, leadMinutes: leadMinutes)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Rectangle().fill(DS.ink).frame(height: DS.wallBorder)
                    Rectangle().fill(DS.accent)
                }
                .frame(height: max(0, geo.size.height * pct / 100))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.paper)
            .animation(.linear(duration: 1), value: pct)
        }
        .frame(width: DS.wallWidth)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.ink).frame(width: DS.wallBorder)
        }
    }

    // MARK: - Content column

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 40)
            details
            Spacer(minLength: 40)
            actionRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DS.contentPadding)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("REMINDER · \(Self.dayLabel(now))")
                .font(DS.mono(13, 500))
                .tracking(DS.tracking(0.14, 13))
            Spacer(minLength: 24)
            Text(Self.clock(now))
                .font(DS.mono(13, 700))
                .tracking(DS.tracking(0.08, 13))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var details: some View {
        // Reference: flex column with gap:4px. The gap applies *in addition* to each
        // child's margin-top, e.g. room row y=436 = title end 410 + 4 gap + 22 margin.
        VStack(alignment: .leading, spacing: 4) {
            countdown
            title
            roomRow
            metaLine
            attendeeRow
            if let clash = alert.clashLabel { clashSlab(clash) }
        }
    }

    private var countdown: some View {
        let c = alert.countdown(now: now)
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(c.value)
                .font(DS.display(208, 800))
                .tracking(DS.tracking(-0.055, 208))
                .monospacedDigit()
            Text(c.unit)
                .font(DS.display(64, 800))
                .tracking(DS.tracking(-0.02, 64))
                .padding(.leading, 14)
        }
        .tightLineHeight(family: .display, size: 208, weight: 800, lineHeight: 0.8)
        .fixedSize()
    }

    private var title: some View {
        Text(alert.title)
            .font(DS.display(76, 800))
            .tracking(DS.tracking(-0.04, 76))
            .lineLimit(2)
            .tightLineHeight(family: .display, size: 76, weight: 800, lineHeight: 0.95)
            .padding(.top, 18)
    }

    @ViewBuilder
    private var roomRow: some View {
        if let slab = alert.roomSlab {
            HStack(spacing: 16) {
                // Static element: flat by design. Shadows mean clickable.
                Text(slab.uppercased())
                    .font(DS.mono(20, 700))
                    .tracking(DS.tracking(0.06, 20))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .padding(3)   // CSS border adds to the box; strokeBorder does not
                    .background(
                        RoundedRectangle(cornerRadius: 18).fill(DS.accent)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18).strokeBorder(DS.ink, lineWidth: 3)
                    )
                if let floor = alert.floorLabel {
                    Text(floor.uppercased())
                        .font(DS.mono(14, 500))
                        .tracking(DS.tracking(0.12, 14))
                }
            }
            .padding(.top, 22)
        }
    }

    private var metaLine: some View {
        Text("\(alert.timeRange) · \(alert.durationLabel.uppercased()) · \(alert.attendanceLabel.uppercased())")
            .font(DS.mono(14, 500))
            .tracking(DS.tracking(0.12, 14))
            .foregroundStyle(DS.muted)
            .padding(.top, 16)
    }

    private var attendeeRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("WITH")
                .font(DS.mono(13, 700))
                .tracking(DS.tracking(0.14, 13))

            HStack(spacing: 10) {
                hostPill
                ForEach(alert.participantNames, id: \.self) { name in
                    Text(name)
                        .font(DS.display(17, 700))
                        .tracking(DS.tracking(-0.01, 17))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .padding(2)
                        .background(Capsule().fill(DS.paper))
                        .overlay(Capsule().strokeBorder(DS.ink, lineWidth: 2))
                }
                if let more = alert.moreLabel {
                    Text(more.uppercased())
                        .font(DS.mono(13, 700))
                        .tracking(DS.tracking(0.08, 13))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .padding(2)
                        .overlay(
                            Capsule().strokeBorder(
                                DS.ink,
                                style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                            )
                        )
                }
            }
        }
        .padding(.top, 24)
    }

    private var hostPill: some View {
        HStack(spacing: 10) {
            Text(alert.hostName)
                .font(DS.display(17, 700))
                .tracking(DS.tracking(-0.01, 17))
            Text(alert.hostTag)
                .font(DS.mono(10, 700))
                .tracking(DS.tracking(0.14, 10))
                .foregroundStyle(DS.paper)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.ink))
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .padding(2.5)
        .background(Capsule().fill(DS.paper))
        .overlay(Capsule().strokeBorder(DS.ink, lineWidth: 2.5))
    }

    private func clashSlab(_ label: String) -> some View {
        HStack(spacing: 16) {
            Text("CLASHES WITH")
                .font(DS.mono(12.5, 700))
                .tracking(DS.tracking(0.14, 12.5))
                .fixedSize()
            Text(label)
                .font(DS.display(19, 700))
                .tracking(DS.tracking(-0.01, 19))
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 18).fill(DS.accent))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(DS.ink, lineWidth: 3))
        .padding(.top, 24)
    }

    // MARK: - Action row
    //
    // Handoff had two snoozes and no dismiss. Per instruction the 1-min snooze is
    // replaced by Dismiss, and the SNOOZE label moved to sit with the one real
    // snooze it now describes.

    private var actionRow: some View {
        HStack(alignment: .center, spacing: 32) {
            if let url = alert.joinURL {
                NeoButton(
                    title: "Join call",
                    font: DS.display(21, 700),
                    tracking: DS.tracking(-0.01, 21),
                    paddingH: 40, paddingV: 18,
                    radius: 16, border: 3,
                    shadow: 5, hoverShadow: 7, activeShadow: 2
                ) { onAction(.join(url)) }
            }

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 18) {
                NeoButton(
                    title: "DISMISS",
                    font: DS.mono(15, 700),
                    tracking: DS.tracking(0.1, 15),
                    paddingH: 26, paddingV: 15,
                    radius: 16, border: 3,
                    shadow: 4, hoverShadow: 6, activeShadow: 1
                ) { onAction(.dismiss) }

                Text("SNOOZE")
                    .font(DS.mono(13, 700))
                    .tracking(DS.tracking(0.14, 13))

                NeoButton(
                    title: "UNTIL IT STARTS",
                    font: DS.mono(15, 700),
                    tracking: DS.tracking(0.1, 15),
                    paddingH: 26, paddingV: 15,
                    radius: 16, border: 3,
                    shadow: 4, hoverShadow: 6, activeShadow: 1
                ) { onAction(.snoozeUntilStart) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Formatting

    static func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        f.locale = Locale(identifier: "en_GB")
        // Intl en-GB (which the prototype used) renders September as "Sept";
        // DateFormatter's shortMonthSymbols give "Sep".
        f.shortMonthSymbols = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                               "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]
        return f.string(from: date).uppercased()
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: date)
    }
}

// MARK: - Neobrutalist button
//
// SwiftUI's .shadow blurs, which the handoff forbids. A hard offset shadow is an
// ink rectangle drawn behind the fill.

struct NeoButton: View {
    let title: String
    let font: Font
    let tracking: CGFloat
    let paddingH: CGFloat
    let paddingV: CGFloat
    let radius: CGFloat
    let border: CGFloat
    let shadow: CGFloat
    let hoverShadow: CGFloat
    let activeShadow: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(DS.ink)
                .padding(.horizontal, paddingH)
                .padding(.vertical, paddingV)
                .padding(border)
        }
        .buttonStyle(
            NeoButtonStyle(
                radius: radius, border: border,
                shadow: shadow, hoverShadow: hoverShadow, activeShadow: activeShadow
            )
        )
    }
}

struct NeoButtonStyle: ButtonStyle {
    let radius: CGFloat
    let border: CGFloat
    let shadow: CGFloat
    let hoverShadow: CGFloat
    let activeShadow: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        // @State only tracks changes inside a real View, not in makeBody itself.
        NeoButtonSurface(
            configuration: configuration,
            radius: radius, border: border,
            shadow: shadow, hoverShadow: hoverShadow, activeShadow: activeShadow
        )
    }
}

private struct NeoButtonSurface: View {
    let configuration: ButtonStyle.Configuration
    let radius: CGFloat
    let border: CGFloat
    let shadow: CGFloat
    let hoverShadow: CGFloat
    let activeShadow: CGFloat

    @State private var hovering = false

    var body: some View {
        // normal: offset 0, shadow 5 · hover: offset -1, shadow 7 · active: offset +2, shadow 2
        let pressed = configuration.isPressed
        let offset: CGFloat = pressed ? 2 : (hovering ? -1 : 0)
        let depth: CGFloat = pressed ? activeShadow : (hovering ? hoverShadow : shadow)

        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(DS.ink)
                .offset(x: depth, y: depth)
            RoundedRectangle(cornerRadius: radius).fill(DS.paper)
            RoundedRectangle(cornerRadius: radius).strokeBorder(DS.ink, lineWidth: border)
            configuration.label
        }
        .fixedSize()
        .offset(x: offset, y: offset)
        .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.14), value: pressed)
        .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tight line height
//
// CSS line-height compresses the line box; SwiftUI has no equivalent, so the
// difference between the font's natural line height and the target is removed
// with symmetric negative padding.

private struct TightLineHeight: ViewModifier {
    let family: FontLoader.Family
    let size: CGFloat
    let weight: CGFloat
    let lineHeight: CGFloat

    func body(content: Content) -> some View {
        let natural = FontLoader.shared.naturalLineHeight(
            family: family, size: size, weight: weight)
        let target = size * lineHeight
        let trim = max(0, (natural - target) / 2)
        return content.padding(.vertical, -trim)
    }
}

extension View {
    func tightLineHeight(
        family: FontLoader.Family, size: CGFloat, weight: CGFloat, lineHeight: CGFloat
    ) -> some View {
        modifier(TightLineHeight(
            family: family, size: size, weight: weight, lineHeight: lineHeight))
    }
}
