# p0ng modernization: release qualification

This is a candidate implementation. The Foundation game engine is verified with `swift test` on Linux. The SwiftUI app and Apple MultipeerConnectivity delegate lifecycle require macOS/Xcode and physical devices for verification before release.

## Build gates

- [x] Portable engine, protocol, and role-isolation tests (`swift test`)
- [x] Swift syntax parse and YAML parse
- [ ] `xcodegen generate` on macOS
- [ ] Xcode build and simulator smoke test
- [ ] Xcode build on two physical devices (iOS 17+)
- [ ] Two-device LAN gameplay qualification

## Device acceptance matrix

1. Install on two devices on the same LAN; accept Local Network permission. Verify host appears in guest's discovered list.
2. Guest selects host; host must explicitly accept. Verify guest-initiated hello/welcome handshake, including delayed session-ready callbacks. Reject then retry, and verify rejection does not start a game.
3. Verify host controls **left**, guest controls **right**; both screens show the same left/right positions, scores, serves, and final winner. Solo mode must retain right-hand computer paddle.
4. Verify rapid dragging, paddle edge clamping, serves, scoring, and game-over on both devices.
5. Disconnect host and guest separately, change Wi-Fi networks, background the app, and disable networking; verify the game does not continue with stale authority. A new match must require a new invitation.
6. Test iPhone/iPad mixed screen sizes and portrait/landscape, ensuring normalized court coordinates and input still agree.
7. Test slow/lossy networks using Network Link Conditioner, especially phase transitions and stale-snapshot rejection. Measure snapshot jitter and dropped inputs.
8. Verify protocol mismatch rejects the peer's messages, and invalid/oversized wire messages do not crash or alter game state.

## Security/operational notes

- MCSession encryption is required but peer display names are not authenticated identities. Host approval is a consent gate, not cryptographic identity proof. This is sufficient for casual local play, not adversarial internet matchmaking.
- Every received wire payload is capped at 4 KiB; guest cannot write game ball, scores, or phase. The host is the sole authority.
- The application deliberately does not advertise while a match is active.
- Packet sequence and match UUID reject stale or duplicate packets but do not implement a reconnect/resume token. Disconnect means a new match.
- Do not deploy a relay, cloud backend, Game Center entitlement, or analytics service for the LAN slice.

## Follow-on items (do not block initial LAN qualification)

- Network interpolation and jitter buffer, independent of authoritative scoring.
- UI polish, sound/haptics, accessibility controls, settings, match length, and deterministic replay harness.
- Internet matchmaking (e.g. modern GameKit) through a second `Transport` implementation without changing the core protocol.
- macOS and tvOS targets once iOS device evidence is collected. The legacy project remains available for behavior comparison.
