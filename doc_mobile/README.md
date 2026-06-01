# nodejs-mobile maintainer docs

`nodejs-mobile` is **upstream Node.js plus a stack of mobile-specific patches**,
rebased on a clean `nodejs/node` release tag. The current line is **Node 24**
(`mobile/v24`); `main` is the legacy Node 18 line. These docs are for
maintainers building, testing, releasing, and upgrading that patch stack. (For
using nodejs-mobile in an app, see the consumer plugins
`nodejs-mobile-react-native` / `nodejs-mobile-cordova`.)

New here, or an agent? Start with [`/CLAUDE.md`](../CLAUDE.md) at the repo root —
the orientation + task playbooks — then dive into the doc for your task below.

## Maintenance & upgrading
- [MAINTENANCE_MODEL.md](./MAINTENANCE_MODEL.md) — the patch-stack model and
  branch layout; the canonical "how this project is maintained".
- [UPGRADING.md](./UPGRADING.md) — step-by-step recipe to rebase the stack onto
  a newer upstream Node release.
- [PATCH_TOOLING.md](./PATCH_TOOLING.md) — the `scripts/mobile/` export / apply /
  verify patch tooling.
- [PATCHES_ONLY_PROPOSAL.md](./PATCHES_ONLY_PROPOSAL.md) — a *filed-for-later*
  proposal to move patches out-of-tree; revisit after the next rebase.

## Building & releasing
- [BUILDING.md](./BUILDING.md) — build the Android `libnode.so` and the iOS
  `NodeMobile.xcframework` (incl. the `lite` flavor).
- [RELEASING.md](./RELEASING.md) — the guarded, automated release process
  (version-bump PR → required checks → approval-gated tag + publish).
- The [lite variant](#the-lite-variant) — a comapeo-tuned smaller binary
  (see below).

## Testing
- [TEST_PLAN.md](./TEST_PLAN.md) — the CI test strategy and the pre-release
  **gate**: the tiered smoke → curated `test/parallel` subset → real-device ladder.
- [TESTING.md](./TESTING.md) — manual how-to for running the upstream test suite
  on a physical device via the proxy harness.

## The lite variant

The build ships in two flavors (selected by `NODEJS_MOBILE_FLAVOR`, default
`full`). **`full`** is the general-purpose binary all consumers get. **`lite`**
is a smaller binary tuned for one consumer (CoMapeo), built by layering
feature-drops on top of the full configure — so the full binary and its test
gate are unchanged.

What `lite` drops (all already-available upstream `configure` flags, so no extra
patch-stack surface):

| Cut | Why it's safe for comapeo |
|---|---|
| `--without-amaro` (TS type-stripping) | comapeo ships plain `.js` |
| `--without-inspector` | not used in production |
| `--without-sqlite` | comapeo uses the `better-sqlite3` addon, not `node:sqlite` |
| `--with-intl=none` (no ICU) | comapeo's backend uses no `Intl.*` (verified: its only `Intl` user, valibot's `Intl.Segmenter`, sits behind grapheme validators comapeo doesn't use); it also shipped on Node 18 with `intl=none` |
| `-ffunction-sections`/`--gc-sections` | dead-code strip; no behavior change |
| **iOS only:** `--v8-lite-mode` | drops the compiled JIT + V8 WASM engine, both **dead on iOS** (it runs jitless; undici's WASM is served by the polywasm JS shim). This is the big lever. |

Measured shipping sizes (arm64, after symbol strip):

- **iOS:** ~63 MB (full) → **~44.5 MB (lite)**, a ~29% cut (mostly `--v8-lite-mode`).
- **Android:** smaller via the feature drops + gc-sections, but no
  `--v8-lite-mode` (Android keeps the JIT and V8's native WASM for undici).

`build-id` (`-Wl,--build-id=sha1`) is emitted on the Android `libnode.so` in
**both** flavors so Sentry can symbolicate native crashes. The standing
safeguard for `intl=none` is the comapeo backend test suite run against the lite
binary — it catches any `Intl` breakage from future dependency changes.

## Reference
- [CONTRIBUTING.md](./CONTRIBUTING.md) — contribution guidelines and the DCO.
- [FAQ.md](./FAQ.md) — common questions about what nodejs-mobile supports.
- [CHANGELOG.md](./CHANGELOG.md) — release history.

## v24 point-in-time records
Snapshots of the Node 18 → 24 upgrade, kept as provenance for the upstream
review. **They will be removed once the v24 work is merged upstream** (their
substance moves into the upstream RFC / PR description), so don't treat them as
living docs:
- [UPSTREAM_PROPOSAL_v24.md](./UPSTREAM_PROPOSAL_v24.md) — the RFC proposing the
  `mobile/v24` patch stack to the maintainers (source text for the RFC issue).
- [V24_AUDIT_REPORT.md](./V24_AUDIT_REPORT.md) — per-file audit of the import.
- [UPGRADE_BLOCKERS_v24.md](./UPGRADE_BLOCKERS_v24.md) — the upgrade blockers + fixes.
- [RELEASE_PLAN_v24.md](./RELEASE_PLAN_v24.md) — the v24 release plan.
