#!/usr/bin/env bash
set -Eeuo pipefail

# Resolved without starting a process: this hook runs at the end of every turn,
# usually just to find it is switched off, and each process start is slow on a
# sandboxed host.
SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ "$SCRIPT_PATH" == /* ]] || SCRIPT_PATH="$PWD/$SCRIPT_PATH"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
INPUT=""
IFS= read -r -d '' INPUT || true

# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"

# Exit when the root config switches the hook off, before starting the
# orchestrator. It anchors to the same directory and reads the same setting, so
# this only skips work that would end in the same exit 0.
stop_hook_is_switched_off() { # <project_dir>
    local enabled_when
    enabled_when=$(read_json_config "$1/.reviewer/settings.json" stop_hook.enabled_when "")
    [[ -z "$enabled_when" || "$enabled_when" == "false" ]] && return 0
    ! bash -c "$enabled_when" 2>/dev/null
}

# PLUGIN_ROOT is set by Codex for plugin hooks; Claude sets CLAUDE_PLUGIN_ROOT.
if [[ -z "${PLUGIN_ROOT:-}" ]]; then
    PROJECT_DIR="$PWD"
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && [[ -d "$CLAUDE_PROJECT_DIR" ]]; then
        PROJECT_DIR="$CLAUDE_PROJECT_DIR"
    fi
    if stop_hook_is_switched_off "$PROJECT_DIR"; then
        exit 0
    fi
    exec bash "$SCRIPT_DIR/stop_hook_orchestrator.sh" <<< "$INPUT"
fi

# Codex treats exit 1 as a non-blocking error and reserves stdout for hook JSON.
exec 1>&2
trap 'echo "Code-guardian could not finish its checks; fix the error above before stopping." >&2; exit 2' ERR
export CODE_GUARDIAN_HARNESS=codex
SESSION_CWD=$(jq -er '.cwd | strings | select(length > 0)' <<< "$INPUT")
export CLAUDE_PROJECT_DIR
if ! CLAUDE_PROJECT_DIR=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null); then
    exit 0
fi
cd "$CLAUDE_PROJECT_DIR"

if stop_hook_is_switched_off "$CLAUDE_PROJECT_DIR"; then
    exit 0
fi

SESSION_ID=$(jq -er '.session_id | strings | select(test("^[A-Za-z0-9_-]+$"))' <<< "$INPUT")
mkdir -p .reviewer/outputs/codex
jq '{session_id, transcript_path, cwd}' <<< "$INPUT" > ".reviewer/outputs/codex/$SESSION_ID.json"

bash "$SCRIPT_DIR/stop_hook_orchestrator.sh" <<< "$INPUT"
