import PrivacyFlowCore
import SwiftUI

/// Which tab of the console is showing. Activity is first because the console
/// is opened most often to see what just happened.
enum ConsoleTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case settings = "Settings"
    case status = "Status"

    var id: String { rawValue }
}

/// The console: a conventional window that never blocks dictation.
struct ConsoleView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var installer: ModelInstaller
    @State private var tab: ConsoleTab
    var openSetup: () -> Void

    init(controller: AppController, installer: ModelInstaller, initialTab: ConsoleTab = .activity, openSetup: @escaping () -> Void) {
        self.controller = controller
        self.installer = installer
        _tab = State(initialValue: initialTab)
        self.openSetup = openSetup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(ConsoleTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
            Divider().overlay(Theme.border.swiftUI)
            switch tab {
            case .activity: ActivityTab(history: controller.state.history)
            case .settings: SettingsTab(controller: controller)
            case .status: StatusTab(controller: controller, installer: installer, openSetup: openSetup)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.fill.swiftUI)
        .font(.inter(13))
        .foregroundStyle(Theme.label.swiftUI)
    }
}

// MARK: Activity

/// The history, newest first. Each card leads with what the user said,
/// because that is what they came to find; how it got there is one click away.
private struct ActivityTab: View {
    let history: [DictationRecord]

    var body: some View {
        if history.isEmpty {
            Text("Nothing dictated yet.")
                .foregroundStyle(Theme.muted.swiftUI)
                .padding(20)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(history) { HistoryCard(record: $0) }
                }
                .padding(20)
            }
        }
    }
}

private struct HistoryCard: View {
    let record: DictationRecord
    @State private var expanded = false
    /// What the Copy button last did, shown beside it.
    @State private var copyOutcome: String?

    /// The words this dictation produced: the finished text, or what was heard.
    private var words: String {
        record.output.isEmpty ? record.transcript : record.output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.timestamp, format: .dateTime.hour().minute())
                    .font(.inter(11))
                    .foregroundStyle(Theme.muted.swiftUI)
                Spacer()
                // The toast that offered ⌘V is gone in seconds, and a later
                // dictation may have replaced the clipboard since, so the
                // words can always be copied again from here.
                if record.note == nil && !words.isEmpty {
                    if let copyOutcome {
                        Text(copyOutcome).font(.inter(11)).foregroundStyle(Theme.muted.swiftUI)
                    }
                    Button("Copy", action: copy)
                        .buttonStyle(.borderless)
                        .font(.inter(11, weight: .semibold))
                        .foregroundStyle(Theme.muted.swiftUI)
                }
            }
            // A dictation that was heard and not understood has nothing to show
            // but the remark, so the card is that remark.
            if let note = record.note {
                Text(note).foregroundStyle(Theme.muted.swiftUI)
            } else {
                if !words.isEmpty {
                    Text(words).font(.inter(14.5)).textSelection(.enabled)
                }
                // The capsule's "Copied" and its toast are gone in seconds, so
                // the durable record carries the reason.
                if let why = whyCopied {
                    Text(why).foregroundStyle(Theme.muted.swiftUI)
                }
                if let failure = record.failure {
                    Text(failure.detail).foregroundStyle(Theme.errorText.swiftUI).textSelection(.enabled)
                }
                // A failure outside any dictation, such as the worker
                // stopping, has nothing to break down.
                if hasDetails {
                    DisclosureGroup(isExpanded: $expanded) {
                        details.padding(.top, 6)
                    } label: {
                        Text("Details").font(.inter(11)).foregroundStyle(Theme.muted.swiftUI)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill.swiftUI))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border.swiftUI))
    }

    private var hasDetails: Bool {
        !record.transcript.isEmpty || record.route != nil || !record.output.isEmpty || record.timings != Timings()
    }

    private func copy() {
        do {
            try Inserter.copy(words)
            copyOutcome = "Copied"
        } catch {
            copyOutcome = "Could not copy: \(error)"
        }
    }

    private var whyCopied: String? {
        switch record.insertion {
        case .copiedOnly: "Copied to the clipboard, not pasted: the destination app was no longer frontmost."
        case .copiedNoField: "Copied to the clipboard, not pasted: the destination app had no text field focused to receive it."
        case .pasted, nil: nil
        }
    }

    /// How the dictation was produced, for diagnosing, so kept out of the way.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                DetailRow(label: "Heard", value: record.transcript.isEmpty ? "—" : record.transcript)
                DetailRow(label: "Route", value: record.route?.rawValue ?? "—")
                DetailRow(label: "Output", value: record.output.isEmpty ? "—" : record.output)
            }
            Text(timings)
                .font(.inter(11))
                .foregroundStyle(Theme.muted.swiftUI)
                .textSelection(.enabled)
        }
    }

    /// A stage the dictation never reached reads as a dash, not a zero that
    /// claims it was free.
    private var timings: String {
        let t = record.timings
        func ms(_ value: Int?) -> String { value.map(String.init) ?? "—" }
        return "audio \(ms(t.audioMs)) · finalize \(ms(t.captureFinalizeMs)) · queue \(ms(t.queueMs)) · ASR \(ms(t.asrMs)) · router \(ms(t.routerMs)) · S1 \(ms(t.processingMs)) · insert \(ms(t.insertMs)) · total \(ms(t.totalMs)) ms"
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label).font(.inter(11, weight: .semibold)).foregroundStyle(Theme.muted.swiftUI)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: Settings

