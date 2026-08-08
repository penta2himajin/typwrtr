#!/usr/bin/env bash
# Build the macOS shell and install it to ~/Applications for dogfood.
#
# Exists because the signature decides whether TCC grants survive a rebuild.
# macOS stores Accessibility / Input Monitoring approval against the app's
# designated requirement. Signed with the "Typwrtr Dogfood" cert that is
# `identifier + certificate leaf`, which is stable; signed ad-hoc (`--sign -`)
# it is the cdhash, which changes on every build, so every rebuild silently
# loses its permissions and System Settings shows a toggle that looks enabled
# but is not. Re-signing the copy ad-hoc has cost a debugging session once.
set -euo pipefail

CONFIG="${TYPWRTR_CONFIG:-Debug}"
CERT_NAME="${TYPWRTR_DEV_CERT_NAME:-Typwrtr Dogfood}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${TYPWRTR_INSTALL_DIR:-$HOME/Applications}/Typwrtr.app"
BUNDLE_ID=app.typwrtr.macos.menuextra

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
  echo "error: code-signing identity '$CERT_NAME' not found." >&2
  echo "Run scripts/create-dogfood-cert.sh first; ad-hoc signing loses TCC grants." >&2
  exit 1
fi

cd "$ROOT/apps/macos"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project Typwrtr.xcodeproj -scheme Typwrtr -configuration "$CONFIG" \
  CODE_SIGN_IDENTITY="$CERT_NAME" CODE_SIGNING_REQUIRED=YES build >/tmp/typwrtr-build.log 2>&1 ||
  { tail -30 /tmp/typwrtr-build.log >&2; exit 1; }

APP="$(xcodebuild -project Typwrtr.xcodeproj -scheme Typwrtr -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null | awk '
    $1 == "BUILT_PRODUCTS_DIR" { dir = $3 }
    $1 == "FULL_PRODUCT_NAME" { sub(/^[^=]*= /, ""); name = $0 }
    END { print dir "/" name }')"
[[ -d "$APP" ]] || { echo "error: built app not found at $APP" >&2; exit 1; }

pkill -x Typwrtr 2>/dev/null || true
sleep 1
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
# ditto, not cp: keeps the signature intact so re-signing is unnecessary.
ditto "$APP" "$DEST"

codesign --verify --deep --strict "$DEST"
if codesign -dvv "$DEST" 2>&1 | grep -q "adhoc"; then
  echo "error: installed app is ad-hoc signed; TCC grants would not survive." >&2
  exit 1
fi
echo "installed $DEST"
codesign -d --requirements - "$DEST" 2>&1 | grep designated

if [[ "${1:-}" == "--reset-permissions" ]]; then
  # Only needed after the requirement changed (e.g. recovering from an ad-hoc
  # install or a new cert); a normal rebuild keeps its grants.
  for svc in Accessibility ListenEvent PostEvent Microphone; do
    tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1 || true
  done
  echo "reset TCC grants; re-approve when prompted"
fi

open "$DEST"
