# Claude Code project instructions

This project uses a single, agent-agnostic instruction file for both Claude Code
and Codex. Read [`AGENTS.md`](AGENTS.md) for the canonical project rules
(environment, conventions, tests, required rules, PR template, docs policy).

## Shared skills

Reusable playbooks live under [`.ai/skills/`](.ai/skills) and are shared between
agents:

- `.codex/skills/` → symlink to `.ai/skills/` (so Codex finds them)
- `.claude/skills/` → symlink to `.ai/skills/` (so Claude Code finds them)

Add new shared skills under `.ai/skills/<name>/SKILL.md` (front matter:
`name`, `description`). Update both agents at once by editing one file.
