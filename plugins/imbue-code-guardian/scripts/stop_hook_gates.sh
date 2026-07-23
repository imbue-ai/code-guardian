#!/usr/bin/env bash
set -euo pipefail
#
# stop_hook_gates.sh
#
# Cross-directory review-gate checker. Verifies that the UNIFIED autofix,
# architecture, and conversation gates are satisfied across every reviewed
# directory. Exits 0 if all enabled gates pass, 2 if any are missing.
#
# The review gates run ONCE per stop cycle (one /autofix, one
# /verify-architecture, one /verify-conversation), covering all dirs -- but
# each dir keeps its own dir-local markers, so a gate is satisfied only when
# EVERY changed dir has a current marker:
#   - autofix:       <dir>/.reviewer/outputs/autofix/<HEAD>_verified.md  (per-commit)
#   - architecture:  <dir>/.reviewer/outputs/architecture/<branch>.md    (per-branch)
#   - conversation:  .reviewer/outputs/conversation/<root HEAD>.json     (root only)
#
# Stuck-agent detection is handled by the orchestrator, not here.
#
# Usage:
#   ./stop_hook_gates.sh <manifest_file>
#
# The manifest has one tab-separated line per reviewed dir:
#   <dir>\t<HEAD>\t<branch>\t<has_changes:true|false>
# The root repo is the line whose <dir> is ".".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"

MANIFEST="${1:?usage: stop_hook_gates.sh <manifest_file>}"

# Build a command hint by appending extra instructions to a base command.
# `_root_cmd` reads a single extra from the ROOT config (used for the
# conversation gate, which is session-scoped/root-only). `_append_extras`
# appends a deduped list of extras gathered across dirs (used for the unified
# autofix/architecture gates -- one invocation covers every changed dir, so each
# changed dir's own append_to_prompt must flow into the single command).
_root_cmd() {
    local base="$1" key="$2" extra
    extra=$(read_json_config ".reviewer/settings.json" "$key" "")
    if [[ -n "$extra" ]]; then
        echo "$base $extra"
    else
        echo "$base"
    fi
}

