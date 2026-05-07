# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents. It retries failed work and recovers silent agent stalls so
long-running queues do not need constant operator supervision.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## How Symphony works

Symphony treats Linear as the source of work, then runs each issue through an isolated agent loop. It
claims eligible Linear issues, creates a fresh workspace for each one, launches Codex in that
workspace with the repository's workflow prompt, and keeps the run moving until there is a pull
request with validation evidence. Review state, blockers, and final landing status are reflected
back in Linear so operators can manage the work queue instead of supervising every Codex turn.

```text
Linear issue -> Symphony -> workspace -> Codex -> pull request -> Linear status
```

Glossary: a `workflow` is the repo-owned policy and prompt that tells Symphony what to run; a `run`
is one attempt to make progress on a Linear issue; a `workspace` is the isolated checkout or
worktree for that run; a `tracker` is the system Symphony polls for work, currently Linear in the
reference implementation; a `quality gate` is the optional pre-dispatch check that decides whether
an issue is clear enough for an agent; and `harness engineering` is the practice of preparing a
codebase with scripts, tests, docs, and guardrails so coding agents can work safely.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

If you prefer a containerized runtime, see [docker/README.md](docker/README.md). The Docker setup
runs the existing Elixir implementation against your own mounted workflow, repository, credentials,
and agent command.

The reference implementation also includes opt-in UI verification orchestration for parallel
worktree runs: Symphony can allocate a per-issue port, expose it as
`SYMPHONY_VERIFICATION_PORT`, start a configured dev server, health-check it, and tear it down when
the run ends.

## Where to read next

- [SPEC.md](SPEC.md): the full Symphony specification, useful if you are implementing your own
  runtime.
- [elixir/README.md](elixir/README.md): getting started with the experimental Elixir reference
  implementation.
- [elixir/docs/configuration.md](elixir/docs/configuration.md): the full configuration reference
  for `WORKFLOW.md`, CLI flags, defaults, and supported values.
- [elixir/docs/logging.md](elixir/docs/logging.md),
  [elixir/docs/quality_gate_security.md](elixir/docs/quality_gate_security.md), and
  [elixir/docs/token_accounting.md](elixir/docs/token_accounting.md): operational deep-dives.
- [elixir/WORKFLOW.md](elixir/WORKFLOW.md): the example in-repo workflow contract and agent prompt.
- [elixir/AGENTS.md](elixir/AGENTS.md): maintainer notes for agents working on the Elixir
  implementation.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
