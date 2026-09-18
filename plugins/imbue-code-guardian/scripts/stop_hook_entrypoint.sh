#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)

# PLUGIN_ROOT is set by Codex for plugin hooks; Claude sets CLAUDE_PLUGIN_ROOT.
if [[ -z "${PLUGIN_ROOT:-}" ]]; then
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

# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"
ENABLED_WHEN=$(read_json_config .reviewer/settings.json stop_hook.enabled_when "")
if [[ -z "$ENABLED_WHEN" ]] || ! bash -c "$ENABLED_WHEN"; then
    exit 0
fi

SESSION_ID=$(jq -er '.session_id | strings | select(test("^[A-Za-z0-9_-]+$"))' <<< "$INPUT")
mkdir -p .reviewer/outputs/codex
jq '{session_id, transcript_path, cwd}' <<< "$INPUT" > ".reviewer/outputs/codex/$SESSION_ID.json"

bash "$SCRIPT_DIR/stop_hook_orchestrator.sh" <<< "$INPUT"
