#!/usr/bin/env bash
# Build Release x68drv.app → sign → notarize → zip → GitHub Release.
#
# Prerequisites:
#   - Developer ID Application cert in login keychain
#   - notarytool profile (one-time):
#       xcrun notarytool store-credentials "x68drv-notary" \
#         --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"
#   - gh auth login (repo scope)
#
# Usage:
#   ./scripts/release.sh --version 0.1.0
#   ./scripts/release.sh --version 0.1.0 --draft
#   ./scripts/release.sh --version 0.1.0 --skip-notarize   # sign+zip only (dev)
#   ./scripts/release.sh --version 0.1.0 --skip-github     # build/sign/zip only
#
# Env overrides:
#   DEVELOPER_ID   Developer ID Application identity string
#   DEVELOPMENT_TEAM  Team ID
#   NOTARY_PROFILE    notarytool keychain profile (default: x68drv-notary)
#
# See docs/distribution.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=""
DRAFT=0
SKIP_NOTARIZE=0
SKIP_GITHUB=0
IDENTITY="${DEVELOPER_ID:-Developer ID Application: Masanao Hayashi (P5G28RMWUN)}"
TEAM_ID="${DEVELOPMENT_TEAM:-P5G28RMWUN}"
NOTARY_PROFILE="${NOTARY_PROFILE:-x68drv-notary}"
DERIVED="${ROOT}/build/ReleaseDerivedData"
DIST="${ROOT}/build/dist"
REPO="${GITHUB_REPOSITORY:-masanaohayashi/x68drv}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v) VERSION="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --team) TEAM_ID="${2:-}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    --draft) DRAFT=1; shift ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --skip-github) SKIP_GITHUB=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "error: --version is required (e.g. --version 0.1.0)" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
  echo "error: version should look like 0.1.0 (got: $VERSION)" >&2
  exit 2
fi

TAG="v${VERSION}"
ZIP_NAME="x68drv-${VERSION}-macos.zip"
APP_NAME="x68drv.app"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}
need xcodebuild
need codesign
need ditto
need gh
need xcrun

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool profile '$NOTARY_PROFILE' not found." >&2
    echo "" >&2
    echo "Create it once (Apple ID app-specific password):" >&2
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
    echo "    --apple-id \"you@example.com\" \\" >&2
    echo "    --team-id \"$TEAM_ID\" \\" >&2
    echo "    --password \"app-specific-password\"" >&2
    echo "" >&2
    echo "Or pass --skip-notarize for a local signed-only zip." >&2
    exit 1
  fi
fi

echo "==> Version $VERSION  tag $TAG"
echo "    identity: $IDENTITY"
echo "    team:     $TEAM_ID"

# --- Build ---
echo "==> xcodebuild Release"
rm -rf "$DERIVED"
mkdir -p "$DIST"

xcodebuild \
  -project x68drv.xcodeproj \
  -scheme x68drv \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build

APP="$DERIVED/Build/Products/Release/$APP_NAME"
if [[ ! -d "$APP" ]]; then
  echo "error: build did not produce $APP" >&2
  exit 1
fi
if [[ ! -x "$APP/Contents/Helpers/x68mount-helper" ]]; then
  echo "error: x68mount-helper missing from app bundle" >&2
  exit 1
fi
echo "    app: $APP"

# --- Sign / notarize ---
SIGN_ARGS=(--app "$APP" --identity "$IDENTITY")
if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  SIGN_ARGS+=(--skip-notarize)
else
  SIGN_ARGS+=(--notary-profile "$NOTARY_PROFILE")
fi
echo "==> sign-and-notarize"
"$ROOT/scripts/sign-and-notarize.sh" "${SIGN_ARGS[@]}"

# --- Zip stapled app ---
ZIP_PATH="$DIST/$ZIP_NAME"
echo "==> Zip → $ZIP_PATH"
rm -f "$ZIP_PATH"
# Ship only the .app inside the zip (Finder double-click friendly)
(
  cd "$(dirname "$APP")"
  ditto -c -k --keepParent "$(basename "$APP")" "$ZIP_PATH"
)

echo "==> Artifact check"
ls -lh "$ZIP_PATH"
unzip -l "$ZIP_PATH" | head -20
codesign --verify --deep --strict --verbose=2 "$APP" || true
if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  spctl -a -vv "$APP" || true
  xcrun stapler validate "$APP" || true
fi

if [[ "$SKIP_GITHUB" -eq 1 ]]; then
  echo "Skipped GitHub release (--skip-github)."
  echo "Zip ready: $ZIP_PATH"
  exit 0
fi

# --- GitHub Release ---
echo "==> GitHub Release $TAG on $REPO"
NOTES="$(mktemp -t x68drv-notes)"
cleanup_notes() { rm -f "$NOTES"; }
trap cleanup_notes EXIT

cat >"$NOTES" <<EOF
## x68drv ${VERSION}

macOS menu-bar app to mount X68000 disk images (\`.xdf\` / \`.hds\` / \`.hdf\` / \`.dim\`) read-only.

### Download
- **${ZIP_NAME}** — notarized \`.app\` (unzip and open)

### Requirements
- macOS 13+
- [FUSE-T](https://www.fuse-t.org/) for live Finder volumes (optional; without it, snapshot folders still work)

### Notes
- Hardened Runtime + Developer ID notarization (not Mac App Store / not App Sandbox)
- Double-click a disk image or use **Open Image…** from the menu bar
EOF

GH_ARGS=(release create "$TAG" "$ZIP_PATH" --repo "$REPO" --title "x68drv ${VERSION}" --notes-file "$NOTES")
if [[ "$DRAFT" -eq 1 ]]; then
  GH_ARGS+=(--draft)
else
  GH_ARGS+=(--latest)
fi

# Fail if tag already exists remotely unless draft re-upload — user can delete release first.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: release $TAG already exists on $REPO" >&2
  echo "Delete it first:  gh release delete $TAG --repo $REPO --yes" >&2
  exit 1
fi

gh "${GH_ARGS[@]}"

echo ""
echo "Done."
echo "  Release: https://github.com/${REPO}/releases/tag/${TAG}"
echo "  Asset:   $ZIP_PATH"
