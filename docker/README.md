# Run Symphony in Docker

This directory contains a generic Docker runner for the existing Elixir Symphony implementation.
It does not include a sample repository, seeded issues, or a fake agent. It runs Symphony against
the operator config, repositories, credentials, and agent command that you provide.

## Requirements

- Docker Compose
- A customized `symphony.yml` operator config
- Repo-local `WORKFLOW.md` files referenced by `repos:` in that config
- Credentials for the services referenced by that config, usually `LINEAR_API_KEY` plus the API keys
  needed by the configured agent
- A Linux-compatible agent command, auth, and settings available inside the container

The image installs Symphony's Elixir runtime plus basic tools such as `git` and `ssh`. It does not
install Codex, Claude, GitHub CLI, or repository-specific build dependencies. Use a derived image
when your workflow needs additional tools.

## Quick Start

From the Symphony repository root, point Compose at your operator config and at the host directory
that contains the repositories Symphony should supervise:

```bash
SYMPHONY_CONFIG=/path/to/symphony.yml \
SYMPHONY_REPOS_ROOT=/path/to/repos-parent \
LINEAR_API_KEY=lin_api_... \
OPENAI_API_KEY=sk-... \
docker compose -f docker/docker-compose.yml up --build
```

The LiveView dashboard is available at `http://localhost:4000`.

All paths in `symphony.yml` must be container paths, not host paths. If the host directory is:

```text
/path/to/repos-parent/
  web/
    WORKFLOW.md
```

then the repo path in `symphony.yml` is `/workspace/repos/web`.

## Config and Repo Paths

The Compose file mounts these paths into the container:

| Host input | Container path | Purpose |
| --- | --- | --- |
| `SYMPHONY_CONFIG` env var | `/workspace/symphony.yml` | Operator config with tracker, agent, and `repos:` |
| `SYMPHONY_REPOS_ROOT` env var | `/workspace/repos` | Parent directory containing supervised repositories |
| `symphony-workspaces` volume | `/workspace/workspaces` | Per-issue workspaces |
| `symphony-logs` volume | `/workspace/logs` | Log files |
| `symphony-state` volume | `/workspace/state` | Durable run store and generated server secrets |
| `symphony-codex-home` volume | `/home/symphony/.codex` | Codex settings, auth, cache, and session state |
| `symphony-claude-home` volume | `/home/symphony/.claude` | Claude settings, auth, cache, and session state |

The container runs as a non-root `symphony` user (UID/GID `1000` by default). Files written into
the bind-mounted repo root and into the named volumes are owned by that UID. On Linux, override
the defaults to match your host user so cleanup does not require `sudo`:

```bash
SYMPHONY_UID=$(id -u) SYMPHONY_GID=$(id -g) \
SYMPHONY_CONFIG=... SYMPHONY_REPOS_ROOT=... \
docker compose -f docker/docker-compose.yml up --build
```

Compose binds Symphony to all interfaces inside the container so Docker can publish the port, but
the host port is bound to `127.0.0.1` only. If you override `ports:` to expose the dashboard beyond
localhost, put authentication in front of it.

## Operator Config

A typical Docker-oriented `symphony.yml` starts with:

```yaml
tracker:
  kind: linear
  project_slug: "your-linear-project-slug"
  assignee: null
workspace:
  root: /workspace/workspaces
  strategy: worktree
agent:
  kind: codex
  command: codex app-server
server:
  host: 0.0.0.0
  port: 4000
repos:
  - name: web
    path: /workspace/repos/web
    workflow: WORKFLOW.md
    workspace:
      strategy: worktree
      repo: /workspace/repos/web
  - name: mobile
    path: /workspace/repos/mobile
    workflow: WORKFLOW.md
    workspace:
      strategy: worktree
      repo: /workspace/repos/mobile
```

Each listed repo has its own repo-local `WORKFLOW.md`. If your repositories do not share one parent
directory on the host, use a local Compose override to add extra bind mounts and point each
`repos[].path` / `repos[].workspace.repo` at its container path.

If your agent command or repositories expect SSH, GitHub CLI, package managers, or project-specific
services, add them in a derived image or mount the required configuration explicitly.

## Dashboard Binding

The dashboard and `/api/v1/*` routes do not have built-in authentication. Symphony refuses to bind
the HTTP server to a non-loopback address unless `SYMPHONY_ALLOW_REMOTE_BIND=1` is set.

Docker is the one intentional exception: the process must bind `0.0.0.0` inside the container so
Docker can publish the port to the host. The Compose file therefore sets `SYMPHONY_ALLOW_REMOTE_BIND=1`
and publishes the dashboard only on host loopback:

```yaml
ports:
  - "127.0.0.1:4000:4000"
```

Keep that host-side `127.0.0.1` binding unless you put an authenticated reverse proxy in front of
the dashboard, such as Tailscale, Cloudflare Access, or nginx basic auth. If you use `docker run`
directly instead of Compose, include the same binding and mount shape:

```bash
docker run --rm \
  -e SYMPHONY_ALLOW_REMOTE_BIND=1 \
  -p 127.0.0.1:4000:4000 \
  -v /path/to/symphony.yml:/workspace/symphony.yml:ro \
  -v /path/to/repos-parent:/workspace/repos \
  -v symphony-state:/workspace/state \
  -v symphony-logs:/workspace/logs \
  -v symphony-workspaces:/workspace/workspaces \
  symphony:local \
  --logs-root /workspace/logs \
  --state-root /workspace/state \
  --host 0.0.0.0 \
  --port 4000 \
  --config /workspace/symphony.yml
```

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

For GitHub, prefer token environment variables when possible. GitHub CLI accepts both `GH_TOKEN`
and `GITHUB_TOKEN` for github.com, with `GH_TOKEN` taking precedence; `GITHUB_TOKEN` is kept in the
Compose file because many CI and agent environments already provide that name. Mount
`${HOME}/.config/gh` only when a derived image installs `gh` and you intentionally want to reuse
stored CLI auth, host config, or extensions instead of token-only auth.

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
agent config point at container paths such as `/workspace/repos/web`, not host-specific absolute
paths.

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
