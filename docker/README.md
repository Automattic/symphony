# Run Symphony in Docker

A single image bundles Symphony plus both supported agent CLIs — Codex and Claude Code — so any
operator config that picks `agent.kind: codex` or `agent.kind: claude` will work out of the box.

## Requirements

- Docker Compose v2
- A `symphony.yml` operator config with paths written in container form (`/workspace/repos/<name>`)
- One or more host directories that contain repos to supervise, each with its own `WORKFLOW.md`
- The API keys your config needs (typically `LINEAR_API_KEY` plus agent credentials)

The agent CLIs read auth from `~/.codex` and `~/.claude` on your host — those directories are
bind-mounted into the container, so host logins and token refreshes are reused.

## Setup

```bash
cp docker/.env.example .env
# edit .env: set SYMPHONY_CONFIG, SYMPHONY_REPOS_ROOT, LINEAR_API_KEY
docker compose -f docker/docker-compose.yml up --build
```

Dashboard: <http://localhost:4000> (bound to loopback only).

`.env` lives at the repo root and is gitignored. Run the `docker compose` command from the repo
root so it gets picked up automatically.

## What gets mounted

| Source on host | Container path | Mode |
| --- | --- | --- |
| `$SYMPHONY_CONFIG` | `/workspace/symphony.yml` | ro |
| `$SYMPHONY_REPOS_ROOT` | `/workspace/repos` | rw |
| `~/.codex` | `/home/symphony/.codex` | rw |
| `~/.claude` | `/home/symphony/.claude` | rw |
| `~/.ssh` | `/home/symphony/.ssh` | ro |
| `symphony-logs` volume | `/workspace/logs` | rw |
| `symphony-state` volume | `/workspace/state` | rw |
| `symphony-workspaces` volume | `/workspace/workspaces` | rw |

Per-issue worktrees live in the `symphony-workspaces` named volume, not on your host, so they
won't clutter the filesystem you work from.

## Writing `symphony.yml` for the container

Every path inside the config must be a container path. If your host layout is:

```text
/Users/you/code/
  web/
    WORKFLOW.md
  mobile/
    WORKFLOW.md
```

then set `SYMPHONY_REPOS_ROOT=/Users/you/code` in `.env` and your config uses:

```yaml
workspace:
  root: /workspace/workspaces
  strategy: worktree
agent:
  kind: codex            # or: claude
  command: codex app-server
repos:
  - name: web
    workflow: WORKFLOW.md
    workspace:
      strategy: worktree
      repo: /workspace/repos/web
  - name: mobile
    workflow: WORKFLOW.md
    workspace:
      strategy: worktree
      repo: /workspace/repos/mobile
```

The folder name on the host must match `repos[].name` (so `/Users/you/code/web` → `repos[0].name: web`).

## Picking an agent

Switch agents by editing `symphony.yml`, not by rebuilding. Both CLIs are installed at fixed
versions (see `Dockerfile` build args).

- **Codex**: `agent.kind: codex`, `agent.command: codex app-server`. Reuses `~/.codex/auth.json`
  for ChatGPT auth, or set `OPENAI_API_KEY` in `.env`.
- **Claude Code**: `agent.kind: claude`, `agent.command: claude` (plus any flags). Reuses
  `~/.claude/.credentials.json` for Anthropic Console auth, or set `ANTHROPIC_API_KEY` in `.env`.

## Dashboard binding

Symphony refuses non-loopback binds unless `SYMPHONY_ALLOW_REMOTE_BIND=1`. The compose file sets
this so the container can bind `0.0.0.0:4000` and let Docker publish the port — but the host port
is bound to `127.0.0.1` only. Put authentication in front of it if you change that.

## Linux UID matching

On Linux, files written into bind-mounted repo paths inherit the container UID (`1000` by default).
Override before running so cleanup does not need `sudo`:

```bash
SYMPHONY_UID=$(id -u) SYMPHONY_GID=$(id -g) \
  docker compose -f docker/docker-compose.yml up --build
```

Docker Desktop on macOS handles UID mapping transparently — no override needed.

## Tear down

```bash
# stop, keep state
docker compose -f docker/docker-compose.yml down

# nuke named volumes too (loses workspaces, logs, runtime state)
docker compose -f docker/docker-compose.yml down -v
```

Note: `down -v` does NOT touch your bind-mounted `~/.codex` or `~/.claude` — those are host
directories, not Docker volumes.
