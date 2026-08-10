#!/usr/bin/env bash
#
# stop_hook_orchestrator.sh
#
# Main stop hook orchestrator for code-guardian. Runs the full pipeline across
# one or more git working directories (the root repo plus any
# stop_hook.additional_git_directories):
#
#   1. Check enabled_when condition (once, from the ROOT config)
#   2. Resolve + validate the set of reviewed dirs
#   3. Stuck agent detection (safety hatch, keyed on the composite state of all dirs)
#   4. Per-dir non-review pipeline, run concurrently (uncommitted check,
#      fetch/merge/push, docs-only detection, ensure-PR) -- see
#      stop_hook_dir_pipeline.sh
#   5. Unified review-gate check across all dirs (one /autofix, one
#      /verify-architecture, one /verify-conversation) -- see stop_hook_gates.sh
#   6. Per-dir CI polling (only once review gates pass)
#   7. Report all unsatisfied dirs/gates together
#
# Each reviewed dir is self-contained: its own .reviewer/settings.json,
# outputs/, and logs/ govern how it is reviewed. The ROOT config additionally
# provides the master switch (enabled_when), the coordination log, and the
# conversation gate (which is session-scoped, root-only).
#
# Exit codes:
#   0 -- all gates passed (or hook disabled/skipped)
#   2 -- gates unsatisfied (stderr shown to agent)
#   1 -- unexpected error

set -euo pipefail

# Drain stdin so downstream commands don't accidentally consume the hook JSON
cat > /dev/null 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Anchor to the session's project root before resolving ANY relative path.
# Claude Code runs Stop hooks in the agent's *current* working directory, which
# follows `cd` from tool calls. Without this, an agent that cd'd into one of the
# additional reviewed dirs (the natural thing to do when working in a nested
# repo) would make the orchestrator read THAT dir's .reviewer/settings.json as
# the root config -- so its enabled_when would gate the whole hook and
# additional_git_directories would be lost, silently skipping all review.
# Everything below (root config, block tracker, per-dir paths) is relative to
# this directory. Falls back to the current directory when the variable is
# unset (e.g. direct invocation from tests).
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && [[ -d "$CLAUDE_PROJECT_DIR" ]]; then
    cd "$CLAUDE_PROJECT_DIR" || exit 1
fi

# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"

REVIEWER_SETTINGS=".reviewer/settings.json"

# =========================================================================
# Step 1: Check enabled_when (evaluated once, from the root config)
# =========================================================================
ENABLED_WHEN=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.enabled_when" "")
if [[ -z "$ENABLED_WHEN" ]]; then
    exit 0
fi
if ! bash -c "$ENABLED_WHEN" 2>/dev/null; then
    exit 0
fi

# Set up coordination logging now that we know the hook is enabled. Per-dir
# pipeline steps log into each dir's own log; this root log records the
# fan-out/aggregate decisions.
STOP_HOOK_LOG=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.log_file" ".reviewer/logs/stop_hook.jsonl")
export STOP_HOOK_LOG
export STOP_HOOK_SCRIPT_NAME="orchestrator"

# shellcheck source=stop_hook_common.sh
source "$SCRIPT_DIR/stop_hook_common.sh"
# shellcheck source=stop_hook_dirs.sh
source "$SCRIPT_DIR/stop_hook_dirs.sh"

_log_to_file "INFO" "========================================================"
_log_to_file "INFO" "Stop hook orchestrator started (pid=$$, ppid=$PPID)"
_log_to_file "INFO" "========================================================"

# Trap signals so we can log unexpected terminations
# shellcheck disable=SC2329  # invoked indirectly via the signal traps below
_on_signal() {
    local sig="$1"
    _log_to_file "ERROR" "orchestrator received signal $sig (pid=$$) -- UNEXPECTED TERMINATION"
    exit 128
}
# shellcheck disable=SC2064  # Intentional: $_sig must expand at trap-set time
for _sig in HUP INT QUIT TERM PIPE; do
    trap "_on_signal $_sig" "$_sig"
done

# =========================================================================
# Step 2: Resolve + validate the reviewed dirs (root + additional)
# =========================================================================
REVIEW_DIRS=()
resolve_review_dirs "$REVIEWER_SETTINGS"
_log_to_file "INFO" "Reviewing ${#REVIEW_DIRS[@]} dir(s): ${REVIEW_DIRS[*]}"

