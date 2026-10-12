# Nearby multiplayer performance and native networking — decision record

**Status:** Implementation candidate; **not a final transport adoption decision**.
**Owning work:** [#4 gameplay feel](https://github.com/ryjen/p0ng/issues/4), [#5 Network.framework comparison](https://github.com/ryjen/p0ng/issues/5), [#2 physical device qualification](https://github.com/ryjen/p0ng/issues/2).
**Current support floor:** iOS 17+.

## Consumer outcome

Two phones can pair without accounts or a relay and play Pong with immediate local paddle feedback, smooth animation and identical host-authoritative scores. Connectivity failures stop the match safely. The observer can reproduce before/after latency and frame-time measurements on physical devices.

## Existing evidence

- The 2018 game could suspend updates while awaiting an ACK and used screen-dependent coordinate conversions; the rewrite already separates normalized physics from transport.
- The active candidate uses bounded host 60 Hz fixed steps, `CADisplayLink`-aligned presentation, ~67 ms interpolation delay for received guest state, locally responsive guest paddles with bounded release-time reconciliation, and latest-value 30 Hz input transmission.
- Portable, build and simulator smoke tests show functional correctness for their covered cases. **None measures physical network latency, end-to-end frame smoothness, power use, or near-peer trust.**
- DEBUG-only counters report render frames, unusually long frame gaps, guest snapshots and discarded simulation seconds; they do not capture usernames or message contents. RTT telemetry and distributional p95/p99 measurements remain open.

## Options under consideration

| Option | Benefits | Tradeoffs | Decision |
| --- | --- | --- | --- |
| Keep MultipeerConnectivity as-is | Existing pairing and encryption; easiest physical baseline | Entire framework deprecated by Xcode 27; black-box transport, possible performance variance | Retain only as temporary baseline/integration path |
| Network.framework Bonjour + authenticated TLS | Apple's migration destination, explicit host/listener model, iOS 17+ API surface, peer-to-peer option | Implement certificate/key identity, consent, connection lifecycle and framed messages ourselves | **Preferred migration candidate**, gated by security review and side-by-side physical tests |
| Network.framework QUIC datagrams | Connection-associated best-effort messages can avoid stale-state retransmits | Availability, framing, and trust management need qualification; no latency advantage yet demonstrated | Evaluate *after* reliable control plane is proven |
| SpriteKit rendering | Native per-frame `SKScene.update` and spatial content | Another renderer to maintain; not itself a network fix | Benchmark against display-linked SwiftUI Canvas before choosing |
| GameKit/Game Center | Internet matchmaking and player identity | Accounts, online dependencies, user sign-in | Separate #3; not a nearby-LAN replacement |

Apple's [TN3213: Moving from Multipeer Connectivity to Network framework](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework) was revised July 14, 2026; Apple's [custom peer-to-peer game sample](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol) demonstrates Bonjour and TLS on iOS/iPadOS.

## Migration design and security boundaries

1. Keep `PongCore` independent of any network implementation. Extract peer discovery, accept/decline, send, receive, disconnect and error semantics behind a minimal adapter with protocol-controlled state. Do not expose `MCPeerID` as the cross-transport identity.
2. For iOS 17–25 use `NWBrowser`, `NWListener`, `NWConnection` with Bonjour service discovery and `includePeerToPeer` when available. Keep one host listener and one authorized guest connection.
3. Use authenticated TLS, **not merely encrypted but unverified** TLS. Validate the peer identity and pair with explicit user consent. Deny unidentified, extra, stale or mismatched peers. Design repeatable key rotation and failure recovery before enabling the path.
4. Frame messages with bounded lengths and protocol version/match ID; keep control/phase/score transitions reliable. Adopt low-latency datagrams only after testing authenticated channels and head-of-line behavior.
5. Preserve the existing match-start acknowledgement, error/cancellation handling, maximum two-player count and explicit disconnect semantics. Failing transport cannot leave the coordinator playing.
6. Gate new transport behind an opt-in test mode until physical-device comparison and an independent security review are complete; do not silently substitute it in the release candidate.

## Evidence to collect on two iOS devices

Record device model, OS, available networking interfaces, AP/Wi-Fi topology, app commit, transport mode, network conditions and test duration.

| Metric | Baseline MCSession | Performance candidate | Network.framework spike |
| --- | --- | --- | --- |
| Discovery + successful pairing % | Not measured | Not measured | Not measured |
| Pairing time p50/p95 | Not measured | Not measured | Not measured |
| Input → remote authoritative application p50/p95 | Not measured | Not measured | Not measured |
| Display-frame time and missed frames p50/p95/p99 | Not measured | Not measured | Not measured |
| RTT, jitter, loss and input throughput | Not measured | Not measured | Not measured |
| Pause/reconnect/abort correctness | Not measured | Not measured | Not measured |
| Battery/thermal behavior | Not measured | Not measured | Not measured |

Test normal LAN, peer-to-peer Wi-Fi, 50–150 ms simulated delay, jitter, 1–5% loss, orientation and backgrounding. Preserve raw evidence for honest before/after comparisons.

## Stop/ship rule

No proof of better gameplay without measured two-device data. No deployment of a Network.framework replacement until consent, trust, isolation, cancellation, startup failure and recovery are verified. The current PR remains a draft and the legacy game remains intact.
