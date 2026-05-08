# Symphony

Symphony runs autonomous, isolated agent sessions on Linear issues so teams can manage the work, not
the agents. It claims issues, recovers stalled runs, retries failures, and reports outcomes back to
the tracker.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## How Symphony works

```text
Linear issue -> Symphony -> workspace -> Codex -> pull request -> Linear status
```

Symphony claims eligible Linear issues, creates a fresh workspace per issue, launches Codex against
the repository's workflow prompt, and keeps the run moving until there is a pull request with
validation evidence. Failed runs are retried with backoff and stalled agents are detected and
recovered, so long-running queues do not need constant operator supervision.

<details>
<summary>Glossary</summary>

- **Workflow** — the repo-owned policy and prompt that tells Symphony what to run.
- **Run** — one attempt to make progress on a Linear issue.
- **Workspace** — the isolated checkout or worktree for a run.
- **Tracker** — the system Symphony polls for work, currently Linear in the reference implementation.
- **Quality gate** — the optional pre-dispatch check that decides whether an issue is clear enough
  for an agent.
- **Harness engineering** — the practice of preparing a codebase with scripts, tests, docs, and
  guardrails so coding agents can work safely.

</details>

## What's in the reference implementation

- **LiveView dashboard** for active runs, the watching list, and the retry queue, with per-issue
  transcript views.
- **Operator controls** for pause, resume, and stop, persisted across restarts so dispatch state
  survives a deploy.
- **Watchdog** that detects stalled agent sessions and recovers them without operator intervention.
- **Durable run store** for run history, retry backoff, captured learnings, and aggregate token
  totals.
- **Quality gate** (optional) that scores issue clarity before dispatch so unclear work is held
  instead of reaching Codex.
- **Verification dev server orchestration** for parallel worktree runs: per-issue port allocation,
  dev-server lifecycle, and health checks via `SYMPHONY_VERIFICATION_PORT`.
- **Learnings capture** from merged PR reviews, fed back into future workflow prompts.

## Try it

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/) — Symphony is the next step,
moving from managing agents to managing work that needs to get done.

### Docker

The Docker runtime mounts your workflow, repository, credentials, and agent command into the Elixir
reference implementation. See [docker/README.md](docker/README.md).

### Elixir reference implementation

Run Symphony directly on a host you control. See [elixir/README.md](elixir/README.md) for setup, or
ask your favorite coding agent to handle it:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

## Documentation

- [SPEC.md](SPEC.md): the full Symphony specification, useful if you are implementing your own
  runtime.
- [elixir/README.md](elixir/README.md): getting started with the Elixir reference implementation.
- [elixir/docs/configuration.md](elixir/docs/configuration.md): full configuration reference for
  `WORKFLOW.md`, CLI flags, defaults, and supported values.
- [elixir/docs/logging.md](elixir/docs/logging.md),
  [elixir/docs/quality_gate_security.md](elixir/docs/quality_gate_security.md), and
  [elixir/docs/token_accounting.md](elixir/docs/token_accounting.md): operational deep-dives.
- [elixir/WORKFLOW.md](elixir/WORKFLOW.md): the example in-repo workflow contract and agent prompt.
- [elixir/AGENTS.md](elixir/AGENTS.md): maintainer notes for agents working on the Elixir
  implementation.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
