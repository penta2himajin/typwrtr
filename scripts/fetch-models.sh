#!/usr/bin/env bash
# Fetch curated models / tools for Typwrtr dogfood (euhadra L1 packs).
# Wizard (architecture step 6) should reuse the same layout/URLs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${TYPWRTR_MODELS_DIR:-$ROOT/models}"
KIND="${1:-help}"
EUHADRA_ROOT="${EUHADRA_ROOT:-$ROOT/../euhadra}"

mkdir -p "$DEST"

fetch() {
  local url="$1"
  local out="$2"
  if [[ -f "$out" && -s "$out" ]]; then
    echo "[fetch-models] present: $out"
    return 0
  fi
  echo "[fetch-models] downloading $url"
  mkdir -p "$(dirname "$out")"
  curl -sSL --fail --retry 3 --retry-delay 2 --max-time 1200 "$url" -o "$out"
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
  parakeet-ja)
    # Same ONNX mirror as euhadra scripts/setup_parakeet_ja.sh (~2.4 GB).
    dir="${PARAKEET_JA_DIR:-$DEST/parakeet-tdt_ctc-0.6b-ja}"
    mkdir -p "$dir"
    base="https://huggingface.co/sunilmahendrakar/parakeet-tdt-0.6b-ja-onnx/resolve/main"
    for f in vocab.txt config.json encoder-model.onnx decoder_joint-model.onnx \
             encoder-model.onnx.data decoder_joint-model.onnx.data; do
      fetch "$base/$f" "$dir/$f"
    done
    if [[ ! -s "$dir/encoder-model.onnx" || ! -s "$dir/encoder-model.onnx.data" ]]; then
      echo "[fetch-models] incomplete Parakeet-ja bundle under $dir" >&2
      exit 4
    fi
    echo "[fetch-models] parakeet-ja ready under $dir"
    echo "TYPWRTR_PARAKEET_JA_DIR=$dir"
    echo "PARAKEET_JA_DIR=$dir"
    echo "TYPWRTR_MODELS_DIR=$DEST"
    ;;
  canary)
    # euhadra scripts/setup_canary.sh — INT8 by default (~213 MB). Serves en + es.
    dir="${CANARY_DIR:-$DEST/canary-180m-flash-onnx}"
    mkdir -p "$dir"
    base="https://huggingface.co/istupakov/canary-180m-flash-onnx/resolve/main"
    if [[ "${CANARY_FP32:-0}" == "1" ]]; then
      enc="encoder-model.onnx"
      dec="decoder-model.onnx"
    else
      enc="encoder-model.int8.onnx"
      dec="decoder-model.int8.onnx"
    fi
    for f in vocab.txt config.json "$enc" "$dec"; do
      fetch "$base/$f" "$dir/$f"
    done
    if [[ "${CANARY_FP32:-0}" != "1" ]]; then
      for pair in "encoder-model.onnx encoder-model.int8.onnx" "decoder-model.onnx decoder-model.int8.onnx"; do
        link="${pair% *}"
        target="${pair#* }"
        if [[ ! -e "$dir/$link" && -s "$dir/$target" ]]; then
          (cd "$dir" && ln -sf "$target" "$link")
        fi
      done
    fi
    echo "[fetch-models] canary ready under $dir"
    echo "TYPWRTR_CANARY_DIR=$dir"
    echo "CANARY_DIR=$dir"
    echo "TYPWRTR_MODELS_DIR=$DEST"
    ;;
  paraformer-zh)
    # euhadra scripts/setup_paraformer_zh.sh (~238 MB quant).
    dir="${PARAFORMER_ZH_DIR:-$DEST/paraformer-zh}"
    mkdir -p "$dir"
    base="https://huggingface.co/funasr/Paraformer-large/resolve/main"
    fetch "$base/am.mvn" "$dir/am.mvn"
    fetch "$base/config.yaml" "$dir/config.yaml"
    if [[ ! -s "$dir/model.onnx" ]]; then
      fetch "$base/model_quant.onnx" "$dir/model.onnx"
    fi
    if [[ ! -s "$dir/tokens.json" ]]; then
      echo "[fetch-models] generating tokens.json from config.yaml"
      python3 - "$dir/config.yaml" "$dir/tokens.json" <<'PY'
import re, sys
cfg_path, out_path = sys.argv[1], sys.argv[2]
text = open(cfg_path, encoding="utf-8").read()
m = re.search(r"^token_list:\s*\n((?:\s*-\s.*\n)+)", text, re.MULTILINE)
if not m:
    raise SystemExit("token_list not found in config.yaml")
tokens = []
for line in m.group(1).splitlines():
    line = line.strip()
    if line.startswith("- "):
        tok = line[2:].strip()
        if (tok.startswith('"') and tok.endswith('"')) or (tok.startswith("'") and tok.endswith("'")):
            tok = tok[1:-1]
        tokens.append(tok)
import json
json.dump(tokens, open(out_path, "w", encoding="utf-8"), ensure_ascii=False)
print(f"wrote {len(tokens)} tokens → {out_path}")
PY
    fi
    echo "[fetch-models] paraformer-zh ready under $dir"
    echo "TYPWRTR_PARAFORMER_ZH_DIR=$dir"
    echo "PARAFORMER_ZH_DIR=$dir"
    echo "TYPWRTR_MODELS_DIR=$DEST"
    ;;
  sensevoice-ko)
    echo "[fetch-models] sensevoice-ko is legacy; Typwrtr Korean uses dolphin-ko" >&2
    echo "  Re-run: $0 dolphin-ko" >&2
    exit 3
    ;;
  dolphin-ko)
    # euhadra scripts/setup_dolphin_ko.sh — curl-only INT8 CTC (~250 MB).
    dir="${DOLPHIN_KO_DIR:-$DEST/dolphin-ko}"
    mkdir -p "$dir"
    base="https://huggingface.co/csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02/resolve/main"
    for f in tokens.txt model.int8.onnx; do
      fetch "$base/$f" "$dir/$f"
    done
    if [[ ! -s "$dir/model.int8.onnx" || ! -s "$dir/tokens.txt" ]]; then
      echo "[fetch-models] incomplete Dolphin-ko bundle under $dir" >&2
      exit 4
    fi
    echo "[fetch-models] dolphin-ko ready under $dir"
    echo "TYPWRTR_DOLPHIN_KO_DIR=$dir"
    echo "DOLPHIN_KO_DIR=$dir"
    echo "TYPWRTR_MODELS_DIR=$DEST"
    ;;
  help|-h|--help)
    cat <<EOF
Usage: $0 <kind>

  parakeet-ja     Japanese — nvidia Parakeet-ja ONNX (~2.4 GB)
  canary          English + Spanish — Canary-180M-Flash INT8 (~213 MB)
  paraformer-zh   Chinese — FunASR Paraformer-large quant (~238 MB)
  dolphin-ko      Korean — Dolphin small CTC INT8 (~250 MB)
  whisper-tiny    legacy Whisper ggml-tiny + whisper-cli
  whisper-cli     build whisper-cli only

Env:
  TYPWRTR_MODELS_DIR   model root (default: $ROOT/models)
  EUHADRA_ROOT          euhadra checkout (default: $ROOT/../euhadra)
  CANARY_FP32=1         download full-precision Canary instead of INT8
EOF
    ;;
  *)
    echo "unknown kind: $KIND (try: $0 help)" >&2
    exit 1
    ;;
esac
