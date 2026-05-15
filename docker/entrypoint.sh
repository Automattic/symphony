#!/usr/bin/env bash
set -euo pipefail

eval "$(mise env -C /app/symphony -s bash)"

exec /app/symphony/bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$@"
