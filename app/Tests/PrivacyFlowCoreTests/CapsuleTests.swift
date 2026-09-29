import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PrivacyFlowCore

/// The capsule's shape and motion.
struct CapsuleGeometryTests {
    @Test func withMinimalModeOffTheCapsuleIsAlwaysFullSize() {
        for pointing in [false, true] {
            for dictating in [false, true] {
                #expect(CapsuleGeometry.size(minimal: false, pointing: pointing, dictating: dictating) == .full)
            }
        }
    }

    /// Pointing at a dictating capsule shows the whole thing, because the
    /// reason to point at it is to read it.
    @Test func minimalModeRestsAsABeadAndTheLargestClaimWins() {
        #expect(CapsuleGeometry.size(minimal: true, pointing: false, dictating: false) == .bead)
        #expect(CapsuleGeometry.size(minimal: true, pointing: false, dictating: true) == .active)
        #expect(CapsuleGeometry.size(minimal: true, pointing: true, dictating: true) == .full)
    }

    /// The cog never moves, so the capsule never moves out from under the
    /// pointer that opened it.
    @Test func theCogStaysPutAtEverySize() {
        let button = CapsuleGeometry.buttonCentre(windowCentre: CGPoint(x: 500, y: 500))
        for size in [CapsuleGeometry.beadSize, CapsuleGeometry.activeSize, CapsuleGeometry.fullSize, CGSize(width: 150, height: 50)] {
            let rect = CapsuleGeometry.capsuleRect(button: button, size: size)
            #expect(CapsuleGeometry.cogCentre(in: rect) == button)
        }
    }

    @Test func theFullCapsuleIsCentredInItsWindow() {
        let centre = CGPoint(x: 500, y: 500)
        let rect = CapsuleGeometry.capsuleRect(button: CapsuleGeometry.buttonCentre(windowCentre: centre), size: CapsuleGeometry.fullSize)
        #expect(rect.midX == centre.x && rect.midY == centre.y)
    }

    /// The capsule is drawn at hundreds of sizes between its three, with width
    /// and height at different points of their travel, and the mark must stay
    /// inside at every one.
    @Test func theMarkStaysInsideTheCapsuleAtEverySizeOfTheAnimation() {
        for width in stride(from: CapsuleGeometry.beadSize.width, through: CapsuleGeometry.fullSize.width, by: 2) {
            for height in stride(from: CapsuleGeometry.beadSize.height, through: CapsuleGeometry.fullSize.height, by: 2) {
                let capsule = CGRect(x: 400, y: 400, width: width, height: height)
                #expect(capsule.contains(CapsuleGeometry.markRect(in: capsule)), "\(width) by \(height)")
            }
        }
    }

    @Test func theDictatingCapsuleFitsTheBarsBesideTheCog() {
        let rect = CapsuleGeometry.capsuleRect(button: CapsuleGeometry.buttonCentre(windowCentre: CGPoint(x: 500, y: 500)), size: CapsuleGeometry.activeSize)
        let mark = CapsuleGeometry.markRect(in: rect)
        let scale = rect.height / CapsuleGeometry.fullSize.height
        let cogLeft = CapsuleGeometry.cogCentre(in: rect).x - CapsuleGeometry.cogToothTip
        #expect(mark.maxX + CapsuleGeometry.markGap * scale <= cogLeft)
    }

    /// The words read on every dictation must fit whole in the real font;
    /// "Didn't catch th…" would be a defect.
    @Test func everyHealthyLabelFitsTheFullCapsuleWhole() throws {
        let fontURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/Inter-SemiBold.ttf")
        let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor])
        let font = CTFontCreateWithFontDescriptor(try #require(descriptors.first), 12, nil)
        let states: [HudState] = [.idle, .listening, .processing, .done, .copied, .noSpeech, .notUnderstood]
        for processing in ["Loading models", "Transcribing"] {
            for hud in states {
                let text = CapsuleGeometry.label(for: hud, processing: processing).text
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                #expect(width <= CapsuleGeometry.labelRoom, "\"\(text)\" is \(width) wide with \(CapsuleGeometry.labelRoom) to fit in")
            }
        }
    }
}

struct MotionTests {
    /// Opening pops slightly past its target, and neither feel is sluggish.
    @Test func growingOvershootsSlightlyAndSettlesQuickly() {
        var spring = Spring(88)
        var peak = 88.0
        var elapsed = 0.0
        var arrived = 0.0
        while spring.step(towards: 216, seconds: 1 / 60, feel: .grow) {
            peak = max(peak, spring.value)
            elapsed += 1 / 60
            if abs(spring.value - 216) > 1 { arrived = elapsed }
            #expect(elapsed < 2)
        }
        let overshoot = (peak - 216) / (216 - 88)
        #expect(overshoot > 0.01 && overshoot < 0.08)
        #expect(arrived < 0.35)
    }

    /// A capsule that undershoots the bead reads as flinching.
    @Test func shrinkingNeverPassesItsTarget() {
        var spring = Spring(216)
        while spring.step(towards: 72, seconds: 1 / 60, feel: .shrink) {
            #expect(spring.value >= 72)
        }
        #expect(spring.value == 72)
    }

    /// A quiet microphone's speech must move the bars and its room noise must not.
    @Test func quietSpeechFillsTheBarsAndRoomNoiseDoesNot() {
        var meter = VoiceMeter()
        var bars: [Float] = []
        for _ in 0..<30 { bars = meter.update(level: 0.0126, seconds: 1 / 60) }
        #expect(bars.allSatisfy { $0 == 0 })
        for _ in 0..<30 { bars = meter.update(level: 0.05, seconds: 1 / 60) }
        #expect(bars[1] > 0.4)
    }
}
