# p0ng — modern iOS

The `main` branch contains the experimental SwiftUI modernization and a Foundation-only Swift 6 `PongCore` package. The original UIKit/XIB/SpriteKit line remains preserved in legacy `master`; this is not yet a production-qualified multiplayer release.

## Run

1. On macOS, use **Xcode 16.4** with Swift 6 and [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0); CI pins both versions.
2. Run `xcodegen generate --spec project.yml` and open `p0ng-modern.xcodeproj`.
3. Use an **iOS Simulator** to validate launch, solo play and the nearby-host menu. Separately run `swift test` from this directory for portable protocol and game tests.
4. **Final manual qualification, deferred until engineering is complete:** sign and install the app on two iOS 17+ devices, grant Local Network permission, host/join/approve, and record results in [VALIDATION.md](VALIDATION.md). This does not block continued work on `main`.

A third choice, **Play against computer**, works without a network.

## Design

- Foundation-only `PongCore` module: normalized deterministic physics, single-writer multiplayer coordinator, JSON Codable wire protocol v2. Linux testable with `swift test`.
- Native SwiftUI presentation: vector retro court, touch paddle, score/round state.
- MultipeerConnectivity LAN transport: encrypted sessions, explicit host approval, two players maximum; host authoritative for ball, scoring, and phase. Reliable protocol-v2 `hello → welcome → ready → start → started` handshake prevents the host from simulating until the guest acknowledges the start. Guest then sends only right-paddle input.
- Host snapshot stream at 30 Hz (unreliable) with reliable phase/score changes. Display-linked rendering interpolates buffered guest snapshots, keeps the local guest paddle responsive, and coalesces input to 30 Hz while sending finger release reliably. Version, match UUID and monotonically increasing sequence numbers reject stale/replayed packets. Payloads limited to 4 KiB.
- Disconnections invalidate the current match. Discovery startup failures return to a retryable menu. Invitation decisions are explicit and idempotent.

## Verification

Run `swift test` for cross-platform protocol and physics tests. See `VALIDATION.md` for the explicit acceptance matrix. Real-device validation is still required for discovery, Bluetooth/Wi-Fi connectivity, background/foreground transitions, orientation changes and reconnection behavior. The iOS app itself cannot be compiled on Linux.

## Deliberate limitations

This integration candidate supports local-area two-player matches, **not internet matchmaking or Game Center**. The host broadcasts authoritative snapshots at 30 Hz; the guest now interpolates render-only positions at the native refresh cadence, and locally predicts then gently reconciles its own paddle. At present the two-player match is all-or-nothing on disconnect. The historical `p0ng.xcodeproj` is not overwritten. Preserve its implementation and assets until device parity is confirmed.

The hosted macOS validation workflow also runs XCTest UI smoke checks in an iOS Simulator (launch, solo mode, exit, menu). Simulator tests cannot establish that MultipeerConnectivity works between physical devices.

## Performance candidate

The modern iOS app uses `CADisplayLink` for native display cadence instead of posting 60 new main-actor tasks per second. The host runs deterministic 60 Hz simulation in bounded catch-up steps. The guest interpolates render-only coordinates with a ~67 ms presentation delay; its own paddle is locally predicted, never used as authoritative ball/score state. Inputs are coalesced to 30 Hz and releases are reliable. These are hypotheses for better smoothness, **not measured improvements**; use two physical devices and compare frame/jitter metrics before claiming performance.

## Accessible input

The court remains draggable and also exposes a VoiceOver adjustable paddle control (swipe up/down). Drag cancellation releases the pending input as a reliable final position, and leaving the match clears discovery state. This is source-level accessibility support; VoiceOver usability still needs device acceptance testing.

## Native release polish

The modern target packages the original 1024px iOS icon and paddle/wall sounds
without modifying legacy resources. Sound effects and UIKit haptics are optional
and default on; toggles persist through native AppStorage. An inbound 120-message/
second decoding budget protects the main UI actor from excessive peer traffic.
Neither the icon's App Store metadata nor in-person audio/haptic behavior is
claimed release-qualified until physical-device verification.

## Swift 6 isolation boundary

The modern iOS targets and portable `PongCore` compile in Swift 6 language mode. `GameTransport` and its UI callbacks are main-actor isolated; MultipeerConnectivity delegate callbacks remain nonisolated, decode bounded packets outside the UI actor, and hand off immutable identities and messages. Lock-protected callback state prevents duplicate invitation replies and packet admission races. Framework peer references are wrapped narrowly at that handoff because the SDK predates Swift Sendable annotations. Display-link cleanup is scheduled on the main queue without experimental compiler flags.
