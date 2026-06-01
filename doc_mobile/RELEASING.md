# Release Instructions

Releases are **automated and guarded**: a maintainer opens a release PR by
dispatching a workflow, CI proves the binaries build and pass the test gate, and
merging the reviewed PR triggers the tag + GitHub Release behind a human
approval. **No one pushes a tag by hand**, and nothing publishes unless the
tests passed first.

Two workflows drive it:

- [`prepare-release.yml`](../.github/workflows/prepare-release.yml) — opens the
  release PR (version bump + CHANGELOG + release flag).
- [`publish-release.yml`](../.github/workflows/publish-release.yml) — on merge,
  tags and publishes, behind the `release` Environment approval.

The version of record is `src/node_mobile_version.h`. The tag is
`nodejs-mobile-X.Y.Z`. Releases ship **both flavors** — `full` (the default
binary) and `lite` (comapeo-tuned; see the
[lite variant](./README.md#the-lite-variant)).

---

## One-time setup (admin)

1. **`RELEASE_PAT` secret** — a PAT with `repo` + `workflow` scope. The release
   bot pushes the release branch with it; a branch pushed with the default
   `GITHUB_TOKEN` does *not* trigger the Build/gate workflows, so its required
   checks would never run.
2. **`release` Environment** (Settings → Environments) with **required
   reviewers**. `publish-release.yml` runs its tag+publish job in this
   Environment, so it pauses for human approval before the irreversible step.
3. **Branch protection** on `mobile/v24` — run
   [`scripts/mobile/setup-branch-protection.sh`](../scripts/mobile/setup-branch-protection.sh).
   It requires the always-run checks (`smoke-android`, `smoke-ios`,
   `smoke-host`, `napi-smoke-android`) and a review, and enforces linear history.

---

## Cutting a release

1. **Dispatch `prepare-release`** with the version (e.g. `24.15.0`). It opens a
   `release/vX.Y.Z` PR that bumps `src/node_mobile_version.h`, flags
   `NODE_VERSION_IS_RELEASE`, prepends a CHANGELOG stub, and adds the
   `mobile-test` label so the Tier-2 curated gate runs.
2. **Fill in the CHANGELOG** entry in the PR and review the diff.
3. **Wait for green.** Required checks (build + smoke + NAPI) must pass to merge;
   the Tier-2 curated gate (both platforms) also runs via the label —
   `publish-release` re-checks it before tagging, so it must be green for the
   release commit.
4. **Real-device smoke** (RELEASE_PLAN Phase 5 / Tier 3) — the CI gate runs on an
   emulator + simulator, which don't fully exercise a physical device's
   restricted `dlopen` / 16 KB-page loader. Before approving, on at least one
   physical **Android arm64** device (16 KB-page where available) and one
   physical **iOS arm64** device, and for **both flavors** (full + lite):
   confirm the testnode boot smoke passes, **and** load the crc-native N-API
   addon — build it for the device ABI with
   `tools/mobile-test/addon/build-{android,ios}-addon.sh`, then stage + run
   `tools/mobile-test/addon/test-napi-addon.js` and confirm `PASS`. Record the
   device model + OS in the PR. This is a manual gate; GitHub-hosted runners
   have no physical devices, so the `release` Environment approval (step 6)
   attests it was done.
5. **Merge the PR** with **rebase/fast-forward** (linear history is required, so
   the merge commit keeps the PR's SHA and its green gate run applies).
6. **Approve the `release` Environment.** Merging fires `publish-release.yml`; it
   waits for your approval, then tags `nodejs-mobile-X.Y.Z`, builds **both
   flavors**, and creates the GitHub Release with four zips:
   `nodejs-mobile-{android,ios}{,-lite}-X.Y.Z.zip`.
7. **Post-release:** open a follow-up PR unflagging `NODE_VERSION_IS_RELEASE`
   (`src: unflag NODE_VERSION_IS_RELEASE`), and bump the consumer plugins
   (`nodejs-mobile-react-native`, `-cordova`).

---

## Why this shape

The old flow was 16 manual steps ending in `git push origin --tags` with nothing
enforcing that CI had passed — a single-point-of-failure we removed. We already
produce the two combined artifacts that *are* the release payload and a credible
test gate ([`TEST_PLAN.md`](./TEST_PLAN.md)); this just wires them so the tag
can only exist after the gate is green and a human approves the publish.
