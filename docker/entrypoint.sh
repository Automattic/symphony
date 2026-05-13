#!/usr/bin/env bash
set -euo pipefail

eval "$(mise env -C /app/elixir -s bash)"

exec /app/elixir/bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$@"
