# p0ng

A retro Pong game in Swift, originally built for iOS with experimental macOS/tvOS support.

## Modernization candidate

A new **SwiftUI iOS app** lives in [`modern/`](modern/README.md). The original UIKit/XIB/SpriteKit app and assets remain preserved for comparison.

- **Solo:** play against a local computer opponent.
- **Nearby two-player:** one host and one guest, using encrypted MultipeerConnectivity sessions and explicit host approval.
- **Architecture:** Foundation-only physics and protocol core, normalized coordinates, single-writer host-authoritative game state, versioned messages and replay rejection.

### Test the portable core

With a compatible Swift toolchain:

```sh
cd modern
swift test
```

### Generate the new iOS Xcode project

On macOS, install Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen), then:

```sh
cd modern
xcodegen generate --spec project.yml
open p0ng-modern.xcodeproj
```

Install on two physical iOS devices for multiplayer qualification.

**Release status:** candidate; portable tests do not prove that device-to-device multiplayer works. See the [validation checklist](modern/VALIDATION.md) for outstanding Xcode and physical-device gates.

## Original implementation

The historical app lives in `iOS/`, `macOS/`, `tvOS/`, `shared/` and `p0ng.xcodeproj`. It is intentionally unchanged. The modernization currently targets **iOS 17+** and LAN multiplayer, not internet matchmaking or Game Center.

