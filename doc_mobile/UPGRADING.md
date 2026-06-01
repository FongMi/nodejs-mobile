# Updating nodejs-mobile to a newer upstream Node.js

This document describes how to rebase the mobile patch stack onto a newer
upstream Node.js release. It is the canonical procedure under the
patch-stack maintenance model
([MAINTENANCE_MODEL.md](./MAINTENANCE_MODEL.md)); the squash-merge
`format-patch` workflow used previously is deprecated in this branch.

## Prerequisites

```sh
git remote add upstream https://github.com/nodejs/node.git
git fetch upstream --tags
```

## 1. Pick a target version

The mobile fork tracks one upstream major at a time. The current branch is
`mobile/v24`.

For minor/patch upgrades within a major, prefer the latest published release
tag. For major upgrades, expect the rebase to require multi-day work and to
produce a new long-lived branch (e.g. `mobile/v26`).

## 2. Identify the current base

The current patch-stack base is recorded in
[`doc_mobile/upstream-base.txt`](./upstream-base.txt). The first non-comment,
non-empty line is the SHA (or tag) the stack is rebased on; subsequent lines
are informational (typically the human-readable version label).

```sh
cat doc_mobile/upstream-base.txt
```

CI ([`validate-patch-stack.yml`](../.github/workflows/validate-patch-stack.yml))
reads this file to enumerate the patches it must validate. **Updating this
file is part of every rebase** — make it the first commit on the rebase
branch.

## 3. Create a rebase branch

```sh
git checkout -B mobile/v24-rebase-24.16.0 mobile/v24
git rebase --onto v24.16.0 v24.15.0 mobile/v24-rebase-24.16.0
```

`git rebase` will replay every mobile patch on top of `v24.16.0`. Patches that
touch files unchanged upstream will replay cleanly. Patches that touch files
upstream also modified will land in conflict — resolve them individually.

If you encounter a patch that has been **made obsolete by upstream** (e.g.
upstream fixed the issue we were patching around), drop the commit:

```sh
git rebase --skip   # if the rebase says "the patch is now empty"
```

If a patch needs to be **rewritten** to fit the new upstream code, do so in
`git rebase --continue`, but keep the original commit subject (so it's clear
to future maintainers what the patch was originally for) and add a brief
note in the commit body, e.g. `Reworked for v24.16.0: foo.cc was renamed to
bar.cc upstream.`

## 4. Validate per patch

Push the rebase branch:

```sh
git push --force-with-lease origin mobile/v24-rebase-24.16.0
```

CI runs the [`validate-patch-stack`](../.github/workflows/validate-patch-stack.yml)
workflow which checks that **every commit** on the rebase branch
configure-validates against Android. A broken intermediate patch must be
fixed before merge — even if `HEAD` happens to build.

Mobile platform builds (the `build-android` / `build-ios` matrices in
[`build-mobile.yml`](../.github/workflows/build-mobile.yml)) only run at the
tip of the branch.

## 5. Smoke-test on real devices

Before merging:

- Run `tools/mobile-test/prepare-android-test.sh` then
  `tools/mobile-test/node-android-proxy.sh tools/test.py` on at least one
  arm64 Android device.
- Run `tools/mobile-test/prepare-ios-tests.sh` then
  `tools/mobile-test/node-ios-proxy.sh tools/test.py` on an arm64 iOS device
  and on the iOS simulator.

Document any newly skipped tests by adding a `test,android: SKIP <test>` or
`test,ios: SKIP <test>` patch to the stack.

## 6. Merge

```sh
git checkout mobile/v24
git merge --ff-only mobile/v24-rebase-24.16.0
git tag nodejs-mobile-24.16.0
git push origin mobile/v24 nodejs-mobile-24.16.0
```

Update `src/node_mobile_version.h` and `doc_mobile/CHANGELOG.md` as the last
patch in the stack (or as a separate `release:` commit, by convention the
final commit on the branch).

## Cross-major upgrades (e.g. v24 → v26)

A cross-major rebase is functionally a fresh patch stack:

1. Branch `mobile/v26` from `upstream/v26.x.y` (a release tag).
2. `git cherry-pick` patches from `mobile/v24` one at a time. Many will need
   rework; some will be obsolete.
3. Open a PR per logical group of patches (build system, source guards,
   tests, CI). Each PR enforces per-patch CI.
4. When all patches land and devices smoke-test green, cut the first
   `nodejs-mobile-26.x.y` release.

Cross-major upgrades should target an LTS release.

## Known v24 blockers

When rebasing the v24 stack to a newer minor, watch out for the issues
documented in [UPGRADE_BLOCKERS_v24.md](./UPGRADE_BLOCKERS_v24.md).
