#!/usr/bin/env bash
#
# export-patches.sh — export the mobile patch stack as a numbered patch series.
#
# Reads the patch-stack base from doc_mobile/upstream-base.txt (the first
# non-comment, non-empty line — the same parse the validate-patch-stack
# workflow uses) and runs `git format-patch <base>..HEAD` into an output
# directory. The resulting `*.patch` files plus a `series` manifest are the
# raw material for the out-of-tree patches-only repo described in
# doc_mobile/PATCHES_ONLY_PROPOSAL.md.
#
# Usage:
#   scripts/mobile/export-patches.sh [output_dir]
#
# Defaults to ./mobile-patches-out. The directory is created if missing and
# any pre-existing *.patch / series files in it are cleared first, so the
# export is reproducible.
#
set -euo pipefail

# Resolve repo root from this script's location so the script works no matter
# the caller's cwd (CI, worktrees, etc.).
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

BASE_FILE="${REPO_ROOT}/doc_mobile/upstream-base.txt"
OUT_DIR=${1:-"${REPO_ROOT}/mobile-patches-out"}

if [ ! -f "${BASE_FILE}" ]; then
  echo "error: ${BASE_FILE} is missing — cannot determine the patch-stack base." >&2
  echo "       See doc_mobile/UPGRADING.md." >&2
  exit 1
fi

# First non-comment, non-empty line, whitespace stripped — matches the
# parse in .github/workflows/validate-patch-stack.yml.
BASE=$(grep -Ev '^\s*(#|$)' "${BASE_FILE}" | head -n1 | tr -d '[:space:]')
if [ -z "${BASE}" ]; then
  echo "error: no base recorded in ${BASE_FILE}." >&2
  exit 1
fi

if ! git -C "${REPO_ROOT}" rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
  echo "error: patch-stack base '${BASE}' is not a valid commit in this repo." >&2
  exit 1
fi

if ! git -C "${REPO_ROOT}" merge-base --is-ancestor "${BASE}" HEAD; then
  echo "error: patch-stack base '${BASE}' is not an ancestor of HEAD." >&2
  exit 1
fi

COUNT=$(git -C "${REPO_ROOT}" rev-list --count "${BASE}..HEAD")
if [ "${COUNT}" -eq 0 ]; then
  echo "error: no commits between base '${BASE}' and HEAD — nothing to export." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
# Clear prior export so stale patches from a longer stack don't linger.
find "${OUT_DIR}" -maxdepth 1 -type f \( -name '*.patch' -o -name 'series' \) -delete

# --zero-commit: stable "From" hash so re-exports of identical content are
#   byte-identical (the patch-applies-cleanly contract, not provenance).
# --no-signature: drop the trailing "-- \n<git version>" so patches don't
#   churn across git versions.
# numbered (default): preserves apply order in the filename prefix.
git -C "${REPO_ROOT}" format-patch \
  --output-directory "${OUT_DIR}" \
  --zero-commit \
  --no-signature \
  "${BASE}..HEAD" >/dev/null

# Write the ordered series manifest (basenames, in apply order). This is what
# apply-patches.sh consumes and what a patches-only repo would track.
SERIES="${OUT_DIR}/series"
: > "${SERIES}"
for f in "${OUT_DIR}"/[0-9]*.patch; do
  basename -- "${f}" >> "${SERIES}"
done

N=$(wc -l < "${SERIES}" | tr -d '[:space:]')
echo "Exported ${N} patch(es) from ${BASE}..HEAD"
echo "  base:   ${BASE}"
echo "  output: ${OUT_DIR}"
echo "  series: ${SERIES}"
