#!/usr/bin/env bash
#
# audit-test-edits.sh — enforce the minimal-test-edit policy (doc_mobile/TESTING.md).
#
# Mobile adaptations of upstream Node tests must be small, greppable guards
# (anchored on common.isAndroid/isIOS or a "nodejs-mobile patch:" comment) or
# live in test/*/*.status — NOT wholesale rewrites. The brittle anti-pattern is
# rewriting a node:test-based test into a flat script: node:test works in the
# mobile binary (the harness scores by exit code), so there is no reason to strip
# it, and the rewrite is a large per-upgrade conflict surface.
#
# Hard rule (fails CI): no edited upstream test may have node:test removed.
# Soft signal (warning): flag oversized edits for review.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
cd "${REPO_ROOT}"

BASE_FILE="doc_mobile/upstream-base.txt"
if [ ! -f "${BASE_FILE}" ]; then
  echo "error: ${BASE_FILE} is missing — cannot determine the patch-stack base." >&2
  exit 1
fi
BASE=$(grep -Ev '^\s*(#|$)' "${BASE_FILE}" | head -n1 | tr -d '[:space:]')
if [ -z "${BASE}" ] || ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
  echo "error: patch-stack base '${BASE}' is not a valid commit." >&2
  exit 1
fi

NODE_TEST_RE="require\\(['\"]node:test['\"]\\)|from ['\"]node:test['\"]"
MAX_LINES=${MAX_TEST_EDIT_LINES:-40}
fail=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  up=$(git show "${BASE}:$f" 2>/dev/null | grep -cE "${NODE_TEST_RE}" || true)
  cur=$(grep -cE "${NODE_TEST_RE}" "$f" 2>/dev/null || true)
  if [ "${up:-0}" -gt 0 ] && [ "${cur:-0}" -eq 0 ]; then
    echo "::error file=$f::node:test was stripped from an upstream test. Keep node:test (it works in the mobile binary, scored by exit code) and skip the file via test/*/*.status, or use a small guard — do not rewrite it."
    fail=1
  fi
  churn=$(git diff --numstat "${BASE}" HEAD -- "$f" | awk '{s+=$1+$2} END{print s+0}')
  if [ "${churn:-0}" -gt "${MAX_LINES}" ]; then
    echo "::warning file=$f::large mobile test edit (${churn} lines changed). Prefer a small anchored guard or a .status skip; review whether this can shrink."
  fi
done < <(git diff --name-only "${BASE}" HEAD -- 'test/parallel/*.js' 'test/sequential/*.js' 'test/message/*.js')

if [ "${fail}" -ne 0 ]; then
  echo "FAIL: an upstream test had node:test stripped. See doc_mobile/TESTING.md (minimal test-edit policy)." >&2
  exit 1
fi
echo "Test-edit audit passed: no node:test rewrites."
