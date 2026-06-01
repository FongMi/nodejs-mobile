#!/bin/bash
# Per-test proxy for the iOS *simulator*, used via `test.py --shell`. Launches the
# installed testnode app with simctl, reads the test's real exit code from a
# verdict file the app writes to its Documents dir (durable; not scraped from the
# lossy `simctl --console` stream), echoes node's stdout/stderr for test.py to
# compare, and maps PASS->0 / FAIL or no-verdict->1.
#
# The physical-device proxy is node-ios-proxy.sh, which uses ios-deploy and gets
# the real exit code back; `simctl launch` does not return it, hence the file.
set -uo pipefail

: "${DEVICE_ID:?set DEVICE_ID to the target simulator UDID}"
UDID="$DEVICE_ID"
BUNDLE=nodejsmobile.test
TIMEOUT="${NODE_IOS_PROXY_TIMEOUT:-120}"
# `simctl launch --console` occasionally fails to establish its stdout FIFO on a
# rapid relaunch ("Unable to establish FIFO ... Error 17" / NSPOSIXErrorDomain),
# which launches nothing -> no verdict -> a spurious FAIL. Retry the launch a few
# times; a real PASS/FAIL verdict ends the loop immediately, so only infra
# failures pay the retry.
LAUNCH_ATTEMPTS="${NODE_IOS_PROXY_LAUNCH_ATTEMPTS:-3}"

SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"
TEST_BASE="$( cd "$SCRIPT_DIR/../../.." && cd test && pwd )"
# Resolve the app's data container. Under `set -uo pipefail` (no -e) a command
# substitution that exits 0 with empty stdout would silently yield DOCS=/Documents
# and an unwritable verdict path; assert non-empty so a degraded simctl fails
# loudly instead of turning every test into a no-verdict FAIL.
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)"
[ -n "$CONTAINER" ] || { echo "::error::node-ios-sim-proxy: could not resolve app container for $BUNDLE on $UDID" >&2; exit 1; }
DOCS="$CONTAINER/Documents"
LOG="$(mktemp)"

# Per-launch token names the verdict file (Documents/result-<token>.txt) so a
# stale file or a spawned child (never gets --run-token) can't be confused for
# this launch. Lowercased uuid -> [0-9a-f], uniform with the Android token.
RUN_TOKEN="$(/usr/bin/uuidgen | tr 'A-F' 'a-f' | tr -d '-')"
RESULT_FILE="$DOCS/result-${RUN_TOKEN}.txt"
RESULT=1
verdict=""
for attempt in $(seq 1 "$LAUNCH_ATTEMPTS"); do
  rm -f "$RESULT_FILE"
  : >| "$LOG"
  # main.m consumes --run-token into the env (NodeRunner builds the verdict path)
  # and applies --substitute-dir to rewrite host test paths to the Documents copy.
  xcrun simctl launch --console --terminate-running-process "$UDID" "$BUNDLE" \
    --run-token "$RUN_TOKEN" --substitute-dir "$TEST_BASE" "$@" >| "$LOG" 2>&1 &
  LP=$!
  verdict=""
  for _ in $(seq 1 "$TIMEOUT"); do
    if [ -f "$RESULT_FILE" ]; then
      verdict=$(tr -d '\r\n' < "$RESULT_FILE")
      [ -n "$verdict" ] && break
    fi
    kill -0 "$LP" 2>/dev/null || { [ -f "$RESULT_FILE" ] && verdict=$(tr -d '\r\n' < "$RESULT_FILE"); break; }
    sleep 1
  done
  kill "$LP" 2>/dev/null || true
  wait "$LP" 2>/dev/null || true

  # A real PASS/FAIL verdict is authoritative -> stop (never retry a genuine
  # FAIL). Retry only when there is no verdict AND simctl reported a launch
  # failure (the --console FIFO race); a no-verdict with no launch error is a
  # genuine hang -> let it stand as FAIL rather than burn retries.
  case "$verdict" in PASS|FAIL) break ;; esac
  if grep -qiE "Unable to establish FIFO|error was encountered|NSPOSIXErrorDomain|Could not (launch|find)" "$LOG"; then
    echo "::warning::node-ios-sim-proxy: simctl launch failed (attempt ${attempt}/${LAUNCH_ATTEMPTS}), retrying: $*" >&2
    sleep 2
    continue
  fi
  break
done
case "$verdict" in
  PASS) RESULT=0 ;;
  FAIL) RESULT=1 ;;
  *) RESULT=1; echo "::warning::node-ios-sim-proxy: no verdict file after ${LAUNCH_ATTEMPTS} attempt(s) (timeout/crash/launch-failure) for: $*" >&2 ;;
esac

# Echo node's output for test.py's .out comparison (best-effort via --console),
# dropping the "<bundle>: <pid>" line simctl prints. The verdict no longer rides
# this stream.
grep -vE "^${BUNDLE}: [0-9]+$" "$LOG" || true
rm -f "$LOG" "$RESULT_FILE"
exit "$RESULT"
