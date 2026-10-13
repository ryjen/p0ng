import Foundation
import MultipeerConnectivity
import UIKit
import PongCore

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
    func allow(at time: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return window.admit(at: time)
    }
    func reset() {
        lock.lock()
        defer { lock.unlock() }
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
    private var pendingInvitation: (peer: MCPeerID, reply: InvitationReply)?
    private var acceptedPeer: MCPeerID?
    private var selectedPeer: MCPeerID?
    private var activePeer: MCPeerID?
    private var admission = NearbyAdmissionGate()
    private let ingress = LockedPacketIngress()

    nonisolated private func canDecodePacket() -> Bool {
        ingress.allow(at: ProcessInfo.processInfo.systemUptime)
    }

    var onPeersChanged: (@MainActor @Sendable ([NearbyPeer]) -> Void)?
    var onInvitation: (@MainActor @Sendable (String) -> Void)?
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

    func send(_ message: OutgoingMessage) {
        guard connected, let session, let activePeer,
              session.connectedPeers.count == 1,
              session.connectedPeers.contains(activePeer) else { return }
        do {
            let encoded = try JSONEncoder().encode(message.packet)
            guard encoded.count <= 4096 else { return }
            try session.send(encoded, toPeers: [activePeer],
                             with: message.quality == .reliable ? .reliable : .unreliable)
        } catch {
            if message.quality == .reliable {
                // Never continue with apparently healthy game authority when
                // a reliable score/handshake/control message cannot be sent.
                stop()
                onDisconnected?("Match ended: reliable network send failed.")
            } else {
                // Unreliable messages are superseded by the next state/input;
                // a transient send failure must not open a modal SwiftUI alert
                // every frame. Reliable control failures still tear down.
            }
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
        let id = ObjectIdentifier(advertiser)
        let peer = PeerReference(value: peerID)
        let reply = InvitationReply(invitationHandler)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.advertiser,
                  ObjectIdentifier(current) == id,
                  self.hosting, !self.connected, self.acceptedPeer == nil,
                  self.pendingInvitation == nil, self.session != nil,
                  self.admission.offer() else {
                reply.respond(false, session: nil)
                return
            }
            self.pendingInvitation = (peer: peer.value, reply: reply)
            self.onInvitation?(peer.value.displayName)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {
        let id = ObjectIdentifier(advertiser)
        let reason = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.advertiser,
                  ObjectIdentifier(current) == id else { return }
            self.onDiscoveryFailed?(reason)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        let id = ObjectIdentifier(browser)
        let peer = PeerReference(value: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.browser,
                  ObjectIdentifier(current) == id else { return }
            if !self.discovered.contains(peer.value) {
                self.discovered.append(peer.value)
                self.peerTokens[peer.value] = UUID()
            }
            self.onPeersChanged?(self.publishedPeers())
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let id = ObjectIdentifier(browser)
        let peer = PeerReference(value: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.browser,
                  ObjectIdentifier(current) == id else { return }
            self.discovered.removeAll { $0 == peer.value }
            self.peerTokens.removeValue(forKey: peer.value)
            self.onPeersChanged?(self.publishedPeers())
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {
        let id = ObjectIdentifier(browser)
        let reason = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.browser,
                  ObjectIdentifier(current) == id else { return }
            self.onDiscoveryFailed?(reason)
        }
    }

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        let id = ObjectIdentifier(session)
        let peer = PeerReference(value: peerID)
        let stateCode = state.rawValue
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.session,
                  ObjectIdentifier(current) == id,
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
                self.browser?.stopBrowsingForPeers()
                self.advertiser?.stopAdvertisingPeer()
                self.onConnected?()
            case .notConnected:
                if self.connected, self.activePeer == peer.value {
                    self.connected = false
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
        guard data.count <= 4096, canDecodePacket(),
              let message = try? JSONDecoder().decode(MatchMessage.self, from: data) else { return }
        let id = ObjectIdentifier(session)
        let peer = PeerReference(value: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.session,
                  ObjectIdentifier(current) == id,
                  self.connected, self.activePeer == peer.value,
                  current.connectedPeers.count == 1,
                  current.connectedPeers.contains(peer.value) else { return }
            self.onPacket?(message)
        }
    }

    /// p0ng's protocol has only bounded data packets. Streams and resource
    /// transfers are outside the negotiated protocol and must never be accepted
    /// merely because a peer joined an encrypted session.
    nonisolated private func rejectUnexpectedChannel(sessionID: ObjectIdentifier) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.session,
                  ObjectIdentifier(current) == sessionID else { return }
            self.stop()
            self.onDisconnected?("Match ended: unsupported network channel.")
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
        rejectUnexpectedChannel(sessionID: ObjectIdentifier(session))
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
        rejectUnexpectedChannel(sessionID: ObjectIdentifier(session))
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        rejectUnexpectedChannel(sessionID: ObjectIdentifier(session))
    }
}
