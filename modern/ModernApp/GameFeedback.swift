import AVFoundation
import UIKit
import PongCore

/// Native feedback is derived from authoritative simulation events, never
/// interpolated guest rendering. Nothing is emitted for a mere visual correction.
@MainActor
final class GameFeedback: GameFeedbacking {
    private var previous: PongSnapshot?
    private let paddle: AVAudioPlayer?
    private let wall: AVAudioPlayer?

    private let preferences: @MainActor () -> FeedbackPreferences

    init(preferences: @escaping @MainActor () -> FeedbackPreferences) {
        self.preferences = preferences
        func load(_ name: String) -> AVAudioPlayer? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.prepareToPlay()
            return player
        }
        paddle = load("offthepaddle")
        wall = load("offthewall")
    }

    func reset() { previous = nil }

    func observe(_ next: PongSnapshot) {
        defer { previous = next }
        guard let old = previous else { return }
        let settings = preferences()
        let sound = settings.sound
        let haptics = settings.haptics

        if next.leftScore != old.leftScore || next.rightScore != old.rightScore {
            if sound { play(wall) }
            if haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        } else if old.phase == .playing && next.phase == .playing {
            if old.ballVX * next.ballVX < 0 {
                if sound { play(paddle) }
                if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            } else if old.ballVY * next.ballVY < 0 {
                if sound { play(wall) }
            }
        }
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }
}
