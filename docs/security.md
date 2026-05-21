# Security

Symphony runs autonomous coding agents against real repositories, real tracker accounts, and real
GitHub remotes. This document describes what Symphony does to keep those actions contained, and the
operational practices an operator should layer on top.

## Threat Model

Symphony is designed against three primary risks:

- **A misbehaving agent** that wanders outside the current issue's workspace, leaks secrets, or
  pushes to the wrong remote.
- **Untrusted tracker input** — anyone who can edit a Linear issue can attempt prompt injection
  through the title, description, or comments.
- **Operational mistakes** that expose the unauthenticated dashboard or quality-gate provider
  traffic to the public network.

It is *not* designed to safely execute work submitted by anonymous third parties, nor to act as a
public multi-tenant service.

## What's Included

### Per-issue isolated workspaces

Every run gets a fresh workspace under the configured `workspace.root`. Source repositories are
never used as the agent's working directory. Workspaces are subject to age-based cleanup, startup
orphan reporting, and free-disk-space dispatch pauses (`workspace.disk.*`).

### Sandbox defaults for the agent process

For Codex, Symphony applies safer defaults whenever the operator does not override them
(see [docs/configuration.md](configuration.md)):

- `agent.thread_sandbox` defaults to `workspace-write` — writes are scoped to the current issue
  workspace.
