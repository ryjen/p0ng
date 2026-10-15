import Foundation
import MultipeerConnectivity
import UIKit
import PongCore

/// Strongly retains a legacy SDK instance across a main-actor handoff,
/// solely to compare object identity. A bare ObjectIdentifier is insufficient:
/// after deallocation a new SDK session can reuse the same address.
/// Framework methods and mutable state remain accessed only on MainActor.
private struct SDKReference<Object: AnyObject>: @unchecked Sendable {
    let value: Object
}

/// Immutable MCPeerID value crossing a legacy delegate-to-MainActor handoff.
/// MCPeerID has no mutable public identity state; use it only on MainActor.
private struct PeerReference: @unchecked Sendable {
    let value: MCPeerID
}

/// Once-only response to an SDK invitation from an arbitrary callback queue.
final class InvitationReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Bool, MCSession?) -> Void)?
    init(_ handler: @escaping (Bool, MCSession?) -> Void) { self.handler = handler }
    func respond(_ accepted: Bool, session: MCSession?) {
        lock.lock()
        let current = handler
        handler = nil
        lock.unlock()
        current?(accepted, session)
    }
}

/// The only mutable transport state accessed by delegate threads.
final class LockedPacketIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var window = PacketIngressWindow()
    // Both SDK references are inspected only while holding the lock. Retaining
    // the actual session prevents stale pointer/identity reuse across matches.
    private var session: MCSession?
    private var peer: MCPeerID?

    func authorize(session: MCSession, peer: MCPeerID) {
        lock.lock()
        defer { lock.unlock() }
        window.reset()
        self.session = session
        self.peer = peer
    }

    func allow(session candidate: MCSession, from sender: MCPeerID,
               at time: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session === candidate,
              let peer, peer == sender else { return false }
        return window.admit(at: time)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        session = nil
        peer = nil
        window.reset()
    }
}

