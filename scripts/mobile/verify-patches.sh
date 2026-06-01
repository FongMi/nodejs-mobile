#!/usr/bin/env bash
#
# verify-patches.sh — prove the patch series reconstructs HEAD exactly.
#
# The integrity check for the patches-only model: export the series from
# HEAD, create a throwaway worktree at the recorded base tag, apply the
# series there, and assert the resulting tree is byte-for-byte identical to
# HEAD's tree. If they match, the patch series is a faithful, lossless
# representation of the mobile diff — which is the contract a patches-only
# repo (doc_mobile/PATCHES_ONLY_PROPOSAL.md) depends on.
#
# Usage:
#   scripts/mobile/verify-patches.sh [patches_dir]
#
# Exits 0 on a clean reconstruction, non-zero (with a diff summary) otherwise.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

BASE_FILE="${REPO_ROOT}/doc_mobile/upstream-base.txt"
if [ ! -f "${BASE_FILE}" ]; then
  echo "error: ${BASE_FILE} is missing — cannot determine the patch-stack base." >&2
  echo "       See doc_mobile/UPGRADING.md." >&2
  exit 1
fi
# First non-comment, non-empty line, whitespace stripped — matches the parse in
# export-patches.sh and .github/workflows/validate-patch-stack.yml.
BASE=$(grep -Ev '^\s*(#|$)' "${BASE_FILE}" | head -n1 | tr -d '[:space:]')
if [ -z "${BASE}" ]; then
  echo "error: no base recorded in ${BASE_FILE}." >&2
  exit 1
fi
if ! git -C "${REPO_ROOT}" rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
  echo "error: patch-stack base '${BASE}' is not a valid commit in this repo." >&2
  exit 1
fi

HEAD_TREE=$(git -C "${REPO_ROOT}" rev-parse 'HEAD^{tree}')

# Scratch space: a patches dir and a worktree, both removed on exit.
WORKTREE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mp-verify-wt.XXXXXX")
PATCHES_DIR=${1:-$(mktemp -d "${TMPDIR:-/tmp}/mp-verify-patches.XXXXXX")}
CLEAN_PATCHES=0
[ "$#" -lt 1 ] && CLEAN_PATCHES=1

cleanup() {
  # Order matters: abort any in-progress am, then drop the worktree via git
  # so its administrative entry is removed too, then rm scratch dirs.
  git -C "${WORKTREE_DIR}" am --abort >/dev/null 2>&1 || true
  git -C "${REPO_ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
  if [ "${CLEAN_PATCHES}" -eq 1 ]; then
    rm -rf "${PATCHES_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "1/3 Exporting patch series from HEAD..."
"${SCRIPT_DIR}/export-patches.sh" "${PATCHES_DIR}" >/dev/null

echo "2/3 Creating throwaway worktree at ${BASE} and applying series..."
# Detached worktree at the base tag — never touches the caller's branches.
rm -rf "${WORKTREE_DIR}"
git -C "${REPO_ROOT}" worktree add --detach --force "${WORKTREE_DIR}" "${BASE}" >/dev/null

if ! "${SCRIPT_DIR}/apply-patches.sh" "${WORKTREE_DIR}" "${PATCHES_DIR}"; then
  echo "FAIL: patch series did not apply cleanly onto ${BASE}." >&2
  exit 1
fi

echo "3/3 Comparing reconstructed tree against HEAD..."
RECONSTRUCTED_TREE=$(git -C "${WORKTREE_DIR}" rev-parse 'HEAD^{tree}')

if [ "${RECONSTRUCTED_TREE}" = "${HEAD_TREE}" ]; then
  echo "OK: reconstructed tree ${RECONSTRUCTED_TREE} == HEAD tree ${HEAD_TREE}"
  echo "PASS: the patch series losslessly reconstructs HEAD."
  exit 0
fi

echo "FAIL: reconstructed tree ${RECONSTRUCTED_TREE} != HEAD tree ${HEAD_TREE}" >&2
echo "Diff summary (HEAD tree vs reconstructed tree):" >&2
git -C "${REPO_ROOT}" diff --stat "${HEAD_TREE}" "${RECONSTRUCTED_TREE}" >&2 || true
exit 1
