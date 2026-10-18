#!/usr/bin/env bash
# Check that loading the ASR session at launch leaves the main thread free.
#
# Quits Typwrtr, deletes the ANE compile cache (unless --warm), launches the
# installed app with the given language, and waits for the coordinator's
# `asr load done … heartbeats=N` line. Heartbeats are a 1 s main-run-loop timer
# that runs while the load runs, so a blocked main thread logs none.
#
# Fails when heartbeats < half the load seconds, or when `app ready` is logged
# after the load finished.
#
# Needs Debug → Latency logs on (Release builds) — defaults key typwrtr.latencyLogging.
# Wrap in `jacquard measure` on a shared-GPU machine: the load compiles for the ANE.
#
#   ./scripts/check-cold-load.sh [--warm] [language]   # language: japanese (default), english, …
set -euo pipefail

WARM=0
if [[ "${1:-}" == "--warm" ]]; then WARM=1; shift; fi
LANGUAGE="${1:-japanese}"
BUNDLE_ID=app.typwrtr.macos.menuextra
APP="${TYPWRTR_APP:-/Applications/Typwrtr.app}"
CACHE="$HOME/Library/Caches/$BUNDLE_ID/com.apple.e5rt.e5bundlecache"
TIMEOUT="${TYPWRTR_LOAD_TIMEOUT:-240}"

[[ "$(defaults read "$BUNDLE_ID" typwrtr.latencyLogging 2>/dev/null)" == 1 ]] ||
  echo "warning: typwrtr.latencyLogging is off; a Release build logs nothing" >&2

osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' 2>/dev/null || true
for _ in $(seq 20); do pgrep -x Typwrtr >/dev/null || break; sleep 0.5; done
pkill -x Typwrtr 2>/dev/null || true
sleep 1

if [[ $WARM == 0 ]]; then
  rm -rf "$CACHE"
  echo "cache: deleted"
else
  echo "cache: kept (warm)"
fi
defaults write "$BUNDLE_ID" typwrtr.language "$LANGUAGE"

START="$(date '+%Y-%m-%d %H:%M:%S')"
sleep 1
open -a "$APP"

LOGS=""
for _ in $(seq "$TIMEOUT"); do
  sleep 1
  LOGS="$(/usr/bin/log show --style compact --start "$START" \
    --predicate "subsystem == \"$BUNDLE_ID\"" 2>/dev/null |
    grep -E 'app ready|asr load' || true)"
  grep -q 'asr load done' <<<"$LOGS" && break
done

DONE="$(grep 'asr load done' <<<"$LOGS" | head -1 || true)"
[[ -n "$DONE" ]] || { echo "error: no 'asr load done' within ${TIMEOUT}s" >&2; echo "$LOGS" >&2; exit 1; }

grep -E 'app ready|asr load backend=' <<<"$LOGS" | sed 's/^/  /'
echo "  $DONE"

MS="$(sed -E 's/.* ms=([0-9]+).*/\1/' <<<"$DONE")"
BEATS="$(sed -E 's/.* heartbeats=([0-9]+).*/\1/' <<<"$DONE")"
# Line order in the log is the order the app wrote them.
READY_LINE="$(grep -n 'app ready' <<<"$LOGS" | head -1 | cut -d: -f1 || true)"
DONE_LINE="$(grep -n 'asr load done' <<<"$LOGS" | head -1 | cut -d: -f1)"
NEED=$((MS / 2000))

echo "load_ms=$MS heartbeats=$BEATS (need >= $NEED)"
FAIL=0
if [[ -z "$READY_LINE" ]]; then
  echo "FAIL: no 'app ready' line"; FAIL=1
elif ((READY_LINE > DONE_LINE)); then
  echo "FAIL: app ready came after the load finished"; FAIL=1
else
  echo "ok: app ready before load end"
fi
if ((BEATS < NEED)); then
  echo "FAIL: main thread looks blocked during the load"; FAIL=1
else
  echo "ok: main thread ticked during the load"
fi
exit $FAIL
