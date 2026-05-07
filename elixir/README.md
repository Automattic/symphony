# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Symphony recently ran an agent for an issue that later moves outside active states but has not
reached a terminal state, the terminal status view and LiveView dashboard show it in a Watching
section with its current Linear state, last-run age, and Linear URL.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - By default, `pr_review.mode: tracker` expects the Linear workflow to drive review loops with
     states such as "Rework" and "Merging". Set `pr_review.mode: polling` to let Symphony poll
     GitHub while Linear stays on the standard Todo → In Progress → In Review → Done path.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` pins the Phoenix observability service to a specific port

Symphony also keeps an OTP-native durable run store next to the configured log file
(`run_store/`). It persists run history, retry queue entries, session metadata, and aggregate token
totals so retry backoff and observability data survive process restarts.

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

PR review mode is controlled by the optional `pr_review` block. `tracker` is the default and
preserves the existing human-driven review loop. In `polling` mode, Symphony starts a
`PrReviewPoller` process that discovers in-review issues with attached GitHub PRs, records their
PR URL and workspace path in the durable run store, waits `cooldown_minutes` before responding to
requested changes or non-bot reviewer comments, moves approved or rework-requested issues back to
`In Progress` for the orchestrator to dispatch through the normal run path, injects unaddressed
reviewer comments into the first prompt, and removes tracked workspaces when PRs close or stay idle
beyond `stale_days`. `cooldown_minutes`, `stale_days`, comment bot filters, and review follow-up
flags are polling-only settings; polling mode defaults them to 10 minutes, 7 days, no ignored users,
and no GitHub replies or review re-requests when omitted.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
  assignee: null
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
routing:
  - requires_label: js
    hooks:
      after_create: |
        git clone git@github.com:your-org/js-package.git .
  - requires_label: php
    hooks:
      after_create: |
        git clone git@github.com:your-org/php-plugin.git .
agent:
  kind: codex
  max_concurrent_agents: 10
  max_turns: 20
  # max_tokens_per_issue: 500000
  # max_tokens_per_day: 5000000
  command: codex app-server
  network_access:
    mode: allowlist
    allowed_domains: []
    denied_domains: []
pr_review:
  mode: tracker
  # The following keys are polling-mode only and are ignored while mode is tracker.
  # mode: polling
  # auto_reply: false
  # auto_request_review: false
  # github_user: null
  # bot_users: []
notifications:
  enabled: false
  # redact_titles: true
  # channels:
  #   - kind: slack
  #     webhook_url: $SLACK_WEBHOOK_URL
  #     events: [pr_opened, awaiting_review, run_failed, issue_completed, budget_exceeded, reviewer_commented, rework_pushed]
  #   - kind: webhook
  #     url: $NOTIFY_WEBHOOK_URL
  #     events: [run_failed, budget_exceeded]
  #     headers:
  #       Authorization: $NOTIFY_AUTH_HEADER
quality_gate:
  enabled: true
  provider: anthropic           # or: openai
  model: claude-haiku-4-5-20251001
  pass_threshold: 6             # >= this score, issues dispatch
  clarification_floor: 4        # 4..5 asks Linear clarification questions
  max_clarification_rounds: 2   # then skip until the description is updated
  on_error: pass                # or: skip
self_review:
  enabled: false                # opt in to a pre-push LLM self-review
  provider: anthropic           # or: openai
  model: claude-haiku-4-5-20251001
  diff_max_lines: 600
  max_rounds: 1                 # v1 only supports one correction round
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- For Linear trackers, `project_slug` is optional when another scoping filter is set. Configure at
  least one of `project_slug`, `team`, or `labels`; these filters are combined server-side. Example:
  `team: "RSM"` with `labels: ["backend", "infra"]`.
- Safer Codex defaults are used when policy fields are omitted:
  - `agent.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}` for Codex.
  - `agent.thread_sandbox` defaults to `workspace-write` for Codex.
  - `agent.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace for Codex.
  - `agent.network_access.mode` defaults to `allowlist`.
