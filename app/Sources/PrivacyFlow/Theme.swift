import AppKit
import CoreText
import SwiftUI

/// The app's colours and type. The surfaces are a neutral near-black so the
/// state accents are the only colour in the frame, and each accent has to earn
/// its place.
enum Theme {
    static let fill = rgb(10, 10, 10)
    /// History cards sit on the fill and read as raised from it, one step lighter.
    static let cardFill = rgb(20, 20, 20)
    /// Close to the fill on purpose: with real contrast the edge reads as a
    /// ring drawn around the capsule rather than its edge.
    static let border = rgb(26, 26, 26)

    static let label = rgb(245, 245, 245)
    static let muted = rgb(154, 154, 154)
    static let iconTint = rgb(176, 176, 176)
    static let iconHover = rgb(35, 35, 35)

    static let idle = rgb(110, 110, 110)
    static let listening = rgb(95, 211, 155)
    static let transcribing = rgb(110, 142, 245)
    static let inserted = rgb(134, 217, 143)
    static let error = rgb(224, 112, 112)
    static let errorText = rgb(235, 179, 179)
    /// Amber rather than red: the quiet warning arrives while the dictation can
    /// still be saved, so it must not read as a failure that already happened.
    static let warningText = rgb(238, 205, 156)

    static let borderListening = rgb(42, 95, 72)
    static let borderTranscribing = rgb(51, 64, 110)
    static let borderInserted = rgb(58, 95, 63)
    static let errorBorder = rgb(92, 46, 46)
    static let warningBorder = rgb(99, 76, 38)

    /// The one thing allowed to be brighter than its surroundings, because its
    /// whole job is to be noticed after the fact.
    static let iconAlert = rgb(224, 138, 138)
    static let unreadDot = rgb(246, 128, 128)

    /// A bar that is present but dead, for a microphone that cannot be opened.
    static let markDead = rgb(74, 58, 58)
    /// A bar that was never lit, for the half of the mark that dropped out.
    static let markUnlit = rgb(107, 71, 71)

    static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// The capsule's state label.
    static func labelFont() -> NSFont { inter("Inter-SemiBold", 12) }
    /// Failure headlines are quieter than the healthy labels they replace.
    static func errorFont() -> NSFont { inter("Inter-Regular", 11.5) }
    static func bodyFont(_ size: CGFloat = 13) -> NSFont { inter("Inter-Regular", size) }
    static func strongFont(_ size: CGFloat = 13) -> NSFont { inter("Inter-SemiBold", size) }

    private static func inter(_ name: String, _ size: CGFloat) -> NSFont {
        guard let font = NSFont(name: name, size: size) else {
            // The fonts are registered from the bundle before any window
            // exists, and registration failing stops launch, so this is a
            // programming error rather than a runtime condition.
            fatalError("\(name) is not registered")
        }
        return font
    }

    /// Register Inter from the app bundle. Throws naming the file, because a
    /// bundle missing its fonts is a broken build.
    static func registerFonts() throws {
        for name in ["Inter-Regular", "Inter-SemiBold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                throw LaunchProblem("\(name).ttf is missing from the app bundle")
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
                throw LaunchProblem("Could not register \(name).ttf: \(reason)")
            }
        }
    }
}

extension NSColor {
    var swiftUI: Color { Color(nsColor: self) }
}

extension Font {
    static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "Inter-Regular" : "Inter-SemiBold", size: size)
    }
}

/// Something that stops PrivacyFlow from starting at all.
struct LaunchProblem: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