- `agent.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at that workspace.
- `agent.approval_policy` defaults to `reject` for `sandbox_approval`, `rules`, and
  `mcp_elicitations`, so the agent cannot cross those policy boundaries on its own.
- `agent.network_access.mode` defaults to `allowlist` — the agent talks only to Symphony's
  built-in dev domains plus the operator's `allowed_domains`, minus `denied_domains`.

A managed permission profile carries a built-in **credential/config read-deny list** covering paths
such as `~/.ssh`, `~/.aws`, `~/.config/gh`, `*.pem`, `*.key`, and the agent runtime credential
stores under `~/.codex` and `~/.claude`. `workspace.sandbox.allow_read_paths` lets you carve narrow
exceptions when a repo legitimately needs something like `~/.npmrc`.

### Optional outer sandbox (Codex + SRT)

Set `agent.sandbox_runtime.kind: srt` to wrap Codex with
`@anthropic-ai/sandbox-runtime`. Symphony generates a temporary SRT settings file with deny-reads
on the credential paths, allow-writes scoped to the issue workspace, and an `externalSandbox` turn
policy so SRT — not nested `sandbox-exec` — owns command enforcement. Use this when native Codex
deny-list enforcement is not enough.

**Git write model.** SRT settings always deny writes to the high-risk Git metadata files
`config`, `config.worktree`, `hooks`, `info`, `packed-refs`, and any `worktrees/*/config(.worktree)`
entries on every discovered Git metadata root. Writes to `.git/objects` remain allowed so `git add`
and `git commit` work in both clone workspaces and linked worktrees. For linked worktrees
(`workspace.strategy: worktree`, `workspace.repo: <source>`), those object writes target the
shared `<source>/.git/objects` database; this is an intentional cleanup/blast-radius tradeoff so
SRT-wrapped Codex can commit normally while config, hooks, packed refs, and other high-risk Git
metadata stay write-protected.

### Network access controls

`agent.network_access` supports `allowlist`, `block`, and `open`. `denied_domains` always
overrides built-in and user-supplied `allowed_domains`. Quality-gate and orchestrator HTTP traffic
are *not* covered by these switches — see Best Practices below.

### Untrusted-input handling

Linear titles, descriptions, and comments are rendered into the prompt inside bounded `<linear_...>`
blocks, and the example `WORKFLOW.md` instructs the agent to treat content in `BEGIN UNTRUSTED` /
`END UNTRUSTED` blocks as data only. The default workflow also forbids reading or printing common
secret paths, pushing to anything other than the workspace's configured `origin`, rewriting git
remotes, or opening pull requests against unrelated repositories.

### Scoped Linear and PR tools

During app-server sessions, Symphony exposes scoped client-side `linear_*` tools so the agent can
only read and update the **current** Linear issue, not arbitrary issues. PR evidence and
attachment handling go through the same scoped surface.

### Dispatch and budget caps

- `agent.max_concurrent_agents`, `agent.max_turns`, `agent.max_tokens_per_issue`, and
  `agent.max_tokens_per_day` cap blast radius and spend.
- Watchdog detects no-progress sessions and recovers them; failed runs back off through the retry
  queue.
- `Pause Dispatch` (dashboard or `mix symphony.pause`) survives restarts and is persisted with the
  pause reason.

### Quality gate isolation

The optional quality gate runs in the orchestrator, not in the agent sandbox. It is documented
separately in [quality_gate_security.md](quality_gate_security.md), including its prompt-injection
surface, the `on_error: pass` failure mode, and the lack of in-process network restrictions on
provider calls.

### Tamper-evident audit log

Side-effect events (prompt sends, tool calls, file changes, PR actions, Linear state/comment
actions, token deltas) are appended to `<state-root>/audit/YYYY-MM-DD.ndjson`. Each record carries
`previous_hash` and `record_hash` so the chain is verifiable with
`SymphonyElixir.AuditLog.verify_file/1` or `mix symphony.audit`. Prompts are stored as SHA-256
hashes plus a redacted preview — never raw — and configured secrets and common API-key env vars
are scrubbed before write. See [logging.md](logging.md).

### Local-only dashboard bind

The LiveView dashboard and `/api/v1/*` endpoints have **no built-in authentication**. Symphony
refuses to bind to non-loopback hosts unless `SYMPHONY_ALLOW_REMOTE_BIND=1` is set explicitly, and
the error message points operators at a reverse-proxy front door (Tailscale, Cloudflare Access,
nginx basic auth, etc.).

### Credentials from environment, not from config

Secrets (`LINEAR_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, notification webhook auth) are
read from environment variables. The quality gate explicitly ignores credentials placed in
`WORKFLOW.md`.

## Best Practices

### Deployment

- Keep `SYMPHONY_SERVER_HOST=127.0.0.1` and front the dashboard with an authenticated reverse proxy.
  Only set `SYMPHONY_ALLOW_REMOTE_BIND=1` when you know exactly what is in front of the port.
- Apply infrastructure-level egress filtering on the Symphony host or container. The orchestrator's
  HTTP calls (tracker, quality gate, learnings, notifications) are not covered by the agent's
  in-process network controls.
- Persist `<state-root>` on storage you trust, and back up `audit/` and `run_store/` if you need
  long-term traceability.

### Tracker hygiene

- Restrict who can edit issues that fall inside Symphony's poll filter. Anyone who can edit an
  issue can attempt prompt injection through its content.
- If issue editing is open to a wider audience, consider `quality_gate.on_error: skip` and a
  stronger scoring model, as discussed in [quality_gate_security.md](quality_gate_security.md).

### Sandboxing

- Prefer `agent.sandbox_runtime.kind: srt` when you need credential deny rules enforced at the OS
  layer rather than as a best-effort Codex profile. Native Codex enforcement of the managed deny
  list is best-effort across versions.
- Keep `agent.approval_policy` at its `reject` defaults unless an unattended use case truly
  requires `auto_approve_all`, and never combine `auto_approve_all` with `thread_sandbox:
  danger-full-access`.
- Treat `workspace.sandbox.allow_read_paths` as an escape hatch. Add only the narrowest path you
  need (e.g. `~/.npmrc`), never a directory containing other credentials.
- Keep `agent.network_access.mode: allowlist`. Use `denied_domains` to override anything in the
  built-in dev allow list you do not want the agent to reach.

### Secrets and credentials

- Store every secret as an environment variable. Do not place API keys or webhook auth headers in
  `WORKFLOW.md` or `symphony.yml`; reference `$ENV_VAR` placeholders.
- Use separate API keys for the main agent and the quality gate so quotas and spend are
  independently observable and revocable.
- Rotate the Linear and provider keys on a schedule. Revoking a key is the fastest kill switch
  short of stopping the service.

### Operations

- Watch provider dashboards for the first week after enabling the quality gate or learnings — both
  can produce sudden bursts.
- Pair `Pause Dispatch` with a deploy window or incident; in-flight agents continue, so a
  `mix symphony.stop ISSUE-ID` is the right tool for cutting an individual run.
- Periodically verify the audit chain (`mix symphony.audit ...` or `AuditLog.verify_file/1`),
  especially after host migrations or restores.