# Composite state key across all dirs -- the stuck hatch and block tracking are
# keyed on this so the whole cycle is treated as one unit. Computed from the
# pre-merge HEADs (the state the agent left things in).
_composite_state() {
    local d h
    for d in "${REVIEW_DIRS[@]}"; do
        h=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "unknown")
        printf '%s:%s\n' "$d" "$h"
    done | sort | (sha1sum 2>/dev/null || shasum 2>/dev/null) | cut -d' ' -f1
}
COMPOSITE=$(_composite_state)
ROOT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

BLOCK_TRACKER=".reviewer/outputs/stop_hook_consecutive_blocks"
PHASE_TMP=$(mktemp -d)

# Track whether the safety hatch fired so the EXIT trap doesn't re-create the
# tracker entry, and always clean up temp files.
_STUCK_HATCH_FIRED=false
# shellcheck disable=SC2154  # _exit_code is assigned inside the trap string
trap '
    _exit_code=$?
    _log_to_file "INFO" "orchestrator EXIT trap fired (pid=$$, exit_code=$_exit_code)"
    if [[ $_exit_code -ne 0 ]] && [[ "$_STUCK_HATCH_FIRED" != "true" ]]; then
        mkdir -p "$(dirname "$BLOCK_TRACKER")" 2>/dev/null || true
        echo "$COMPOSITE" >> "$BLOCK_TRACKER" 2>/dev/null || true
    fi
    rm -rf "$PHASE_TMP" 2>/dev/null || true
' EXIT

# =========================================================================
# Step 3: Stuck agent detection (keyed on composite state of all dirs)
# =========================================================================
MAX_CONSECUTIVE_BLOCKS=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.max_consecutive_blocks" "3")

_count_consecutive_blocks() {
    if [[ ! -f "$BLOCK_TRACKER" ]]; then
        echo 0
        return
    fi
    tail -n "$MAX_CONSECUTIVE_BLOCKS" "$BLOCK_TRACKER" | grep -c "^${COMPOSITE}$" || true
}

CONSECUTIVE_BLOCKS=$(_count_consecutive_blocks)
if [[ $CONSECUTIVE_BLOCKS -ge $MAX_CONSECUTIVE_BLOCKS ]]; then
    log_error "Stop hook has blocked ${MAX_CONSECUTIVE_BLOCKS} consecutive times at the same state ($COMPOSITE)."
    log_error "The agent appears stuck. Letting through to prevent an infinite loop."
    log_error "The review gates are still unsatisfied -- please investigate manually."
    _log_to_file "ERROR" "Stuck agent detected at $COMPOSITE (${CONSECUTIVE_BLOCKS} blocks), letting through"
    _STUCK_HATCH_FIRED=true
    rm -f "$BLOCK_TRACKER"
    exit 0
fi

# =========================================================================
# Step 4: Per-dir non-review pipeline, run concurrently
# =========================================================================
_log_to_file "INFO" "Launching per-dir pipelines..."

declare -a DIR_RESULT DIR_STDERR DIR_PIDS DIR_EXIT
for i in "${!REVIEW_DIRS[@]}"; do
    DIR_RESULT[i]="$PHASE_TMP/result_$i"
    DIR_STDERR[i]="$PHASE_TMP/stderr_$i"
    : > "${DIR_RESULT[i]}"
    "$SCRIPT_DIR/stop_hook_dir_pipeline.sh" "${REVIEW_DIRS[i]}" "${DIR_RESULT[i]}" 2>"${DIR_STDERR[i]}" &
    DIR_PIDS[i]=$!
done

for i in "${!DIR_PIDS[@]}"; do
    _ec=0
    wait "${DIR_PIDS[i]}" || _ec=$?
    DIR_EXIT[i]=$_ec
    _log_to_file "INFO" "dir '${REVIEW_DIRS[i]}' pipeline exited with $_ec"
done

_result_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

# =========================================================================
# Step 5: Build the manifest + run the unified review-gate check
# =========================================================================
MANIFEST="$PHASE_TMP/manifest"
: > "$MANIFEST"
PHASE1_FAILED=false
for i in "${!REVIEW_DIRS[@]}"; do
    _dir="${REVIEW_DIRS[i]}"
    _head=$(_result_get "${DIR_RESULT[i]}" HEAD)
    _branch=$(_result_get "${DIR_RESULT[i]}" BRANCH)
    _has=$(_result_get "${DIR_RESULT[i]}" HAS_CHANGES)
    if [[ "${DIR_EXIT[i]}" -ne 0 ]]; then
        PHASE1_FAILED=true
        # A hard non-review failure is already reported via this dir's stderr;
        # don't also demand review gates for it.
        _has="false"
    fi
    printf '%s\t%s\t%s\t%s\n' "$_dir" "${_head:-unknown}" "${_branch:-unknown}" "${_has:-false}" >> "$MANIFEST"