private struct SettingsTab: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let problem = controller.settingsProblem {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your settings could not be read").font(.inter(13, weight: .semibold))
                        Text(problem).foregroundStyle(Theme.errorText.swiftUI).textSelection(.enabled)
                        Text("PrivacyFlow started on its defaults. The file is left as it is until you change a setting here.")
                            .font(.inter(11)).foregroundStyle(Theme.muted.swiftUI)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardFill.swiftUI))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.errorBorder.swiftUI))
                }

                DictationKeyRow(controller: controller)

                SettingRow(
                    title: "Minimal mode",
                    caption: "Fold the capsule into its settings button when it is not in use. It opens out of the button while you dictate, and when you point at the button.",
                    isOn: Binding(get: { controller.settings.minimalMode }, set: controller.setMinimalMode)
                )

                VStack(alignment: .leading, spacing: 6) {
                    SettingRow(
                        title: "Sound cues",
                        caption: "Play a short, quiet tone when a dictation starts and when it ends. It rises on the press and falls on the release.",
                        isOn: Binding(get: { controller.settings.soundCues }, set: controller.setSoundCues)
                    )
                    if let problem = controller.cueProblem {
                        Text("Cannot play: \(problem)").foregroundStyle(Theme.errorText.swiftUI)
                    }
                }

                MicrophoneChoice(controller: controller)

                if let error = controller.settingsWriteError {
                    Text("Not saved: \(error)").foregroundStyle(Theme.errorText.swiftUI)
                }

                Divider().overlay(Theme.border.swiftUI).padding(.top, 10)
                // Rare and final, so it sits at the foot rather than in reach.
                Button("Quit PrivacyFlow", action: controller.quit)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: $isOn).toggleStyle(.checkbox)
            Text(caption)
                .font(.inter(11))
                .foregroundStyle(Theme.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }
}

/// The shortcut held to dictate: what it is, a way to record a new one, and
/// a way back to the default. A new one takes effect at once.
private struct DictationKeyRow: View {
    @ObservedObject var controller: AppController
    @StateObject private var recorder: ShortcutRecorder

    init(controller: AppController) {
        self.controller = controller
        _recorder = StateObject(wrappedValue: ShortcutRecorder(controller: controller))
    }

