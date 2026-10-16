# Swift/Nix development toolchain — candidate

**Status:** Draft / not qualified. This does not change the existing CI or authorize the
`runner-p0ng` selector. Tracked by [p0ng #25](https://github.com/ryjen/p0ng/issues/25).

The production CI baseline currently runs portable tests under Swift **6.2.1** from
`swift:6.2.1-noble` on GitHub-hosted Ubuntu. The **candidate** flake pins the
Nixpkgs source commit `3083577807ab374ec345b338b319349da443e68d` and its NAR digest, which declares Swift **6.2.4**
at `pkgs/top-level/swift-packages.nix`. The `flake.nix` assertion prevents an
implicit toolchain version change. This is a **deliberate patch-version trial**,
not evidence of compatibility or a signed-device release.

## Qualification (on an approved, isolated Nix-capable runner)

```sh
nix flake check --no-write-lock-file
nix develop --command swift --version
nix develop --command swift test --package-path modern -j 2 -Xswiftc -strict-concurrency=complete
```

Accept only after the complete existing portable test suite passes under the exact
locked compiler and the environment meets the same reproducibility and memory-budget
constraints as other Dubnium flake-owned CI. Do not run public fork PR code on a
self-hosted runner before the protected trust/fork admission checks are proven.
A dedicated iOS/macOS environment must continue to use an explicitly reviewed Xcode
toolchain; the Linux flake does **not** build or qualify an iOS app.

The `flake.lock` NAR digest is sourced from a pinned public Nixpkgs master lock
entry rather than generated on this execution host. It must be independently
verified by Nix before this PR can be merged. No local Nix execution or Swift 6.2.4
test success is claimed yet.