done

GATE_STDERR="$PHASE_TMP/gate_stderr"
GATES_EXIT=0
"$SCRIPT_DIR/stop_hook_gates.sh" "$MANIFEST" 2>"$GATE_STDERR" || GATES_EXIT=$?
_log_to_file "INFO" "Unified gate check exited with $GATES_EXIT"

# =========================================================================
# Step 6: Per-dir CI polling -- only once phase-1 and review gates are clean.
# (No point making the agent wait out CI when it already has work to do.)
# =========================================================================
CI_STDERR="$PHASE_TMP/ci_stderr"
: > "$CI_STDERR"
CI_EXIT=0

if [[ "$PHASE1_FAILED" == "false" ]] && [[ $GATES_EXIT -eq 0 ]]; then
    declare -a CI_PIDS CI_ERR CI_WHICH
    _k=0
    for i in "${!REVIEW_DIRS[@]}"; do
        _poll=$(_result_get "${DIR_RESULT[i]}" POLL_CI)
        _pr=$(_result_get "${DIR_RESULT[i]}" PR_NUMBER)
        if [[ "$_poll" == "true" ]] && [[ -n "$_pr" ]]; then
            CI_ERR[_k]="$PHASE_TMP/ci_stderr_$i"
            CI_WHICH[_k]="${REVIEW_DIRS[i]}"
            "$SCRIPT_DIR/stop_hook_pr_and_ci.sh" poll-ci "${REVIEW_DIRS[i]}" "$_pr" 2>"${CI_ERR[_k]}" &
            CI_PIDS[_k]=$!
            _log_to_file "INFO" "Launched CI poll for '${REVIEW_DIRS[i]}' (pr=$_pr)"
            _k=$((_k + 1))
        fi
    done
    for m in "${!CI_PIDS[@]}"; do
        _ec=0
        wait "${CI_PIDS[m]}" || _ec=$?
        if [[ $_ec -ne 0 ]]; then
            CI_EXIT=$_ec
            {
                echo "[${CI_WHICH[m]}] CI checks have not passed:"
                cat "${CI_ERR[m]}" 2>/dev/null || true
                echo ""
            } >> "$CI_STDERR"
        fi
    done
fi

# =========================================================================
# Step 7: Report results
# =========================================================================
if [[ "$PHASE1_FAILED" == "true" ]] || [[ $GATES_EXIT -ne 0 ]] || [[ $CI_EXIT -ne 0 ]]; then
    _log_to_file "INFO" "Blocking (phase1_failed=$PHASE1_FAILED, gates=$GATES_EXIT, ci=$CI_EXIT)"

    # Per-dir non-review failures first, each already dir-tagged on its stderr.
    for i in "${!REVIEW_DIRS[@]}"; do
        if [[ "${DIR_EXIT[i]}" -ne 0 ]] && [[ -s "${DIR_STDERR[i]}" ]]; then
            cat "${DIR_STDERR[i]}" >&2
            echo "" >&2
        fi
    done

    # Unified review-gate report.
    if [[ $GATES_EXIT -ne 0 ]] && [[ -s "$GATE_STDERR" ]]; then
        cat "$GATE_STDERR" >&2
    fi

    # CI failures (per dir).
    if [[ $CI_EXIT -ne 0 ]] && [[ -s "$CI_STDERR" ]]; then
        echo "" >&2
        cat "$CI_STDERR" >&2
    fi

    _log_to_file "INFO" "orchestrator exiting with code 2 (unsatisfied gates)"
    exit 2
fi

# =========================================================================
# Success -- clear stuck tracking, write success marker
# =========================================================================
rm -f "$BLOCK_TRACKER"
mkdir -p .reviewer/outputs 2>/dev/null || true
echo "$ROOT_HEAD" > .reviewer/outputs/orchestrator_success

_log_to_file "INFO" "orchestrator completed successfully (exit 0)"
exit 0
