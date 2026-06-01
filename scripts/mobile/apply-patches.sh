#!/usr/bin/env bash
#
# apply-patches.sh — apply the mobile patch series onto an upstream checkout.
#
# This is the "prepare" half of the patches-only model
# (doc_mobile/PATCHES_ONLY_PROPOSAL.md): given a clean nodejs/node checkout
# already at the patch-stack base tag, layer the mobile patches on top in
# order, stopping on the first failure with a clear message.
#
# Usage:
#   scripts/mobile/apply-patches.sh <upstream_checkout_dir> [patches_dir]
#
#   upstream_checkout_dir  a git checkout of nodejs/node at the base tag
#                          (see doc_mobile/upstream-base.txt). Must be clean.
#   patches_dir            directory of *.patch files + a `series` manifest,
#                          as produced by export-patches.sh.
#                          Defaults to ./mobile-patches-out.
#
# Patches are applied with `git am --3way`. The --3way fallback lets git use
# the blob context embedded in the patch to merge hunks whose line numbers
# drifted, which makes the series robust across minor upstream churn while
# still failing loudly on a real conflict.
#
# --whitespace=nowarn is forced so the apply is byte-exact regardless of the
# caller's apply.whitespace config. With the common apply.whitespace=fix
# setting, git am would otherwise silently strip trailing whitespace,
# mutating the reconstructed tree and breaking verify-patches.sh.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

if [ "$#" -lt 1 ]; then
  echo "usage: $(basename -- "$0") <upstream_checkout_dir> [patches_dir]" >&2
  exit 2
fi

UPSTREAM_DIR=$1
PATCHES_DIR=${2:-"${REPO_ROOT}/mobile-patches-out"}

if [ ! -d "${UPSTREAM_DIR}" ]; then
  echo "error: upstream checkout dir '${UPSTREAM_DIR}' does not exist." >&2
  exit 1
fi
if ! git -C "${UPSTREAM_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: '${UPSTREAM_DIR}' is not a git repository." >&2
  exit 1
fi
if [ ! -f "${PATCHES_DIR}/series" ]; then
  echo "error: no 'series' manifest in '${PATCHES_DIR}'." >&2
  echo "       Run scripts/mobile/export-patches.sh first." >&2
  exit 1
fi

# Refuse to apply onto a dirty tree — `git am` would otherwise leave a
# confusing half-applied state mixed with the caller's own changes.
if [ -n "$(git -C "${UPSTREAM_DIR}" status --porcelain)" ]; then
  echo "error: upstream checkout '${UPSTREAM_DIR}' is not clean." >&2
  echo "       Commit, stash, or reset it before applying patches." >&2
  exit 1
fi

# Clear a leftover git-am session from a previous failed run, but only if one is
# actually in progress — a blind `am --abort` would silently mask an unrelated
# in-progress sequencer operation (e.g. a rebase) and let the series apply on top.
if [ -d "$(git -C "${UPSTREAM_DIR}" rev-parse --git-path rebase-apply)" ]; then
  git -C "${UPSTREAM_DIR}" am --abort >/dev/null 2>&1 || true
fi

APPLIED=0
while IFS= read -r patch; do
  [ -z "${patch}" ] && continue
  case "${patch}" in \#*) continue ;; esac
  patch_path="${PATCHES_DIR}/${patch}"
  if [ ! -f "${patch_path}" ]; then
    echo "error: series lists '${patch}' but the file is missing in ${PATCHES_DIR}." >&2
    exit 1
  fi
  if ! git -C "${UPSTREAM_DIR}" am --3way --keep-cr --whitespace=nowarn "${patch_path}" >/dev/null 2>&1; then
    echo "error: failed to apply patch: ${patch}" >&2
    echo "       Conflict in ${UPSTREAM_DIR}. Inspect with:" >&2
    echo "         git -C '${UPSTREAM_DIR}' status" >&2
    echo "         git -C '${UPSTREAM_DIR}' am --show-current-patch=diff" >&2
    echo "       Resolve, then 'git am --continue', or 'git am --abort' to bail." >&2
    exit 1
  fi
  APPLIED=$((APPLIED + 1))
done < "${PATCHES_DIR}/series"

echo "Applied ${APPLIED} patch(es) onto ${UPSTREAM_DIR}"
