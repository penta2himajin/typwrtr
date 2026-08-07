#!/usr/bin/env bash
# Fetch curated models for Typwrtr dogfood.
# Wizard (architecture step 6) should reuse the same layout/URLs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${TYPWRTR_MODELS_DIR:-$ROOT/models}"
KIND="${1:-whisper-tiny}"

mkdir -p "$DEST"

fetch() {
  local url="$1"
  local out="$2"
  if [[ -f "$out" ]]; then
    echo "[fetch-models] present: $out"
    return 0
  fi
  echo "[fetch-models] downloading $url"
  curl -sSL --fail --retry 3 --retry-delay 2 --max-time 600 "$url" -o "$out"
}

case "$KIND" in
  whisper-tiny)
    # ggml tiny models for whisper.cpp CLI (euhadra WhisperLocal).
    # Runtime binary is separate: build whisper.cpp yourself or set WHISPER_CLI.
    dir="$DEST/whisper"
    mkdir -p "$dir"
    base="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    fetch "$base/ggml-tiny.en.bin" "$dir/ggml-tiny.en.bin"
    fetch "$base/ggml-tiny.bin" "$dir/ggml-tiny.bin"
    echo "[fetch-models] whisper-tiny ready under $dir"
    echo "TYPWRTR_WHISPER_MODEL_DIR=$dir"
    echo "Set WHISPER_CLI to your whisper-cli binary to use WhisperLocal."
    ;;
  help|-h|--help)
    echo "Usage: $0 [whisper-tiny]"
    echo "  TYPWRTR_MODELS_DIR  override destination (default: $ROOT/models)"
    echo
    echo "Parakeet JA/EN ONNX bundles are large; add targets here when dogfood needs them."
    echo "See docs/architecture.md §5 and euhadra scripts/setup_parakeet_ja.sh."
    ;;
  *)
    echo "unknown kind: $KIND (try: whisper-tiny | help)" >&2
    exit 1
    ;;
esac
