# Development

Notes for contributors and operators building, testing, or packaging Symphony.

See also [AGENTS.md](../AGENTS.md) for conventions when working on this repo with coding agents,
and [SPEC.md](../SPEC.md) for the behavior reference for the current service.

## Toolchain

- Elixir `1.19.x` (OTP 28) installed via `mise`.
- `mix setup` to install dependencies.

```bash
mise trust
mise install
mise exec -- mix setup
```

## Testing

Use the fast local gate while iterating:

```bash
make check
```

`make check` runs the format check, lint, escript build, and plain `mix test`. It does not run
coverage or Dialyzer, so treat it as a confidence check rather than a replacement for CI.

When CPU pressure matters, lower local test concurrency and BEAM scheduler usage:

```bash
make check TEST_MAX_CASES=2 BEAM_SCHEDULERS=2
```

Before pushing, run the full gate:

```bash
make all
```

To find slow validation work before optimizing tests, use the profiling targets:

```bash
make test-profile
make coverage-profile
make dialyzer-profile
```

In sandboxed Codex workspaces, prefer a writable Hex cache location for the full gate:

```bash
HEX_HOME=/private/tmp/symphony-hex-home make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real agent session:

```bash
export LINEAR_API_KEY=...
make e2e
```

## Packaging

Packaged macOS binaries are built with Burrito and include the Erlang runtime:

```bash
make package
```

Release artifacts are written to `burrito_out/` such as `burrito_out/symphony-macos-arm64`.
Distribution, code signing, notarization, and a Homebrew tap are not wired yet.

## Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is a good fit for supervising long-running processes. It
has an active ecosystem of tools and libraries, and it supports hot code reloading without stopping
actively running subagents during development.
