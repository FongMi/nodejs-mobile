#!/bin/bash
set -e

# Use the environment variable to target a specific device
if [ "$DEVICE_ID" = "" ]; then
  TARGET=""
else
  TARGET="-s $DEVICE_ID"
fi

# Seconds to wait for a test to report a RESULT before treating it as failed,
# so a hung test can't block the whole run.
TIMEOUT="${NODE_ANDROID_PROXY_TIMEOUT:-120}"

# Kill the test app if it's running, clear the log so we only read this run, and
# drop any verdict files left by previous launches. The per-launch token already
# makes a stale file un-readable (different name), but clearing them keeps the
# sandbox from accumulating files across a 151-test run and removes any doubt.
adb $TARGET shell 'am force-stop nodejsmobile.test.testnode'
adb $TARGET shell "run-as nodejsmobile.test.testnode sh -c 'rm -f files/result-*.txt'" 2>/dev/null || true
adb $TARGET logcat -c

TEST_PATH="$( cd "$( dirname "$0" )" && cd .. && cd .. && cd test && pwd )"

ARGS=$(echo $*)

# Per-launch token: the RESULT marker is tagged with it, so a marker emitted by
# an aborting test or a spawned grandchild can't be mis-attributed to a
# neighbouring test (the contiguous false-FAIL block seen on CI). [a-f0-9] only,
# so it's safe unquoted inside the am extra and in a grep/sed regex.
RUN_TOKEN="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 16)"
[ -n "$RUN_TOKEN" ] || RUN_TOKEN="${RANDOM}${RANDOM}$$"

# Start the test app, passing the test filename, the host dir to substitute, and
# the per-launch token (its own extra so it never enters the test's process.argv).
# -W makes `am start` block until the activity is idle, so the launch can't
# coalesce into the just-force-stopped process still tearing down (which would
# leave node un-started -> a spurious no-verdict timeout).
ADB_START_COMMAND='am start -W -n nodejsmobile.test.testnode/nodejsmobile.test.testnode.MainActivity -e "nodeargs" "'$ARGS'" -e "substitutedir" "'$TEST_PATH'" -e "runtoken" "'$RUN_TOKEN'" '
adb $TARGET shell "$ADB_START_COMMAND" > /dev/null

# The app writes the test's real exit code to a per-launch file in its sandbox
# (filesDir/result-<token>.txt). Read it via run-as — a durable, private channel
# immune to logcat's rate-limit / ring-buffer eviction / 4KB truncation that made
# a single scraped marker an unrecoverable false FAIL. PASS / FAIL / no-file
# (timeout) are now distinguishable.
RESULT_REL="files/result-${RUN_TOKEN}.txt"
RESULT=1
verdict=""
for _ in $(seq 1 "$TIMEOUT"); do
  verdict=$(adb $TARGET shell "run-as nodejsmobile.test.testnode cat ${RESULT_REL} 2>/dev/null" 2>/dev/null | tr -d '\r\n' || true)
  case "$verdict" in
    PASS) RESULT=0; break ;;
    FAIL) RESULT=1; break ;;
  esac
  sleep 1
done
[ -n "$verdict" ] || echo "::warning::node-android-proxy: no verdict file after ${TIMEOUT}s (timeout/crash) for: $ARGS" >&2

# Echo the raw stdout/stderr for test.py's .out comparison. The verdict no longer
# rides this stream, so there is nothing to strip.
adb $TARGET shell 'logcat -d -b main -v raw -s TestNode:E -s TestNode:I -s nodejs' \
  | sed '/^--------- beginning of/d'

exit $RESULT
