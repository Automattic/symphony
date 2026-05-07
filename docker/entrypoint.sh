#!/usr/bin/env bash
set -euo pipefail

exec /app/elixir/bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$@"
