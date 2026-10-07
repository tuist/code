#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Compilation is excluded from the phase timers and paired ratios.
mise exec -- env MIX_ENV=test mix compile
mise exec -- env MIX_ENV=test mix run --no-compile bench/git_service/workload.exs
mise exec -- env MIX_ENV=test mix run --no-compile bench/git_service/cost.exs
