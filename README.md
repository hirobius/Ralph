# Ralph — the org-level autonomous issue→PR loop engine

This PUBLIC repo hosts the two reusable GitHub workflows every hirobius repo
calls to run Ralph (public because GitHub forbids public repos from calling
reusable workflows hosted in private ones). The files reference secrets by
NAME only — actual secrets live in each caller repo / the org.

## What lives here

- `kit/` — the **canonical shared kit**, listed in `kit/MANIFEST.json`
  (`lib.sh`, `next.sh`, `run.sh`, `loop.sh`, `status.sh`, `prompt.md` and the
  manifest itself). Consumer repos vendor byte-identical copies under
  `ralph/`; the gate reusable enforces that through `scripts/kit-drift.sh`,
  which reads the manifest (see below). A new kit file goes in the manifest
  in the same change, or `tests/kit-manifest.test.sh` fails. The two
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
- **Frontier selection** (ops#474): `next.sh` skips a `ralph-ready` issue while
  any same-repo `#N` listed under its `## Blocked by` heading (any `#` level,
  optional colon, CRLF tolerated) is still open (logged to stderr; no park, no
  attempt burned). CLOSED and MERGED blockers are done. A missing section or
  "None…" means no blockers; a blocker that is missing or whose state can't be
  read fails closed (skip, reason logged). The check runs after the claim and
  open-PR guards, with blocker states cached per run.
- **Parked PRs** (ops#476): an open Ralph PR labelled `needs-adrian` is parked
  on a human — it does not hold single-flight (run.sh exit 13), and
  `next.sh` never re-picks the issue that owns it.
- `tests/` — decision-table tests for the kit, `gh`/`git` stubbed, no network
  (the #86 stall and #126 restart loop are both locked cases); see **Tests**
  below.
- `.github/workflows/ralph-gate-reusable.yml` — the review gate: **kit-drift
  checksum guard** (vendored `ralph/` vs `kit/`; a PR touching a drifted kit
  file fails, pre-existing drift warns) + per-repo `ralph/gate.sh` +
  independent AI review + HUMAN-approved merges, now behind the
  **supervised-path boundary** (`ralph_diff_is_supervised` in `kit/lib.sh`,
  ralph#25): a diff touching a path a caller's `RALPH_SUPERVISED_CMD` names
  never auto-merges regardless of which of the three reasons armed it
  (`ralph-approved` on the PR, `ralph-auto` pre-tagged on the issue, or the
  opt-in `RALPH_DEFAULT_AUTO_MERGE` posture below) — it posts an
  awaiting-approval comment naming the supervised files instead, and only a
  human adding `ralph-approved` merges it. Callers with no
  `RALPH_SUPERVISED_CMD` configured see no change. One bounded self-heal per
  PR either way.
- `.github/workflows/ralph-triage-reusable.yml` — the intake comb
  (propose-then-approve): scopes candidate work into TDD-shaped issue
  proposals; never tags `ralph-ready`, never touches code.

- **Close on merge + `post-close.sh` hook** (ops#531): if a merged Ralph PR's
  body names the issue with a closing keyword (`Closes`/`Fixes`/`Resolves #N`,
  any case) but the issue is still open, the kit closes it as completed
  (instead of parking it). Without a keyword it still parks. Bot closes never
  trigger other workflows, so after any close the kit itself performs it runs
  an optional, executable `ralph/post-close.sh <issue-number>` (looked up
  beside `gate.sh`) — e.g. to run a spec rollup. A missing hook is fine; a
  failing hook only logs a warning.

## Tests

`bash tests/run.sh` runs every suite (CI: `.github/workflows/test.yml`, with
shellcheck). Extend `tests/*.test.sh` whenever reconcile/selection semantics
change. The same run checks that the generated docs are fresh
(`AGENTS.md`, this list) and that `docs/state-surfaces.json` holds: every
registered path exists, no markdown names a missing path. The suites:

<!-- ralph:tests:start — generated from tests/*.test.sh by scripts/generate-readme-tests.sh; do not hand-edit until the end marker. -->

- `tests/approver-gate.test.sh`: Approver gate wiring (ralph#44): RALPH_APPROVER=off|shadow|on.
- `tests/approver.test.sh`: Approver Phase 1 (ralph#43, engine side of ops#564): ralph_approver_decide is a pure decision table.
- `tests/arm-reason.test.sh`: ralph_arm_reason tests (ralph#26).
- `tests/attempts.test.sh`: Attempt-accounting tests for the selector's budget guard (ops#303).
- `tests/blocked-inference.test.sh`: Fallback blocked-stop inference (ops#303, the PRIMARY half).
- `tests/claim-dedupe.test.sh`: Decision-table tests for ralph#17's double-claim dedupe: recent_claim_within (kit/lib.sh) and its wiring into next.sh's selector.
- `tests/classify-wedged.test.sh`: Decision-table tests for classify_wedged (ralph#16) — the single-flight wedge check must tell "gate is running" from "gate died/never...
- `tests/close-on-merge.test.sh`: ops#531: a merged Ralph PR whose body names the issue with a closing keyword but left it open must CLOSE the issue (not park it), and...
- `tests/closure-verify.test.sh`: Post-merge closure verification (ops#305).
- `tests/consumer-pins.test.sh`: Consumer pin audit tests (ralph#45, spec #40): scripts/audit-consumer-pins.sh reads each repo's caller workflows through `gh api` and...
- `tests/default-auto-merge.test.sh`: RALPH_DEFAULT_AUTO_MERGE default (ralph#26).
- `tests/docs-fresh.test.sh`: The real repo's docs are fresh (ralph#37, spec ops#576).
- `tests/dod-draft.test.sh`: ops#296: a missing DoD checklist drafts one as a comment instead of a bare park.
- `tests/fast-sleep.test.sh`: Test speed (ralph#40): retry/backoff sleeps are stubbed in tests, so a retried gh call costs no wall time, and the backoff schedule is...
- `tests/gate-arming.test.sh`: Gate arming wiring (ralph#25 / ralph#26).
- `tests/generated-docs.test.sh`: Generated-docs tests (ralph#37, spec ops#576): scripts/generate-readme-tests.sh (README's test list from tests/*.test.sh) and...
- `tests/how-ralph-decides.test.sh`: How Ralph Decides doc generator tests: scripts/generate-how-ralph-decides.sh (docs/HOW-RALPH-DECIDES.md generated from kit/lib.sh...
- `tests/kit-lock.test.sh`: kit-lock.sh (ralph#42): consumers pin their vendored kit in ralph/kit.lock.json ({"ref":..., "files":{name: sha256}}, ops#492/#568).
- `tests/kit-manifest.test.sh`: Kit manifest (ralph#42): kit/MANIFEST.json is the one list of vendored kit files.
- `tests/lessons-drift.test.sh`: The vendored lessons copy in .claude/lessons matches its lock, and the recall hook is wired (ops#610).
- `tests/next.test.sh`: Decision-table tests for next.sh — the deterministic selector.
- `tests/parked-prs.test.sh`: Decision-table tests for ops#476 — a Ralph PR labelled needs-adrian is PARKED on a human and no longer holds single-flight (run.sh exit...
- `tests/pre-pr-gates.test.sh`: Pre-PR gates (ops#504): tests-with-code hook, /pr body headings, red-first.
- `tests/reconcile.test.sh`: Decision-table tests for reconcile_issue — the loop's single most safety-critical decision: "the model iteration finished — what...
- `tests/release.test.sh`: Release-train check tests (ralph#45, spec #40): scripts/release.sh refuses a bad tag name, a taken tag, a dirty tree, a HEAD that is not...
- `tests/result-file.test.sh`: ralph#46 (workflow half of ralph#10): the run reusable turns claude-code-action's execution_file into RALPH_RESULT_FILE, so a silent...
- `tests/retry-hop.test.sh`: retry_hop_issue tests (ops#481).
- `tests/runner.test.sh`: tests/run.sh (ralph#40): suites run in parallel, but their output prints in a fixed order (the order given), and the run fails when any...
- `tests/state-surfaces.test.sh`: State-surface registry gate tests (ralph#37, spec ops#576): scripts/check-state-surfaces.sh.
- `tests/supervised-paths.test.sh`: ralph_diff_is_supervised tests (ralph#25).

<!-- ralph:tests:end -->

Agents working on the kit start at `AGENTS.md`.

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

   | Knob | Default | What it does |
   |---|---|---|
   | `ralph-approved` (PR label) | — | Arms auto-merge on this one PR. |
   | `ralph-auto` (issue label) | — | Pre-approves every PR closing this issue. |
   | `RALPH_SUPERVISED_CMD` | empty (no boundary) | Command printing the supervised-path manifest (ops#400); a diff matching it never auto-merges under ANY of the three reasons below — it waits for a human `ralph-approved` instead (ralph#25). |
   | `RALPH_DEFAULT_AUTO_MERGE` | `false` | Opt-in: a green gate + AI-approved PR with NO label at all still arms auto-merge (ralph#26). Still fully subject to the `RALPH_SUPERVISED_CMD` boundary — the flag can never bypass it. Set per-repo in `ralph/config.env`; the engine default is never flipped here. |
   | `RALPH_APPROVER` | `off` | ralph#44 (ops#564): `shadow` posts the approver's verdict (merge / escalate / park + reason) as a PR comment only; `on` labels escalated or parked PRs `needs-adrian`, quotes the reason on the issue, pages Discord when the approver can't run, and lets a `merge` verdict arm auto-merge (still behind `RALPH_SUPERVISED_CMD`). The table lives in `ralph_approver_decide` (`tests/approver.test.sh`). |

   All four arming reasons (`ralph-approved`, issue `ralph-auto`, an
   approver `merge`, `RALPH_DEFAULT_AUTO_MERGE`) are gated by the same supervised-path check —
   none of them can merge a supervised diff without a human's
   `ralph-approved`.
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

- **Callers pin `@v1`, never `@main`.** `main` can then move freely without
  changing what any fleet repo executes. Upgrading a repo = a deliberate PR in
  that repo (bump the ref in its three callers), never a side effect of an
  engine push.

  **`v1` is a BRANCH (`refs/heads/v1`), not a tag** — this repo has no tags at
  all. Verify with `git ls-remote --tags origin` (empty) and by reading any
  consumer run's `referenced_workflows`, which reports `ref: refs/heads/v1`.
  Release it by fast-forwarding:

  ```sh
  git push origin origin/main:refs/heads/v1     # fast-forward, nothing discarded
  ```

  Do NOT run `git tag -f v1` — that creates a *tag* named `v1` beside the
  *branch* named `v1`, leaving `@v1` ambiguous for every consumer at once.
  Confirm `git merge-base --is-ancestor origin/v1 origin/main` first; if that
  fails, `v1` has diverged and a force would discard commits.
- **`v1` only moves for backward-compatible changes** — same caller files,
  same permission contract, same inputs/secrets. Re-point it with the
  fast-forward push above. Anything that requires
  callers to change (new required permission, input, or secret) is **v2**:
  new tag, plus a PR per consumer repo updating its callers in the same
  breath. A permission a caller might lack must degrade gracefully in-run
  (fail-soft with the named fix), never be requested at the job level.

**Tag flow for v2 and later (ADR-009 section 2).** Releases after `v1` are
immutable tags (`v2`, `v2.1.0`), never moved once pushed. `ops` re-pins first;
`hds` and `site-engine` follow after a week of green ops runs. Rollback is a
PR re-pinning the previous tag. `scripts/release.sh <tag>` only checks (name,
tag unused locally and on origin, clean tree, HEAD is `origin/main`, tests
green) and prints the commits since the previous tag plus the exact
`git tag -a` and `git push origin refs/tags/<tag>` lines for a person to run.
`scripts/audit-consumer-pins.sh` shows who runs what: one line per consumer
use, `repo workflow ref behind`, read-only.

Changes to the engine land here via PR, like everywhere else.