    private var shortcut: Shortcut { controller.settings.dictationShortcut }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Dictation key")
                Text(recorder.state == .recording ? "Press the new shortcut…" : shortcut.label)
                    .font(.inter(13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle((recorder.state == .recording ? Theme.listening : Theme.label).swiftUI)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 180, minHeight: 24, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardFill.swiftUI))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder((recorder.state == .recording ? Theme.borderListening : Theme.border).swiftUI))
                    // The field grows to hold a long shortcut on one line.
                    .fixedSize()
                if recorder.state == .recording {
                    Button("Cancel", action: recorder.cancel)
                } else {
                    Button("Record…", action: recorder.start)
                }
                if shortcut != .rightOption && recorder.state != .recording {
                    Button("Use Right Option") { controller.setShortcut(.rightOption) }
                }
            }
            Text(recorder.state == .recording
                 ? "Press a modifier on its own and let go, or a key with any modifiers. Escape cancels."
                 : "Hold it to dictate and let go to finish. A modifier on its own, a function key, or a key with Command or Control.")
                .font(.inter(11))
                .foregroundStyle(Theme.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            if case .refused(let reason) = recorder.state {
                Text("Not used: \(reason)").foregroundStyle(Theme.errorText.swiftUI).fixedSize(horizontal: false, vertical: true)
            }
            if recorder.state != .recording, case .warned(let reason) = shortcut.assessment {
                Text(reason).foregroundStyle(Theme.warningText.swiftUI).fixedSize(horizontal: false, vertical: true)
            }
            if recorder.state != .recording, shortcut.needsKeySwallowed {
                Text("PrivacyFlow keeps \(shortcut.label) from reaching other apps while it runs, which needs Accessibility.")
                    .font(.inter(11))
                    .foregroundStyle(Theme.muted.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = controller.hotkeyProblem, recorder.state != .recording {
                Text(problem).foregroundStyle(Theme.errorText.swiftUI).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear(perform: recorder.cancel)
    }
}

/// The microphone to prefer. A choice takes effect at once, and a saved choice
/// that is not connected stays listed so it does not vanish from the one place
/// it can be seen.
private struct MicrophoneChoice: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Microphone")
                Picker("", selection: Binding(get: { controller.settings.preferredMicrophone }, set: controller.setPreferredMicrophone)) {
                    Text("System default").tag(String?.none)
                    Divider()
                    ForEach(controller.microphoneNames, id: \.self) { Text($0).tag(String?.some($0)) }
                    if let preferred = controller.settings.preferredMicrophone, !controller.microphoneNames.contains(preferred) {
                        Text("\(preferred) (not connected)").tag(String?.some(preferred))
                    }
                }
                .labelsHidden()
                .frame(width: 280)
            }
            Text("Record from this microphone whenever it is connected, even when macOS switches its input to a headset. When it is not connected, the system input is used.")
                .font(.inter(11))
                .foregroundStyle(Theme.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            if let listing = controller.microphoneListingProblem {
                Text(listing).foregroundStyle(Theme.errorText.swiftUI)
            }
            if let binding = controller.microphoneBinding, let missing = binding.missingPreferred {
                Text("\(missing) is not connected, so recording from \(binding.deviceName).").foregroundStyle(Theme.warningText.swiftUI)
            }
            if let problem = controller.microphoneProblem {
                Text("Cannot open: \(problem)").foregroundStyle(Theme.errorText.swiftUI)
            }
        }
    }
}

// MARK: Status

