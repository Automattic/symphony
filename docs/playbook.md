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
| `completion_bar` | — | Baseline bar that must be satisfied before moving an issue to In Review; repos append their own criteria after the render. |
| `continuation_context` | `attempt` | Retry-attempt guidance shown when Symphony re-activates an issue that is still in an active state. |
| `default_posture` | — | General operating posture for an unattended issue run: autonomy, status-first routing, single workpad, planning rigor, and when to stop. |
| `dependency_guardrail` | `lockfile` | Justify dependency changes and keep the lock file diff scoped to the current ticket. |
| `escape_hatches` | — | Blocked-access and in-execution clarification escape hatches; both move the issue to Backlog and stop. |
| `guardrails` | — | Cross-cutting safety and process guardrails for an issue run; repos append repo-specific guardrails after the render. |
| `issue_context` | `issue` | Standard Linear issue fields, description, recent comments, and linked issues for the agent to act on. |
| `out_of_scope_backlog` | — | File a separate Backlog issue for meaningful out-of-scope improvements instead of expanding scope. |
| `pr_feedback_sweep` | — | Required sweep of all PR feedback channels; every actionable comment must be resolved or answered before In Review. |
| `reproduce_and_blast_radius` | — | Capture a reproduction/acceptance signal and a blast-radius analysis before the first code edit. |
| `scoped_tools` | — | How to discover and use the scoped linear_* and github_* tools Symphony injects for the current issue. |
| `status_map` | — | Canonical Symphony issue state machine and what each state means for the agent. |
| `workpad_bootstrap` | `agent` | Find, reuse, or create the single persistent Linear workpad comment and reconcile it before new work. |
| `workpad_template` | `agent` | Canonical structure for the persistent workpad comment. |

## Recommended composition

A repo `WORKFLOW.md` owns the *structure* — the status routing, the numbered
steps, and their ordering — and pulls the shared *prose* blocks in around that
skeleton. A sensible default order, with the repo-authored parts called out:

```liquid
You are working on a Linear ticket `{{ issue.identifier }}`

{% render "continuation_context", attempt: attempt %}
{% render "issue_context", issue: issue %}

{% render "default_posture" %}
{% render "scoped_tools" %}

<!-- repo-authored: command/output hygiene, available skills -->

{% render "status_map" %}

## Step 0 … Step 4   <!-- repo-authored routing + execution skeleton -->
{% render "pr_feedback_sweep" %}
{% render "ci_triage" %}
{% render "escape_hatches" %}

{% render "completion_bar" %}
<!-- repo-authored: extra completion criteria, e.g. coverage gate -->

{% render "guardrails" %}
<!-- repo-authored: extra guardrails, e.g. lock-file rule -->

{% render "out_of_scope_backlog" %}
{% render "dependency_guardrail", lockfile: "<your-lock-file>" %}
{% render "workpad_template", agent: agent %}
```

Leaner repos can also render `workpad_bootstrap` and `reproduce_and_blast_radius`
instead of authoring those steps inline; repos with richer, repo-specific Step 1
detail (pull/sync evidence, coverage planning) keep them inline and interleave the
repo-specific prose.

## Extending a block

Solid partials have no inheritance, so you *extend* a block by rendering it and
appending your own lines immediately after — the partial emits a clean baseline
list, and the repo adds repo-specific bullets below it:

```liquid
{% render "completion_bar" %}
- Coverage is at the repo threshold and the coverage CI job is green.
```

`completion_bar` and `guardrails` are designed for this render-then-append
pattern.
