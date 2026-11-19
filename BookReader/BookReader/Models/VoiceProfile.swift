import Foundation

/// Which TTS backend to use for a chapter job.
/// Shape A from the MVP plan: app owns policy; backends are short-lived CLIs.
enum VoiceProfile: Equatable, Hashable, Identifiable {
    case onlineAndrew
    case offlineKokoro(voice: String)
    case clone(refAudioURL: URL)

    var id: String {
        switch self {
        case .onlineAndrew:
            return "online-andrew"
        case .offlineKokoro(let voice):
            return "offline-kokoro-\(voice)"
        case .clone(let url):
            return "clone-\(url.path)"
        }
    }

    var displayName: String {
        switch self {
        case .onlineAndrew:
            return "Andrew (online)"
        case .offlineKokoro(let voice):
            return "Kokoro (\(voice)) — coming soon"
        case .clone:
            return "Narrator clone (Chatterbox)"
        }
    }

    var detail: String {
        switch self {
        case .onlineAndrew:
            return "edge-tts · en-US-AndrewNeural · MP3"
        case .offlineKokoro(let voice):
            return "Local ONNX · \(voice) · not wired yet"
        case .clone(let url):
            return "MPS Chatterbox · ref: \(url.lastPathComponent)"
        }
    }

    static let defaultOnline = VoiceProfile.onlineAndrew
    static let defaultKokoroVoice = "am_michael"
}

struct SavedVoiceReference: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// Filename under Application Support/BookReader/VoiceRefs/
    var fileName: String
    var createdAt: Date
    var isDenoised: Bool

    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        createdAt: Date = Date(),
        isDenoised: Bool = true
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.createdAt = createdAt
        self.isDenoised = isDenoised
    }
}
