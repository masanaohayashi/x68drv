# x68drv

Mount X68000 emulator disk images (`.xdf` / `.hds` / `.hdf`) on macOS and open them in **Finder** (read-only for v0.1).

Design and research notes live in [`docs/`](docs/README.md).

## Requirements

- macOS 13+
- Xcode 15+ (developed with Xcode 16/26)
- **FUSE-T** for Finder mount (product path; later phases). Core parsing does not need FUSE.

## Open in Xcode

```bash
open x68drv.xcodeproj
```

- App target: **x68drv**
- Library: local Swift package **X68Core** (same repo root `Package.swift`)

## Build & test

```bash
# Unit tests (X68Core)
swift test

# Dev CLI (list / export / fsck / detect)
swift run x68drv-tool list path/to/disk.xdf
swift run x68drv-tool fsck path/to/disk.hds

# App
xcodebuild -project x68drv.xcodeproj -scheme x68drv -configuration Debug -destination 'platform=macOS' build
```

## Layout

```text
x68drv.xcodeproj/     # macOS app
Package.swift         # X68Core library + tests
Sources/X68Core/      # format / FS (to be implemented)
Tests/X68CoreTests/
Apps/x68drv/          # SwiftUI app shell (settings + menu bar skeleton)
docs/                 # design, research, implementation plan
```

## Mount modes (dual backend)

| FUSE-T / macFUSE | Behavior |
|------------------|----------|
| **Installed** | Live RO FUSE volume via bundled `x68mount-helper` (Finder shows volume name = image file; mountpoint under `~/Library/Application Support/x68drv/Volumes/`) |
| **Not installed** | Temporary **snapshot folder** under Application Support (still works for copy-out) |

Xcode builds embed `x68mount-helper` into `x68drv.app/Contents/Helpers/`. FUSE-T is loaded at runtime from `/Library/Frameworks/fuse_t.framework`.

```bash
# Build the FUSE helper alone (optional; Xcode Run does this)
swift build --product x68mount-helper

# Optional CLI mount test
swift run x68drv-tool mount path/to/disk.xdf
```

Install FUSE-T: https://www.fuse-t.org/  
(or `brew install macos-fuse-t/cask/fuse-t` — needs admin password)

**Note:** FUSE-T uses NFS under the hood. Terminal `ls` may need **System Settings → Privacy & Security → Files and Folders → Network Volumes**. Finder usually works without that.

## Distribution (Hardened Runtime + notarization)

**Not** App Sandbox / Mac App Store. Ship with Developer ID + Apple notarization + GitHub Release.

```bash
# One-time notary profile + gh auth — see docs/distribution.md
./scripts/release.sh --version 0.1.0
```

That builds Release, signs with Hardened Runtime, notarizes, zips, and uploads to [GitHub Releases](https://github.com/masanaohayashi/x68drv/releases).

- Entitlements: `Apps/x68drv/x68drv.entitlements` (app), `x68mount-helper.entitlements` (helper)
- Only special entitlement: `disable-library-validation` (load system FUSE-T framework)
- Guide: [`docs/distribution.md`](docs/distribution.md)

See also [`docs/implementation-plan.md`](docs/implementation-plan.md).

## License

MIT — see [LICENSE](LICENSE).
