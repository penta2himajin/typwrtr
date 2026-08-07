#!/usr/bin/env bash
# Fetch curated models / tools for Typwrtr dogfood.
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
  mkdir -p "$(dirname "$out")"
  curl -sSL --fail --retry 3 --retry-delay 2 --max-time 600 "$url" -o "$out"
}

build_whisper_cli() {
  local WHISPER_DIR="${WHISPER_DIR:-$ROOT/vendor/whisper.cpp}"
  local WHISPER_REF="${WHISPER_REF:-v1.7.4}"

  if [[ ! -d "$WHISPER_DIR/.git" ]]; then
    echo "[fetch-models] cloning whisper.cpp@$WHISPER_REF"
    rm -rf "$WHISPER_DIR"
    git clone --depth 1 --branch "$WHISPER_REF" \
      https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
  fi

  if [[ ! -x "$WHISPER_DIR/build/bin/whisper-cli" ]]; then
    echo "[fetch-models] building whisper-cli"
    cmake -B "$WHISPER_DIR/build" -S "$WHISPER_DIR" \
      -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
      -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$WHISPER_DIR/build" --config Release \
      --target whisper-cli -j >/dev/null
  else
    echo "[fetch-models] whisper-cli already built"
  fi

  echo "TYPWRTR_WHISPER_CLI=$WHISPER_DIR/build/bin/whisper-cli"
  echo "WHISPER_CLI=$WHISPER_DIR/build/bin/whisper-cli"
}

case "$KIND" in
  whisper-tiny)
    dir="$DEST/whisper"
    mkdir -p "$dir"
    base="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    fetch "$base/ggml-tiny.en.bin" "$dir/ggml-tiny.en.bin"
    fetch "$base/ggml-tiny.bin" "$dir/ggml-tiny.bin"
    build_whisper_cli
    echo "[fetch-models] whisper-tiny ready under $dir"
    echo "TYPWRTR_WHISPER_MODEL_DIR=$dir"
    echo "TYPWRTR_MODELS_DIR=$DEST"
    ;;
  whisper-cli)
    build_whisper_cli
    ;;
  help|-h|--help)
    cat <<EOF
Usage: $0 [whisper-tiny|whisper-cli|help]

  whisper-tiny  download ggml-tiny(.en) + build whisper-cli (default)
  whisper-cli   build whisper-cli only

Env:
  TYPWRTR_MODELS_DIR   model root (default: $ROOT/models)
  WHISPER_DIR           whisper.cpp checkout (default: $ROOT/vendor/whisper.cpp)
  WHISPER_REF           git tag/branch (default: v1.7.4)

After whisper-tiny:
  export TYPWRTR_WHISPER_CLI=...   # printed by the script
  export TYPWRTR_WHISPER_MODEL_DIR=...
EOF
    ;;
  *)
    echo "unknown kind: $KIND (try: whisper-tiny | whisper-cli | help)" >&2
    exit 1
    ;;
esac