/// Read-only, and only what can actually be observed. Permissions are asked
/// live, every second, because the user can grant them while this is open.
private struct StatusTab: View {
    @ObservedObject var controller: AppController
    @ObservedObject var installer: ModelInstaller
    var openSetup: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
                        StatusRow("Dictation key", hotkey)
                        StatusRow("Secure keyboard entry", secureInput)
                        StatusRow("Microphone", microphone)
                        StatusRow("Accessibility", accessibility)
                        StatusRow("Input Monitoring", inputMonitoring)
                        StatusRow("Worker", worker)
                        StatusRow("Runtime", runtime)
                        ForEach(installer.manifest.models) { model in
                            StatusRow(model.role, (model.title, .normal))
                        }
                        StatusRow("Models", models)
                        StatusRow("Data folder", (controller.dataDirectory.path, .quiet))
                    }
                    if needsSetup {
                        Button("Open Setup", action: openSetup)
                    }
                    Text("Local only. Audio is deleted after transcription.")
                        .font(.inter(11))
                        .foregroundStyle(Theme.muted.swiftUI)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var needsSetup: Bool {
        !installer.isInstalled || Permissions.microphone != .granted || !Permissions.accessibility || !Permissions.inputMonitoring
    }

    private var accessibility: (String, StatusTone) {
        if Permissions.accessibility {
            return ("Allowed to paste", .normal)
        }
        return ("Not allowed. Turn on PrivacyFlow in Accessibility, then relaunch.", .problem)
    }

    private var inputMonitoring: (String, StatusTone) {
        if Permissions.inputMonitoring {
            return ("Allowed to see the dictation key in other apps", .normal)
        }
        return ("Not allowed. Turn on PrivacyFlow in Input Monitoring, then relaunch.", .problem)
    }

    private var models: (String, StatusTone) {
        if installer.isInstalled {
            return ("Installed and verified", .normal)
        }
        return ("Not installed", .problem)
    }

    private var hotkey: (String, StatusTone) {
        let label = controller.settings.dictationShortcut.label
        if controller.recordingShortcut {
            return ("Dictation is paused while a new dictation key is recorded in Settings", .warning)
        }
        if let problem = controller.hotkeyProblem {
            return ("\(label), but it is not being watched: \(problem)", .problem)
        }
        if !controller.inputMonitoringAtLaunch {
            return ("\(label), once Input Monitoring is allowed and PrivacyFlow is relaunched", .problem)
        }
        return ("\(label) (hold to dictate)", .normal)
    }

    private var secureInput: (String, StatusTone) {
        if controller.secureInputOn {
            return ("On in another app, which hides the keyboard from PrivacyFlow until it is turned off. It is usually a password field, or a terminal's Secure Keyboard Entry.", .warning)
        }
        return ("Off", .quiet)
    }

    private var microphone: (String, StatusTone) {
        guard let binding = controller.microphoneBinding else {
            return ("No device opened", .problem)
        }
        if let missing = binding.missingPreferred {
            return ("\(binding.deviceName), because \(missing) is not connected", .warning)
        }
        return (binding.deviceName, .normal)
    }

    private var worker: (String, StatusTone) {
        switch controller.state.worker {
        case .awaitingModels:
            return ("Waiting for the models to be installed", .quiet)
        case .starting:
            return ("Loading the models", .quiet)
        case .ready(let ready):
            var parts = ["Ready"]
            if let load = ready.loadMilliseconds {
                parts.append(String(format: "loaded in %.1f s", load / 1000))
            }
            if let locked = ready.lockedBytes {
                parts.append("\(formatBytes(locked)) held in memory")
            }
            return (parts.joined(separator: ", "), .good)
        case .failed(let reason):
            return (reason, .problem)
        }
    }

    private var runtime: (String, StatusTone) {
        switch controller.workerLaunch {
        case .success(let launch) where launch.isDevelopmentOverride:
            return ("Development interpreter from \(WorkerLaunch.developmentPythonVariable): \(launch.python.path)", .warning)
        case .success(let launch):
            return (launch.python.path, .quiet)
        case .failure(let problem):
            return (problem.description, .problem)
        }
    }
}

private enum StatusTone {
    case normal, quiet, good, warning, problem

    var colour: Color {
        switch self {
        case .normal: Theme.label.swiftUI
        case .quiet: Theme.muted.swiftUI
        case .good: Theme.inserted.swiftUI
        case .warning: Theme.warningText.swiftUI
        case .problem: Theme.errorText.swiftUI
        }
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    let tone: StatusTone

    init(_ label: String, _ value: (String, StatusTone)) {
        self.label = label
        (self.value, self.tone) = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .font(.inter(11, weight: .semibold))
                .foregroundStyle(Theme.muted.swiftUI)
                .gridColumnAlignment(.trailing)
            Text(value)
                .foregroundStyle(tone.colour)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
