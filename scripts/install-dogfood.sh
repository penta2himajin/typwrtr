#!/usr/bin/env bash
# Build the macOS shell and install it to /Applications for dogfood.
#
# Exists because the signature decides whether TCC grants survive a rebuild.
# macOS stores Accessibility / Input Monitoring approval against the app's
# designated requirement. Signed with the "Typwrtr Dogfood" cert that is
# `identifier + certificate leaf`, which is stable; signed ad-hoc (`--sign -`)
# it is the cdhash, which changes on every build, so every rebuild silently
# loses its permissions and System Settings shows a toggle that looks enabled
# but is not. Re-signing the copy ad-hoc has cost a debugging session once.
#
# Spotlight indexes every Typwrtr.app Xcode leaves in DerivedData. This script
# installs one copy to /Applications and unregisters the rest so Spotlight
# shows a single result.
set -euo pipefail

CONFIG="${TYPWRTR_CONFIG:-Release}"
CERT_NAME="${TYPWRTR_DEV_CERT_NAME:-Typwrtr Dogfood}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${TYPWRTR_INSTALL_DIR:-/Applications}/Typwrtr.app"
BUNDLE_ID=app.typwrtr.macos.menuextra
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

# Finder/Spotlight launch cannot use the repo rpath. Ship the Rust dylib in the bundle.
RUST_LIB="$ROOT/target/debug/libtypwrtr_core.dylib"
[[ "$CONFIG" == "Release" ]] && RUST_LIB="$ROOT/target/release/libtypwrtr_core.dylib"
mkdir -p "$DEST/Contents/Frameworks"
cp "$RUST_LIB" "$DEST/Contents/Frameworks/libtypwrtr_core.dylib"
install_name_tool -id "@rpath/libtypwrtr_core.dylib" "$DEST/Contents/Frameworks/libtypwrtr_core.dylib"
BIN="$DEST/Contents/MacOS/Typwrtr"
OLD=$(otool -L "$BIN" | awk '/libtypwrtr_core\.dylib/{print $1; exit}')
if [[ -n "$OLD" && "$OLD" != "@rpath/libtypwrtr_core.dylib" ]]; then
  install_name_tool -change "$OLD" "@rpath/libtypwrtr_core.dylib" "$BIN"
fi
codesign --force --sign "$CERT_NAME" --timestamp=none \
  "$DEST/Contents/Frameworks/libtypwrtr_core.dylib"
codesign --force --sign "$CERT_NAME" --timestamp=none --deep "$DEST"

codesign --verify --deep --strict "$DEST"
if codesign -dvv "$DEST" 2>&1 | grep -q "adhoc"; then
  echo "error: installed app is ad-hoc signed; TCC grants would not survive." >&2
  exit 1
fi

# Keep Xcode/build trees out of Spotlight; they are extra Typwrtr.app hits.
hide_from_spotlight() {
  local dir=$1
  [[ -d "$dir" ]] || return 0
  touch "$dir/.metadata_never_index"
}

hide_from_spotlight "$ROOT/apps/macos/DerivedData"
shopt -s nullglob
for dd in "$HOME/Library/Developer/Xcode/DerivedData"/Typwrtr-*; do
  hide_from_spotlight "$dd"
done
shopt -u nullglob

# Extra belt: mark leftover Typwrtr.app bundles themselves as never-indexed.
while IFS= read -r extra; do
  [[ -d "$extra" && "$extra" != "$DEST" ]] || continue
  touch "$extra/.metadata_never_index"
done < <(find "$ROOT/apps/macos/DerivedData" "$HOME/Library/Developer/Xcode/DerivedData" \
  -name Typwrtr.app -type d 2>/dev/null || true)

# Drop the old user-level install so Launch Services has one path.
if [[ "$DEST" == /Applications/Typwrtr.app && -d "$HOME/Applications/Typwrtr.app" ]]; then
  "$LSREGISTER" -u "$HOME/Applications/Typwrtr.app" >/dev/null 2>&1 || true
  rm -rf "$HOME/Applications/Typwrtr.app"
fi

# Unregister every other copy Spotlight already knows, then pin /Applications.
while IFS= read -r extra; do
  [[ -n "$extra" && "$extra" != "$DEST" ]] || continue
  "$LSREGISTER" -u "$extra" >/dev/null 2>&1 || true
done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true)
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

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
