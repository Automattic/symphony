#!/usr/bin/env bash
set -euo pipefail

eval "$(mise env -C /app/symphony -s bash)"

exec /app/symphony/bin/symphony \
  "$@"