- Supported `agent.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `agent.thread_sandbox` values for Codex: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `agent.network_access.mode` values:
  - `allowlist`: enables the Codex sandbox network switch and sends a thread-level
    `config.experimental_network` allow map built from Symphony's built-in dev domains plus
    `allowed_domains` minus `denied_domains`.
  - `open`: enables the Codex sandbox network switch without a Symphony-managed domain overlay,
    matching the previous broad `networkAccess: true` behavior.
  - `block`: disables the Codex sandbox network switch, matching `networkAccess: false`.
  `denied_domains` always takes precedence over built-in and user-provided `allowed_domains`.
- `agent.command_timeout_ms` caps a single shell command even when it keeps streaming output.
  Default: `600000` (10 minutes). Set `0` to disable this command-level guard.
- When `agent.turn_sandbox_policy` is set explicitly for Codex, Symphony forwards the configured map to
  Codex, but for `workspaceWrite` policies it ensures the current issue workspace stays in
  `writableRoots` at runtime when a workspace path is available. Symphony always includes the
  issue workspace `.git` path. For local Git checkouts, Symphony asks Git for the actual
  `--git-dir` and `--git-common-dir` and includes those roots too, so branch, commit, fetch, and
  push operations can update metadata for both regular clones and linked worktrees. When those
  roots cannot be discovered, `workspace.strategy: worktree` falls back to the configured
  repository `.git` metadata root. Symphony prepends these managed roots before any
  `writableRoots` already present in the configured policy, and deduplicates the combined list.
  Compatibility for the remaining fields still depends on the targeted Codex app-server version
  rather than local Symphony validation. For known Codex policies with a boolean `networkAccess`
  field, `agent.network_access` controls that field.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.max_tokens_per_issue` and `agent.max_tokens_per_day` are optional guardrails. When omitted,
  no token budget is enforced. The per-issue limit stops only the over-budget issue without retrying;
  the daily limit pauses new dispatch for the UTC day while allowing already-running agents to
  continue. Budget enforcement depends on Codex app-server token reporting, so Symphony warns if
  either budget is configured with a command that may not report token usage. Per-issue exhausted
  runs are rehydrated from run history across restarts while the current limit still applies; raising
  or removing the per-issue limit lets the issue dispatch again.
- The optional `notifications` block is disabled by default. When enabled, Symphony emits semantic
  lifecycle events to configured Slack incoming webhooks and generic JSON webhooks without blocking
  the orchestrator. Supported v1 events are `pr_opened`, `awaiting_review`, `run_failed`,
  `issue_completed`, `budget_exceeded`, `reviewer_commented`, and `rework_pushed`. Per-channel `events` filters limit delivery; omitting
  `events` sends all supported events to that channel. `redact_titles: true` suppresses issue and PR
  titles while preserving identifiers and URLs. Slack and webhook URL/header values support the same
  `$VAR` environment reference convention used by other secret-backed settings.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- Set `workspace.strategy: worktree` to create each issue workspace from an existing local primary
  clone instead of cloning in `hooks.after_create`. Configure `workspace.repo` with that primary
  clone path; Symphony creates `auto/<issue-identifier>` branches with `git worktree add`, fetches
  `origin` before dispatch by default, and removes worktree workspaces with `git worktree remove
  --force` during cleanup.
- With SSH workers, `workspace.root` and `workspace.repo` are both interpreted on the worker host.
  Each worker host needs its own primary clone; Symphony surfaces a workspace error if it is missing.
- Use `routing` to override workspace hooks for issues with specific Linear labels. Entries are
  checked in order; the first `requires_label` that matches an issue label wins. Hook fields omitted
  from a matching route fall back to the top-level `hooks` values, and issues without a matching
  label use the top-level hooks unchanged.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- Set `tracker.assignee` to a Linear user ID, or `me` to use the current API token's Linear viewer,
  when you want one Symphony process to pick up only issues assigned to that user. If unset, all
  active issues in the configured Linear scope are eligible. `tracker.assignee` reads from
  `LINEAR_ASSIGNEE` when unset or when value is `$LINEAR_ASSIGNEE`.
