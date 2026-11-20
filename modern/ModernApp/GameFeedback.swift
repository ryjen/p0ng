import PongCore

enum FeedbackEvent: Equatable {
    case paddleSound, wallSound, pointHaptic, paddleHaptic
}

@MainActor
protocol FeedbackOutput {
    func emit(_ event: FeedbackEvent)
}

/// Feedback policy uses authoritative simulation events, never interpolated
/// rendering. Native resources and settings are injected at composition.
@MainActor
final class GameFeedback: GameFeedbacking {
    private var previous: PongSnapshot?
    private let preferences: @MainActor () -> FeedbackPreferences
    private let output: FeedbackOutput

    init(preferences: @escaping @MainActor () -> FeedbackPreferences,
         output: FeedbackOutput) {
        self.preferences = preferences
        self.output = output
    }

    func reset() { previous = nil }

    func observe(_ next: PongSnapshot) {
        defer { previous = next }
        guard let old = previous else { return }
        let settings = preferences()
        if next.leftScore != old.leftScore || next.rightScore != old.rightScore {
            if settings.sound { output.emit(.wallSound) }
            if settings.haptics { output.emit(.pointHaptic) }
        } else if old.phase == .playing && next.phase == .playing {
            if old.ballVX * next.ballVX < 0 {
                if settings.sound { output.emit(.paddleSound) }
                if settings.haptics { output.emit(.paddleHaptic) }
            } else if old.ballVY * next.ballVY < 0 {
                if settings.sound { output.emit(.wallSound) }
            }
        }
    }
}
