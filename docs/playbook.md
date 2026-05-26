# Playbook partials

Symphony owns the generic orchestration playbook as a set of Solid partials. A
repo `WORKFLOW.md` pulls the blocks it wants into its own structure with the
Solid `{% render %}` tag, so the shared prose lives in one place
(`priv/playbook/*.liquid`) and stops drifting across repos. Repo-specific
structure — status map, step ordering, completion bar, conventions — stays
authored in the repo's `WORKFLOW.md`.

## How to use

Place a render tag wherever that block belongs in your flow:

```liquid
{% render "pr_feedback_sweep" %}
{% render "workpad_bootstrap", agent: agent %}
{% render "dependency_guardrail", lockfile: "pnpm-lock.yaml" %}
```

`{% render %}` uses **isolated scope**: a partial only sees the variables you pass
to it, not the surrounding template's `issue` / `agent` / `pr`. Pass every
variable listed in the partial's `Vars` column explicitly. Because rendering runs
with `strict_variables`, a missing variable fails the prompt build loudly rather
than rendering blank, and an unknown partial name raises `template_render_error`.

This catalog is kept in sync with `priv/playbook/` by
`test/symphony_elixir/playbook_catalog_test.exs` — edit the partial's
`{% comment %}` header and this table together.

## Available partials

| Partial | Vars | Description |
| --- | --- | --- |
| `ci_triage` | — | Triage protocol for red CI checks at any push gate. |
| `continuation_context` | `attempt` | Retry-attempt guidance shown when Symphony re-activates an issue that is still in an active state. |
| `dependency_guardrail` | `lockfile` | Justify dependency changes and keep the lock file diff scoped to the current ticket. |
| `escape_hatches` | — | Blocked-access and in-execution clarification escape hatches; both move the issue to Backlog and stop. |
| `issue_context` | `issue` | Standard Linear issue fields, description, recent comments, and linked issues for the agent to act on. |
| `out_of_scope_backlog` | — | File a separate Backlog issue for meaningful out-of-scope improvements instead of expanding scope. |
| `pr_feedback_sweep` | — | Required sweep of all PR feedback channels; every actionable comment must be resolved or answered before In Review. |
| `reproduce_and_blast_radius` | — | Capture a reproduction/acceptance signal and a blast-radius analysis before the first code edit. |
| `workpad_bootstrap` | `agent` | Find, reuse, or create the single persistent Linear workpad comment and reconcile it before new work. |
| `workpad_template` | `agent` | Canonical structure for the persistent workpad comment. |
