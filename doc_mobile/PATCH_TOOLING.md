# Mobile patch tooling

Three small scripts under [`scripts/mobile/`](../scripts/mobile/) turn the
in-tree mobile patch stack into an exportable, re-appliable, and *verifiable*
patch series. They are the concrete bridge between the patch-stack maintenance
model ([MAINTENANCE_MODEL.md](./MAINTENANCE_MODEL.md),
[UPGRADING.md](./UPGRADING.md)) that this repo already follows and the
out-of-tree patches-only repo sketched in
[PATCHES_ONLY_PROPOSAL.md](./PATCHES_ONLY_PROPOSAL.md).

All three read the patch-stack base from
[`upstream-base.txt`](./upstream-base.txt) using the exact same parse as the
CI workflow `.github/workflows/validate-patch-stack.yml`: the first
non-comment, non-empty line, whitespace-stripped. Today that is `v24.15.0`.

## The scripts

### `export-patches.sh [output_dir]`

Emits the stack as a numbered patch series.

```sh
scripts/mobile/export-patches.sh ./mobile-patches-out
```

- Runs `git format-patch <base>..HEAD` into `output_dir` (default
  `./mobile-patches-out`).
- `--zero-commit` and `--no-signature` make re-exports of identical content
  byte-stable: the goal is "applies cleanly", not commit provenance, so the
  ephemeral `From <sha>` line and the trailing git-version signature are
  pinned/removed to avoid churn across machines and git versions.
- Clears any prior `*.patch` / `series` files in the output dir first, so a
  shrinking stack never leaves stale patches behind.
- Writes a `series` manifest: the patch basenames in apply order, one per
  line. This is the file `apply-patches.sh` consumes and the file a
  patches-only repo would track in git.
- Prints the base, output dir, and patch count.

This is the in-tree equivalent of the `regenerate-patches.sh` sketched in
PATCHES_ONLY_PROPOSAL.md.

### `apply-patches.sh <upstream_checkout_dir> [patches_dir]`

The "prepare" half: layer the series onto a clean upstream checkout.

```sh
git clone --depth 1 --branch v24.15.0 https://github.com/nodejs/node.git ./node-build
scripts/mobile/apply-patches.sh ./node-build ./mobile-patches-out
```

- Requires `upstream_checkout_dir` to be a git repo, already at the base tag,
  with a clean working tree.
- Applies each patch listed in `patches_dir/series` (default
  `./mobile-patches-out`) in order with
  `git am --3way --keep-cr --whitespace=nowarn`.
  - `--3way` lets git fall back to the blob context embedded in each patch so
    hunks whose line numbers drifted across minor upstream churn still merge,
    while real conflicts still fail loudly.
  - `--whitespace=nowarn` forces a byte-exact apply regardless of the
    caller's `apply.whitespace` git config. The common `apply.whitespace=fix`
    setting would otherwise silently strip trailing whitespace and mutate the
    tree — see the note in `verify-patches.sh` below.
- Stops on the first failed patch, naming it and printing the exact `git am`
  recovery commands, then exits non-zero.

### `verify-patches.sh [patches_dir]`

The proof. Exports the series from `HEAD`, applies it to a throwaway worktree
of the base tag, and asserts the reconstructed tree is identical to `HEAD`'s
tree.

```sh
scripts/mobile/verify-patches.sh
```

1. Calls `export-patches.sh` into a scratch dir (or `patches_dir` if given).
2. `git worktree add --detach <tmp> v24.15.0` — a throwaway checkout that
   never touches your branches.
3. Calls `apply-patches.sh` against that worktree.
4. Compares `git rev-parse HEAD^{tree}` of the worktree against `HEAD^{tree}`
   of this repo. Identical trees ⇒ the series is a lossless representation of
   the mobile diff.
5. Always removes the worktree (`git worktree remove --force`) and scratch
   dirs on exit, including after a failure or interrupt.

Exits `0` on a clean reconstruction; non-zero with a `git diff --stat` summary
on mismatch. This is exactly the integrity gate a patches-only repo needs in
CI: it guarantees `apply(export(HEAD)) == HEAD`.

## How a maintainer uses these

### (a) Export the series

After landing or rebasing the stack (see [UPGRADING.md](./UPGRADING.md)):

```sh
scripts/mobile/export-patches.sh ./mobile-patches-out
ls ./mobile-patches-out          # 0001-*.patch … + series
```

### (b) Bootstrap a patches-only repo

Following the layout in PATCHES_ONLY_PROPOSAL.md, the one-time seed of the
sibling `patches/` repo:

```sh
# In this source-carrying repo, on the released tip (e.g. mobile/v24):
scripts/mobile/export-patches.sh /tmp/seed-patches

# In the new patches-only repo:
mkdir -p patches
cp /tmp/seed-patches/*.patch /tmp/seed-patches/series patches/
cp <this-repo>/doc_mobile/upstream-base.txt .
git add patches upstream-base.txt && git commit -m "seed patch series from v24.15.0"
```

Its `prepare.sh` then clones `nodejs/node` at `$(cat upstream-base.txt)`,
copies the mobile-only files in, and applies the series — the apply step is
exactly what `apply-patches.sh` does:

```sh
git clone --branch "$(cat upstream-base.txt)" https://github.com/nodejs/node.git out
scripts/mobile/apply-patches.sh out patches
```

### (c) Verify integrity in CI

Add a job that fails the build if the series ever drifts from `HEAD`:

```yaml
verify-patch-series:
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0          # need the base tag + full history
    - run: git fetch --tags --force
    - run: scripts/mobile/verify-patches.sh
```

`fetch-depth: 0` (or an explicit fetch of the base tag) is required because
the script checks out the base tag in a worktree. The job is fast — it does no
compilation, only `format-patch` + `git am` + a tree comparison — so it
complements rather than replaces the per-commit build validation in
`validate-patch-stack.yml`.

## Relationship to the existing model

| Artifact | Role |
| --- | --- |
| `upstream-base.txt` | single source of truth for the base; read by all three scripts and by `validate-patch-stack.yml`. |
| `UPGRADING.md` | how to rebase the stack onto a newer upstream tag (produces the commits these scripts export). |
| `validate-patch-stack.yml` | per-commit *build* validation of the stack at each commit. |
| `export/apply/verify-patches.sh` | turn the validated stack into a portable, verifiable patch series. |
| `PATCHES_ONLY_PROPOSAL.md` | the future repo these scripts make possible. |

These scripts add no new source of truth and modify no existing files; they
are pure tooling layered on the discipline the patch-stack model already
enforces.
