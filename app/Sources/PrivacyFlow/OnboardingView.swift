import PrivacyFlowCore
import SwiftUI

/// First-launch setup: the models, then the three permissions, each with its
/// live status and the one action that moves it forward.
struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var installer: ModelInstaller
    var close: () -> Void

    var body: some View {
        // Asked every second, because two of the three permissions are granted
        // in System Settings, where this window cannot see the switch flip.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up PrivacyFlow").font(.inter(20, weight: .semibold))
                    Text("Hold \(controller.settings.dictationShortcut.label), speak, and let go: the text appears where you are typing. Everything runs on this Mac, and nothing you say leaves it.")
                        .foregroundStyle(Theme.muted.swiftUI)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 22)

                VStack(spacing: 10) {
                    ModelsStep(installer: installer)
                    PermissionStep(
                        title: "Microphone",
                        detail: "To hear you while you hold the key. The microphone is off between dictations.",
                        done: Permissions.microphone == .granted,
                        action: microphoneAction
                    )
                    PermissionStep(
                        title: "Accessibility",
                        detail: accessibilityDetail,
                        done: Permissions.accessibility,
                        action: Permissions.accessibility ? nil : ("Open Settings", Permissions.openAccessibilitySettings)
                    )
                    PermissionStep(
                        title: "Input Monitoring",
                        detail: "To notice \(controller.settings.dictationShortcut.label) while another app is in front. Turn on PrivacyFlow in the list that opens. macOS applies this after a relaunch.",
                        done: Permissions.inputMonitoring && controller.inputMonitoringAtLaunch,
                        action: inputMonitoringAction
                    )
                }

                Spacer(minLength: 20)

                HStack {
                    Text(footnote)
                        .font(.inter(11))
                        .foregroundStyle(Theme.muted.swiftUI)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 16)
                    Button(finished ? "Done" : "Later", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.fill.swiftUI)
        .font(.inter(13))
        .foregroundStyle(Theme.label.swiftUI)
    }

    private var finished: Bool {
        installer.isInstalled && Permissions.microphone == .granted && Permissions.accessibility && Permissions.inputMonitoring && controller.inputMonitoringAtLaunch
    }

    private var footnote: String {
        finished
            ? "PrivacyFlow is ready. It lives in the menu bar and in the capsule."
            : "You can close this and come back to it from the console's Status tab."
    }

    /// A key shortcut is kept from other apps, which is a second reason to
    /// need Accessibility, and the user should know it.
    private var accessibilityDetail: String {
        let shortcut = controller.settings.dictationShortcut
        if shortcut.needsKeySwallowed {
            return "To paste the text into the app you are using, and to keep \(shortcut.label) from reaching other apps. Turn on PrivacyFlow in the list that opens."
        }
        return "To paste the text into the app you are using. Turn on PrivacyFlow in the list that opens."
    }

    private var microphoneAction: (String, () -> Void)? {
        switch Permissions.microphone {
        case .granted: nil
        case .undecided: ("Allow", { Permissions.requestMicrophone { if $0 { controller.microphoneAccessGranted() } } })
        case .denied: ("Open Settings", Permissions.openMicrophoneSettings)
        }
    }

    /// The event tap was built at launch and does not pick up a later grant,
    /// so once it is granted the next step is a relaunch.
    private var inputMonitoringAction: (String, () -> Void)? {
        if !Permissions.inputMonitoring {
            return ("Open Settings", Permissions.openInputMonitoringSettings)
        }
        if !controller.inputMonitoringAtLaunch {
            return ("Relaunch", controller.relaunch)
        }
        return nil
    }
}

/// A row with a status mark, a title, what it is for and its action.
private struct StepRow<Trailing: View>: View {
    let title: String
    let detail: String
    let done: Bool
    /// Shown as a bar under the detail while something is in progress.
    var progress: Double?
    /// Whether the detail is reporting a failure rather than describing the step.
    var detailIsProblem = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(done ? Theme.inserted.swiftUI : Theme.muted.swiftUI)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.inter(13, weight: .semibold))
                Text(detail)
                    .font(.inter(12))
                    .foregroundStyle((detailIsProblem ? Theme.errorText : Theme.muted).swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.listening.swiftUI)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill.swiftUI))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border.swiftUI))
    }
}

private struct PermissionStep: View {
    let title: String
    let detail: String
    let done: Bool
    let action: (String, () -> Void)?

    var body: some View {
        StepRow(title: title, detail: detail, done: done) {
            if let (label, perform) = action {
                Button(label, action: perform)
            }
        }
    }
}

/// The models: how much is left, how it is going, and what failed if it did.
private struct ModelsStep: View {
    @ObservedObject var installer: ModelInstaller

    var body: some View {
        StepRow(title: "Speech models", detail: detail, done: installer.isInstalled, progress: progress, detailIsProblem: failed) {
            switch installer.phase {
            case .idle: Button("Download", action: installer.install)
            case .failed: Button("Try Again", action: installer.install)
            case .downloading, .verifying, .installed: EmptyView()
            }
        }
    }

    private var failed: Bool {
        if case .failed = installer.phase { return true }
        return false
    }

    private var progress: Double? {
        guard installer.phase == .downloading || installer.phase == .verifying else { return nil }
        guard installer.totalBytes > 0 else { return 0 }
        return min(Double(installer.completedBytes) / Double(installer.totalBytes), 1)
    }

    private var detail: String {
        let total = formatBytes(installer.manifest.totalBytes)
        switch installer.phase {
        case .idle:
            return "Speech recognition, routing and rewriting, about \(total) in all. Downloaded once and checked, then used offline."
        case .downloading:
            let done = formatBytes(installer.completedBytes)
            let of = formatBytes(installer.totalBytes)
            return "Downloading \(installer.currentModel ?? "the models"): \(done) of \(of)"
        case .verifying:
            return "Checking \(installer.currentModel ?? "the models") against its published checksums"
        case .installed:
            return installer.manifest.models.map(\.title).joined(separator: ", ")
        case .failed(let reason):
            return reason
        }
    }
}
