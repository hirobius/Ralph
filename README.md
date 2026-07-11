# Ralph — the org-level autonomous issue→PR loop engine

This PUBLIC repo hosts the two reusable GitHub workflows every hirobius repo
calls to run Ralph (public because GitHub forbids public repos from calling
reusable workflows hosted in private ones). The files reference secrets by
NAME only — actual secrets live in each caller repo / the org.

## What lives here

- `.github/workflows/ralph-run-reusable.yml` — the run engine: deterministic
  guard (event filter → wedge check → `ralph/next.sh` selection → atomic
  claim) → one model iteration → state-based reconcile. Push events chain via
  a workflow_dispatch hop.
- `.github/workflows/ralph-gate-reusable.yml` — the review gate: per-repo
  `ralph/gate.sh` + independent AI review + HUMAN-approved merges
  (`ralph-approved` on the PR, or `ralph-auto` pre-tagged on the issue) +
  one bounded self-heal per PR.

## Add Ralph to a repo

1. Vendor the `ralph/` script kit from `hirobius/ops` (private, org members):
   `cp -r ../ops/ralph . && rm -rf ralph/logs ralph/runs.jsonl ralph/.lock`
   then edit the two per-repo files: `ralph/gate.sh` and `ralph/config.env`.
2. Add two thin caller workflows (copy from any migrated repo — ops, hds,
   site-engine) pointing at:
   - `hirobius/ralph/.github/workflows/ralph-run-reusable.yml@main`
   - `hirobius/ralph/.github/workflows/ralph-gate-reusable.yml@main`
3. Ensure secrets `CLAUDE_CODE_OAUTH_TOKEN` (+ optional `DISCORD_WEBHOOK_URL`)
   reach the repo (org secrets shared to it, or repo secrets).
4. Branch protection on the default branch requiring the plain `ralph-gate`
   status check + "Allow auto-merge" in repo settings.
5. Tag issues `ralph-ready` (+ `p0`–`p3` priority, + `ralph-auto` to
   batch-pre-approve merges); approve other PRs with the `ralph-approved`
   label. Full contract: `hirobius/ops/ralph/README.md`.

Changes to the engine land here via PR, like everywhere else.
