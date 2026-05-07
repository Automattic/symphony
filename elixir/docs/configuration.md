# Symphony Elixir Configuration Reference

This is the full reference for the Elixir implementation's `WORKFLOW.md` front matter, startup
flags, defaults, and supported values. For the shortest setup path, start with
[`../README.md`](../README.md).

## Startup

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--host` pins the Phoenix observability service to a specific host
- `--port` pins the Phoenix observability service to a specific port

Symphony also keeps an OTP-native durable run store next to the configured log file
(`run_store/`). It persists run history, retry queue entries, session metadata, captured learnings,
and aggregate token totals so retry backoff and observability data survive process restarts. The
same store persists the operator dispatch pause flag, including its reason and timestamp.

## Workflow file shape

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

CI polling is controlled by the optional `ci` block and is disabled by default. When
`pr_review.mode: polling` and `ci.enabled: true` are both set, Symphony starts a `CiPoller` process
that polls GitHub Actions status through `gh pr view --json statusCheckRollup`. Failed checks are
rerun once with `gh run rerun --failed` by default before any agent dispatch. If the rerun also
fails, Symphony stores a truncated failed-job log excerpt, emits a CI failure notification event,
moves the Linear issue back to `In Progress`, and injects the CI failure context into the first
agent prompt. After `ci.max_retries` dispatched attempts, Symphony transitions the issue to
`ci.escalation_state` and emits a CI escalation notification event.

Run learnings are controlled by the optional `learnings` block and are disabled by default. When
`learnings.enabled: true` and `pr_review.mode: polling`, a merged tracked PR triggers one LLM
reflection call through the same Anthropic/OpenAI provider modules used by the quality gate. Valid
JSON responses write up to `max_per_run` records with an evidence quote into the durable run store,
pruned by `max_total_per_repo` per repository. Phase 1 is capture-only: learnings appear read-only
at `/learnings` and are not injected into agent prompts. Provider API keys are read from
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`.

## Full example

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
verification:
  enabled: false
  port_allocation:
    range: [4000, 4099]
  dev_server:
    start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
    health_check_url: "http://localhost:${SYMPHONY_VERIFICATION_PORT}/healthz"
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
ci:
  enabled: false
  # poll_interval_ms: 30000
  # log_excerpt_lines: 200
  # flaky_retry: true
  # max_retries: 3
  # escalation_state: In Review
watchdog:
  enabled: true
  tick_interval_ms: 60000
  no_progress_threshold_ms: 600000
learnings:
  enabled: false
  provider: anthropic
  model: claude-haiku-4-5-20251001
  max_total_per_repo: 500
  max_per_run: 3
notifications:
  enabled: false
  # redact_titles: true
  # channels:
  #   - kind: slack
  #     webhook_url: $SLACK_WEBHOOK_URL
  #     events: [pr_opened, awaiting_review, run_failed, run_stuck, issue_completed, budget_exceeded, reviewer_commented, rework_pushed, ci_failed, ci_escalated]
  #   - kind: webhook
  #     url: $NOTIFY_WEBHOOK_URL
  #     events: [run_failed, run_stuck, budget_exceeded, ci_failed, ci_escalated]
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

## Reference notes

- If a value is missing, defaults are used.
- For Linear trackers, `project_slug` is optional when another scoping filter is set. Configure at
  least one of `project_slug`, `team`, or `labels`; these filters are combined server-side. Example:
  `team: "RSM"` with `labels: ["backend", "infra"]`.
