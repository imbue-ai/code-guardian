#!/usr/bin/env bash
#
# stop_hook_orchestrator.sh
#
# Main stop hook orchestrator for code-guardian. Runs the full pipeline:
#
#   1. Check enabled_when condition
#   2. Read-only turn skip (exit early if no code-affecting tools used)
#   3. Stuck agent detection (safety hatch)
#   4. Uncommitted changes enforcement
#   5. Fetch and merge base branch
#   6. Push to origin + ensure PR exists (so CI starts early)
#   7. Informational session detection (skip if .md-only changes)
#   8. Run review gates synchronously; surface any prior-turn CI failure;
#      fire-and-forget a fresh CI poll in the background for the next turn
#   9. Report all unsatisfied gates together
#
# All configuration is read from .reviewer/settings.json (with
# .reviewer/settings.local.json overrides). No environment variable
# fallbacks -- use config for everything.
#
# Exit codes:
#   0 -- all gates passed (or hook disabled/skipped)
#   2 -- gates unsatisfied (stderr shown to agent)
#   1 -- unexpected error

set -euo pipefail

# Capture the hook JSON from stdin so we can extract transcript_path. Drain
# any remainder so downstream commands don't accidentally consume it.
HOOK_INPUT=""
if [[ ! -t 0 ]]; then
    HOOK_INPUT=$(cat 2>/dev/null || true)
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"

REVIEWER_SETTINGS=".reviewer/settings.json"

# =========================================================================
# Step 1: Check enabled_when
# =========================================================================
ENABLED_WHEN=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.enabled_when" "")
if [[ -z "$ENABLED_WHEN" ]]; then
    exit 0
fi
if ! bash -c "$ENABLED_WHEN" 2>/dev/null; then
    exit 0
fi

# Set up logging now that we know the hook is enabled
STOP_HOOK_LOG=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.log_file" ".reviewer/logs/stop_hook.jsonl")
export STOP_HOOK_LOG
export STOP_HOOK_SCRIPT_NAME="orchestrator"

# shellcheck source=stop_hook_common.sh
source "$SCRIPT_DIR/stop_hook_common.sh"

_log_to_file "INFO" "========================================================"
_log_to_file "INFO" "Stop hook orchestrator started (pid=$$, ppid=$PPID)"
_log_to_file "INFO" "========================================================"

# =========================================================================
# Read-only turn skip
# =========================================================================
# If the assistant only used read-only tools (Read/Glob/Grep/LS) since the
# last human user turn, the turn produced no code-affecting work. Skip the
# whole pipeline -- no fetch, no push, no PR ops, no gates, no CI poll.
SKIP_READONLY=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.skip_readonly_turns" "true")

