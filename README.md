# p0ng

A personal retro Pong experiment in Swift, now with a separate modern iOS implementation.

## Branches and status

- **`main` — modern development:** SwiftUI iOS 17+ app in [`modern/`](modern/README.md), portable `PongCore`, and nearby two-player networking. The original sources remain present for historical comparison.
- **`master` — legacy archive:** preserves the original UIKit/XIB/SpriteKit implementation and its history. No modernization changes should be merged into `master`.

**Maturity:** the modern game is an **experimental integration candidate**, not a production-ready multiplayer release. Automated tests and iOS Simulator validation pass, but discovery, pairing, recovery, and performance have not been qualified on two physical iOS devices. Merging to `main` does not approve a release; the manual work remains in [issue #2](https://github.com/ryjen/p0ng/issues/2) and [issue #4](https://github.com/ryjen/p0ng/issues/4).

## Modern implementation

- **Solo:** play against a computer-controlled paddle.
- **Nearby:** one host and one guest, explicit host consent, encrypted MultipeerConnectivity transport with documented peer-identity limitations.
- **Core:** deterministic normalized physics, host-authoritative state, versioned wire protocol, replay checks, bounded transport inputs, and deterministic tests for lossy or reordered delivery.
- **iOS:** SwiftUI court, CADisplayLink frame pacing, guest render-only smoothing, accessible paddle input, optional sound and haptics.

### Test the portable core

With an appropriate Swift toolchain:

```sh
cd modern
swift test
```

### Build the iOS project

On macOS with Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
cd modern
xcodegen generate --spec project.yml
open p0ng-modern.xcodeproj
```

Two physical iOS devices are still required for LAN validation. See [modern/VALIDATION.md](modern/VALIDATION.md) for the checklist and security boundaries.

## Legacy implementation

The historical app lives in `iOS/`, `macOS/`, `tvOS/`, `shared/` and `p0ng.xcodeproj`. Those assets are retained rather than rewritten. The `master` branch is the permanent reference to the legacy line.

**Scope:** no Game Center online multiplayer, production release, or claim of measured device-to-device performance yet. This is a personal software experiment, not a production game service.
