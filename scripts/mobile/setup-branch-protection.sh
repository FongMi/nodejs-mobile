#!/bin/bash
# One-time release-guard setup (run by a maintainer with admin on the repo).
# Protects the release branch so nothing merges without the cheap always-run
# checks green and a review. The heavy Tier-2 curated gate is enforced at
# publish time by publish-release.yml (it would be wasteful to require the
# 151-test gate on every PR), and the irreversible tag+publish is gated by the
# `release` Environment.
#
# Usage: scripts/mobile/setup-branch-protection.sh [branch]   (default mobile/v24)
#
# Prerequisites this does NOT do (also one-time, see doc_mobile/RELEASING.md):
#   - Create a `release` Environment with required reviewers (Settings ->
#     Environments) so publish-release.yml pauses for human approval.
#   - Install the release GitHub App + set RELEASE_APP_ID (variable) and
#     RELEASE_APP_PRIVATE_KEY (secret) so the bot's release-branch push (via an
#     App token, not GITHUB_TOKEN) triggers the required-check workflows.
set -euo pipefail

BRANCH="${1:-mobile/v24}"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Protecting ${REPO}@${BRANCH} ..."

# Required checks = the checks that run automatically on every PR's commits
# (build+smoke via build-mobile on the release/** or mobile/** push, host smoke,
# and the NAPI symbol smoke). Job names must match exactly. The build-mobile
# smoke jobs are a [full, lite] matrix, so each appears as "smoke-<plat>
# (<flavor>)"; requiring all four gates BOTH flavors at merge. The build-*/
# combine-* matrix jobs are intentionally NOT listed — the smoke-* jobs require
# them transitively via `needs:`.
cat > /tmp/branch-protection.json <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["smoke-android (full)", "smoke-android (lite)", "smoke-ios (full)", "smoke-ios (lite)", "smoke-host", "napi-smoke-android"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON

gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" \
  --input /tmp/branch-protection.json

echo "Done. Required checks: smoke-android (full|lite), smoke-ios (full|lite), smoke-host, napi-smoke-android."
echo "Linear history enforced (releases rebase/FF-merge so the gate's PR-SHA == merge-SHA)."