# Args: <base> <extra>... (caller guarantees at least one extra). Emits
# "<base> <deduped extras joined by space>", preserving first-seen order.
_append_extras() {
    local base="$1"; shift
    local -a out=()
    local e s dup
    for e in "$@"; do
        dup=false
        if [[ ${#out[@]} -gt 0 ]]; then
            for s in "${out[@]}"; do [[ "$s" == "$e" ]] && { dup=true; break; }; done
        fi
        [[ "$dup" == "true" ]] && continue
        out+=("$e")
    done
    printf '%s %s' "$base" "${out[*]}"
}

CONVO_CMD=$(_root_cmd "/verify-conversation" "verify_conversation.append_to_prompt")

# Dirs (by gate) still missing a marker.
AUTOFIX_MISSING=()
ARCH_MISSING=()
CONVO_NEEDED=false

# append_to_prompt extras gathered from every changed dir with the gate enabled.
AUTOFIX_EXTRAS=()
ARCH_EXTRAS=()

ROOT_HEAD=""
ANY_CHANGES=false

while IFS=$'\t' read -r dir head branch has_changes; do
    [ -z "$dir" ] && continue
    [ "$dir" == "." ] && ROOT_HEAD="$head"
    [ "$has_changes" != "true" ] && continue
    ANY_CHANGES=true

    local_settings="$dir/.reviewer/settings.json"

    autofix_enabled=$(read_json_config "$local_settings" "autofix.is_enabled" "true")
    arch_enabled=$(read_json_config "$local_settings" "verify_architecture.is_enabled" "true")

    # Gather each changed dir's own append_to_prompt so the unified command
    # carries every reviewed repo's extra instructions (the single /autofix /
    # /verify-architecture invocation reviews all changed dirs at once).
    if [[ "$autofix_enabled" == "true" ]]; then
        a_extra=$(read_json_config "$local_settings" "autofix.append_to_prompt" "")
        [[ -n "$a_extra" ]] && AUTOFIX_EXTRAS+=("$a_extra")
        if [[ ! -f "$dir/.reviewer/outputs/autofix/${head}_verified.md" ]]; then
            AUTOFIX_MISSING+=("$dir")
        fi
    fi

    if [[ "$arch_enabled" == "true" ]]; then
        r_extra=$(read_json_config "$local_settings" "verify_architecture.append_to_prompt" "")
        [[ -n "$r_extra" ]] && ARCH_EXTRAS+=("$r_extra")
        branch_sanitized="${branch//\//_}"
        if [[ ! -f "$dir/.reviewer/outputs/architecture/${branch_sanitized}.md" ]]; then
            ARCH_MISSING+=("$dir")
        fi
    fi
done < "$MANIFEST"

# Build the unified command hints now that we know every changed dir's extras.
AUTOFIX_CMD="/autofix"
if [[ ${#AUTOFIX_EXTRAS[@]} -gt 0 ]]; then
    AUTOFIX_CMD=$(_append_extras "/autofix" "${AUTOFIX_EXTRAS[@]}")
fi
ARCH_CMD="/verify-architecture"
if [[ ${#ARCH_EXTRAS[@]} -gt 0 ]]; then
    ARCH_CMD=$(_append_extras "/verify-architecture" "${ARCH_EXTRAS[@]}")
fi

# Conversation review is a single, session-scoped gate keyed on the root HEAD.
# It fires whenever ANY reviewed dir has changes (the agent did work somewhere),
# independent of whether the root repo itself changed.
CONVO_ENABLED=$(read_json_config ".reviewer/settings.json" "verify_conversation.is_enabled" "true")
if [[ "$CONVO_ENABLED" == "true" ]] && [[ "$ANY_CHANGES" == "true" ]] && [[ -n "$ROOT_HEAD" ]]; then
    if [[ ! -f ".reviewer/outputs/conversation/${ROOT_HEAD}.json" ]]; then
        CONVO_NEEDED=true
    fi
fi

# Render "needed in: a, b" only when the covered set isn't just the root repo,
# so single-repo output stays identical to the pre-multi-dir behavior.
_dirs_suffix() {
    local dirs=("$@")
    if [[ ${#dirs[@]} -eq 1 ]] && [[ "${dirs[0]}" == "." ]]; then
        echo ""
    else
        local joined
        joined=$(printf '%s, ' "${dirs[@]}")
        echo " -- needed in: ${joined%, }"
    fi
}

MISSING=()
if [[ ${#ARCH_MISSING[@]} -gt 0 ]]; then
    MISSING+=("architecture verification (${ARCH_CMD})$(_dirs_suffix "${ARCH_MISSING[@]}")")
fi
if [[ ${#AUTOFIX_MISSING[@]} -gt 0 ]]; then
    MISSING+=("autofix (${AUTOFIX_CMD})$(_dirs_suffix "${AUTOFIX_MISSING[@]}")")
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

# When more than one reviewed dir is in play, remind the agent that each review
# command is unified: run it ONCE and it covers every listed dir.
DISTINCT_DIRS=$(cut -f1 "$MANIFEST" | sort -u | grep -vc '^$' || true)
if [[ "${DISTINCT_DIRS:-1}" -gt 1 ]]; then
    echo "Each review command runs ONCE and covers all listed directories -- do not run it per directory. It should ground itself in each repo's own diff, and account for related changes in the other repos where they share a surface." >&2
    echo "" >&2
fi

if [[ ${#MISSING[@]} -gt 1 ]]; then
    GUIDANCE="Run these before finishing."
    if [[ ${#ARCH_MISSING[@]} -gt 0 ]] && [[ ${#AUTOFIX_MISSING[@]} -gt 0 ]]; then
        GUIDANCE="${GUIDANCE} Address any issues raised by /verify-architecture before running /autofix, since architecture changes may make autofix results obsolete."
    fi
    if [[ "$CONVO_NEEDED" == "true" ]]; then
        GUIDANCE="${GUIDANCE} If possible, run /verify-conversation in the background while running the others."
    fi
    echo "$GUIDANCE" >&2
fi

# The per-commit gates (autofix, conversation) may fire again after new commits.
echo "" >&2
echo "Note: these gates may fire again after you make changes. /verify-conversation is incremental and only reviews new content. For /autofix, the default is to run the full check, but if your changes since the last autofix run are focused, you may pass instructions telling it to focus on the diff since the last run (while still providing the true base branch)." >&2
exit 2
