#!/usr/bin/env bash
# Sign x68drv.app (Hardened Runtime) and optionally notarize + staple.
#
# Usage:
#   ./scripts/sign-and-notarize.sh --app path/to/x68drv.app \
#     --identity "Developer ID Application: Name (TEAMID)" \
#     [--notary-profile x68drv-notary] \
#     [--skip-notarize]
#
# Prerequisites: Developer ID cert, notarytool credentials (if notarizing).
# See docs/distribution.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=""
IDENTITY=""
NOTARY_PROFILE=""
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$APP" || -z "$IDENTITY" ]]; then
  echo "error: --app and --identity are required" >&2
  exit 2
fi
if [[ ! -d "$APP" ]]; then
  echo "error: app not found: $APP" >&2
  exit 1
fi

ENT_APP="$ROOT/Apps/x68drv/x68drv.entitlements"
ENT_HELP="$ROOT/Apps/x68drv/x68mount-helper.entitlements"
HELPER="$APP/Contents/Helpers/x68mount-helper"

if [[ ! -f "$ENT_APP" || ! -f "$ENT_HELP" ]]; then
  echo "error: entitlements missing under Apps/x68drv/" >&2
  exit 1
fi
if [[ ! -x "$HELPER" ]]; then
  echo "error: helper not embedded at $HELPER" >&2
  echo "Build Release first so the Embed x68mount-helper phase runs." >&2
  exit 1
fi

echo "==> Sign helper (Hardened Runtime)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENT_HELP" \
  --sign "$IDENTITY" \
  "$HELPER"

echo "==> Sign app (Hardened Runtime)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENT_APP" \
  --sign "$IDENTITY" \
  "$APP"

echo "==> Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E 'Authority|Flags|Identifier' || true

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo "Skipped notarization (--skip-notarize)."
  exit 0
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "No --notary-profile: signed only. Pass profile to notarize."
  exit 0
fi

ZIP="$(mktemp -t x68drv-notarize).zip"
cleanup() { rm -f "$ZIP"; }
trap cleanup EXIT

echo "==> Zip for notarytool"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submit notarization (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
spctl -a -vv "$APP" || true

echo "Done. Ship a fresh zip/dmg of the stapled app:"
echo "  ditto -c -k --keepParent \"$APP\" x68drv-notarized.zip"
