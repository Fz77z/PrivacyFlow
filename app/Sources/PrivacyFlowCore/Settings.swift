import Foundation

/// Everything the user has chosen, kept in `settings.json` in the data
/// directory and written whenever a control changes.
///
/// Missing fields take their defaults and unknown fields are ignored, so a file
/// written by an earlier or later version still loads.
public struct Settings: Equatable, Sendable {
    public var minimalMode = false
    /// Whether a short sound confirms the start and end of a dictation. On
    /// unless the user turns it off, including for a file that predates it.
    public var soundCues = true
    /// The microphone to record from whenever it is connected, by name. Nil
    /// follows the system input.
    public var preferredMicrophone: String?
    /// The shortcut held to dictate. Right Option unless the user chose another.
    public var dictationShortcut = Shortcut.rightOption
    /// Why a stored shortcut could not be used, when one was stored and could
    /// not be. Never written back: the next save stores the shortcut in use.
    public private(set) var shortcutProblem: String?

    public init(minimalMode: Bool = false, soundCues: Bool = true, preferredMicrophone: String? = nil, dictationShortcut: Shortcut = .rightOption) {
        self.minimalMode = minimalMode
        self.soundCues = soundCues
        self.preferredMicrophone = preferredMicrophone
        self.dictationShortcut = dictationShortcut
    }
}

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case minimalMode = "minimal_mode"
        case soundCues = "sound_cues"
        case preferredMicrophone = "preferred_microphone"
        case dictationShortcut = "dictation_shortcut"
    }

    /// Written out so each absent field takes its own default rather than
    /// failing the whole file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        minimalMode = try container.decodeIfPresent(Bool.self, forKey: .minimalMode) ?? defaults.minimalMode
        soundCues = try container.decodeIfPresent(Bool.self, forKey: .soundCues) ?? defaults.soundCues
        preferredMicrophone = try container.decodeIfPresent(String.self, forKey: .preferredMicrophone)
        // Read on its own, so an unreadable shortcut costs only the shortcut:
        // the other settings still load, and dictation runs on the default.
        if container.contains(.dictationShortcut) {
            do {
                let stored = try container.decode(Shortcut.self, forKey: .dictationShortcut)
                if case .refused(let reason) = stored.assessment {
                    shortcutProblem = "The saved dictation key, \(stored.label), cannot be used: \(reason) Right Option is used instead."
                } else {
                    dictationShortcut = stored
                }
            } catch {
                shortcutProblem = "The saved dictation key could not be read (\(SettingsFile.describe(error))), so Right Option is used instead."
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minimalMode, forKey: .minimalMode)
        try container.encode(soundCues, forKey: .soundCues)
        try container.encodeIfPresent(preferredMicrophone, forKey: .preferredMicrophone)
        try container.encode(dictationShortcut, forKey: .dictationShortcut)
    }
}

/// Reading and writing `settings.json`.
public enum SettingsFile {
    /// The settings, and why they could not be read if a file existed and
    /// could not be used. The caller runs on the defaults either way and must
    /// report the problem, so a reverted preference is not a mystery.
    public struct Load: Sendable {
        public var settings: Settings
        public var problem: String?
    }

    public static func url(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("settings.json")
    }

    /// A missing file is a first run, not a problem. An unreadable file is left
    /// on disk until the user changes a setting, which is the instruction to
    /// replace it.
    public static func load(from dataDirectory: URL) -> Load {
        let url = url(in: dataDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Load(settings: Settings(), problem: nil)
        } catch {
            return Load(settings: Settings(), problem: "Could not read \(url.path): \(error.localizedDescription)")
        }
        do {
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            return Load(settings: settings, problem: settings.shortcutProblem.map { "In \(url.path): \($0)" })
        } catch {
            return Load(settings: Settings(), problem: "Could not read \(url.path): \(describe(error))")
        }
    }

    /// Write the settings, returning what went wrong rather than printing it:
    /// a control on screen shows the new value, and a failed write leaves it
    /// describing a state the app is not in.
    public static func save(_ settings: Settings, to dataDirectory: URL) -> String? {
        let url = url(in: dataDirectory)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: .atomic)
            return nil
        } catch {
            return "Could not write \(url.path): \(error.localizedDescription)"
        }
    }

    static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty:
            return "it is not valid JSON (\(context.debugDescription))"
        case DecodingError.dataCorrupted(let context):
            return "\(path(context)) is \(context.debugDescription)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "\(path(context)) has the wrong type"
        case DecodingError.keyNotFound(let key, let context):
            return "\([path(context), key.stringValue].filter { !$0.isEmpty }.joined(separator: ".")) is missing"
        default:
            return "\(error)"
        }
    }

}