/// LAN transport for exactly two players. Intentionally no third-party relay or account.
/// Callbacks are delivered on the main queue for the SwiftUI coordinator.
@MainActor
final class NearbyTransport: NSObject, GameTransport, MCNearbyServiceAdvertiserDelegate,
                             MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    private static let service = "p0ng-lan"
    // Avoid advertising the owner's device name (often personally identifying).
    private let localPeer = MCPeerID(displayName: "p0ng-" + String(UUID().uuidString.prefix(6)))
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private(set) var hosting = false
    private(set) var connected = false
    private var pendingInvitation: (id: UUID, peer: MCPeerID, reply: InvitationReply)?
    private var acceptedPeer: MCPeerID?
    private var selectedPeer: MCPeerID?
    private var activePeer: MCPeerID?
    private var admission = NearbyAdmissionGate()
    private let ingress = LockedPacketIngress()

    nonisolated private func canDecodePacket(from peer: MCPeerID,
                                              in session: MCSession) -> Bool {
        // Check the admitted peer BEFORE JSON decoding or consuming rate quota.
        // Unexpected peers cannot starve the authorized player's packet budget.
        ingress.allow(session: session, from: peer,
                      at: ProcessInfo.processInfo.systemUptime)
    }

    var onPeersChanged: (@MainActor @Sendable ([NearbyPeer]) -> Void)?
    var onInvitation: (@MainActor @Sendable (String) -> Void)?
    var onInvitationExpired: (@MainActor @Sendable () -> Void)?
    var onConnected: (@MainActor @Sendable () -> Void)?
    var onDisconnected: (@MainActor @Sendable (String) -> Void)?
    var onPacket: (@MainActor @Sendable (MatchMessage) -> Void)?
    var onError: (@MainActor @Sendable (String) -> Void)?
    var onDiscoveryFailed: (@MainActor @Sendable (String) -> Void)?
    private var discovered: [MCPeerID] = []
    private var peerTokens: [MCPeerID: UUID] = [:]

    private func publishedPeers() -> [NearbyPeer] {
        discovered.compactMap { peer in
            guard let id = peerTokens[peer] else { return nil }
            return NearbyPeer(id: id, displayName: peer.displayName)
        }
    }

    func host() {
        stop()
        hosting = true
        prepareSession()
        let advertiser = MCNearbyServiceAdvertiser(peer: localPeer,
            discoveryInfo: nil, serviceType: Self.service)
        self.advertiser = advertiser
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
    }

    func browse() {
        stop()
        hosting = false
        prepareSession()
        let browser = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.service)
        self.browser = browser
        browser.delegate = self
        browser.startBrowsingForPeers()
    }

    func join(_ peer: NearbyPeer) {
        guard !hosting, !connected, selectedPeer == nil,
              let actualPeer = discovered.first(where: { peerTokens[$0] == peer.id }),
              let browser, let session else { return }
        selectedPeer = actualPeer
        browser.invitePeer(actualPeer, to: session, withContext: nil, timeout: 20)
    }

    func decideInvitation(accept: Bool) {
        guard let pendingInvitation else { return }
        self.pendingInvitation = nil
        let allow = accept && hosting && session != nil
        guard admission.resolve(accept: allow) else {
            pendingInvitation.reply.respond(false, session: nil)
            return
        }
        if allow { acceptedPeer = pendingInvitation.peer }
        pendingInvitation.reply.respond(allow, session: allow ? session : nil)
    }

    /// Only a connected, explicitly admitted single peer may receive match
    /// traffic. Reliable control failures cannot leave the host simulating
    /// while the guest silently misses a score or phase transition.
    private func failMatchDelivery(_ reason: String) {
        stop()
        onDisconnected?(reason)
    }

    func send(_ message: OutgoingMessage) {
        let singleAuthorizedPeer: Bool
        if let session, let activePeer {
            singleAuthorizedPeer = session.connectedPeers.count == 1 &&
                session.connectedPeers.contains(activePeer)
        } else {
            singleAuthorizedPeer = false
        }
        switch OutboundSendPolicy.evaluate(connected: connected,
                                           singleAuthorizedPeer: singleAuthorizedPeer,
                                           quality: message.quality) {
        case .ignore: return
        case .terminate:
            failMatchDelivery("Match ended: authorized peer unavailable.")
            return
        case .transmit: break
        }

        guard let session, let activePeer else { return }
        do {
            let encoded = try JSONEncoder().encode(message.packet)
            switch OutboundSendPolicy.evaluate(connected: true,
                                               singleAuthorizedPeer: true,
                                               quality: message.quality,
                                               encodedByteCount: encoded.count) {
            case .ignore: return
            case .terminate:
                failMatchDelivery("Match ended: reliable packet exceeded the size limit.")
                return
            case .transmit: break
            }
            try session.send(encoded, toPeers: [activePeer],
                             with: message.quality == .reliable ? .reliable : .unreliable)
        } catch {
            if message.quality == .reliable {
                failMatchDelivery("Match ended: reliable network send failed.")
            }
            // Realtime data is replaceable, so a transient failure is ignored.
        }
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        pendingInvitation?.reply.respond(false, session: nil)
        pendingInvitation = nil
        acceptedPeer = nil
        selectedPeer = nil
        activePeer = nil
        admission.reset()
        ingress.reset()
        session?.disconnect()
        session?.delegate = nil
        session = nil
        hosting = false
        connected = false
        discovered = []
        peerTokens.removeAll()
        onPeersChanged?([])
    }

    private func prepareSession() {
        let session = MCSession(peer: localPeer, securityIdentity: nil,
                                encryptionPreference: .required)
        session.delegate = self
        self.session = session
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let sdk = SDKReference(value: advertiser)
        let peer = PeerReference(value: peerID)
        let reply = InvitationReply(invitationHandler)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.advertiser,
                  current === sdk.value,
                  self.hosting, !self.connected, self.acceptedPeer == nil,
                  self.pendingInvitation == nil, self.session != nil,
                  self.admission.offer() else {
                reply.respond(false, session: nil)
                return
            }
            let id = UUID()
            self.pendingInvitation = (id: id, peer: peer.value, reply: reply)
            self.onInvitation?(peer.value.displayName)

            // The browsing peer's invitation expires after 20 seconds. Do
            // not keep this host's single admission slot occupied indefinitely
            // if nobody responds or the UI remains in the background.
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in
                guard let self, let pending = self.pendingInvitation,
                      pending.id == id, self.hosting,
                      self.admission.expire() else { return }
                self.pendingInvitation = nil
                pending.reply.respond(false, session: nil)
                self.onInvitationExpired?()
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {
        let sdk = SDKReference(value: advertiser)
        let reason = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.advertiser,
                  current === sdk.value else { return }
            self.onDiscoveryFailed?(reason)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        let sdk = SDKReference(value: browser)
        let peer = PeerReference(value: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.browser,
                  current === sdk.value else { return }
            if !self.discovered.contains(peer.value) {
                self.discovered.append(peer.value)
                self.peerTokens[peer.value] = UUID()
            }
            self.onPeersChanged?(self.publishedPeers())
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let sdk = SDKReference(value: browser)
        let peer = PeerReference(value: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.browser,
                  current === sdk.value else { return }
            self.discovered.removeAll { $0 == peer.value }
            self.peerTokens.removeValue(forKey: peer.value)
            self.onPeersChanged?(self.publishedPeers())
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {
        let sdk = SDKReference(value: browser)
        let reason = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.browser,
                  current === sdk.value else { return }
            self.onDiscoveryFailed?(reason)
        }
    }

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        let sdk = SDKReference(value: session)
        let peer = PeerReference(value: peerID)
        let stateCode = state.rawValue
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.session,
                  current === sdk.value,
                  let state = MCSessionState(rawValue: stateCode) else { return }
            switch state {
            case .connected:
                guard current.connectedPeers.count == 1,
                      (self.hosting
                        ? (self.acceptedPeer == peer.value && self.admission.didConnect())
                        : (self.selectedPeer == peer.value)) else {
                    self.stop()
                    self.onDisconnected?("Match ended: unexpected peer connection.")
                    return
                }
                guard !self.connected else { return }
                self.connected = true
                self.activePeer = peer.value
                self.ingress.authorize(session: current, peer: peer.value)
                self.browser?.stopBrowsingForPeers()
                self.advertiser?.stopAdvertisingPeer()
                self.onConnected?()
            case .notConnected:
                if self.connected, self.activePeer == peer.value {
                    self.connected = false
                    self.ingress.reset()
                    self.onDisconnected?("Peer disconnected. Start another match to play again.")
                } else if self.hosting, self.acceptedPeer == peer.value {
                    self.acceptedPeer = nil
                    self.admission.reset()
                }
            case .connecting: break
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data,
                             fromPeer peerID: MCPeerID) {
        // Decode off the UI actor. Only a bounded, Sendable MatchMessage crosses.
        guard data.count <= 4096, canDecodePacket(from: peerID, in: session),
              let message = try? JSONDecoder().decode(MatchMessage.self, from: data) else { return }
        let sdk = SDKReference(value: session)
        let peer = PeerReference(value: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.session,
                  current === sdk.value,
                  self.connected, self.activePeer == peer.value,
                  current.connectedPeers.count == 1,
                  current.connectedPeers.contains(peer.value) else { return }
            self.onPacket?(message)
        }
    }

    /// p0ng's protocol has only bounded data packets. Streams and resource
    /// transfers are outside the negotiated protocol and must never be accepted
    /// merely because a peer joined an encrypted session.
    nonisolated private func rejectUnexpectedChannel(from source: MCSession) {
        let sdk = SDKReference(value: source)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.session,
                  current === sdk.value else { return }
            self.stop()
            self.onDisconnected?("Match ended: unsupported network channel.")
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
        rejectUnexpectedChannel(from: session)
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
        rejectUnexpectedChannel(from: session)
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        rejectUnexpectedChannel(from: session)
    }
}
