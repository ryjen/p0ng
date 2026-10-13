import Foundation
import MultipeerConnectivity
import UIKit
import PongCore

/// LAN transport for exactly two players. Intentionally no third-party relay or account.
/// Callbacks are delivered on the main queue for the SwiftUI coordinator.
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
    private var pendingInvitation: (peer: MCPeerID, handler: (Bool, MCSession?) -> Void)?
    private var acceptedPeer: MCPeerID?
    private var selectedPeer: MCPeerID?
    private var activePeer: MCPeerID?
    private var admission = NearbyAdmissionGate()
    private let ingressLock = NSLock()
    private var ingressWindow = PacketIngressWindow()

    /// MCSession delegates are delivered off-main. Limit decoding before
    /// allocating messages and scheduling work onto the UI actor.
    private func canDecodePacket() -> Bool {
        ingressLock.lock()
        defer { ingressLock.unlock() }
        return ingressWindow.admit(at: ProcessInfo.processInfo.systemUptime)
    }

    var onPeersChanged: (([NearbyPeer]) -> Void)?
    var onInvitation: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onPacket: ((MatchMessage) -> Void)?
    var onError: ((String) -> Void)?
    var onDiscoveryFailed: ((String) -> Void)?
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
            pendingInvitation.handler(false, nil)
            return
        }
        if allow { acceptedPeer = pendingInvitation.peer }
        pendingInvitation.handler(allow, allow ? session : nil)
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
                onError?("Realtime network packet dropped.")
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
        pendingInvitation?.handler(false, nil)
        pendingInvitation = nil
        acceptedPeer = nil
        selectedPeer = nil
        activePeer = nil
        admission.reset()
        ingressLock.lock()
        ingressWindow.reset()
        ingressLock.unlock()
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

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.advertiser === advertiser,
                  self.hosting, !self.connected, self.acceptedPeer == nil,
                  self.pendingInvitation == nil, self.session != nil else {
                invitationHandler(false, nil)
                return
            }
            guard self.admission.offer() else {
                invitationHandler(false, nil)
                return
            }
            self.pendingInvitation = (peer: peerID, handler: invitationHandler)
            self.onInvitation?(peerID.displayName)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.advertiser === advertiser else { return }
            self.onDiscoveryFailed?(error.localizedDescription)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.browser === browser else { return }
            if !self.discovered.contains(peerID) {
                self.discovered.append(peerID)
                self.peerTokens[peerID] = UUID()
            }
            self.onPeersChanged?(self.publishedPeers())
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.discovered.removeAll { $0 == peerID }
            self.peerTokens.removeValue(forKey: peerID)
            self.onPeersChanged?(self.publishedPeers())
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.onDiscoveryFailed?(error.localizedDescription)
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session else { return }
            switch state {
            case .connected:
                // The approved peer is the only one allowed to join a host.
                // Any abnormal shutdown also tears down the game's authority.
                guard session.connectedPeers.count == 1,
                      self.hosting
                        ? (self.acceptedPeer == peerID && self.admission.didConnect())
                        : (self.selectedPeer == peerID) else {
                    self.stop()
                    self.onDisconnected?("Match ended: unexpected peer connection.")
                    return
                }
                guard !self.connected else { return } // duplicate callback
                self.connected = true
                self.activePeer = peerID
                self.browser?.stopBrowsingForPeers()
                self.advertiser?.stopAdvertisingPeer()
                self.onConnected?()
            case .notConnected:
                if self.connected, self.activePeer == peerID {
                    self.connected = false
                    self.onDisconnected?("Peer disconnected. Start another match to play again.")
                } else if self.hosting, self.acceptedPeer == peerID {
                    // An accepted invitation failed before connecting; keep hosting.
                    self.acceptedPeer = nil
                    self.admission.reset()
                }
            case .connecting: break
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Reject oversized or unexpected messages before decoding or touching game state.
        guard data.count <= 4096, canDecodePacket(),
              let message = try? JSONDecoder().decode(MatchMessage.self, from: data) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session,
                  self.connected, self.activePeer == peerID,
                  session.connectedPeers.count == 1,
                  session.connectedPeers.contains(peerID) else { return }
            self.onPacket?(message)
        }
    }

    /// p0ng's protocol has only bounded data packets. Streams and resource
    /// transfers are outside the negotiated protocol and must never be accepted
    /// merely because a peer joined an encrypted session.
    private func rejectUnexpectedChannel(from source: MCSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === source else { return }
            self.stop()
            self.onDisconnected?("Match ended: unsupported network channel.")
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
        rejectUnexpectedChannel(from: session)
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
        rejectUnexpectedChannel(from: session)
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        rejectUnexpectedChannel(from: session)
    }
}
