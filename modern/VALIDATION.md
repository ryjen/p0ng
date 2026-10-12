# p0ng modernization: release qualification

This is an integration candidate. The Foundation game engine passes portable tests and two native iOS Simulator XCTest UI smoke cases pass on GitHub-hosted macOS. This verifies launch/solo/menu behavior, **not** nearby peer discovery or actual multiplayer responsiveness. Two physical devices and baseline/comparison performance measurements remain required before release.

## Build gates

- [x] 26 portable XCTest cases passed for game physics, handshake, pacing, input coalescing, interpolation, and paddle reconciliation ([performance candidate CI](https://github.com/ryjen/p0ng/actions/runs/38219041864))
- [x] Swift syntax parse and YAML parse
- [x] `xcodegen generate` on GitHub-hosted macOS (workflow [p0ng validation](https://github.com/ryjen/p0ng/actions/workflows/pong-core.yml))
- [x] iOS Simulator build on macOS (same workflow; unsigned Debug build)
- [x] Hosted iOS Simulator XCTest smoke passed (2 cases: launch/solo/exit and nearby-menu visibility) in the same workflow run
- [ ] Xcode build on two physical devices (iOS 17+)
- [ ] Two-device LAN gameplay qualification
- [ ] Test VoiceOver adjustable paddle input, interrupted drags, and accessibility contrast on actual iOS devices.
- [ ] Measure rendering frame gaps and authoritative catch-up on real devices; compare pre/post smoothing for guest ball and local paddle. CI cannot demonstrate measured responsiveness.

## Device acceptance matrix

1. Install on two devices on the same LAN; accept Local Network permission. Verify host appears in guest's discovered list.
2. Guest selects host; host must explicitly accept. Verify protocol-v2 `hello → welcome → ready → start → started` handshake, with late callback delivery, rejection, retries, message loss and duplicate packets. Host simulation must remain stopped until `started` is acknowledged. Reject then retry, and verify rejection does not start a game.
3. Verify host controls **left**, guest controls **right**; both screens show the same left/right positions, scores, serves, and final winner. Solo mode must retain right-hand computer paddle.
4. Verify rapid dragging, paddle edge clamping, serves, scoring, and game-over on both devices.
5. Disconnect host and guest separately, change Wi-Fi networks, background the app, and disable networking; verify the game does not continue with stale authority. A new match must require a new invitation.
6. Test iPhone/iPad mixed screen sizes and portrait/landscape, ensuring normalized court coordinates and input still agree.
7. Test slow/lossy networks using Network Link Conditioner, especially phase transitions and stale-snapshot rejection. Measure snapshot jitter and dropped inputs.
8. Verify protocol mismatch rejects the peer's messages, and invalid/oversized wire messages do not crash or alter game state. Verify discovery startup failure returns to retryable menu, a single alert destination handles both invitations and network errors, and alert acceptance cannot be consumed by automatic dismissal. Verify multiple simultaneous invitations admit at most one peer, abnormal session termination resets game state, and callbacks queued before rehosting cannot authorize a new session.

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
