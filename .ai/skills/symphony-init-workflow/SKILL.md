---
name: symphony-init-workflow
description: Author a repo-specific WORKFLOW.md for Symphony after `symphony init` has created symphony.yml.
---

# Symphony WORKFLOW.md Init

Use this skill after `symphony init` has created the operator-owned `symphony.yml`.
Your job is to inspect the repository and write a tailored repo-owned `WORKFLOW.md`;
do not generate generic language templates.

## 1. Inspect The Repo

Read only files in the target repository. Prefer these signals:

- `mix.exs`, `package.json`, `Gemfile`, `pyproject.toml`, `go.mod`, `Cargo.toml`
- `Makefile`, `justfile`, `Taskfile.yml`, `bin/*`, `scripts/*`
- `.github/workflows/*`
- existing agent or contributor docs such as `AGENTS.md`, `CLAUDE.md`, or `CONTRIBUTING.md`

Identify the real commands for:

- dependency setup or bootstrap
- targeted or fast local validation for iteration
- tests
- lint/format checks
- the full pre-handoff validation gate
- any profiling command that exposes slow tests or checks
- any hook that should run after Symphony creates a fresh workspace

Prefer repository-owned aggregate commands over language defaults. For example,
choose `make all`, `pnpm test:unit`, or `bundle exec rspec` when the repo
declares those commands; do not guess `mix test`, `npm test`, `pytest`,
`go test ./...`, `cargo test`, or `bundle exec rake test` unless repo evidence
points there.

## 2. Resolve Ambiguity

If multiple plausible commands exist and the repo does not show a clear primary
gate, ask one or two concise clarifying questions before writing `WORKFLOW.md`.
Do not ask questions when the repo has an obvious aggregate command or CI gate.

## 3. Write WORKFLOW.md

Create or update `WORKFLOW.md` with YAML front matter and a prompt body.

The front matter should include only repo-local settings, especially:

- `hooks.after_create` for workspace bootstrap commands when needed
- `validation` or other repo-supported validation keys already accepted by
  Symphony's runtime parser
- repo-specific verification dev-server settings when applicable

Keep operator-wide settings in `symphony.yml`; do not move `tracker`, `repos`,
`workspace.root`, `agent.command`, polling, CI, notification, or quality-gate
operator settings into `WORKFLOW.md`.

The prompt body should tell the agent how to work in this repository:

- respect existing conventions and docs
- use the discovered validation commands before handoff
- explain any repo-specific status, review, or handoff rules

Do not duplicate Symphony's managed runtime context in `WORKFLOW.md`. Symphony
already prepends platform-owned guidance for workspace isolation, untrusted
Linear/GitHub/CI/tool-output handling, scoped tools, workpad usage, obvious
secret paths, and final-response shape.

### Pull shared playbook blocks instead of re-authoring them

Symphony owns the generic orchestration playbook (PR feedback sweep, CI triage,
escape hatches, workpad bootstrap/template, out-of-scope→Backlog, dependency
guardrail) as Solid partials. Pull the blocks your flow needs with `{% render %}`
instead of copy-pasting the prose — that is what keeps these blocks from drifting
across repos:

```liquid
{% render "pr_feedback_sweep" %}
{% render "workpad_bootstrap", agent: agent %}
{% render "dependency_guardrail", lockfile: "<your-lock-file>" %}
```

`{% render %}` uses isolated scope, so pass every variable the partial needs
(`agent`, `lockfile`, …) explicitly. See [`docs/playbook.md`](../../docs/playbook.md)
for the full catalog of partial names and their variables. Author only the
repo-specific structure — status map, step ordering, completion bar, conventions —
directly in `WORKFLOW.md`, and place the render tags where each block belongs in
that flow.

## 4. Validate

Before declaring done, validate with the same parser the runtime uses:

```bash
mix run -e 'case SymphonyElixir.Workflow.load("WORKFLOW.md") do {:ok, _} -> :ok; {:error, reason} -> raise inspect(reason) end'
```

`Workflow.load` only parses the front matter; it does not render the body, so it
cannot catch a typo'd `{% render %}` partial name. Confirm the prompt actually
composes by building it once with a stub issue — a bad partial name raises
`template_render_error`:

```bash
mix run -e 'SymphonyElixir.Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md")); SymphonyElixir.PromptBuilder.build_prompt(%SymphonyElixir.Linear.Issue{identifier: "VALIDATE-0", title: "validate", state: "In Progress"}); IO.puts("prompt render ok")'
```

Also run the discovered targeted or fast local validation when it is practical
for the current change. Reserve full gates for handoff or push-readiness when
the repo documents them as expensive.

## Manual Check For This Repo

In the Symphony repository, `Makefile` declares `make check` as the fast local
validation gate and `make all` as the full pre-push gate. A correct
`WORKFLOW.md` for this repo should teach both commands, plus the profiling
targets (`make test-profile`, `make coverage-profile`, `make dialyzer-profile`),
instead of guessing a generic `mix test` command.
