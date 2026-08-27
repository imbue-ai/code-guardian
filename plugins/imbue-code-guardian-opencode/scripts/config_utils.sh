#!/usr/bin/env bash
set -euo pipefail
#
# config_utils.sh
#
# Shared config-reading utilities. Source this file, then call read_json_config.
#
# Usage:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config_utils.sh"
#   val=$(read_json_config "path/to/config.json" "key_name" "default_value")
#   val=$(read_json_config "path/to/config.json" "nested.key" "default_value")
#
# Lookup precedence (first non-empty wins):
#   1. Environment variable CODE_GUARDIAN_<KEY> (dotted key uppercased, dots
#      replaced with double underscores so the section boundary is recoverable;
#      e.g. "stop_hook.base_branch" -> CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH).
#   2. The .local.json sibling of the config file (e.g. settings.local.json).
#   3. The config file itself.
#   4. The provided default.
#
# Local configs are gitignored and take precedence over checked-in configs.
# Env vars take precedence over both, so per-process / per-agent overrides
# work without touching any file.

# Read a single key from a JSON config file with env-var and local-override
# support.
# Args: <config_path> <key> <default>
read_json_config() {
    local config_path="$1"
    local key="$2"
    local default="$3"
    local val

    # Env-var override: CODE_GUARDIAN_<KEY uppercased, dots -> __>
    local env_var
    env_var="CODE_GUARDIAN_$(echo "$key" | tr '[:lower:]' '[:upper:]' | sed 's/\./__/g')"
    if [ -n "${!env_var:-}" ]; then
        echo "${!env_var}"
        return
    fi

    # Derive .local.json path: foo/bar.json -> foo/bar.local.json
    local local_path="${config_path%.json}.local.json"

    # Build a jq path expression from the key. Dotted keys like "ci.is_enabled"
    # become the jq path .ci.is_enabled; simple keys like "enabled" become .enabled.
    local jq_path
    jq_path=$(echo "$key" | sed 's/\././g; s/^/./')

    # Local overrides take precedence
    if [ -f "$local_path" ]; then
        val=$(jq -r "if $jq_path == null then empty else $jq_path end" "$local_path" 2>/dev/null)
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    fi
    if [ -f "$config_path" ]; then
        val=$(jq -r "if $jq_path == null then empty else $jq_path end" "$config_path" 2>/dev/null)
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}
