import Foundation
import Network

/// A user-initiated, short-lived Bonjour operation. Ready means the browser
/// started, not that iOS granted a general Local Network authorization.
@MainActor
final class BonjourDiscoveryProbe: DiscoveryPreflighting {
    private let scheduler: DeadlineScheduling
    private var browser: NWBrowser?
    private var attempt: UUID?
    private var deadline: CancelDeadline?
    private var lastFailure: DiscoveryFailure?
    private var completion: (@MainActor (Result<Void, DiscoveryFailure>) -> Void)?

    init(scheduler: DeadlineScheduling) { self.scheduler = scheduler }

    private enum Event: Sendable {
        case ready
        case waiting(DiscoveryFailure)
        case failed(DiscoveryFailure)
    }

    nonisolated private static func failure(_ error: NWError) -> DiscoveryFailure {
        if case .dns(let code) = error {
            return DiscoveryFailure(operation: .preflight, domain: "DNSService",
                                    code: Int(code), detail: error.localizedDescription)
        }
        return DiscoveryFailure(operation: .preflight, error: error as NSError)
    }

    func start(completion: @escaping @MainActor (Result<Void, DiscoveryFailure>) -> Void) {
        cancel()
        let token = UUID()
        attempt = token
        self.completion = completion
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_p0ng-lan._tcp", domain: nil),
                                using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            let event: Event
            switch state {
            case .ready: event = .ready
            case .waiting(let error): event = .waiting(Self.failure(error))
            case .failed(let error): event = .failed(Self.failure(error))
            default: return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attempt == token else { return }
                switch event {
                case .ready: self.finish(.success(()))
                case .waiting(let failure): self.lastFailure = failure
                case .failed(let failure): self.finish(.failure(failure))
                }
            }
        }
        deadline = scheduler.schedule(after: 20) { [weak self] in
            guard let self, self.attempt == token else { return }
            self.finish(.failure(self.lastFailure ?? DiscoveryFailure(
                operation: .preflight, domain: "p0ng.discovery", code: 1,
                detail: "Local Network check timed out")))
        }
        browser.start(queue: .main)
    }

    private func finish(_ result: Result<Void, DiscoveryFailure>) {
        let callback = completion
        cancel()
        callback?(result)
    }

    func cancel() {
        attempt = nil
        deadline?()
        deadline = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        lastFailure = nil
        completion = nil
    }
}
