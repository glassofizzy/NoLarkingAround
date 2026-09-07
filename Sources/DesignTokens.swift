import AppKit
import CoreText
import SwiftUI

/// Design tokens transcribed from design_handoff_takeover_reminder/README.md.
/// Palette discipline: three colours plus ink. No fourth hue, no gradient, no blur.
enum DS {
    // MARK: Colours
    static let ground = Color(hex: 0xA4E2EE)   // screen ground / blue
    static let accent = Color(hex: 0xF7B557)   // yellow, time fill
    static let paper  = Color(hex: 0xFFFCF2)   // cards, pills, wall
    static let ink    = Color(hex: 0x1E1B16)   // all borders, text, shadows
    static let muted  = Color(hex: 0x1E1B16, alpha: 0.7)

    // MARK: Metrics
    static let wallWidth: CGFloat = 162
    static let wallBorder: CGFloat = 3
    static let contentPadding = EdgeInsets(top: 40, leading: 56, bottom: 44, trailing: 56)

    // MARK: Fonts

    /// CSS letter-spacing is em-relative; SwiftUI tracking is in points.
    static func tracking(_ em: CGFloat, _ size: CGFloat) -> CGFloat { em * size }

    static func display(_ size: CGFloat, _ weight: CGFloat) -> Font {
        FontLoader.shared.font(family: .display, size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: CGFloat) -> Font {
        FontLoader.shared.font(family: .mono, size: size, weight: weight)
    }
}

// MARK: - Font loading

/// Registers the bundled OFL variable fonts and instantiates specific weights via
/// the CoreText `wght` variation axis. Verified ranges: Schibsted Grotesk 400–900,
/// JetBrains Mono 100–800.
final class FontLoader {
    static let shared = FontLoader()

    enum Family {
        case display, mono
        /// PostScript name of the variable font's default instance.
        var postScriptName: String {
            switch self {
            case .display: return "SchibstedGrotesk-Regular"
            case .mono:    return "JetBrainsMono-Regular"
            }
        }
        var fileName: String {
            switch self {
            case .display: return "SchibstedGrotesk[wght].ttf"
            case .mono:    return "JetBrainsMono[wght].ttf"
            }
        }
    }

    private static let wghtAxis: UInt32 = 0x77676874  // 'wght'
    private var registered = false
    private var cache: [String: Font] = [:]
    private(set) var didFallBack = false

    /// Registers fonts from the app bundle, or from Resources/Fonts next to the
    /// binary when running unbundled during development.
    func register() {
        guard !registered else { return }
        registered = true

        for family in [Family.display, Family.mono] {
            var url = Bundle.main.url(forResource: family.fileName, withExtension: nil)
            if url == nil {
                url = Bundle.main.resourceURL?
                    .appendingPathComponent("Fonts/\(family.fileName)")
            }
            if url == nil || !FileManager.default.fileExists(atPath: url!.path) {
                // Dev path: ../Resources/Fonts relative to the executable.
                let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
                    .resolvingSymlinksInPath().deletingLastPathComponent()
                url = exeDir.appendingPathComponent("Resources/Fonts/\(family.fileName)")
            }
            if let url, FileManager.default.fileExists(atPath: url.path) {
                // Failure here is not necessarily a problem: inside an .app bundle
                // ATSApplicationFontsPath has already registered the file, and a
                // second registration reports false.
                var err: Unmanaged<CFError>?
                _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
            }
            // What actually matters is whether the face resolves.
            if NSFont(name: family.postScriptName, size: 12) == nil {
                didFallBack = true
            }
        }
    }

    func font(family: Family, size: CGFloat, weight: CGFloat) -> Font {
        register()
        let key = "\(family.postScriptName)-\(size)-\(weight)"
        if let hit = cache[key] { return hit }

        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: family.postScriptName,
            NSFontDescriptor.AttributeName(rawValue: "NSCTFontVariationAttribute"):
                [FontLoader.wghtAxis: weight],
        ])

        let result: Font
        if let nsFont = NSFont(descriptor: descriptor, size: size) {
            result = Font(nsFont)
        } else {
            // Never crash over a font: fall back to the system face at the
            // nearest weight so the takeover still appears.
            didFallBack = true
            result = .system(size: size, weight: FontLoader.systemWeight(weight),
                             design: family == .mono ? .monospaced : .default)
        }
        cache[key] = result
        return result
    }

    /// The face's natural line height, used to emulate CSS line-height.
    func naturalLineHeight(family: Family, size: CGFloat, weight: CGFloat) -> CGFloat {
        guard let f = nsFont(family: family, size: size, weight: weight) else {
            return size * 1.2
        }
        return f.ascender - f.descender + f.leading
    }

    func nsFont(family: Family, size: CGFloat, weight: CGFloat) -> NSFont? {
        register()
        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: family.postScriptName,
            NSFontDescriptor.AttributeName(rawValue: "NSCTFontVariationAttribute"):
                [FontLoader.wghtAxis: weight],
        ])
        return NSFont(descriptor: descriptor, size: size)
    }

    private static func systemWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<450:  return .regular
        case ..<550:  return .medium
        case ..<650:  return .semibold
        case ..<750:  return .bold
        case ..<850:  return .heavy
        default:      return .black
        }
    }
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
