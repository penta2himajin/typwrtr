#!/usr/bin/env bash
# Build typwrtr-core and regenerate Swift UniFFI bindings into apps/macos/Generated.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/apps/macos/Generated"
mkdir -p "$OUT"

cd "$ROOT"
cargo build -p typwrtr-core

TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
# Prefer dylib for library-mode metadata; fall back to staticlib path naming.
LIB=""
for candidate in \
  "$TARGET_DIR/debug/libtypwrtr_core.dylib" \
  "$TARGET_DIR/debug/libtypwrtr_core.so" \
  "$TARGET_DIR/debug/libtypwrtr_core.a"
do
  if [[ -f "$candidate" ]]; then
    LIB="$candidate"
    break
  fi
done

if [[ -z "$LIB" ]]; then
  echo "error: libtypwrtr_core not found under $TARGET_DIR/debug" >&2
  exit 1
fi

echo "[generate-swift] library=$LIB"
echo "[generate-swift] out=$OUT"

cargo run -q -p typwrtr-core --bin uniffi-bindgen -- generate \
  --library "$LIB" \
  --language swift \
  --out-dir "$OUT"

# UniFFI emits typwrtr_core.swift + FFI header/modulemap with crate name.
ls -la "$OUT"
echo "[generate-swift] done."
