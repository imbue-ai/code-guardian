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

# Set the variable named $1 to the env-var override name for config key $2.
# Built without starting a process where bash allows: the Stop hook reads its
# config on every turn, and each process start is slow on a sandboxed host.
_config_env_var_name() {
    local name="${2//./__}"
    if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
        name="${name^^}"
    else
        name=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
    fi
    printf -v "$1" 'CODE_GUARDIAN_%s' "$name"
}

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
    _config_env_var_name env_var "$key"
    if [ -n "${!env_var:-}" ]; then
        echo "${!env_var}"
        return
    fi

    # Derive .local.json path: foo/bar.json -> foo/bar.local.json
    local local_path="${config_path%.json}.local.json"

    # Dotted keys like "ci.is_enabled" are already jq paths once prefixed with a dot
    local jq_path=".$key"

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

# Read a JSON array of strings from a config file, emitting one element per line.
# Same lookup precedence as read_json_config (env var -> local -> main). The env
# var value, if set, is parsed as a JSON array. An explicit array in a
# higher-precedence file wins even when empty, so a local override can clear a
# list defined in the checked-in config. Emits nothing if the key is absent.
# Args: <config_path> <key>
read_json_array() {
    local config_path="$1"
    local key="$2"

    local env_var
    _config_env_var_name env_var "$key"
    if [ -n "${!env_var:-}" ]; then
        echo "${!env_var}" | jq -r '.[]' 2>/dev/null
        return
    fi

    local local_path="${config_path%.json}.local.json"
    local jq_path=".$key"

    local f
    for f in "$local_path" "$config_path"; do
        if [ -f "$f" ] && jq -e "$jq_path | arrays" "$f" >/dev/null 2>&1; then
            jq -r "${jq_path}[]" "$f" 2>/dev/null
            return
        fi
    done
}
