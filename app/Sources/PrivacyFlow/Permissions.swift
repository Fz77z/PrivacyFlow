import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// The three privacy permissions PrivacyFlow needs, asked live.
///
/// Only the microphone prompts reliably. Accessibility and Input Monitoring
/// have to be turned on by hand in System Settings: a listen-only event tap
/// without Input Monitoring gets a reduced event stream rather than a prompt,
/// so the app looks like it works rather than like it is blocked.
enum Permissions {
    enum Microphone {
        case granted
        case denied
        case undecided
    }

    static var microphone: Microphone {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undecided
        default: .denied
        }
    }

    /// Whether PrivacyFlow may post the keystrokes that paste.
    static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Whether PrivacyFlow's event tap can see the dictation key while another app
    /// is focused.
    static var inputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Add PrivacyFlow to the Accessibility list and open it, so the user only
    /// has to turn the switch on.
    static func openAccessibilitySettings() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        open("Privacy_Accessibility")
    }

    /// Add PrivacyFlow to the Input Monitoring list and open it.
    static func openInputMonitoringSettings() {
        _ = CGRequestListenEventAccess()
        open("Privacy_ListenEvent")
    }

    static func openMicrophoneSettings() {
        open("Privacy_Microphone")
    }

    private static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
