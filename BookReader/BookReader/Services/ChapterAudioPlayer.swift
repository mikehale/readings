import AVFoundation
import Combine
import Foundation

@MainActor
final class ChapterAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var endObserver: NSObjectProtocol?

    func load(url: URL) throws {
        stop()
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.prepareToPlay()
        player = audio
        currentURL = url
        errorMessage = nil
    }

    func play() {
        guard let player else { return }
        isPlaying = player.play()
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentURL = nil
    }
}
