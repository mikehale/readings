import Foundation

protocol SpeechSynthesizing {
    func synthesize(text: String, profile: VoiceProfile, to outputURL: URL) async throws
}

enum SpeechSynthesisError: LocalizedError {
    case unsupportedProfile(VoiceProfile)
    case cloneNotWired
    case kokoroNotWired
    case missingReference

    var errorDescription: String? {
        switch self {
        case .unsupportedProfile(let profile):
            return "Unsupported voice profile: \(profile.displayName)."
        case .cloneNotWired:
            return "Narrator clone (Chatterbox) is selected, but the guarded clone CLI is not wired yet. Use Andrew (online) for now, or keep the reference ready for HQ synth."
        case .kokoroNotWired:
            return "Kokoro offline voice is not wired yet. Switch back to Andrew (online)."
        case .missingReference:
            return "Choose or import a short denoised reference clip before using Narrator clone."
        }
    }
}

/// Routes chapter jobs to the right short-lived backend. Never loads ML in-process.
struct SpeechSynthesisRouter: SpeechSynthesizing {
    private let edge: EdgeTTSSynthesizer

    init(edge: EdgeTTSSynthesizer = EdgeTTSSynthesizer()) {
        self.edge = edge
    }

    func synthesize(text: String, profile: VoiceProfile, to outputURL: URL) async throws {
        switch profile {
        case .onlineAndrew:
            try await edge.synthesize(text: text, to: outputURL)
        case .offlineKokoro:
            throw SpeechSynthesisError.kokoroNotWired
        case .clone(let refURL):
            guard FileManager.default.fileExists(atPath: refURL.path) else {
                throw SpeechSynthesisError.missingReference
            }
            // Stub: keep ref selected for when CloneSynthesizer lands (RAM-gated CLI).
            _ = refURL
            throw SpeechSynthesisError.cloneNotWired
        }
    }
}
