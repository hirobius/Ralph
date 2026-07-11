# Ralph — the org-level autonomous issue→PR loop engine

This PUBLIC repo hosts the two reusable GitHub workflows every hirobius repo
calls to run Ralph (public because GitHub forbids public repos from calling
reusable workflows hosted in private ones). The files reference secrets by
NAME only — actual secrets live in each caller repo / the org.

## What lives here

- `kit/` — the **canonical shared kit** (`lib.sh`, `next.sh`, `run.sh`,
  `loop.sh`, `status.sh`, `prompt.md`). Consumer repos vendor byte-identical
  copies under `ralph/`; the gate reusable enforces that (see below). The two
  **per-repo** files — `ralph/gate.sh` and `ralph/config.env` (plus each
  repo's `ralph/README.md`) — are exempt and live only in the consumers.
- `.github/workflows/ralph-run-reusable.yml` — the run engine: deterministic
  guard (event filter → wedge check → `ralph/next.sh` selection → atomic
  claim) → one model iteration → state-based reconcile. Push events chain via
  a workflow_dispatch hop.
- `.github/workflows/ralph-gate-reusable.yml` — the review gate: **kit-drift
  checksum guard** (vendored `ralph/` vs `kit/`; a PR touching a drifted kit
  file fails, pre-existing drift warns) + per-repo `ralph/gate.sh` +
  independent AI review + HUMAN-approved merges (`ralph-approved` on the PR,
  or `ralph-auto` pre-tagged on the issue) + one bounded self-heal per PR.
- `.github/workflows/ralph-triage-reusable.yml` — the intake comb
  (propose-then-approve): scopes candidate work into TDD-shaped issue
  proposals; never tags `ralph-ready`, never touches code.

## Add Ralph to a repo

1. Vendor the shared kit **from this repo**:
   `cp -r ../ralph/kit <repo>/ralph` — then author the two per-repo files:
   `ralph/gate.sh` (the repo's own red/green gate command) and
   `ralph/config.env` (knobs; write the header comment for THAT repo).
   Re-sync after any engine kit change the same way — the gate's checksum
   guard will tell you when.
2. Add three thin caller workflows (copy from any migrated repo — ops, hds,
   site-engine) pointing at:
   - `hirobius/ralph/.github/workflows/ralph-run-reusable.yml@main`
   - `hirobius/ralph/.github/workflows/ralph-gate-reusable.yml@main`
   - `hirobius/ralph/.github/workflows/ralph-triage-reusable.yml@main`
3. The repo's `package.json` must pin `"packageManager": "pnpm@<version>"` —
   the engine installs whatever it names (no hardcoded version).
4. Ensure secrets `CLAUDE_CODE_OAUTH_TOKEN` (+ optional `DISCORD_WEBHOOK_URL`)
   reach the repo (org secrets shared to it, or repo secrets).
5. Branch protection on the default branch requiring the plain `ralph-gate`
   status check + "Allow auto-merge" in repo settings.
6. Tag issues `ralph-ready` (+ `p0`–`p3` priority, + `ralph-auto` to
   batch-pre-approve merges); approve other PRs with the `ralph-approved`
   label. Full contract: `hirobius/ops/ralph/README.md`.

Changes to the engine land here via PR, like everywhere else.
