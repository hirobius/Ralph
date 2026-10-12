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
- Generated sections (this file, the test list in `README.md`) are rebuilt by their generators, never hand-edited. The intro above is the exception: it is `docs/agents-intro.md`, which a person edits. After changing it, `docs/state-surfaces.json` or `tests/`, run `bash scripts/generate-agents-md.sh` and `bash scripts/generate-readme-tests.sh`.

## Where live state is

Nothing in the repo records the queue, the open work or what is blocked: the ops dashboard derives them. Read the ops dashboard's `/ops/standing` (every verdict from live data).

For one loop's own health (queue order, in-flight PRs, claims, recent runs) run `kit/status.sh` (vendored as `ralph/status.sh` in a consumer repo). Open work for this repo is GitHub Issues here.
