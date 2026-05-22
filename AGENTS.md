# Symphony

This repository contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Fast local gate: `make check` (format check, lint, build, plain tests).
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`SPEC.md`](SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then use the fast local gate before the full pre-push gate.

```bash
make check
```

Before push/handoff, run the full gate or at least the required coverage and Dialyzer gates.

```bash
make all
```

To profile slow validation work before optimizing tests, use:

```bash
make test-profile
make coverage-profile
make dialyzer-profile
```

Preserve full output for long-running gates so the failing phase can be
identified after the fact. Avoid piping to `tail` (e.g. `make all 2>&1 | tail
-80`) — if the command times out or is killed, only the last lines survive and
the actual failing phase is lost. Prefer either splitting the gate into its
phases (`make check`, `make coverage`, `make dialyzer`) so each command's log
stands alone, or `tee` the full stream to a file:

```bash
HEX_HOME=/private/tmp/symphony-hex-home SYMPHONY_MCP_SOCKET_ROOT=/private/tmp/symphony-mcp \
  make all 2>&1 | tee /tmp/symphony-make-all.log
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `README.md` for project concept, goals, and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
