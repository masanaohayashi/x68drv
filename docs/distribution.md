# Distribution: Hardened Runtime + Notarization

x68drv is **not** App Sandbox / Mac App Store. Product path is:

1. **Hardened Runtime** on the `.app` and bundled `x68mount-helper`
2. **Developer ID** code signature
3. **Apple notarization** + staple
4. Direct download (zip / dmg)

This matches FUSE-T (system framework `dlopen`, live volumes, helper process).

## Prerequisites

- Apple Developer Program membership
- Certificate: **Developer ID Application** (not “Apple Development”)
- Xcode 15+ and `notarytool` (ships with Xcode)
- One-time notary credentials, e.g. app-specific password:

```bash
xcrun notarytool store-credentials "x68drv-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

## Build (Release)

```bash
# From repo root
xcodebuild -project x68drv.xcodeproj \
  -scheme x68drv \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  DEVELOPMENT_TEAM=TEAMID \
  build
```

App output (typical):

```text
build/DerivedData/Build/Products/Release/x68drv.app
```

Confirm helper is embedded:

```bash
ls -la …/x68drv.app/Contents/Helpers/x68mount-helper
```

## Sign (inside-out)

Prefer the helper script:

```bash
./scripts/sign-and-notarize.sh \
  --app build/DerivedData/Build/Products/Release/x68drv.app \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile x68drv-notary
```

Manual equivalent (order matters):

```bash
APP=…/x68drv.app
ID="Developer ID Application: Your Name (TEAMID)"
ENT_APP=Apps/x68drv/x68drv.entitlements
ENT_HELP=Apps/x68drv/x68mount-helper.entitlements

# 1) Helper first
codesign --force --options runtime --timestamp \
  --entitlements "$ENT_HELP" \
  --sign "$ID" \
  "$APP/Contents/Helpers/x68mount-helper"

# 2) App bundle
codesign --force --options runtime --timestamp \
  --entitlements "$ENT_APP" \
  --sign "$ID" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vv "$APP"   # may fail until notarized
```

### Entitlements (minimal)

| Key | Why |
|-----|-----|
| `com.apple.security.cs.disable-library-validation` | Load FUSE-T / macFUSE signed by another team |

**No** App Sandbox keys. Do not enable App Sandbox for this product.

## Notarize + staple

```bash
# Zip for upload (preserve symlinks)
ditto -c -k --keepParent "$APP" /tmp/x68drv.zip

xcrun notarytool submit /tmp/x68drv.zip \
  --keychain-profile "x68drv-notary" \
  --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"
```

Ship a **new zip/dmg of the stapled app** (not the pre-staple zip).

## Local Debug vs Release

| | Debug (Xcode Run) | Release (ship) |
|--|-------------------|----------------|
| Identity | Automatic / Sign to Run Locally | Developer ID Application |
| Hardened Runtime | ON (may be relaxed with ad-hoc) | ON + `--options runtime` |
| Notarization | Not required | Required for Gatekeeper on other Macs |

## Gatekeeper checklist

On a clean Mac (or VM):

1. Install FUSE-T if testing live mount
2. Download stapled zip, unzip, open `x68drv.app`
3. No “damaged / unidentified developer” block
4. Double-click a `.xdf` → Finder volume or snapshot folder
5. Quit → no leftover mounts under Application Support (orphan reclaim)

## Out of scope

- Mac App Store
- App Sandbox
- Kernel extensions