_extract_transcript_path() {
    [[ -z "$HOOK_INPUT" ]] && return
    if command -v jq >/dev/null 2>&1; then
        echo "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null
        return
    fi
    # Fallback: simple regex extraction. Handles the typical
    # {"transcript_path":"..."} shape with no embedded escaped quotes.
    echo "$HOOK_INPUT" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

if [[ "$SKIP_READONLY" == "true" ]]; then
    TRANSCRIPT_PATH=$(_extract_transcript_path)
    if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
        if TOOLS_USED=$(python3 "$SCRIPT_DIR/detect_tools_used.py" "$TRANSCRIPT_PATH" 2>/dev/null); then
            # Anything not in the read-only allowlist is "substantive"
            SUBSTANTIVE=$(echo "$TOOLS_USED" | grep -vxE 'Read|Glob|Grep|LS' || true)
            if [[ -z "$SUBSTANTIVE" ]]; then
                tool_summary=$(echo "$TOOLS_USED" | tr '\n' ',' | sed 's/,$//')
                _log_to_file "INFO" "Read-only turn (tools=${tool_summary:-none}); skipping all gates"
                exit 0
            fi
        fi
    fi
fi

# Trap signals so we can log unexpected terminations
_on_signal() {
    local sig="$1"
    _log_to_file "ERROR" "orchestrator received signal $sig (pid=$$) -- UNEXPECTED TERMINATION"
    exit 128
}
# shellcheck disable=SC2064  # Intentional: $_sig must expand at trap-set time
for _sig in HUP INT QUIT TERM PIPE; do
    trap "_on_signal $_sig" "$_sig"
done

# Track whether the safety hatch has fired so the EXIT trap doesn't
# immediately re-create the tracker entry.
_STUCK_HATCH_FIRED=false

HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
BLOCK_TRACKER=".reviewer/outputs/stop_hook_consecutive_blocks"

# shellcheck disable=SC2154  # _exit_code is assigned inside the trap string
trap '
    _exit_code=$?
    _log_to_file "INFO" "orchestrator EXIT trap fired (pid=$$, exit_code=$_exit_code)"
    if [[ $_exit_code -ne 0 ]] && [[ "$_STUCK_HATCH_FIRED" != "true" ]]; then
        mkdir -p "$(dirname "$BLOCK_TRACKER")" 2>/dev/null || true
        echo "$HASH" >> "$BLOCK_TRACKER" 2>/dev/null || true
    fi
' EXIT

# =========================================================================
# Step 2: Stuck agent detection (must be before uncommitted check)
# =========================================================================
MAX_CONSECUTIVE_BLOCKS=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.max_consecutive_blocks" "3")

_count_consecutive_blocks() {
    if [[ ! -f "$BLOCK_TRACKER" ]]; then
        echo 0
        return
    fi
    local match_count
    match_count=$(tail -n "$MAX_CONSECUTIVE_BLOCKS" "$BLOCK_TRACKER" | grep -c "^${HASH}$" || true)
    echo "$match_count"
}

CONSECUTIVE_BLOCKS=$(_count_consecutive_blocks)
if [[ $CONSECUTIVE_BLOCKS -ge $MAX_CONSECUTIVE_BLOCKS ]]; then
    log_error "Stop hook has blocked ${MAX_CONSECUTIVE_BLOCKS} consecutive times at the same commit ($HASH)."
    log_error "The agent appears stuck. Letting through to prevent an infinite loop."
    log_error "The review gates are still unsatisfied -- please investigate manually."
    _log_to_file "ERROR" "Stuck agent detected at $HASH (${CONSECUTIVE_BLOCKS} blocks), letting through"
    _STUCK_HATCH_FIRED=true
    rm -f "$BLOCK_TRACKER"
    exit 0
fi

# =========================================================================
# Step 3: Uncommitted changes enforcement
# =========================================================================
REQUIRE_COMMITTED=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.require_committed" "true")

if [[ "$REQUIRE_COMMITTED" == "true" ]]; then
    untracked=$(git ls-files --others --exclude-standard)
    staged=$(git diff --cached --name-only)
    unstaged=$(git diff --name-only)

    if [[ -n "$untracked" ]] || [[ -n "$staged" ]] || [[ -n "$unstaged" ]]; then
        echo "ERROR: Uncommitted changes detected. All changes must be committed before this hook can run." >&2
        echo "ERROR: Please commit or gitignore all files before stopping." >&2
        if [[ -n "$untracked" ]]; then
            echo "" >&2
            echo "Untracked files (need to git add or add to .gitignore):" >&2
            while IFS= read -r _f; do echo "  $_f" >&2; done <<< "$untracked"
        fi
        if [[ -n "$unstaged" ]]; then
            echo "" >&2
            echo "Unstaged changes (need to git add):" >&2
            while IFS= read -r _f; do echo "  $_f" >&2; done <<< "$unstaged"
        fi
        if [[ -n "$staged" ]]; then
            echo "" >&2
            echo "Staged but not committed (need to git commit):" >&2
            while IFS= read -r _f; do echo "  $_f" >&2; done <<< "$staged"
        fi
        echo "" >&2
        echo "All files must be either gitignored or committed before stopping." >&2
        echo "If you're not ready to commit yet because the task is not yet complete (ex: tests do not pass or you have a question for the user), simply prefix your commit message with WIP:" >&2
        _log_to_file "ERROR" "Uncommitted changes detected, exiting with 2"
        exit 2
    fi
fi

# =========================================================================
# Step 4: Fetch and merge base branch
# =========================================================================
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
BASE_BRANCH=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.base_branch" "main")
FETCH_AND_MERGE=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.fetch_and_merge" "true")

if [[ "$FETCH_AND_MERGE" == "true" ]]; then
    _log_to_file "INFO" "Fetching all remotes (base_branch=$BASE_BRANCH)"
    log_info "Fetching all remotes..."
    git fetch --all

    # Push base branch if it doesn't exist on origin yet
    if ! git rev-parse --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
        log_info "Pushing base branch to origin (not yet present remotely)..."
        if ! retry_command 3 git push origin "$BASE_BRANCH"; then
            log_error "Failed to push base branch after retries."
            exit 2
        fi
    fi

    # Merge origin base branch
    if git rev-parse --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
        log_info "Merging origin/$BASE_BRANCH..."
        if ! git merge "origin/$BASE_BRANCH" --no-edit; then
            log_error "Merge conflict detected while merging origin/$BASE_BRANCH."
            log_error "Please resolve the merge conflicts before continuing."
            exit 2
        fi
    fi

    # Merge local base branch
    if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
        log_info "Merging $BASE_BRANCH..."
        if ! git merge "$BASE_BRANCH" --no-edit; then
            log_error "Merge conflict detected while merging $BASE_BRANCH."
            log_error "Please resolve the merge conflicts before continuing."
            exit 2
        fi
    fi

    # Push merge commits (if any), setting upstream tracking
    log_info "Pushing any merge commits..."
    if ! retry_command 3 git push -u origin HEAD; then
        log_error "Failed to push after retries. Perhaps you forgot to commit something? Or pre-commit hooks changed something?"
        exit 2
    fi

    # Update HASH after merge (may have changed)
    HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
fi

# =========================================================================
# Step 5: Push + ensure PR exists (CI starts early)
# =========================================================================
CI_ENABLED=$(read_json_config "$REVIEWER_SETTINGS" "ci.is_enabled" "true")
PR_NUMBER=""

if [[ "$CI_ENABLED" == "true" ]]; then
    _log_to_file "INFO" "Checking PR existence..."
    if "$SCRIPT_DIR/stop_hook_pr_and_ci.sh" ensure-pr; then
        PR_NUMBER=$(cat .reviewer/outputs/pr_number 2>/dev/null || echo "")
        _log_to_file "INFO" "PR check passed (pr_number=$PR_NUMBER)"
    else
        PR_CI_EXIT=$?
        _log_to_file "INFO" "PR check failed (exit=$PR_CI_EXIT)"
        exit "$PR_CI_EXIT"
    fi
fi

# =========================================================================
# Step 6: Informational session detection
# =========================================================================
SKIP_INFORMATIONAL=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.skip_informational" "true")
IS_INFORMATIONAL_ONLY=false

if [[ "$SKIP_INFORMATIONAL" == "true" ]]; then
    if [[ "$CURRENT_BRANCH" == "$BASE_BRANCH" ]]; then
        log_info "Currently on base branch ($BASE_BRANCH) -- no PR needed"
        IS_INFORMATIONAL_ONLY=true
    else
        # Use origin/$BASE_BRANCH since we just fetched
        CHANGED_FILES=$(git diff --name-only "origin/$BASE_BRANCH"...HEAD 2>/dev/null || echo "")
        if [[ -z "$CHANGED_FILES" ]]; then
            log_info "No files changed compared to $BASE_BRANCH -- informational session"
            IS_INFORMATIONAL_ONLY=true
        else
            NON_MD_FILES=$(echo "$CHANGED_FILES" | grep -v '\.md$' || true)
            if [[ -z "$NON_MD_FILES" ]]; then
                log_info "Only .md files changed compared to $BASE_BRANCH -- informational session"
                IS_INFORMATIONAL_ONLY=true
            fi
        fi
    fi
fi

if [[ "$IS_INFORMATIONAL_ONLY" == "true" ]]; then
    _log_to_file "INFO" "Informational-only session, exiting cleanly (exit 0)"
    exit 0
fi

# =========================================================================
# Step 7: Run review gates synchronously; handle CI asynchronously
#
# CI handling is fire-and-forget: blocking the agent's tmux slot for up to
# ci.timeout (default 600s) waiting on CI turns 30s iterations into 10min
# ones. Instead, surface the *previous* turn's CI result for the current
# commit (if any) and kick off a fresh background poll whose result the
# *next* turn will surface. The poll is detached via nohup + disown +
# stdio redirection so it survives the orchestrator exiting.
# =========================================================================
_log_to_file "INFO" "Starting gate checks..."

GATE_STDERR=$(mktemp)
CI_STDERR=$(mktemp)
_cleanup_temp() {
    rm -f "$GATE_STDERR" "$CI_STDERR"
}

GATES_EXIT=0
CI_REPORT_FAILURE=false

# Run review gates (foreground). `|| true` so the non-zero exit doesn't trip
# `set -e`; we capture the real status via $? immediately.
"$SCRIPT_DIR/stop_hook_gates.sh" "$HASH" 2>"$GATE_STDERR" || GATES_EXIT=$?
_log_to_file "INFO" "Gates process exited with code $GATES_EXIT"

# CI handling -- check the prior poll's outcome for the current SHA, then
# fire and forget a new poll if needed.
if [[ "$CI_ENABLED" == "true" ]] && [[ -n "$PR_NUMBER" ]]; then
    PRIOR_PID_FILE=".reviewer/outputs/pr_status_pid"
    PRIOR_SHA_FILE=".reviewer/outputs/pr_status_sha"
    PRIOR_STATUS_FILE=".reviewer/outputs/pr_status"

    PRIOR_PID=$(cat "$PRIOR_PID_FILE" 2>/dev/null || true)
    PRIOR_SHA=$(cat "$PRIOR_SHA_FILE" 2>/dev/null || true)
    PRIOR_STATUS=$(cat "$PRIOR_STATUS_FILE" 2>/dev/null || true)

    POLL_RUNNING=false
    if [[ -n "$PRIOR_PID" ]] && kill -0 "$PRIOR_PID" 2>/dev/null; then
        POLL_RUNNING=true
    fi

    POLL_NEEDED=true
    if [[ "$PRIOR_SHA" == "$HASH" ]]; then
        if [[ "$PRIOR_STATUS" == "failure" ]]; then
            CI_REPORT_FAILURE=true
            POLL_NEEDED=false
            _log_to_file "INFO" "Surfacing prior CI failure for current commit ($HASH)"
            {
                echo "ERROR: CI tests have failed for the PR (reported by the previous turn's background poll)."
                echo "ERROR: Use the gh tool to inspect the remote test results for this branch and see what failed."
                echo "ERROR: Note that you MUST identify the issue and fix it locally before trying again!"
                echo "ERROR: NEVER just re-trigger the pipeline!"
                echo "ERROR: NEVER fix timeouts by increasing them! Instead, make things faster or increase parallelism."
                echo "ERROR: If it is impossible to fix the test, tell the user and say that you failed."
                echo "ERROR: Otherwise, once you have understood and fixed the issue, you can simply commit to try again."
            } > "$CI_STDERR"
        elif [[ "$PRIOR_STATUS" == "success" ]]; then
            POLL_NEEDED=false
            _log_to_file "INFO" "Prior CI poll already passed for $HASH; not re-polling"
        elif [[ "$POLL_RUNNING" == "true" ]]; then
            POLL_NEEDED=false
            _log_to_file "INFO" "CI poll already running for $HASH (pid=$PRIOR_PID)"
        fi
    else
        if [[ "$POLL_RUNNING" == "true" ]]; then
            _log_to_file "INFO" "HEAD changed ($PRIOR_SHA -> $HASH); terminating stale CI poll (pid=$PRIOR_PID)"
            kill -TERM "$PRIOR_PID" 2>/dev/null || true
        fi
    fi

    if [[ "$POLL_NEEDED" == "true" ]]; then
        mkdir -p .reviewer/outputs 2>/dev/null || true
        echo "$HASH" > "$PRIOR_SHA_FILE"
        echo "pending" > "$PRIOR_STATUS_FILE"
        # Detach the poll: nohup ignores SIGHUP, the redirects untether stdio
        # from the orchestrator, and `disown` removes the job from bash's
        # table so it survives the orchestrator's exit. Plain `& $!` gives a
        # reliable PID (unlike `setsid`, which forks if the caller is a
        # process group leader and yields the wrong $!).
        nohup bash "$SCRIPT_DIR/stop_hook_pr_and_ci.sh" poll-ci "$PR_NUMBER" \
            </dev/null >/dev/null 2>&1 &
        POLL_BG_PID=$!
        echo "$POLL_BG_PID" > "$PRIOR_PID_FILE"
        disown "$POLL_BG_PID" 2>/dev/null || true
        _log_to_file "INFO" "Launched detached CI poll (pid=$POLL_BG_PID, pr=$PR_NUMBER, sha=$HASH)"
    fi
fi

# =========================================================================
# Step 8: Report results
# =========================================================================
if [[ $GATES_EXIT -ne 0 ]] || [[ "$CI_REPORT_FAILURE" == "true" ]]; then
    _log_to_file "INFO" "Gates or CI failed (gates=$GATES_EXIT, ci_report_failure=$CI_REPORT_FAILURE)"

    # Relay gate errors to stderr (these contain the missing gates report)
    if [[ $GATES_EXIT -ne 0 ]] && [[ -s "$GATE_STDERR" ]]; then
        cat "$GATE_STDERR" >&2
    fi

    # Relay CI errors to stderr
    if [[ "$CI_REPORT_FAILURE" == "true" ]] && [[ -s "$CI_STDERR" ]]; then
        # Add separator if both failed
        if [[ $GATES_EXIT -ne 0 ]]; then
            echo "" >&2
            echo "Additionally, CI checks have not passed:" >&2
        fi
        cat "$CI_STDERR" >&2
    fi

    _cleanup_temp
    _log_to_file "INFO" "orchestrator exiting with code 2 (unsatisfied gates)"
    exit 2
fi

# =========================================================================
# Success -- clear stuck tracking, write success marker
# =========================================================================
rm -f "$BLOCK_TRACKER"
_cleanup_temp

mkdir -p .reviewer/outputs 2>/dev/null || true
echo "$HASH" > .reviewer/outputs/orchestrator_success

_log_to_file "INFO" "orchestrator completed successfully (exit 0)"
exit 0