- `tracker.project_slug` is optional. Linear tracker configs must set at least one of
  `tracker.project_slug`, `tracker.team`, or a non-empty `tracker.labels` list.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` and `workspace.repo` resolve `$VAR`
  before path handling. For Codex, `agent.command` stays a shell command string and any `$VAR`
  expansion there happens in the launched shell; Claude Code commands are split into executable
  arguments before launch.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
  strategy: worktree
  repo: $SOURCE_REPO_PATH
hooks:
  after_create: |
    mix deps.get
agent:
  kind: codex
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `observability.transcript_buffer_size` controls how many recent Codex events each running issue
  keeps for transcript replay. Default: `200`.
- The Phoenix LiveView dashboard, transcript view, and JSON API start by default on an ephemeral
  local port. Set `server.port` or pass CLI `--port` to pin the port. Set
  `observability.dashboard_enabled: false` to keep the default observability service off unless
  `--port` is supplied for that run. The service exposes `/`,
  `/issues/<issue_identifier>/transcript`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and
  `/api/v1/refresh`. The state endpoint includes recent durable run history when available.

## Quality gate

The optional `quality_gate` block scores each candidate issue with an LLM
*before* it is queued for dispatch. Issues that score at or above
`pass_threshold` dispatch. Issues below `clarification_floor` are skipped for
the session, surfaced in the dashboard's `Skipped` section, and a Linear
comment is posted explaining the score and how to re-queue. When
`clarification_floor` is set, scores from `clarification_floor` through
`pass_threshold - 1` are held in Linear with a deterministic clarification
comment instead of being dispatched. They also appear in the dashboard's
`Awaiting clarification` section.

```yaml
quality_gate:
  enabled: true
  provider: anthropic           # or: openai
  model: claude-haiku-4-5-20251001
  pass_threshold: 6             # 1–10; scores >= this dispatch
  clarification_floor: 4        # optional; scores 4..5 ask for clarification
  max_clarification_rounds: 2   # optional; default 2
  on_error: pass                # or: skip
```

- API keys are read from the environment (`ANTHROPIC_API_KEY` /
  `OPENAI_API_KEY`); they are never read from `WORKFLOW.md`.
- `min_score` is still accepted for existing configs. When `pass_threshold` is
  unset, Symphony treats `min_score` as the pass threshold and leaves
  clarification disabled unless `clarification_floor` is explicitly set.
- Scores are cached per issue keyed by Linear's `updated_at` plus
  non-quality-gate comment activity, so an operator reply invalidates the cache
  and the next poll re-scores with the reply in context. Symphony's own
  quality-gate comments do not invalidate the cache by themselves.
- Clarification comments are posted once per issue/comment-activity key. If the
  operator replies and the issue still scores in the clarification band,
  Symphony asks again until `max_clarification_rounds` is reached; after that it
  skips with a comment naming the cap. If a clarified issue later passes, it is
  dispatched on the next poll.
- `on_error: pass` (default) lets an issue qualify when the LLM call
  fails, so a failing provider does not block dispatch. `on_error: skip`
  is stricter — when the LLM call fails, the issue is skipped for the
  cycle and retried on the next poll. In both cases the cache is *not*
  updated on failure, so a transient outage automatically retries.

## Self-review

The optional `self_review` block adds a conservative pre-push LLM gate after
the agent completes validation and reviews `git diff origin/main..HEAD`.
It is disabled by default. When enabled, the workflow prompt tells the agent to
pause before `git push`; Symphony then reviews the committed diff, changed
paths, commit subjects/bodies, and issue acceptance criteria using the same
Anthropic/OpenAI provider modules as `quality_gate`.

```yaml
self_review:
  enabled: true
  provider: anthropic
  model: claude-haiku-4-5-20251001
  diff_max_lines: 600
  max_rounds: 1
```

- The self-review prompt only permits blocking findings in
  `acceptance_criteria`, `commit_message`, or `scope_creep`.
- Style, design, speculative risk, and subjective test-coverage opinions are
  discarded and cannot block a push.
- Diffs over `diff_max_lines` are truncated to the first N lines, the gate still
  runs, and Symphony logs a warning naming the line cap.
- Malformed LLM output or provider failures fail open as `approve`.
- On `request_changes`, Symphony injects the findings into one additional
  agent pass. After the follow-up pass, Symphony prompts the agent to push
  regardless and includes a `Known limitations from self-review` PR body block
  when the final non-blocking pass still reports findings.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- LiveView for a running issue transcript at `/issues/<issue_identifier>/transcript`
- JSON API for operational debugging under `/api/v1/*`
- Running, Watching, and retry queue sections for active sessions, human-waiting issues, and backoff
  pressure
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
