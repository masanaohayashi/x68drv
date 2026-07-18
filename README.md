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

## Status

Core can read **XDF / DIM / HDS**. The app mounts images by exporting a **temporary read-only folder** under Application Support and opening it in Finder (works without FUSE-T). Live FUSE is planned once FUSE-T + helper are available.

See [`docs/implementation-plan.md`](docs/implementation-plan.md).

## License

MIT — see [LICENSE](LICENSE).
