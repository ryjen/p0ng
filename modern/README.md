# p0ng — modernization branch

This is a standalone, modern iOS version of the original retro Pong game. The archived UIKit/XIB/SpriteKit implementation remains untouched in the original checkout for comparison.

## Run

1. On macOS, install Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Run `xcodegen generate --spec project.yml` and open `p0ng-modern.xcodeproj`.
3. Select a development team for the iOS target and install on **two physical iOS devices**.
4. On the first device select **Host nearby match**. On the second select **Join nearby match**, tap the host, and approve the invitation on the host.
5. Grant Local Network permissions on both devices. Move the paddles by dragging vertically within the court.

A third choice, **Play against computer**, works without a network.

## Design

- Foundation-only `PongCore` module: normalized deterministic physics, single-writer multiplayer coordinator, JSON Codable wire protocol v2. Linux testable with `swift test`.
- Native SwiftUI presentation: vector retro court, touch paddle, score/round state.
- MultipeerConnectivity LAN transport: encrypted sessions, explicit host approval, two players maximum; host authoritative for ball, scoring, and phase. Guest sends a reliable hello after connecting; host replies with a reliable welcome before simulation begins. Guest then sends only right-paddle input.
- Host snapshot stream at 30 Hz (unreliable) with reliable phase/score changes. Version, match UUID and monotonically increasing sequence numbers reject stale/replayed packets. Payloads limited to 4 KiB.
- Disconnections invalidate the current match. Discovery startup failures return to a retryable menu. Invitation decisions are explicit and idempotent.

## Verification

Run `swift test` for cross-platform protocol and physics tests. See `VALIDATION.md` for the explicit acceptance matrix. Real-device validation is still required for discovery, Bluetooth/Wi-Fi connectivity, background/foreground transitions, orientation changes and reconnection behavior. The iOS app itself cannot be compiled on Linux.

## Deliberate limitations

This initial delivery supports local-area two-player matches, **not internet matchmaking or Game Center**. The guest displays authoritative snapshots at 30 Hz; interpolation/latency smoothing is a follow-up. At present the two-player match is all-or-nothing on disconnect. The historical `p0ng.xcodeproj` is not overwritten. Preserve its implementation and assets until device parity is confirmed.

The hosted macOS validation workflow also runs XCTest UI smoke checks in an iOS Simulator (launch, solo mode, exit, menu). Simulator tests cannot establish that MultipeerConnectivity works between physical devices.
