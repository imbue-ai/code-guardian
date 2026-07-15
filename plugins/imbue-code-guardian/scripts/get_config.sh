#!/usr/bin/env bash
#
# get_config.sh
#
# Read one reviewer config key from the command line, resolving it exactly as
# the stop hook does: env var -> settings.local.json -> settings.json ->
# default. Exists so skills share the hook's resolution instead of reaching for
# one layer of it and silently disagreeing with the hook about, say, which
# branch is the base.
#
# Usage:
#   ./get_config.sh <key> [default]
#   ./get_config.sh stop_hook.base_branch main

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <key> [default]" >&2
    exit 1
fi

read_json_config ".reviewer/settings.json" "$1" "${2:-}"
