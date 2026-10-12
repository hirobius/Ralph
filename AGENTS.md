<!-- ralph:front-door:start — generated from docs/state-surfaces.json by scripts/generate-agents-md.sh; do not hand-edit until the end marker. -->

# AGENTS.md: Ralph

Ralph is the org-level autonomous issue-to-PR loop engine: two reusable GitHub workflows plus a bash kit (`kit/`) that hirobius repos vendor.

## Read order

1. `README.md`: what the kit does, how a repo adopts it, and how `v1` is released.
2. `kit/lib.sh`: the decision functions (reconcile, arming, supervised paths); `kit/next.sh` (selection), `kit/run.sh` (one iteration), `kit/loop.sh`, `kit/prompt.md` (the iteration prompt).
3. `.github/workflows/`: the run, gate and triage reusables (each file's header comment is its contract).
4. `tests/`: decision-table tests with `gh` and `git` stubbed. Run all of them with `bash tests/run.sh`; extend them whenever reconcile or selection semantics change.

Rules for working here:

- `kit/` is vendored byte-identical by consumer repos. A kit change is a fleet change; the gate's drift guard tells each consumer to re-sync.
- Callers pin `@v1`, which is a branch, not a tag. Only backward-compatible changes move it.
- A change under `.github/workflows/` needs a human push: the bot token lacks the `workflows` scope.
- Generated sections (this file, the test list in `README.md`) are rebuilt by their generators, never hand-edited. After changing `docs/state-surfaces.json` or `tests/`, run `bash scripts/generate-agents-md.sh` and `bash scripts/generate-readme-tests.sh`.

## Where live state is

Nothing in the repo records the queue, the open work or what is blocked: ops derives them. Read ops `/ops/standing` (every verdict from live data): https://hirobius-ops-adrian-6234s-projects.vercel.app/ops/standing

For one loop's own health (queue order, in-flight PRs, claims, recent runs) run `kit/status.sh` (vendored as `ralph/status.sh` in a consumer repo). Open work for this repo is GitHub Issues here.

## Documents and what keeps them true

Built from `docs/state-surfaces.json`, which `scripts/check-state-surfaces.sh` gates. Re-read an editorial document, bump its `reviewedAt` there, then run `bash scripts/generate-agents-md.sh`.

### Generated

A script builds it; its `--check` fails when it is stale. Do not hand-edit.

- `README.md` (ralph:tests): The test list, one line per suite. Built by `scripts/generate-readme-tests.sh`.
- `AGENTS.md`: The agent front door: what Ralph is, read order, where live state is, index of these documents. Built by `scripts/generate-agents-md.sh`.
- `kit/status.sh`: Live loop health: queue order, in-flight PRs and wedge state, active claims, recent runs. Nothing is committed; it reads GitHub when run. Generated at runtime.

### Checked

Hand-kept, but a gate compares it with the code.

- `tests`: The kit's decision-table tests (gh and git stubbed); the same run gates the generated docs and this registry. Checked by `tests/run.sh`.

### Editorial

Written by a person; the registry carries who, and when it was last re-read.

- `README.md` (prose): What the kit and reusable workflows do, how a repo adopts Ralph, how v1 is released. Adrian, reviewed 2026-10-12, re-read within 90 days.
- `kit/prompt.md`: The per-iteration prompt consumers vendor: the rules a model iteration follows. Adrian, reviewed 2026-10-12, re-read within 90 days.
- `.github/workflows`: The run, gate and triage reusable workflows; each header comment is that engine's contract. Adrian, reviewed 2026-10-12, re-read within 90 days.

<!-- ralph:front-door:end -->