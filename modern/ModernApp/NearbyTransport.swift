import Foundation
import MultipeerConnectivity
import UIKit
import PongCore

/// LAN transport for exactly two players. Intentionally no third-party relay or account.
/// Callbacks are delivered on the main queue for the SwiftUI coordinator.
final class NearbyTransport: NSObject, MCNearbyServiceAdvertiserDelegate,
                             MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    private static let service = "p0ng-lan"
    // Avoid advertising the owner's device name (often personally identifying).
    private let localPeer = MCPeerID(displayName: "p0ng-" + String(UUID().uuidString.prefix(6)))
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private(set) var hosting = false
    private(set) var connected = false
    private var pendingInvitation: ((Bool, MCSession?) -> Void)?

    var onPeersChanged: (([MCPeerID]) -> Void)?
    var onInvitation: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onPacket: ((MatchMessage) -> Void)?
    var onError: ((String) -> Void)?
    var onDiscoveryFailed: ((String) -> Void)?
    private var discovered: [MCPeerID] = []

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

    func join(_ peer: MCPeerID) {
        guard !hosting, !connected, discovered.contains(peer),
              let browser, let session else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    func decideInvitation(accept: Bool) {
        guard let pendingInvitation else { return }
        self.pendingInvitation = nil
        pendingInvitation(accept, accept ? session : nil)
    }

    func send(_ message: OutgoingMessage) {
        guard connected, let session, !session.connectedPeers.isEmpty else { return }
        do {
            let encoded = try JSONEncoder().encode(message.packet)
            guard encoded.count <= 4096 else { return }
            try session.send(encoded, toPeers: session.connectedPeers,
                             with: message.quality == .reliable ? .reliable : .unreliable)
        } catch {
            onError?("Network send failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        pendingInvitation?(false, nil)
        pendingInvitation = nil
        session?.disconnect()
        session?.delegate = nil
        session = nil
        hosting = false
        connected = false
        discovered = []
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
            guard let self, self.hosting, !self.connected,
                  self.pendingInvitation == nil, self.session != nil else {
                invitationHandler(false, nil)
                return
            }
            self.pendingInvitation = invitationHandler
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
            if !self.discovered.contains(peerID) { self.discovered.append(peerID) }
            self.onPeersChanged?(self.discovered)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.discovered.removeAll { $0 == peerID }
            self.onPeersChanged?(self.discovered)
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
                // Reject any extraneous peers: game protocol supports one remote player.
                guard session.connectedPeers.count == 1 else {
                    self.stop()
                    self.onError?("Only two-player matches are supported")
                    return
                }
                self.connected = true
                self.browser?.stopBrowsingForPeers()
                self.advertiser?.stopAdvertisingPeer()
                self.onConnected?()
            case .notConnected:
                if self.connected {
                    self.connected = false
                    self.onDisconnected?()
                }
            case .connecting: break
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Reject oversized or unexpected messages before decoding or touching game state.
        guard data.count <= 4096, let message = try? JSONDecoder().decode(MatchMessage.self, from: data) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session,
                  self.connected, session.connectedPeers.contains(peerID) else { return }
            self.onPacket?(message)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
