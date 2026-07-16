#!/usr/bin/env bash
#
# get_config.sh
#
# Command-line reader for one reviewer config key, so skills resolve keys the
# same way the stop hook does. Precedence is config_utils.sh's.
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