- Safer Codex defaults are used when policy fields are omitted:
  - `agent.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}` for Codex.
  - `agent.thread_sandbox` defaults to `workspace-write` for Codex.
  - `agent.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace for Codex.
  - `agent.network_access.mode` defaults to `allowlist`.
- Supported `agent.approval_policy` values depend on the targeted Codex app-server version. In the
  current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and
  `never`, and object-form `reject` is also supported.
- Supported `agent.thread_sandbox` values for Codex: `read-only`, `workspace-write`,
  `danger-full-access`.
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
- When `agent.turn_sandbox_policy` is set explicitly for Codex, Symphony forwards the configured
  map to Codex, but for `workspaceWrite` policies it ensures the current issue workspace stays in
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
  no token budget is enforced. The per-issue limit stops only the over-budget issue without
  retrying; the daily limit pauses new dispatch for the UTC day while allowing already-running
  agents to continue. Budget enforcement depends on Codex app-server token reporting, so Symphony
  warns if either budget is configured with a command that may not report token usage. Per-issue
  exhausted runs are rehydrated from run history across restarts while the current limit still
  applies; raising or removing the per-issue limit lets the issue dispatch again.
- `watchdog` is enabled by default and protects running agent sessions from silent no-progress
  stalls. It checks running agents every `watchdog.tick_interval_ms` (default: `60000`) and
  compares the current time with the latest transcript event timestamp. When no event has arrived
  for `watchdog.no_progress_threshold_ms` (default: `600000`), Symphony stops the agent session,
  runs `hooks.after_run`, records the run as timed out, emits `run_stuck`, and schedules a retry
  through the normal retry queue/backoff. Set `watchdog.enabled: false` to keep the timer active
  while disabling automatic termination.
- The optional `ci` block is disabled by default. `poll_interval_ms` falls back to
  `polling.interval_ms` when omitted, `log_excerpt_lines` defaults to 200, `flaky_retry` defaults
  to true, `max_retries` defaults to 3, and `escalation_state` defaults to `In Review`.
- The optional `notifications` block is disabled by default. When enabled, Symphony emits semantic
  lifecycle events to configured Slack incoming webhooks and generic JSON webhooks without blocking
  the orchestrator. Supported v1 events are `pr_opened`, `awaiting_review`, `run_failed`,
  `run_stuck`, `issue_completed`, `budget_exceeded`, `reviewer_commented`, `rework_pushed`,
  `ci_failed`, and `ci_escalated`. Per-channel `events` filters limit delivery; omitting `events`
  sends all supported events to that channel. `redact_titles: true` suppresses issue and PR titles
  while preserving identifiers and URLs. Slack and webhook URL/header values support the same `$VAR`
  environment reference convention used by other secret-backed settings.
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
- Optional `verification` orchestration is disabled by default. When `verification.enabled: true`,
  Symphony allocates one port per dispatched issue from `verification.port_allocation.range`
  (default `[4000, 4099]`) and exposes it as `SYMPHONY_VERIFICATION_PORT` to `hooks.before_run`,
  `hooks.after_run`, and the supervised `verification.dev_server.start_cmd`. Symphony does not set
  `PORT`; wire the value explicitly for the tool you run, for example
  `PORT=$SYMPHONY_VERIFICATION_PORT pnpm dev`, `pnpm dev --port $SYMPHONY_VERIFICATION_PORT`, or
  `PORT=$SYMPHONY_VERIFICATION_PORT mix phx.server`. The port range is global to the Symphony
  process, including SSH worker pools; size it for total concurrently dispatched verification runs,
  not per-worker-host concurrency.
- When `verification.dev_server.start_cmd` is set, Symphony starts it in the issue workspace after
  `hooks.before_run` and before the first agent turn, polls `health_check_url` until HTTP 200 or
  `health_timeout_ms`, then stops the process group with `stop_signal` and escalates to SIGKILL
  after `stop_timeout_ms`. The supervised path requires `python3` or `python` on the host so
  Symphony can call `setsid()` before executing the shell command; without Python, verification
  startup fails with `verification_failed` before any agent turn runs. A hook-started dev server
  still works, but it is outside Symphony's supervision and health gate; such hook scripts must
  manage their own backgrounding and cleanup.
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

The optional `quality_gate` block scores each candidate issue with an LLM before it is queued for
dispatch. Issues that score at or above `pass_threshold` dispatch. Issues below
`clarification_floor` are skipped for the session, surfaced in the dashboard's `Skipped` section,
and a Linear comment is posted explaining the score and how to re-queue. When
`clarification_floor` is set, scores from `clarification_floor` through `pass_threshold - 1` are
held in Linear with a deterministic clarification comment instead of being dispatched. They also
appear in the dashboard's `Awaiting clarification` section.

```yaml
quality_gate:
  enabled: true
  provider: anthropic           # or: openai
  model: claude-haiku-4-5-20251001
  pass_threshold: 6             # 1-10; scores >= this dispatch
  clarification_floor: 4        # optional; scores 4..5 ask for clarification
  max_clarification_rounds: 2   # optional; default 2
  on_error: pass                # or: skip
```

- API keys are read from the environment (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`); they are never
  read from `WORKFLOW.md`.
- `min_score` is still accepted for existing configs. When `pass_threshold` is unset, Symphony
  treats `min_score` as the pass threshold and leaves clarification disabled unless
  `clarification_floor` is explicitly set.
- Scores are cached per issue keyed by Linear's `updated_at` plus non-quality-gate comment
  activity, so an operator reply invalidates the cache and the next poll re-scores with the reply in
  context. Symphony's own quality-gate comments do not invalidate the cache by themselves.
- Clarification comments are posted once per issue/comment-activity key. If the operator replies
  and the issue still scores in the clarification band, Symphony asks again until
  `max_clarification_rounds` is reached; after that it skips with a comment naming the cap. If a
  clarified issue later passes, it is dispatched on the next poll.
- `on_error: pass` (default) lets an issue qualify when the LLM call fails, so a failing provider
  does not block dispatch. `on_error: skip` is stricter: when the LLM call fails, the issue is
  skipped for the cycle and retried on the next poll. In both cases the cache is not updated on
  failure, so a transient outage automatically retries.

## Self-review

The optional `self_review` block adds a conservative pre-push LLM gate after the agent completes
validation and reviews `git diff origin/main..HEAD`. It is disabled by default. When enabled, the
workflow prompt tells the agent to pause before `git push`; Symphony then reviews the committed
diff, changed paths, commit subjects/bodies, and issue acceptance criteria using the same
Anthropic/OpenAI provider modules as `quality_gate`.

```yaml
self_review:
  enabled: true
  provider: anthropic
  model: claude-haiku-4-5-20251001
  diff_max_lines: 600
  max_rounds: 1
```

- The self-review prompt only permits blocking findings in `acceptance_criteria`, `commit_message`,
  or `scope_creep`.
- Style, design, speculative risk, and subjective test-coverage opinions are discarded and cannot
  block a push.
- Diffs over `diff_max_lines` are truncated to the first N lines, the gate still runs, and Symphony
  logs a warning naming the line cap.
- Malformed LLM output or provider failures fail open as `approve`.
- On `request_changes`, Symphony injects the findings into one additional agent pass. After the
  follow-up pass, Symphony prompts the agent to push regardless and includes a
  `Known limitations from self-review` PR body block when the final non-blocking pass still reports
  findings.
