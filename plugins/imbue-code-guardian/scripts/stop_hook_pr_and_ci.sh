#!/usr/bin/env bash
#
# stop_hook_pr_and_ci.sh
#
# Two-phase PR and CI management for the stop hook orchestrator.
#
# Phase 1 (ensure-pr): Check that a PR exists for the current branch.
#   Reopens closed PRs. Writes PR number/URL to .reviewer/outputs/ for downstream use.
#   Called early by the orchestrator so CI starts running in parallel.
#
# Phase 2 (poll-ci): Poll CI status for a given PR number.
#   Reads timeout/interval from config. Writes result to .reviewer/outputs/pr_status.
#   Called later by the orchestrator as a gate alongside review gates.
#
# Usage:
#   ./stop_hook_pr_and_ci.sh ensure-pr
#   ./stop_hook_pr_and_ci.sh poll-ci <pr_number>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export STOP_HOOK_SCRIPT_NAME="pr_and_ci"
# shellcheck source=stop_hook_common.sh
source "$SCRIPT_DIR/stop_hook_common.sh"
# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"

REVIEWER_SETTINGS=".reviewer/settings.json"

# ---------------------------------------------------------------------------
# ensure-pr: verify a PR exists for the current branch
# ---------------------------------------------------------------------------
_ensure_pr() {
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    local require_pr
    require_pr=$(read_json_config "$REVIEWER_SETTINGS" "ci.require_pr" "true")

    _log_to_file "INFO" "ensure-pr started (branch=$current_branch, require_pr=$require_pr)"

    local existing_pr="" pr_state=""
    if PR_INFO=$(gh pr view "$current_branch" --json number,state 2>/dev/null); then
        existing_pr=$(echo "$PR_INFO" | jq -r '.number')
        pr_state=$(echo "$PR_INFO" | jq -r '.state')
        log_info "Found existing PR #$existing_pr (state: $pr_state)"
    fi

    if [[ -z "$existing_pr" ]]; then
        if [[ "$require_pr" != "true" ]]; then
            log_info "No PR found and ci.require_pr=false, skipping CI"
            _log_to_file "INFO" "No PR, require_pr=false, skipping"
            echo "" > .reviewer/outputs/pr_number
            exit 0
        fi
        log_error "No PR found for branch $current_branch."
        log_error "Please create a draft PR using: gh pr create --draft"
        _log_to_file "ERROR" "No PR found for branch $current_branch, exiting with error"
        exit 2
    fi

    if [[ "$pr_state" == "MERGED" ]]; then
        log_info "PR #$existing_pr is already merged, skipping CI polling"
        _log_to_file "INFO" "PR #$existing_pr already merged, skipping CI polling"
        echo "" > .reviewer/outputs/pr_number
        exit 0
    fi

    if [[ "$pr_state" == "CLOSED" ]]; then
        log_info "PR #$existing_pr is closed. Reopening..."
        if gh pr reopen "$existing_pr" --comment "Reopening PR for continued work."; then
            log_info "Reopened PR #$existing_pr"
        else
            log_error "Failed to reopen PR #$existing_pr"
            exit 1
        fi
    fi

    # Write PR number for downstream use
    mkdir -p .reviewer/outputs 2>/dev/null || true
    echo "$existing_pr" > .reviewer/outputs/pr_number

    # Write PR URL for status line display
    local pr_url
    pr_url=$(gh pr view "$existing_pr" --json url --jq '.url' 2>/dev/null || echo "")
    if [[ -n "$pr_url" ]]; then
        echo "$pr_url" > .reviewer/outputs/pr_url
        log_info "Wrote PR URL to .reviewer/outputs/pr_url: $pr_url"
    fi

    # Initialize status as pending
    echo "pending" > .reviewer/outputs/pr_status

    _log_to_file "INFO" "ensure-pr completed (pr=$existing_pr)"
}

# ---------------------------------------------------------------------------
# poll-ci: poll CI status for a PR
# ---------------------------------------------------------------------------
_poll_ci() {
    local pr_number="${1:-}"
    if [[ -z "$pr_number" ]]; then
        log_error "poll-ci requires a PR number argument"
        exit 1
    fi

    local ci_timeout ci_interval
    ci_timeout=$(read_json_config "$REVIEWER_SETTINGS" "ci.timeout" "600")
    ci_interval=$(read_json_config "$REVIEWER_SETTINGS" "ci.poll_interval" "15")

    _log_to_file "INFO" "poll-ci started (pr=$pr_number, timeout=$ci_timeout, interval=$ci_interval)"

    log_info "Polling for PR #$pr_number check results..."
    if RESULT=$("$SCRIPT_DIR/poll_pr_checks.sh" --timeout "$ci_timeout" --interval "$ci_interval" "$pr_number"); then
        echo "$RESULT"
        echo "success" > .reviewer/outputs/pr_status
        log_info "Wrote PR status to .reviewer/outputs/pr_status: success"
        _log_to_file "INFO" "PR checks passed"
    else
        echo "failure" > .reviewer/outputs/pr_status
        log_info "Wrote PR status to .reviewer/outputs/pr_status: failure"
        log_error "CI tests have failed for the PR!"
        log_error "Use the gh tool to inspect the remote test results for this branch and see what failed."
        log_error "Note that you MUST identify the issue and fix it locally before trying again!"
        log_error "NEVER just re-trigger the pipeline!"
        log_error "NEVER fix timeouts by increasing them! Instead, make things faster or increase parallelism."
        log_error "If it is impossible to fix the test, tell the user and say that you failed."
        log_error "Otherwise, once you have understood and fixed the issue, you can simply commit to try again."
        _log_to_file "ERROR" "CI checks failed"
        exit 2
    fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
    ensure-pr)
        _ensure_pr
        ;;
    poll-ci)
        _poll_ci "$@"
        ;;
    *)
        echo "Usage: $0 {ensure-pr|poll-ci <pr_number>}" >&2
        exit 1
        ;;
esac
