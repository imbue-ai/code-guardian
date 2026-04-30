#!/usr/bin/env bash
set -euo pipefail
#
# stop_hook_common.sh
#
# Shared function definitions for stop hook scripts. Source this file to get
# logging helpers and retry_command.
#
# Self-contained -- no external dependencies beyond standard POSIX utilities.
#
# Before sourcing, set:
#   STOP_HOOK_LOG          - path to JSONL log file (optional; empty = no file logging)
#   STOP_HOOK_SCRIPT_NAME  - script name for log entries (default: "unknown")

# Colors for output (disabled if not a terminal)
if [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

STOP_HOOK_LOG="${STOP_HOOK_LOG:-}"
STOP_HOOK_SCRIPT_NAME="${STOP_HOOK_SCRIPT_NAME:-unknown}"

# ---------------------------------------------------------------------------
# Timestamp generation (portable: Linux + macOS)
# ---------------------------------------------------------------------------
_STOP_HOOK_TIMESTAMP_METHOD=""

_detect_timestamp_method() {
    local test_ts
    test_ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%NZ" 2>/dev/null) || true
    if [[ "$test_ts" != *"%N"* ]]; then
        _STOP_HOOK_TIMESTAMP_METHOD="gnu"
        return
    fi
    if perl -MTime::HiRes=gettimeofday -e '1' 2>/dev/null; then
        _STOP_HOOK_TIMESTAMP_METHOD="perl"
        return
    fi
    _STOP_HOOK_TIMESTAMP_METHOD="basic"
}

_detect_timestamp_method

_timestamp() {
    case "$_STOP_HOOK_TIMESTAMP_METHOD" in
        gnu)
            date -u +"%Y-%m-%dT%H:%M:%S.%NZ"
            ;;
        perl)
            perl -MTime::HiRes=gettimeofday -MPOSIX=strftime \
                -e '($s,$us)=gettimeofday();printf "%s.%09dZ\n",strftime("%Y-%m-%dT%H:%M:%S",gmtime($s)),$us*1000'
            ;;
        basic)
            date -u +"%Y-%m-%dT%H:%M:%S.000000000Z"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# JSON escaping
# ---------------------------------------------------------------------------
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# JSONL file logging
# ---------------------------------------------------------------------------
_log_to_file() {
    local level="$1"
    local msg="$2"
    if [[ -z "$STOP_HOOK_LOG" ]]; then
        return
    fi
    local ts eid escaped_msg
    ts=$(_timestamp)
    eid="evt-$(head -c 16 /dev/urandom | xxd -p)"
    escaped_msg=$(_json_escape "$msg")
    mkdir -p "$(dirname "$STOP_HOOK_LOG")" 2>/dev/null || true
    printf '{"timestamp":"%s","type":"stop_hook","event_id":"%s","source":"%s","level":"%s","message":"%s","pid":%s}\n' \
        "$ts" "$eid" "$STOP_HOOK_SCRIPT_NAME" "$level" "$escaped_msg" "$$" >> "$STOP_HOOK_LOG"
}

# ---------------------------------------------------------------------------
# Console + file logging helpers
# ---------------------------------------------------------------------------
log_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    _log_to_file "ERROR" "$1"
}

log_warn() {
    echo -e "${YELLOW}WARN: $1${NC}" >&2
    _log_to_file "WARNING" "$1"
}

log_info() {
    echo -e "${GREEN}$1${NC}"
    _log_to_file "INFO" "$1"
}

log_debug() {
    _log_to_file "DEBUG" "$1"
}

# ---------------------------------------------------------------------------
# GitHub gh-API reachability preflight
#
# Probes `gh api rate_limit` and inspects the GraphQL bucket. Returns:
#   0  -- gh API is reachable AND graphql.remaining > 0
#   1  -- gh API is unreachable, returned an unparseable response, or graphql
#         bucket is exhausted; sets GH_DEGRADED_REASON for logging
#
# Scope: this is purely about the gh-API surface (REST + GraphQL via
# api.github.com). Git transport (github.com via HTTPS / SSH) is a separate
# service and is not probed here -- GraphQL can be rate-limited or down while
# git transport works fine.
# ---------------------------------------------------------------------------
GH_DEGRADED_REASON=""

check_github_reachable() {
    GH_DEGRADED_REASON=""
    local rate_json remaining reset_at
    if ! rate_json=$(gh api rate_limit 2>/dev/null); then
        GH_DEGRADED_REASON="gh_api_unreachable"
        return 1
    fi
    remaining=$(echo "$rate_json" | jq -r '.resources.graphql.remaining // empty' 2>/dev/null)
    if [[ -z "$remaining" ]] || ! [[ "$remaining" =~ ^-?[0-9]+$ ]]; then
        GH_DEGRADED_REASON="rate_limit_response_unparseable"
        return 1
    fi
    if [[ "$remaining" -le 0 ]]; then
        reset_at=$(echo "$rate_json" | jq -r '.resources.graphql.reset // 0' 2>/dev/null)
        GH_DEGRADED_REASON="graphql_rate_limited:reset_at=$reset_at"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Retry a command with exponential backoff
# Usage: retry_command <max_retries> <command...>
# ---------------------------------------------------------------------------
retry_command() {
    local max_retries=$1
    shift
    local attempt=1
    local wait_time=1

    while [[ $attempt -le $max_retries ]]; do
        if "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_retries ]]; then
            log_warn "Command failed (attempt $attempt/$max_retries), retrying in ${wait_time}s..."
            sleep "$wait_time"
            wait_time=$((wait_time * 2))
        fi
        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_retries attempts: $*"
    return 1
}
