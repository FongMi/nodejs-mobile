# Proposal for discussion: Node 24 support as a rebased patch stack

> For the nodejs-mobile maintainers. This is a proposal we'd genuinely like your
> view on — not a finished thing we're asking you to merge as-is. We're
> contributors coming from the CoMapeo project rather than maintainers of this
> repo, so we're very likely missing context. Please push back on anything that's
> wrong, or that cuts against how you'd rather run things; if the shape here isn't
> what you want, that's entirely fair and we'd rather hear it now.
>
> (If anything like this does land, the v24-specific notes —
> [V24_AUDIT_REPORT](./V24_AUDIT_REPORT.md),
> [RELEASE_PLAN_v24](./RELEASE_PLAN_v24.md),
> [UPGRADE_BLOCKERS_v24](./UPGRADE_BLOCKERS_v24.md), and this file — are
> scaffolding and should be deleted, not kept.)

## What this is

An attempt at Node 24.15.0 support, arranged as the clean upstream `v24.15.0`
tag plus 33 small, subsystem-prefixed commits on top (in three rough groups),
instead of one large squashed import. There's a test harness that runs a curated
subset on CI; it currently passes, though — see the caveats below — it doesn't
prove a great deal on its own.

There's nothing clever here; if anything it's the boring option. We know a few
people have asked for a newer Node (#156, #152, #133, #25) while the project sits
on v18.20.4, and this is one possible way to get there. The only real hope is
that it's a bit easier to review, and a bit easier to carry to the next upstream
release.

## Why we tried a different shape

There are already two open v24 attempts (#158, #151), and clearly a lot of work
went into them — getting Node 24 to build for mobile at all is not small, and
we've leaned on that work. Our only difficulty is practical: each is a single
squashed commit of roughly 5 million changed lines across ~30,000 files, which
is very hard for a reviewer (or for us) to read through or bisect, and they
target the older v24.5.0. That's not really a criticism of the authors so much
as of the squash-merge flow the docs describe — it folds a whole upstream bump
into one commit, which was always going to be unwieldy at this size.

So we tried keeping the mobile changes as separate commits on top of the
upstream tag. It's quite possible this is the wrong call for your workflow; if
you'd prefer the squashed form, or a different split, we're happy to redo it.

## The shape

`v24.15.0` + 33 mobile commits, loosely in three groups:

1. **Fork infrastructure** (additive only): the mobile version header, the
   Android/iOS build scripts and xcframework project, the test apps and harness,
   CI workflows, patch tooling, and docs.
2. **Build-system changes**: deltas to `configure.py`, `common.gypi`,
   `node.gyp`/`node.gypi`, the v8 gypfiles, and the gyp generators — each a
   focused diff on the `v24.15.0` base.
3. **Behaviour and test changes**: adjustments in `src/`, `deps/`, `lib/`, and
   the test skips/adaptations.

We've kept the original maintainers as `Co-authored-by` wherever we reorganised
their work (69 trailers in all) — much of this is their code rearranged rather
than ours. If we've mis-attributed anything, please say.

The intention is that a regression can be traced to one commit and that the next
upstream bump is a rebase rather than another full re-import (see
[MAINTENANCE_MODEL.md](./MAINTENANCE_MODEL.md) /
[UPGRADING.md](./UPGRADING.md)). Whether it actually achieves that is for you to
judge.

## What else is in here, and what it's worth

A few things came along with the bump. We'd rather flag them honestly, including
where they fall short:

- A test harness running a curated ~150-case subset of `test/parallel` through a
  relaunch proxy on an Android emulator and an iOS simulator. It's green, but
  it's only emulator/simulator and a hand-picked subset — a regression baseline
  at best, not evidence the runtime is sound on real hardware. See
  [TEST_PLAN.md](./TEST_PLAN.md).
- A per-file pass over the v18→v24 merge ([V24_AUDIT_REPORT.md](./V24_AUDIT_REPORT.md))
  that turned up a handful of files left at their v18 versions — understandable
  in a merge that size — which would have broken the build. We fixed the ones we
  found; we may well have missed others, and a second pair of eyes would be very
  welcome.
- A smaller "lite" build flavour tuned to one consumer (CoMapeo); the default
  build is unchanged. Probably of niche interest. See
  [the lite variant](./README.md#the-lite-variant).
- Some release automation (a version-bump PR gated on the tests, the tag created
  on merge behind an approval) so a release needn't depend on one person
  remembering the steps. See [RELEASING.md](./RELEASING.md).

## If you'd like to take it forward

Roughly what we had in mind, but entirely your call:

1. First, whether the patch-stack shape is acceptable at all — there's little
   point in the rest if it isn't.
2. If so, perhaps three smaller PRs (the groups above) onto a `mobile/v24`
   branch alongside `main`, so the riskier build-system and behaviour changes get
   proper attention while the additive infrastructure can be skimmed.
3. Real-device smoke on physical arm64 hardware, including loading a native
   (NAPI) addon — the one thing CI can't stand in for.
4. Tag and release.

We're glad to do as much or as little of the legwork as is useful, in whatever
form suits you.

## Things we're unsure about, and known gaps

- Whether changing the upgrade procedure (squash → patch stack) is something you
  want at all. That's the real question; the code is the easy part.
- The NAPI-on-device behaviour (the original "B-1" concern) hasn't been exercised
  on real hardware yet — the emulator/simulator doesn't load addons the same way.
- A couple of commits are only correct at the tip of the stack, not in isolation
  (audit F8/F9) — noted in case you read them one at a time.
- We don't have the history the maintainers do, so some choices may unknowingly
  undo something deliberate. Corrections gratefully received.

## On the existing work

To be clear: #158/#151 (and the earlier #150 for v22) are real effort on a real
problem, and we've built on them. If this is useful, we'd suggest closing them
with credit to their authors; if it isn't, no harm done.
