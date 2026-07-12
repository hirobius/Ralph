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
  claim) → one model iteration → state-based reconcile. Push and schedule
  events chain via a workflow_dispatch hop. Reconcile is **run-scoped and
  state-based**: an OPEN PR (or one merged during THIS run) → success; a PR
  merged in a *past* run parks the still-open issue to `needs-adrian` instead
  of masking a no-op iteration (the hds#126 restart loop); branch-but-no-PR →
  recover the PR; a **deliberate blocked-stop** (the model posted a
  `ralph-blocked:` comment, or the issue left the ready queue mid-run) → route
  to `needs-adrian`, **no attempt burned** (keeps a "needs a human" issue from
  reddening the run and halting the chain, site-engine#86); a human-closed PR →
  `needs-adrian` for direction, not a retry; anything else → record a failed
  attempt, park on the cap. `next.sh` applies the same PR-history guard at
  selection time, so the looping class never even costs a model iteration.
- `tests/` — decision-table tests for the kit (`reconcile.test.sh` +
  `next.test.sh`, `gh`/`git` stubbed, no network; the #86 stall and #126
  restart loop are both locked cases) run via `.github/workflows/test.yml`
  with shellcheck. Extend `tests/*.test.sh` whenever reconcile/selection
  semantics change.
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
   site-engine) pointing at the **`v1` tag — never `@main`** (see Versioning):
   - `hirobius/ralph/.github/workflows/ralph-run-reusable.yml@v1`
   - `hirobius/ralph/.github/workflows/ralph-gate-reusable.yml@v1`
   - `hirobius/ralph/.github/workflows/ralph-triage-reusable.yml@v1`
   The caller job's `permissions:` block is the engine's permission contract:
   grant `contents`/`issues`/`pull-requests`/`statuses`/`id-token`: `write`
   (+ `actions: write` for the merge→next-issue chain hop). The reusables
   deliberately declare NO job-level permissions — they inherit the caller's
   grant, and a step whose optional permission is missing degrades with a
   message naming the fix instead of startup-failing the whole run (ops#144).
3. The repo's `package.json` must pin `"packageManager": "pnpm@<version>"` —
   the engine installs whatever it names (no hardcoded version).
4. Ensure secrets `CLAUDE_CODE_OAUTH_TOKEN` (+ optional `DISCORD_WEBHOOK_URL`)
   reach the repo (org secrets shared to it, or repo secrets).
5. Branch protection on the default branch requiring the plain `ralph-gate`
   status check + "Allow auto-merge" in repo settings.
6. Tag issues `ralph-ready` (+ `p0`–`p3` priority, + `ralph-auto` to
   batch-pre-approve merges); approve other PRs with the `ralph-approved`
   label. Full contract: `hirobius/ops/ralph/README.md`.
7. **Recommended — idle watchdog:** add a `schedule:` trigger to the repo's
   run caller (`.github/workflows/ralph.yml`), e.g. `cron: "23 * * * *"`.
   Without it the loop is event-driven only and halts silently after a failed
   iteration, or when an `issues: labeled` run is cancelled by the
   concurrency dedup while another run holds the group. The tick re-enters
   the guard, so an idle tick is a quiet no-op: empty queue or a healthy
   in-flight PR → skip; wedged → Discord alert (repeats hourly until
   cleared); ready work + idle loop → claim + dispatch hop. Stagger the cron
   minute per repo so fleet ticks don't stampede the shared claim/PR checks.

## Versioning — callers pin tags, upgrades are deliberate

Lesson of ops#144: callers are *vendored files* that skew behind the engine —
an engine change that tightens what it needs from callers broke every gate
run org-wide with a blank `startup_failure`. Two rails prevent the class:

- **Callers pin the `v1` tag, never `@main`.** `main` can then move freely
  without changing what any fleet repo executes. Upgrading a repo = a
  deliberate PR in that repo (bump the tag in its three callers), never a
  side effect of an engine push.
- **`v1` only moves for backward-compatible changes** — same caller files,
  same permission contract, same inputs/secrets. Re-point it with
  `git tag -f v1 <sha> && git push -f origin v1`. Anything that requires
  callers to change (new required permission, input, or secret) is **v2**:
  new tag, plus a PR per consumer repo updating its callers in the same
  breath. A permission a caller might lack must degrade gracefully in-run
  (fail-soft with the named fix), never be requested at the job level.

Changes to the engine land here via PR, like everywhere else.
