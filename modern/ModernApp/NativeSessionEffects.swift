import Foundation
import QuartzCore
import UIKit
import PongCore

/// Keep CADisplayLink teardown off the view model's nonisolated deinit.
/// The runloop owns the link, so invalidate on the main queue even if ARC
/// releases the lifetime owner from another executor. Only MainActor code
/// otherwise accesses the reference.
private struct MainQueueDisplayLink: @unchecked Sendable {
    let link: CADisplayLink
}

private final class DisplayLinkLifetime {
    private let token: MainQueueDisplayLink
    init(link: CADisplayLink) { token = MainQueueDisplayLink(link: link) }
    deinit {
        let token = token
        DispatchQueue.main.async { token.link.invalidate() }
    }
}

/// Weak proxy breaks CADisplayLink's retain cycle with its target.
@MainActor
private final class FrameTarget: NSObject {
    weak var owner: NativeFrameClock?
    @objc func frame(_ link: CADisplayLink) { owner?.onFrame?(link.timestamp) }
}

@MainActor
final class NativeFrameClock: FrameClock {
    var onFrame: (@MainActor (TimeInterval) -> Void)?
    private let target: FrameTarget
    private let link: CADisplayLink
    private let lifetime: DisplayLinkLifetime

    init() {
        let target = FrameTarget()
        self.target = target
        let link = CADisplayLink(target: target, selector: #selector(FrameTarget.frame(_:)))
        self.link = link
        self.lifetime = DisplayLinkLifetime(link: link)
        target.owner = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
    }

    var isRunning: Bool { !link.isPaused }
    func setRunning(_ running: Bool) { link.isPaused = !running }
}

@MainActor
final class NativeDeadlineScheduler: DeadlineScheduling {
    func schedule(after seconds: TimeInterval,
                  _ action: @escaping @MainActor @Sendable () -> Void) -> CancelDeadline {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}

@MainActor
final class NativeIdleTimer: IdleTimerControlling {
    private var previous: Bool?
    private let read: @MainActor () -> Bool
    private let write: @MainActor (Bool) -> Void

    init(read: @escaping @MainActor () -> Bool, write: @escaping @MainActor (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    func setPreventingSleep(_ active: Bool) {
        if active {
            guard previous == nil else { return }
            previous = read()
            write(true)
        } else if let previous {
            write(previous)
            self.previous = nil
        }
    }
}

@MainActor
enum P0ngComposition {
    static func makeModel() -> PongViewModel {
        let scheduler = NativeDeadlineScheduler()
        let transport = NearbyTransport(probe: BonjourDiscoveryProbe(scheduler: scheduler),
                                        scheduler: scheduler)
        let feedback = GameFeedback(preferences: {
            let defaults = UserDefaults.standard
            return FeedbackPreferences(
                sound: defaults.object(forKey: "p0ng.soundEnabled") as? Bool ?? true,
                haptics: defaults.object(forKey: "p0ng.hapticsEnabled") as? Bool ?? true)
        })
        return PongViewModel(interactor: SessionInteractor(
            transport: transport, clock: NativeFrameClock(),
            now: { CACurrentMediaTime() }, scheduler: scheduler,
            feedback: feedback, idleTimer: NativeIdleTimer(
                read: { UIApplication.shared.isIdleTimerDisabled },
                write: { UIApplication.shared.isIdleTimerDisabled = $0 })))
    }
}
