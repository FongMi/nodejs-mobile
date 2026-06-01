# Proposal: out-of-tree patches repo (post-v24)

**Status:** proposal, not adopted. Filed for discussion after a v24 release exists.

## Summary

This document outlines a possible *future* structure for nodejs-mobile in
which this repo no longer carries a full copy of upstream Node.js source.
Instead, it would contain only:

- a `patches/` directory of `*.patch` files describing the mobile diff,
- the small set of files that exist *only* in nodejs-mobile and have no
  upstream counterpart (build helpers, framework templates, test
  infrastructure, embedding API, mobile docs),
- a build script that clones `nodejs/node` at a pinned tag, copies the
  mobile-only files into the checkout, applies the patches, and builds.

This is the model used by [Electron](https://github.com/electron/electron),
Debian source packages, Yocto/OpenEmbedded recipes, Buildroot, OpenWrt, and
several long-lived embedded forks.

It is proposed as a **follow-up** to the patch-stack-on-fork model
introduced in this branch — *not* as a replacement for it. The patch-stack
model is a prerequisite: until mobile changes are organized as discrete,
well-named commits on top of an upstream tag, there is nothing to extract
into a `patches/` directory.

## Motivation

The current repo carries ~30,000 files of upstream Node.js source that
nodejs-mobile does not modify. Concretely this causes:

- Slow `git clone` — discouraging casual contributors and complicating CI.
- A GitHub UI that is dominated by upstream files; the question "what does
  nodejs-mobile actually change?" requires `git diff` against a tag, not a
  glance at the file tree.
- Squash-merge based history that breaks `git tag --merged` and similar
  ancestry queries, as found while building the `validate-patch-stack`
  workflow.
- Supply-chain auditing that requires diffing against upstream — there is
  no canonical, in-repo list of "the bytes nodejs-mobile adds."

A patches-only layout addresses all four points by making the mobile
contribution explicit and small.

## Proposed repo layout

```
patches/
  0001-android-build-pin-NDK-r27d.patch
  0002-ios-build-split-host-toolchain.patch
  0003-ios-build-iphoneos-deployment-target-14.patch
  …                                               # one per mobile change
  series                                          # ordered list of patches to apply
mobile-src/                                       # files that have no upstream counterpart
  doc_mobile/
  android-configure
  android_configure.py
  android-patches/
  src/api/embed_helpers.cc
  src/node_mobile_version.h
  tools/android_build.sh
  tools/copy_libnode_headers.sh
  tools/ios-framework/
  tools/ios_framework_prepare.sh
  tools/mobile-test/
  .github/workflows/build-mobile.yml
  .github/workflows/validate-patch-stack.yml
upstream-base.txt                                 # pinned upstream tag, e.g. v24.15.0
scripts/
  prepare.sh                                      # clone upstream, layer mobile-src, apply patches
  regenerate-patches.sh                           # extract patches from a working tree back into patches/
README.md
```

A typical clone would be a few MB. A working source tree only exists after
running `scripts/prepare.sh`, which produces an `out/` directory with the
full source.

## Build process

```sh
./scripts/prepare.sh                    # clones nodejs/node@$(cat upstream-base.txt)
                                        # into out/, copies mobile-src/* in,
                                        # applies patches/*
cd out
./android-configure $NDK 24 arm64
make -j$(nproc)
```

CI does the same. The clone is cached between runs, so the cost is
~minutes of upstream fetch plus the actual build.

## Contributor workflow

```sh
./scripts/prepare.sh                    # one-time setup
cd out
# … edit src/node.cc, common.gypi, etc. …
make node                                # iterate
cd ..
./scripts/regenerate-patches.sh         # extracts your changes back into patches/
git add patches/
git commit -m "android,build: …"
```

`regenerate-patches.sh` is the script that has to actually exist for this
model to work. The simplest implementation:

```sh
cd out
git format-patch \
  --output-directory ../patches/ \
  --zero-commit \
  --no-numbered \
  --signature='' \
  $(cat ../upstream-base.txt)..HEAD
```

This re-emits the patch series from the working tree's git history. It
relies on `out/` itself being a git checkout, with each mobile change as
its own commit — which is exactly the discipline the in-tree patch-stack
model already establishes.

## Tradeoffs

### Wins

- Repo size: ~50 files instead of 30,000.
- Supply-chain story: `git log` against this repo enumerates every byte
  added on top of the pinned upstream.
- Ancestry is sound by construction: `upstream-base.txt` points to a real
  tag, and patches apply cleanly or visibly fail.
- GitHub UI is navigable; reviewers see only mobile-relevant files.
- Migration to a new upstream major is mechanically the same as a minor
  bump, just with more conflicts to resolve.

### Costs

- Contributor dev loop is one step longer (`prepare.sh` before editing,
  `regenerate-patches.sh` after).
- GitHub PR review of source changes shows patch text rather than rendered
  diffs. Mitigations: a CI bot that posts the resolved diff as a PR
  comment; or use a dedicated review tool. Electron lives with this and
  reviewers adapted.
- A wrapper toolchain has to exist and be maintained. Electron's
  [`build-tools`](https://github.com/electron/build-tools) is the
  reference; ours would be much smaller (no Chromium) but still real
  software.
- Requires that the patch stack already be clean — no squash-merge
  commits, no hidden carry-forwards. That's the migration prerequisite.

## Migration sequencing

1. **Land the patch-stack model on this fork** (this PR's branch).
2. **Cut a v24 release** using the in-tree model. Users get a working
   release; the new discipline is exercised end-to-end.
3. **Open a sibling repo**, e.g. `nodejs-mobile/build`. Generate
   `patches/*.patch` from the diff between `mobile/v24` HEAD and
   `v24.x.y`. Write `prepare.sh` and `regenerate-patches.sh`.
   Reproduce a build. Iterate on contributor experience.
4. **Run both repos in parallel for a release cycle.** Compare
   contributor friction, CI cost, and bug counts.
5. **If the prototype is healthy:** archive `nodejs-mobile/nodejs-mobile`
   with a README pointer to the new repo. Active development moves.
6. **If the prototype is painful:** stay on the in-tree patch stack. The
   experiment cost is bounded.

## Why not git submodules

A submodule pinning `nodejs/node` at a release tag, with a parallel
`patches/` tree applied at build, is superficially attractive but
generally regretted in practice:

- `--recurse-submodules` is required almost everywhere; contributors
  forget it and end up with empty submodule directories.
- A submodule with applied patches is in a state that `git status` does
  not describe well (dirty submodule + parallel patch series).
- Tor Browser and Electron both evaluated submodules and rejected them
  for nodejs-style projects.

Submodules work well when the dependency is unmodified. As soon as it is
patched, the model breaks down.

## Open questions

- Where do the **mobile-only files** live? Two reasonable answers:
  1. In a `mobile-src/` directory in this repo, copied into the upstream
     checkout by `prepare.sh`. Simple, but means most "mobile-only"
     edits don't go through `patches/`.
  2. As a single "introduce nodejs-mobile" patch at the start of the
     series. More uniform, but produces a giant patch that's effectively
     re-introducing the same files every upgrade.

  Electron uses approach 1 (a `shell/` directory plus `patches/`). That
  is probably the right answer here too.

- How are **vendored dependencies** (deps/v8 inside upstream) patched?
  Electron has nested `patches/` directories per dep. We have a much
  smaller surface — mainly `deps/v8`, `deps/uv`, `deps/zlib` — but the
  same nested structure would apply.

- Does the mobile-test infrastructure (`tools/mobile-test/ios`,
  `tools/mobile-test/android`) live in this repo or in a dedicated
  testing repo? Probably this repo, because it's tightly coupled to the
  patch series.

- What's the right **release artifact** to publish? Today: pre-built
  `.xcframework` and `libnode.so` zip. That doesn't change.

## When to revisit

After a v24 release exists and has been running for one development
cycle. Concrete trigger: the second upstream rebase (e.g. v24.15.0 →
v24.18.0) is when the in-tree patch-stack model gets stress-tested. If
that rebase is smooth, this proposal stays a proposal. If it's painful,
the migration becomes worth the work.
