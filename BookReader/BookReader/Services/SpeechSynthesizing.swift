import Foundation

protocol SpeechSynthesizing {
    func synthesize(
        text: String,
        profile: VoiceProfile,
        to outputURL: URL,
        broker: SynthesisProcessBroker
    ) async throws

    func cancel(broker: SynthesisProcessBroker)
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
            return "Chatterbox clone is optional and not wired in this build. Use XTTS Curt (HQ) or Andrew (online)."
        case .kokoroNotWired:
            return "Kokoro offline voice is not wired yet. Switch to XTTS Curt or Andrew."
        case .missingReference:
            return "Choose a sample or import a speaker wav before synthesizing with XTTS."
        }
    }
}

/// Routes chapter jobs to short-lived backends. Never loads ML in-process.
struct SpeechSynthesisRouter: SpeechSynthesizing {
    private let edge: EdgeTTSSynthesizer
    private let xtts: XTTSv2Synthesizer

    init(
        edge: EdgeTTSSynthesizer = EdgeTTSSynthesizer(),
        xtts: XTTSv2Synthesizer = XTTSv2Synthesizer()
    ) {
        self.edge = edge
        self.xtts = xtts
    }

    func synthesize(
        text: String,
        profile: VoiceProfile,
        to outputURL: URL,
        broker: SynthesisProcessBroker
    ) async throws {
        switch profile {
        case .xtts(let speaker):
            try await xtts.synthesize(text: text, speakerWav: speaker, to: outputURL, broker: broker)
        case .onlineAndrew:
            try await edge.synthesize(text: text, to: outputURL, broker: broker)
        case .offlineKokoro:
            throw SpeechSynthesisError.kokoroNotWired
        case .clone(let refURL):
            guard FileManager.default.fileExists(atPath: refURL.path) else {
                throw SpeechSynthesisError.missingReference
            }
            _ = refURL
            throw SpeechSynthesisError.cloneNotWired
        }
    }

    func cancel(broker: SynthesisProcessBroker) {
        broker.cancel()
    }
}
