import Foundation

// MARK: - Shared types used across all VoxFlow modules.
// Component files must build against exactly these shapes. Do not redefine
// these types elsewhere; extend them here and update every switch.

/// The app-wide pipeline state, driven by AppDelegate, observed by UI.
public enum FlowState: Equatable {
    case idle
    case recording
    case transcribing
    case cleaning
    case inserting
    case error(String)
    /// Transient informational message in the HUD ("Last dictation recovered
    /// to History"); the menu-bar icon stays idle.
    case notice(String)
}

/// How aggressively transcripts are cleaned before insertion.
public enum CleanupMode: String, CaseIterable {
    /// No cleanup at all — raw Whisper output.
    case off
    /// Fast local regex pass: strip filler words, fix spacing/capitalization.
    case rules
    /// Apple on-device LLM polish (FoundationModels), falls back to `rules`
    /// when Apple Intelligence is unavailable.
    case ai
}

/// A single completed dictation.
public struct HistoryEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let rawText: String
    public let cleanedText: String
    public let appBundleID: String?
    public let durationSeconds: Double

    public init(id: UUID = UUID(), date: Date = Date(), rawText: String,
                cleanedText: String, appBundleID: String?, durationSeconds: Double) {
        self.id = id
        self.date = date
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.appBundleID = appBundleID
        self.durationSeconds = durationSeconds
    }
}

/// A personal-dictionary substitution: "kubernetes" -> "Kubernetes",
/// "vitality" -> "Vitality Massage Therapy", etc.
public struct DictionaryEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public var trigger: String
    public var replacement: String
    /// When true, match whole words case-insensitively; replacement casing wins.
    public var caseInsensitive: Bool

    public init(id: UUID = UUID(), trigger: String, replacement: String, caseInsensitive: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.caseInsensitive = caseInsensitive
    }
}

/// Whisper model choices surfaced in Settings.
/// Ordered fastest → most accurate. The Windows benchmark (see the top-level
/// README) found base.en alone produces outright garbage on technical
/// vocabulary, medium.en is the best English model, and large-v3-turbo is no
/// more accurate than medium.en for English — it is offered for
/// non-English dictation.
public enum WhisperModelChoice: String, CaseIterable {
    case baseEn = "base.en"
    case smallEn = "small.en"
    case mediumEn = "medium.en"
    case largeV3Turbo = "large-v3_turbo"

    public var displayName: String {
        switch self {
        case .baseEn: return "Base — fastest (~150 MB)"
        case .smallEn: return "Small — balanced (~500 MB)"
        case .mediumEn: return "Medium — most accurate English (~1.5 GB)"
        case .largeV3Turbo: return "Large v3 Turbo — multilingual (~1.6 GB)"
        }
    }

    /// Where WhisperKit's Hugging Face helper stores CoreML models.
    public static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// On-disk folder for this variant (`openai_whisper-<variant>`).
    public var modelFolder: URL {
        Self.modelsDirectory.appendingPathComponent("openai_whisper-\(rawValue)", isDirectory: true)
    }

    /// True once the compiled decoder is on disk — good enough to mark the
    /// menu, and the check is a single stat.
    public var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("TextDecoder.mlmodelc").path)
    }
}

/// Notifications used to decouple modules.
public extension Notification.Name {
    /// Posted by AppDelegate whenever FlowState changes. object = nil,
    /// userInfo["state"] = FlowState boxed in StateBox.
    static let voxFlowStateChanged = Notification.Name("VoxFlowStateChanged")
    /// Posted by AudioRecorder with userInfo["level"] as Float (0...1) ~30x/sec while recording.
    static let voxFlowAudioLevel = Notification.Name("VoxFlowAudioLevel")
    /// Posted when the personal dictionary or preferences change and dependents should reload.
    static let voxFlowPrefsChanged = Notification.Name("VoxFlowPrefsChanged")
    /// Posted by the menu bar to ask the pipeline owner (AppDelegate) to do
    /// something: userInfo["command"] is a `PipelineCommand` raw value.
    static let voxFlowCommand = Notification.Name("VoxFlowCommand")
}

/// Maintenance actions the menu bar can request from the pipeline owner
/// without referencing it directly (SPEC: UI talks via notifications).
public enum PipelineCommand: String {
    case restartEngine
    case recoverLastTake
    case restartHotkey
}

/// Reference box so FlowState (an enum with payload) can ride in userInfo.
public final class StateBox: NSObject {
    public let state: FlowState
    public init(_ state: FlowState) { self.state = state }
}
