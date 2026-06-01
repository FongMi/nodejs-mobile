# Maintenance model: patch stack on top of upstream Node.js

`nodejs-mobile` is maintained as a **patch stack** rebased on top of an
upstream `nodejs/node` release tag. The mobile-specific changes live as
discrete, atomic commits on top of a clean upstream base. There is no
long-lived "merge of upstream" model.

This was adopted in 2026 (replacing the squash-merge `format-patch` flow that
was the project's previous procedure) because:

- Each mobile patch is reviewable and attributable on its own.
- Conflicts during an upstream rebase are scoped to the file each patch
  touches, instead of arriving as one giant unresolvable blob.
- Supply-chain auditing is tractable: anyone can run `git log vX.Y.Z..` to
  enumerate every byte we add on top of upstream.
- When upstream eventually fixes a problem we patched around, the
  corresponding patch can be deleted cleanly.

The squash-merge model was the basis of every nodejs-mobile release to date
and reflects significant sustained work by maintainers; the patch-stack
model is intended to make the next major upgrade more incremental, not to
discard that work.

## Branch layout

| Branch                     | Purpose                                                       |
| -------------------------- | ------------------------------------------------------------- |
| `mobile/v24` (and similar) | Long-lived patch stack on top of an upstream major version.   |
| Per-PR feature branches    | Cut from `mobile/v24`, merged via rebase to keep stack clean. |

The tip of `mobile/v24` is always `vX.Y.Z` (an upstream release tag) plus a
sequence of mobile-only commits.

`main` (legacy) tracks the v18.20.4 release line and is no longer actively
developed. New work targets `mobile/v24`.

## Adding a new mobile patch

1. Branch from `mobile/v24`.
2. Make a single focused change. Prefix the subject line with the affected
   subsystem(s), e.g. `android,build: ...`, `ios,test: ...`.
3. Each commit should be small, focused, and self-explanatory. The commit
   message body should describe *why* the change is needed (what platform
   issue it solves) so future maintainers can decide whether the patch is
   still needed when a future upstream Node.js release fixes the underlying
   problem.
4. Open a PR against `mobile/v24`. CI runs `./android-configure` against
   every commit on the branch (see
   [`.github/workflows/validate-patch-stack.yml`](../.github/workflows/validate-patch-stack.yml))
   so a broken intermediate commit is rejected even if HEAD builds.
5. Merge by **rebase**, not merge-commit. The patch stack must stay linear.

## Updating to a newer upstream Node.js

This is the primary exercise of the maintenance model. See
[UPGRADING.md](./UPGRADING.md) for the step-by-step procedure. In summary:

```sh
git fetch upstream tag vX.Y.Z         # e.g. 24.15.0 → 24.16.0
git checkout -b mobile/v24-rebase-X.Y.Z mobile/v24
git rebase --onto vX.Y.Z vA.B.C       # vA.B.C is the current base
# resolve conflicts patch-by-patch
git push --force-with-lease origin mobile/v24-rebase-X.Y.Z
# open PR; CI must be green per-patch before merge
```

A force-push happens on the rebase PR branch only, never on `mobile/v24`
itself. The merge into `mobile/v24` is a fast-forward of the validated
rebase.

## Cross-major upgrades

When a new upstream major lands (e.g. v26), branch a fresh `mobile/v26`
from the upstream release tag and cherry-pick patches from `mobile/v24` one
at a time. Many will need rework; some will be obsolete because upstream
fixed the issue we were patching around. `mobile/v26` is a sibling of
`mobile/v24`, not a descendant.
