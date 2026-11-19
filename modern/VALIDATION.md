# p0ng modernization: release qualification

This is an integration candidate. Automated qualification covers portable game logic, native coordinator behavior, and four hosted iOS Simulator UI smoke cases including rotation. It does **not** establish nearby peer discovery or actual multiplayer responsiveness. Two physical devices and baseline/comparison performance measurements remain required before release.

## Latest integrated evidence (2026-11-18)

- [PR #43](https://github.com/ryjen/p0ng/pull/43) at `156e97aabd063df9a57b4bb97e520b114bda3dfe`, synthetic merge into `645f4d8b`: [hosted CI 44419425549](https://github.com/ryjen/p0ng/actions/runs/44419425549) **63/63 portable, 17/17 native, 4/4 UI**. Zero failures. This is evidence for that exact application source, not for future commits or a signed artifact.
- [Niobium run 44404847337](https://github.com/ryjen/p0ng/actions/runs/44404847337) checked out #36 `2612feee876daf37c346ef89529dd83d58d9934f` and passed Xcode 26.3 unsigned Simulator build, 15 coordinator and 3 UI tests. This is not qualification of the full #43 integration on Niobium.
- The release-preparation change following #43 adds a bundled privacy manifest and resource test; its own qualification is required.

## Release packaging and owner decisions

- [ ] Confirm distribution rights and source licensing intent. The repository has no explicit LICENSE in the inspected tree. The original WAVs and most icons match legacy Git blobs; this proves provenance within the repository, not redistribution rights. Preserve legacy master and existing assets until signed-device parity is established.
- [ ] Confirm final bundle identifier, signing team, marketing version and unique build number (current plist: `com.micrantha.p0ng.modern` via build setting, version `1.0`, build `1`). Do not change registration or signing identities without owner approval.
- [ ] Inspect `PrivacyInfo.xcprivacy` in the archived app and generate the Xcode Organizer privacy report. Source review identified app-only `UserDefaults`/`AppStorage` (`CA92.1`) and elapsed-time use of `ProcessInfo.systemUptime`/`CACurrentMediaTime` (`35F9.1`). No timestamps from uptime are sent to peers. Current first-party source has no analytics or tracking backend; validate actual archive and privacy answers separately. [Apple required reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- [ ] Verify current App Store Connect SDK submission requirements, privacy answers, export-compliance classification (including MCSession encryption), icon, screenshots, and signed-device acceptance. No TestFlight upload or production release without approval.
- [ ] Record archive revision, toolchain, signing identity (nonsecret reference), device models/iOS, acceptance outcomes, and independent review before requesting release approval.

## Build gates

- [x] Modern `main` at `2dceae86` after PRs #19–#22: **51/51 portable Swift tests**, **15/15 native coordinator/unit tests**, and **3/3 iOS Simulator UI smoke tests** passed on [PR #22 exact-head CI](https://github.com/ryjen/p0ng/actions/runs/38819580633). These counts come from the completed workflow job logs; subsequent development heads require their own exact-head verification. This remains an integration candidate, not a signed/device-qualified release.
- [x] Swift syntax parse and YAML parse
- [x] `xcodegen generate` on GitHub-hosted macOS (workflow [p0ng validation](https://github.com/ryjen/p0ng/actions/workflows/pong-core.yml))
- [x] iOS Simulator build on macOS (same workflow; unsigned Debug build)
- [x] Swift 6 complete-concurrency checks and language mode are enforced in portable and native builds. Legacy MultipeerConnectivity delegate handoffs use main-actor isolation with bounded locked ingress and invitation-response state.
- [ ] Two physical-device LAN tests with recorded iOS versions, peer approval, genuine network jitter/loss, and failure recovery.
- [ ] Xcode build on two physical devices (iOS 17+)
- [ ] Two-device LAN gameplay qualification
- [ ] Test VoiceOver adjustable paddle input, the newly combined scoreboard announcement (player role and both scoring sides, [PR #21](https://github.com/ryjen/p0ng/pull/21)), interrupted drags, accessibility contrast, inactive interruption and foreground recovery on actual iOS devices.
- [ ] At the **final physical-device acceptance stage**, capture DEBUG frame-gap p50/p95/p99, guest snapshot-gap p50/p95/p99, snapshot variation p95 and accepted-sequence gaps. Compare pre/post smoothing of ball and paddle on real devices. The snapshot metrics measure **arrival cadence**, not RTT, measured packet loss, or touch-to-visible latency. Source-level measurement code is verified in CI, but gameplay quality is not.

## Pre-device source-level follow-ups

- [x] [PR #19](https://github.com/ryjen/p0ng/pull/19) returns a typed result for stale discovery tokens instead of leaving the guest in a connection attempt for an invitation that never started; two native coordinator regressions.
- [x] [PR #20](https://github.com/ryjen/p0ng/pull/20) names fixed-step catch-up limits and adds deterministic 30/60/90/120Hz and variable-cadence portable tests; these are simulation invariants, not device performance measurements.
- [x] [PR #21](https://github.com/ryjen/p0ng/pull/21) combines player role and left/right scores into a labeled VoiceOver scoreboard element; iOS Simulator UI test added.
- [x] [PR #22](https://github.com/ryjen/p0ng/pull/22) routes the replay action using the typed match role instead of parsing display labels, with a native coordinator regression.
- [ ] Two-device pairing, VoiceOver ergonomics, real frame timing/RTT and game feel remain unverified until the release gate.

## Diagnostics interpretation

PR #17 adds bounded, five-second aggregate DEBUG telemetry: frame and guest snapshot-gap percentiles, guest snapshot interval variation and accepted-sequence gaps. Deliberate snapshot coalescing, old-message rejection, and network reordering can all create sequence gaps. **Do not interpret those gaps as measured packet loss**, or interarrival variation as true one-way latency/RTT. No peer identifiers or raw game packets are logged. These counters are available for later signed-device A/B testing; simulator success alone cannot qualify play feel.

## Device acceptance matrix

1. Install on two devices on the same LAN; accept Local Network permission. Verify host appears in guest's discovered list.
2. Guest selects host; host must explicitly accept. Verify protocol-v2 `hello → welcome → ready → start → started` handshake, with late callback delivery, rejection, retries, message loss and duplicate packets. Host simulation must remain stopped until `started` is acknowledged. Reject then retry, and verify rejection does not start a game.
3. Verify host controls **left**, guest controls **right**; both screens show the same left/right positions, scores, serves, and final winner. Solo mode must retain right-hand computer paddle. Verify the VoiceOver scoreboard announces the appropriate player role and both side scores as they change.
4. Verify rapid dragging, paddle edge clamping, serves, scoring, and game-over on both devices.
5. Disconnect host and guest separately, change Wi-Fi networks, background the app, and disable networking; verify the game does not continue with stale authority. A new match must require a new invitation.
6. Test iPhone/iPad mixed screen sizes and portrait/landscape, ensuring normalized court coordinates and input still agree.
7. Test slow/lossy networks using Network Link Conditioner, especially phase transitions and stale-snapshot rejection. Measure snapshot jitter and dropped inputs.
8. Verify protocol mismatch rejects the peer's messages, and invalid/oversized wire messages do not crash or alter game state. Verify discovery startup failure returns to retryable menu, a single alert destination handles both invitations and network errors, and alert acceptance cannot be consumed by automatic dismissal. Verify multiple simultaneous invitations admit at most one peer; an **unanswered invitation expires before the guest's 20-second timeout**, releasing its slot and clearing the alert; accepted matches must not be expired. Verify a failed reliable score/control send terminates the match instead of continuing with divergent authority. Abnormal session termination must reset game state, and callbacks queued before rehosting cannot authorize a new session.

## Security/operational notes

- MCSession encryption is required but peer display names are not authenticated identities. Host approval is a consent gate, not cryptographic identity proof. This is sufficient for casual local play, not adversarial internet matchmaking.
- Active MCSession traffic is restricted to the accepted peer; an inconsistent active peer topology, oversize reliable control message, failed reliable send, or unexpected stream/resource channel terminates the session. Unanswered host invitations have token-scoped 18-second expiry so a stale request cannot monopolize admission. Received payloads are capped at 4 KiB and 120 packets/second before JSON decode. Host is sole authority. Future Network.framework framed stream helpers do not authenticate or encrypt, and GameKit is not enabled.
- The application deliberately does not advertise while a match is active.
- Packet sequence and match UUID reject stale or duplicate packets but do not implement a reconnect/resume token. Disconnect means a new match.
- Do not deploy a relay, cloud backend, Game Center entitlement, or analytics service for the LAN slice.

## Follow-on items (do not block initial LAN qualification)

- Tune the implemented 67 ms render-only jitter buffer against physical-device RTT and screen recordings; compare with SpriteKit only if measurements show a rendering bottleneck.
- Verify implemented sounds, haptics, adjustable VoiceOver input and icon in signed physical builds; assess match length and settings UX separately.
- Expand the current deterministic peer fault harness to cover native transport failure injection and actual connection-admission interactions.
- Internet matchmaking (e.g. modern GameKit) through a second `Transport` implementation without changing the core protocol.
- macOS and tvOS targets once iOS device evidence is collected. The legacy project remains available for behavior comparison.
