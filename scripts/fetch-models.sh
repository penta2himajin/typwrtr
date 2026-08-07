#!/usr/bin/env bash
# Fetch curated ASR / cleanup models for Typwrtr dogfood.
# In-app wizard download (architecture step 6) should reuse the same URLs/layout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${TYPWRTR_MODELS_DIR:-$ROOT/models}"

echo "typwrtr fetch-models"
echo "  destination: $DEST"
echo
echo "Not implemented yet: pin concrete euhadra-compatible model URLs here."
echo "Expected layout (tentative):"
echo "  \$DEST/ja/   # Parakeet JA (or script-chosen default)"
echo "  \$DEST/en/   # Parakeet EN / whisper stack"
echo
echo "See docs/architecture.md §5."
exit 1
