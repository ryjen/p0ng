# Optional GameKit multiplayer — decision and gate

Status: **Design and portable host-election tests only**. No live GameKit adapter, login UI or entitlement has been enabled.
Owner: https://github.com/ryjen/p0ng/issues/3
Prerequisite: physical LAN interoperability and gameplay quality (issues #2 and #4).

1. Authenticate GKLocalPlayer and respect restrictions. Request exactly two players using GKMatchmaker/system matchmaking UI.
2. Confirm one authenticated remote player; both independently elect the same host from stable opaque Game Center gamePlayerID values (never aliases or callback order). Portable OnlineHostElection enforces fail-closed invalid/duplicate IDs.
3. Adapt GKMatch behind GameTransport. Reliable messages carry v2 hello/welcome/ready/start/started, phase and score; unreliable is reserved for replaceable position packets. Preserve the single-writer authoritative coordinator.
4. Check actual sender membership, match ID, version, sequence and packet-size limits. Terminate on failed controls, unexpected players, disconnects or backgrounding. No custom relay.
5. Never log raw Game Center player IDs or store social data. Offline LAN/solo must remain independent of Game Center.

Human action: configure Apple Developer Game Center entitlement/signing and two test identities. Test across two networks on real iOS devices with p50/p95 latency/jitter and recovery evidence. Obtain independent security and release approval before activation.

Sources:
- https://developer.apple.com/documentation/gamekit/authenticating-a-player
- https://developer.apple.com/documentation/gamekit/gkmatchmaker
- https://developer.apple.com/documentation/gamekit/exchanging-data-between-players-in-real-time-games
