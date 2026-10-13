# p0ng

A legacy multiplayer Pong experiment for iOS, currently undergoing a SwiftUI modernization.

## Status

The default `master` branch preserves the historical experiment; **the newer multiplayer implementation is proposed in [PR #1](https://github.com/ryjen/p0ng/pull/1)**. It is not a released, independently device-qualified multiplayer game. Do not infer completed low-latency LAN performance or physical-device compatibility from the proposed design alone.

## Modernization direction

- SwiftUI presentation and native iOS networking.
- Host-authoritative LAN gameplay to avoid divergent game state.
- Explicit connection, failure, lifecycle, and recovery behavior.
- Deterministic game-state and network-protocol tests, supplemented by representative two-device latency and reconnect tests.

Once the implementation is merged, update this document against the verified source and CI/device evidence rather than treating proposed features as complete.

This repository is a personal game experiment, not a production game service.
