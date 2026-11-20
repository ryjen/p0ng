import Foundation
import PongCore

@MainActor
protocol FrameClock: AnyObject {
    var onFrame: (@MainActor (TimeInterval) -> Void)? { get set }
    var isRunning: Bool { get }
    func setRunning(_ running: Bool)
}

typealias CancelDeadline = @MainActor () -> Void

@MainActor
protocol DeadlineScheduling {
    func schedule(after seconds: TimeInterval,
                  _ action: @escaping @MainActor @Sendable () -> Void) -> CancelDeadline
}

@MainActor
protocol IdleTimerControlling {
    func setPreventingSleep(_ active: Bool)
}

struct FeedbackPreferences {
    let sound: Bool
    let haptics: Bool
}

@MainActor
protocol GameFeedbacking {
    func reset()
    func observe(_ next: PongSnapshot)
}

enum DiscoveryOperation: String, Sendable {
    case preflight = "Local Network check"
    case hosting = "Hosting"
    case browsing = "Browsing"
}

/// Transport diagnostics, not a general permission authorization result.
struct DiscoveryFailure: Error, Equatable, Sendable {
    let operation: DiscoveryOperation
    let domain: String
    let code: Int
    let detail: String
    var localNetworkDenied: Bool { domain == "DNSService" && code == -65570 }

    var presentation: String {
        let hint = localNetworkDenied
            ? " Allow Local Network access for p0ng in Settings, then retry."
            : " Check Wi-Fi and Local Network access, then retry."
        return "\(operation.rawValue) failed [\(domain):\(code)]: \(detail)." + hint
    }

    init(operation: DiscoveryOperation, domain: String, code: Int, detail: String) {
        self.operation = operation
        self.domain = domain
        self.code = code
        self.detail = detail
    }

    init(operation: DiscoveryOperation, error: NSError) {
        self.init(operation: operation, domain: error.domain, code: error.code,
                  detail: error.localizedDescription)
    }
}

@MainActor
protocol DiscoveryPreflighting: AnyObject {
    func start(completion: @escaping @MainActor (Result<Void, DiscoveryFailure>) -> Void)
    func cancel()
}
