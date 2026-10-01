import AppKit
import SwiftUI

/// The menu-bar button: a small capsule in the takeover palette. The menu bar is
/// only ~22pt tall, so this is the mockup's pill scaled down, minus the shadow.
struct StatusPillView: View {
    let state: PillState

    static let height: CGFloat = 18

    var body: some View {
        HStack(spacing: 5) {
            if let badge = state.badge {
                Text(badge)
                    .font(DS.mono(10.5, 700))
                    .foregroundColor(DS.paper)
                    .padding(.horizontal, 5)
                    .frame(height: 13)
                    .background(Capsule().fill(DS.ink))
            }
            Text(state.text)
                .font(DS.display(12.5, 650))
                .foregroundColor(DS.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, state.badge == nil ? 9 : 3)
        .padding(.trailing, 9)
        .frame(height: Self.height)
        .background(Capsule().fill(state.tone == .accent ? DS.accent : DS.paper))
        .overlay(Capsule().strokeBorder(DS.ink, lineWidth: 1))
    }
}

enum StatusPillRenderer {
    /// Renders the pill as a full-colour (non-template) image for the status
    /// button. Nil on macOS 12, where the caller falls back to a text title.
    static func image(for state: PillState, scale: CGFloat) -> NSImage? {
        guard #available(macOS 13.0, *) else { return nil }
        return MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: StatusPillView(state: state))
            renderer.scale = scale
            guard let cg = renderer.cgImage else { return nil }
            let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale,
                                                          height: CGFloat(cg.height) / scale))
            image.isTemplate = false
            return image
        }
    }
}
