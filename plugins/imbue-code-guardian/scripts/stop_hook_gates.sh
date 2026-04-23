#!/usr/bin/env bash
set -euo pipefail
#
# stop_hook_gates.sh
#
# Pure gate checker: verifies that autofix, architecture verification, and
# conversation review have been completed. Exits 0 if all enabled gates
# pass, 2 if any are missing.
#
# Stuck agent detection is handled by the orchestrator
# (stop_hook_orchestrator.sh), not by this script.
#
# Usage:
#   ./stop_hook_gates.sh [COMMIT_HASH]
#
# If COMMIT_HASH is omitted, uses the current HEAD.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"

REVIEWER_SETTINGS=".reviewer/settings.json"

# Read base branch from config (consistent with orchestrator)
BASE_BRANCH=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.base_branch" "main")

# Skip gates when there are no code changes vs the base branch.
if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    CODE_DIFF=$(git diff "$BASE_BRANCH"...HEAD 2>/dev/null || true)
    if [[ -z "$CODE_DIFF" ]]; then
        exit 0
    fi
fi

HASH="${1:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"

AUTOFIX_ENABLED=$(read_json_config "$REVIEWER_SETTINGS" "autofix.is_enabled" "true")
CONVO_ENABLED=$(read_json_config "$REVIEWER_SETTINGS" "verify_conversation.is_enabled" "true")
ARCH_ENABLED=$(read_json_config "$REVIEWER_SETTINGS" "verify_architecture.is_enabled" "true")

AUTOFIX_NEEDED=false
CONVO_NEEDED=false
ARCH_NEEDED=false

if [[ "$AUTOFIX_ENABLED" == "true" ]] && [[ ! -f ".reviewer/outputs/autofix/${HASH}_verified.md" ]]; then
    AUTOFIX_NEEDED=true
fi

if [[ "$CONVO_ENABLED" == "true" ]] && [[ ! -f ".reviewer/outputs/conversation/${HASH}.json" ]]; then
    CONVO_NEEDED=true
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BRANCH_SANITIZED="${BRANCH//\//_}"
if [[ "$ARCH_ENABLED" == "true" ]] && [[ ! -f ".reviewer/outputs/architecture/${BRANCH_SANITIZED}.md" ]]; then
    ARCH_NEEDED=true
fi

AUTOFIX_EXTRA_ARGS=$(read_json_config "$REVIEWER_SETTINGS" "autofix.append_to_prompt" "")
if [[ -n "$AUTOFIX_EXTRA_ARGS" ]]; then
    AUTOFIX_CMD="/autofix ${AUTOFIX_EXTRA_ARGS}"
else
    AUTOFIX_CMD="/autofix"
fi

CONVO_EXTRA_ARGS=$(read_json_config "$REVIEWER_SETTINGS" "verify_conversation.append_to_prompt" "")
if [[ -n "$CONVO_EXTRA_ARGS" ]]; then
    CONVO_CMD="/verify-conversation ${CONVO_EXTRA_ARGS}"
else
    CONVO_CMD="/verify-conversation"
fi

ARCH_EXTRA_ARGS=$(read_json_config "$REVIEWER_SETTINGS" "verify_architecture.append_to_prompt" "")
if [[ -n "$ARCH_EXTRA_ARGS" ]]; then
    ARCH_CMD="/verify-architecture ${ARCH_EXTRA_ARGS}"
else
    ARCH_CMD="/verify-architecture"
fi

MISSING=()
if [[ "$ARCH_NEEDED" == "true" ]]; then
    MISSING+=("architecture verification (${ARCH_CMD})")
fi
if [[ "$AUTOFIX_NEEDED" == "true" ]]; then
    MISSING+=("autofix (${AUTOFIX_CMD})")
fi
if [[ "$CONVO_NEEDED" == "true" ]]; then
    MISSING+=("conversation review (${CONVO_CMD})")
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
    exit 0
fi

echo "The following review gates have not been satisfied:" >&2
for item in "${MISSING[@]}"; do
    echo "  - ${item}" >&2
done
echo "" >&2
if [[ ${#MISSING[@]} -gt 1 ]]; then
    GUIDANCE="Run these before finishing."
    if [[ "$ARCH_NEEDED" == "true" ]] && [[ "$AUTOFIX_NEEDED" == "true" ]]; then
        GUIDANCE="${GUIDANCE} Address any issues raised by /verify-architecture before running /autofix, since architecture changes may make autofix results obsolete."
    fi
    if [[ "$CONVO_NEEDED" == "true" ]]; then
        GUIDANCE="${GUIDANCE} If possible, run /verify-conversation in the background while running the others."
    fi
    echo "$GUIDANCE" >&2
fi
# If any per-commit gate is enabled, note that gates may fire repeatedly.
if [[ "$AUTOFIX_ENABLED" == "true" ]] || [[ "$CONVO_ENABLED" == "true" ]]; then
    echo "" >&2
    echo "Note: these gates may fire again after you make changes. /verify-conversation is incremental and only reviews new content. For /autofix, the default is to run the full check, but if your changes since the last autofix run are focused, you may pass instructions telling it to focus on the diff since the last run (while still providing the true base branch)." >&2
fi
exit 2
