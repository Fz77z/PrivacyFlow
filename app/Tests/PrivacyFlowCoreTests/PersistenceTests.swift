import CoreGraphics
import Foundation
import Testing
@testable import PrivacyFlowCore

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("privacyflow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Reading and writing what the user chose.
struct SettingsTests {
    /// A first run must not start with a red dot.
    @Test func aMissingFileIsAFirstRunNotAProblem() throws {
        let loaded = SettingsFile.load(from: try scratchDirectory())
        #expect(loaded.settings == Settings())
        #expect(loaded.problem == nil)
    }

    /// A file that exists and cannot be used must not pass silently as a first
    /// run, and the report names the file the user has to fix.
    @Test func aMalformedFileGivesDefaultsAndSaysSo() throws {
        let directory = try scratchDirectory()
        try Data("{ this is not json".utf8).write(to: SettingsFile.url(in: directory))
        let loaded = SettingsFile.load(from: directory)
        #expect(loaded.settings == Settings())
        #expect(loaded.problem?.contains("settings.json") == true)
    }

    /// The file the Rust app wrote: cues must stay on, the microphone must
    /// carry over, and its retired retention field must not break the load.
    @Test func aFileFromTheEarlierAppStillLoads() throws {
        let directory = try scratchDirectory()
        try Data(#"{"minimal_mode": true, "preferred_microphone": "fifine Microphone", "retain_audio": true}"#.utf8)
            .write(to: SettingsFile.url(in: directory))
        let loaded = SettingsFile.load(from: directory)
        #expect(loaded.problem == nil)
        #expect(loaded.settings == Settings(minimalMode: true, soundCues: true, preferredMicrophone: "fifine Microphone"))
    }

    @Test func whatIsSavedIsWhatLoadsBack() throws {
        let directory = try scratchDirectory()
        let settings = Settings(minimalMode: true, soundCues: false, preferredMicrophone: "MacBook Pro Microphone")
        #expect(SettingsFile.save(settings, to: directory) == nil)
        #expect(SettingsFile.load(from: directory).settings == settings)
    }

    /// A write that cannot happen comes back as a value, because a ticked box
    /// that did not save is the interface telling the user something untrue.
    @Test func aWriteThatCannotHappenIsReturned() throws {
        let missing = try scratchDirectory().appendingPathComponent("no-such-directory")
        #expect(SettingsFile.save(Settings(), to: missing) != nil)
    }
}

/// Remembering and restoring where the capsule sits.
struct WindowPositionTests {
    let laptop = WorkArea(x: 0, y: 25, width: 1512, height: 907)
    let leftOfLaptop = WorkArea(x: -1920, y: 0, width: 1920, height: 1080)

    /// A capsule restored onto an unplugged display is an app nobody can reach.
    @Test func aCentreOnADisplayThatIsGoneIsRejected() {
        let onExternal = Centre(x: -1200, y: 400)
        #expect(WindowPosition.isReachable(onExternal, areas: [laptop, leftOfLaptop]))
        #expect(!WindowPosition.isReachable(onExternal, areas: [laptop]))
        #expect(!WindowPosition.isReachable(Centre(x: 600, y: 800), areas: []), "unknown displays restore nothing")
    }

    @Test func growingNearAnEdgeStaysOnScreen() {
        let nearTheEdge = Centre(x: 1450, y: 500)
        #expect(WindowPosition.place(nearTheEdge, size: CapsuleGeometry.beadSize, areas: [laptop]).x == 1434)
        #expect(WindowPosition.place(nearTheEdge, size: CapsuleGeometry.fullSize, areas: [laptop]).x == 1296)
    }

    @Test func clampingUsesTheDisplayTheCapsuleIsOn() {
        let onExternal = Centre(x: -1000, y: 500)
        #expect(WindowPosition.place(onExternal, size: CapsuleGeometry.fullSize, areas: [laptop, leftOfLaptop]).x == -1108)
    }

    @Test func aSavedCentreRoundTrips() throws {
        let directory = try scratchDirectory()
        #expect(WindowPosition.save(Centre(x: 700, y: 500), to: directory) == nil)
        #expect(WindowPosition.load(from: directory, areas: [laptop]) == Centre(x: 700, y: 500))
    }

    @Test func theToastSitsAboveTheCapsuleUnlessThereIsNoRoom() {
        let display = [WorkArea(x: 0, y: 0, width: 2000, height: 1000)]
        let toast = CGSize(width: 320, height: 90)
        let above = ToastPlacement.place(capsule: Centre(x: 1000, y: 500), capsuleSize: CapsuleGeometry.fullSize, toast: toast, areas: display)
        #expect(above.x == 840 && above.y == 370)
        let below = ToastPlacement.place(capsule: Centre(x: 1000, y: 40), capsuleSize: CapsuleGeometry.fullSize, toast: toast, areas: display)
        #expect(below.y == 80)
    }
}

/// Which microphone to record from, as preferences and devices change.
struct MicrophoneBindingTests {
    /// The reason the preference exists: AirPods becoming the system input
    /// must not pull a preferred microphone away.
    @Test func aPreferredMicrophoneIgnoresTheSystemInputChanging() {
        let opened = MicrophoneBinding(preferred: "MacBook Pro Microphone", route: .preferred, deviceName: "MacBook Pro Microphone")
        #expect(opened.isCurrent(preferred: "MacBook Pro Microphone", systemInputName: { "AirPods Pro" }, devicesNamed: { _ in 1 }))
    }

    @Test func aStandInGivesWayWhenThePreferredMicrophoneReturns() {
        let opened = MicrophoneBinding(preferred: "MacBook Pro Microphone", route: .preferredMissing(devicesNamedPreferred: 0), deviceName: "AirPods Pro")
        #expect(!opened.isCurrent(preferred: "MacBook Pro Microphone", systemInputName: { "AirPods Pro" }, devicesNamed: { _ in 1 }))
        #expect(opened.isCurrent(preferred: "MacBook Pro Microphone", systemInputName: { "AirPods Pro" }, devicesNamed: { _ in 0 }))
    }

    @Test func aStandInFollowsTheSystemInput() {
        let opened = MicrophoneBinding(preferred: "MacBook Pro Microphone", route: .preferredMissing(devicesNamedPreferred: 0), deviceName: "AirPods Pro")
        #expect(!opened.isCurrent(preferred: "MacBook Pro Microphone", systemInputName: { "fifine Microphone" }, devicesNamed: { _ in 0 }))
    }

    @Test func withoutAPreferenceTheSystemInputIsFollowed() {
        let opened = MicrophoneBinding(preferred: nil, route: .systemDefault, deviceName: "MacBook Pro Microphone")
        #expect(opened.isCurrent(preferred: nil, systemInputName: { "MacBook Pro Microphone" }, devicesNamed: { _ in 0 }))
        #expect(!opened.isCurrent(preferred: nil, systemInputName: { "AirPods Pro" }, devicesNamed: { _ in 0 }))
    }

    @Test func changingThePreferenceRetiresTheOpenMicrophone() {
        let opened = MicrophoneBinding(preferred: nil, route: .systemDefault, deviceName: "AirPods Pro")
        #expect(!opened.isCurrent(preferred: "MacBook Pro Microphone", systemInputName: { "AirPods Pro" }, devicesNamed: { _ in 1 }))
    }
}
