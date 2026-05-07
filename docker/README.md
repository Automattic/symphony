# Run Symphony in Docker

This directory contains a generic Docker runner for the existing Elixir Symphony implementation.
It does not include a sample repository, seeded issues, or a fake agent. It runs Symphony against
the workflow, repository, credentials, and agent command that you provide.

## Requirements

- Docker Compose
- A customized `WORKFLOW.md`
- Credentials for the services referenced by that workflow, usually `LINEAR_API_KEY` plus the API
  keys needed by the configured agent
- A Linux-compatible agent command, auth, and settings available inside the container

The image installs Symphony's Elixir runtime plus basic tools such as `git` and `ssh`. It does not
install Codex, Claude, GitHub CLI, or repository-specific build dependencies. Use a derived image
when your workflow needs additional tools.

## Workflow Paths

The Compose file mounts these paths into the container:

| Host input | Container path | Purpose |
| --- | --- | --- |
| `SYMPHONY_WORKFLOW` env var | `/workspace/WORKFLOW.md` | Workflow configuration and prompt |
| `SYMPHONY_REPO` env var | `/workspace/repo` | Repository Symphony should operate on |
| `symphony-workspaces` volume | `/workspace/workspaces` | Per-issue workspaces |
| `symphony-logs` volume | `/workspace/logs` | Logs and durable run store |
| `symphony-codex-home` volume | `/home/symphony/.codex` | Codex settings, auth, cache, and session state |
| `symphony-claude-home` volume | `/home/symphony/.claude` | Claude settings, auth, cache, and session state |

The container runs as a non-root `symphony` user (UID/GID `1000` by default). Files written into
the bind-mounted host repo and into the named volumes are owned by that UID. On Linux, override
the defaults to match your host user so cleanup does not require `sudo`:

```bash
SYMPHONY_UID=$(id -u) SYMPHONY_GID=$(id -g) \
SYMPHONY_WORKFLOW=... SYMPHONY_REPO=... \
docker compose -f docker/docker-compose.yml up --build
```

Use container paths in the workflow. A typical Docker-oriented workflow starts with:

```md
---
tracker:
  kind: linear
  project_slug: "your-linear-project-slug"
  assignee: null
workspace:
  root: /workspace/workspaces
  strategy: worktree
  repo: /workspace/repo
agent:
  kind: codex
  command: codex app-server
server:
  host: 0.0.0.0
  port: 4000
---
```

If your agent command or repository expects SSH, GitHub CLI, package managers, or project-specific
services, add them in a derived image or mount the required configuration explicitly.

## Agent Auth and Settings

Agent CLIs can depend on local config, auth, skills, MCP definitions, or cache files. The default
Compose file gives Codex and Claude writable home volumes because normal runs may write history,
session state, caches, telemetry, token refreshes, or plugin metadata. Prefer environment variables
when the agent supports them. Otherwise, add an uncommitted Compose override that mounts only the
host files or directories your agent needs.

Read-only mounts are suitable for stable inputs such as static config, skills, commands, and SSH
keys. They are not enough for the entire Codex or Claude home directory during normal use. If the
CLI needs to refresh auth or persist session state, use the writable Docker volume or a dedicated
read/write bind mount instead of mounting your whole host home directory.

For example, mount selected host inputs on top of the writable container volumes:

```yaml
# docker/docker-compose.local.yml
services:
  symphony:
    volumes:
      - ${HOME}/.codex/config.toml:/home/symphony/.codex/config.toml:ro
      - ${HOME}/.codex/auth.json:/home/symphony/.codex/auth.json:ro
      - ${HOME}/.codex/AGENTS.md:/home/symphony/.codex/AGENTS.md:ro
      - ${HOME}/.codex/skills:/home/symphony/.codex/skills:ro
      - ${HOME}/.claude/settings.json:/home/symphony/.claude/settings.json:ro
      - ${HOME}/.claude/CLAUDE.md:/home/symphony/.claude/CLAUDE.md:ro
      - ${HOME}/.claude/commands:/home/symphony/.claude/commands:ro
      - ${HOME}/.claude/skills:/home/symphony/.claude/skills:ro
      - ${HOME}/.config/gh:/home/symphony/.config/gh:ro
      - ${HOME}/.ssh:/home/symphony/.ssh:ro
```

Run with both files:

```bash
docker compose \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.local.yml \
  up --build
```

If read-only `auth.json` or `settings.json` causes token refresh failures, seed those files into the
writable named volume instead of bind-mounting them read-only. Also check that any paths inside the
agent config point at container paths such as `/workspace/repo`, not host-specific absolute paths.

## Run

From the Symphony repository root, point Compose at the workflow and repository you want Symphony
to operate on:

```bash
SYMPHONY_WORKFLOW=/path/to/target/WORKFLOW.md \
SYMPHONY_REPO=/path/to/target/repo \
LINEAR_API_KEY=lin_api_... \
OPENAI_API_KEY=sk-... \
docker compose -f docker/docker-compose.yml up --build
```

The LiveView dashboard is available at `http://localhost:4000`.

## Derived Image

Create a small Dockerfile when your workflow needs additional tools:

```Dockerfile
FROM symphony:local

# Install the Linux agent CLI and project-specific tools required by WORKFLOW.md.
```

Then point Compose at that Dockerfile or build it as `symphony:local` before running Compose.

## Secrets

Pass static credentials through environment variables or explicit read-only mounts. If an agent CLI
refreshes tokens in place, keep that state in the writable named volume or a dedicated read/write
mount. Avoid baking secrets into derived images.

For example, SSH-backed repository access can be mounted when needed:

```bash
docker compose -f docker/docker-compose.yml run --rm \
  -v "$HOME/.ssh:/home/symphony/.ssh:ro" \
  symphony
```
