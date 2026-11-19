import Foundation

/// Which TTS backend to use for a chapter job.
/// Shape A from the MVP plan: app owns policy; backends are short-lived CLIs.
enum VoiceProfile: Equatable, Hashable, Identifiable {
    /// HQ default: Coqui XTTSv2 + speaker wav (Curt locked).
    case xtts(speakerWav: URL)
    case onlineAndrew
    case offlineKokoro(voice: String)
    /// Optional Chatterbox clone path (not default).
    case clone(refAudioURL: URL)

    var id: String {
        switch self {
        case .xtts(let url):
            return "xtts-\(url.path)"
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
        case .xtts(let url):
            return "XTTS · \(url.deletingPathExtension().lastPathComponent)"
        case .onlineAndrew:
            return "Andrew (online)"
        case .offlineKokoro(let voice):
            return "Kokoro (\(voice)) — coming soon"
        case .clone:
            return "Chatterbox clone (optional)"
        }
    }

    var detail: String {
        switch self {
        case .xtts(let url):
            return "XTTSv2 · short-lived · RSS kill 14 GiB · ref: \(url.lastPathComponent)"
        case .onlineAndrew:
            return "edge-tts · en-US-AndrewNeural · MP3"
        case .offlineKokoro(let voice):
            return "Local ONNX · \(voice) · not wired yet"
        case .clone(let url):
            return "Optional Chatterbox · ref: \(url.lastPathComponent)"
        }
    }

    static let defaultKokoroVoice = "am_michael"
}

struct SavedVoiceReference: Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Filename under Application Support/BookReader/VoiceRefs/
    var fileName: String
    var createdAt: Date
    var isDenoised: Bool
    /// Engine hint: "xtts" | "clone" | "unknown"
    var engine: String

    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        createdAt: Date = Date(),
        isDenoised: Bool = false,
        engine: String = "xtts"
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.createdAt = createdAt
        self.isDenoised = isDenoised
        self.engine = engine
    }
}

extension SavedVoiceReference: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, fileName, createdAt, isDenoised, engine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decode(String.self, forKey: .fileName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isDenoised = try c.decodeIfPresent(Bool.self, forKey: .isDenoised) ?? false
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "xtts"
    }
}

extension VoiceProfile {
    /// Prefer a clean label when the speaker file is Curt.
    var shortDisplayName: String {
        switch self {
        case .xtts(let url):
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            if base.contains("curt") { return "XTTS Curt (HQ)" }
            return "XTTS · \(url.deletingPathExtension().lastPathComponent)"
        default:
            return displayName
        }
    }
}

/// Bundled catalog entry (shown in UI; copy into VoiceRefs to use as library voice).
struct BundledVoiceSample: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let resourceName: String
    let isDefaultHQ: Bool

    var resourceURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "wav", subdirectory: "VoiceSamples")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "wav")
    }

    static let catalog: [BundledVoiceSample] = [
        BundledVoiceSample(
            id: "curt",
            name: "Curt",
            detail: "XTTSv2 HQ default · ebook2audiobook male",
            resourceName: "Curt",
            isDefaultHQ: true
        ),
        BundledVoiceSample(
            id: "neil-gaiman",
            name: "Neil Gaiman",
            detail: "XTTSv2 sample · ebook2audiobook male",
            resourceName: "NeilGaiman",
            isDefaultHQ: false
        ),
        BundledVoiceSample(
            id: "ana-florence",
            name: "Ana Florence",
            detail: "XTTSv2 sample · ebook2audiobook female",
            resourceName: "AnaFlorence",
            isDefaultHQ: false
        ),
    ]
}
