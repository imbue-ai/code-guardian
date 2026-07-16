#!/usr/bin/env bash
#
# PR discovery and CI polling in stop_hook_pr_and_ci.sh.
#
# Every test stubs gh: this script is the only one in the hook that talks to
# GitHub, and a test that reaches the real API is a test that can hang, leak,
# or reopen someone's PR.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A branch with a stubbed gh and no remote, so nothing can reach the network.
# The gh stub logs every call to ./gh_calls and refuses anything unexpected.
_setup() {
    make_repo main
    echo "code" > app.py
    commit_all init
    git checkout -q -b feature
    stub_command gh '
echo "$*" >> "$PWD/gh_calls"
echo "unexpected gh call: $*" >&2
exit 1
'
}

_gh_calls() {
    cat gh_calls 2>/dev/null || true
}

# --- ensure-pr: an open PR exists ------------------------------------------
it "records the PR number and URL when a PR already exists"
_setup
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view feature --json number,state")
        echo "{\"number\":42,\"state\":\"OPEN\"}" ;;
    "pr view 42 --json url --jq .url")
        echo "https://github.com/acme/repo/pull/42" ;;
    *)
        echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh ensure-pr
assert_eq "$RUN_EXIT" "0" "an open PR satisfies ensure-pr"
assert_eq "$(cat .reviewer/outputs/pr_number)" "42"
assert_eq "$(cat .reviewer/outputs/pr_url)" "https://github.com/acme/repo/pull/42"
assert_eq "$(cat .reviewer/outputs/pr_status)" "pending" "CI has not run yet"

it "looks the PR up by the current branch"
assert_contains "$(_gh_calls)" "pr view feature --json number,state"
cleanup_repo

# --- ensure-pr: no PR ------------------------------------------------------
it "blocks when no PR exists and one is required"
_setup
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
echo "no pull requests found for branch \"feature\"" >&2
exit 1
'
run_script stop_hook_pr_and_ci.sh ensure-pr
assert_eq "$RUN_EXIT" "2" "ci.require_pr defaults to true"
assert_contains "$RUN_OUT" "No PR found for branch feature"
assert_contains "$RUN_OUT" "gh pr create --draft"

it "writes no PR number when it could not find one"
assert_file_absent ".reviewer/outputs/pr_number"
cleanup_repo

it "passes when no PR exists and none is required"
_setup
write_settings <<'EOF'
{
  "ci": { "require_pr": false }
}
EOF
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
exit 1
'
run_script stop_hook_pr_and_ci.sh ensure-pr
assert_eq "$RUN_EXIT" "0" "ci.require_pr=false makes the PR optional"
assert_contains "$RUN_OUT" "skipping CI"

it "blanks the PR number so downstream steps skip CI"
assert_file_exists ".reviewer/outputs/pr_number"
assert_eq "$(cat .reviewer/outputs/pr_number)" "" "an empty PR number means no CI"
cleanup_repo

# --- ensure-pr: merged and closed PRs --------------------------------------
it "skips CI for an already-merged PR"
_setup
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view feature --json number,state")
        echo "{\"number\":7,\"state\":\"MERGED\"}" ;;
    *)
        echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh ensure-pr
assert_eq "$RUN_EXIT" "0" "a merged PR needs no further CI"
assert_contains "$RUN_OUT" "already merged"
assert_eq "$(cat .reviewer/outputs/pr_number)" ""
assert_file_absent ".reviewer/outputs/pr_status"
cleanup_repo

it "reopens a closed PR and carries on"
_setup
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view feature --json number,state")
        echo "{\"number\":9,\"state\":\"CLOSED\"}" ;;
    "pr reopen 9 --comment Reopening PR for continued work.")
        echo "reopened" ;;
    "pr view 9 --json url --jq .url")
        echo "https://github.com/acme/repo/pull/9" ;;
    *)
        echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh ensure-pr
assert_eq "$RUN_EXIT" "0"
assert_contains "$(_gh_calls)" "pr reopen 9 --comment Reopening PR for continued work."
assert_eq "$(cat .reviewer/outputs/pr_number)" "9"
assert_eq "$(cat .reviewer/outputs/pr_status)" "pending"
cleanup_repo

it "fails when a closed PR cannot be reopened"
_setup
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view feature --json number,state")
        echo "{\"number\":9,\"state\":\"CLOSED\"}" ;;
    *)
        exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh ensure-pr
assert_eq "$RUN_EXIT" "1" "a failed reopen is an error, not a gate block"
assert_contains "$RUN_OUT" "Failed to reopen PR #9"
cleanup_repo

# --- ensure-pr: the outputs directory --------------------------------------
# The early returns above write into .reviewer/outputs, so ensure-pr has to
# create it before it can take one.
it "creates the outputs directory even when it takes an early return"
_setup
write_settings <<'EOF'
{
  "ci": { "require_pr": false }
}
EOF
rm -rf .reviewer/outputs
stub_command gh '
exit 1
'
run_script stop_hook_pr_and_ci.sh ensure-pr
assert_eq "$RUN_EXIT" "0"
assert_file_exists ".reviewer/outputs/pr_number" "the early return must still be able to write"
cleanup_repo

it "creates the outputs directory before failing on a missing PR"
_setup
rm -rf .reviewer/outputs
stub_command gh '
exit 1
'
run_script stop_hook_pr_and_ci.sh ensure-pr
assert_eq "$RUN_EXIT" "2"
[[ -d .reviewer/outputs ]] || _fail ".reviewer/outputs should exist after ensure-pr"
cleanup_repo

# --- poll-ci ---------------------------------------------------------------
# ci.timeout and ci.poll_interval are turned right down: the defaults are 600s
# and 15s, which no test suite can afford.
_setup_poll() {
    _setup
    write_settings <<'EOF'
{
  "ci": { "timeout": 5, "poll_interval": 1 }
}
EOF
    mkdir -p .reviewer/outputs
}

it "passes when every check passes"
_setup_poll
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view 42 --json headRefOid --jq .headRefOid")
        echo "abc123" ;;
    "pr checks 42")
        printf "build\tpass\t1m\thttps://example.invalid/1\n"
        printf "lint\tpass\t20s\thttps://example.invalid/2\n" ;;
    *)
        echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh poll-ci 42
assert_eq "$RUN_EXIT" "0" "green CI should not block"
assert_contains "$RUN_OUT" "success"
assert_eq "$(cat .reviewer/outputs/pr_status)" "success"
cleanup_repo

it "creates the outputs directory when run without a prior ensure-pr"
_setup_poll
rm -rf .reviewer/outputs
stub_command gh '
case "$*" in
    "pr view 42 --json headRefOid --jq .headRefOid")
        echo "abc123" ;;
    "pr checks 42")
        printf "build\tpass\t1m\thttps://example.invalid/1\n" ;;
    *)
        echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh poll-ci 42
assert_eq "$RUN_EXIT" "0" "green CI must not fail on a missing outputs dir"
assert_not_contains "$RUN_OUT" "No such file or directory"
assert_eq "$(cat .reviewer/outputs/pr_status)" "success"
cleanup_repo

it "blocks when a check fails"
_setup_poll
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view 42 --json headRefOid --jq .headRefOid")
        echo "abc123" ;;
    "pr checks 42")
        printf "build\tpass\t1m\thttps://example.invalid/1\n"
        printf "lint\tfail\t20s\thttps://example.invalid/2\n"
        exit 1 ;;
    *)
        echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh poll-ci 42
assert_eq "$RUN_EXIT" "2" "failing CI must block"
assert_contains "$RUN_OUT" "CI tests have failed for the PR!"
assert_eq "$(cat .reviewer/outputs/pr_status)" "failure"

it "tells the agent to fix the cause rather than re-run the pipeline"
assert_contains "$RUN_OUT" "NEVER just re-trigger the pipeline!"
cleanup_repo

it "waits for pending checks and passes once they finish"
_setup_poll
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view 42 --json headRefOid --jq .headRefOid")
        echo "abc123" ;;
    "pr checks 42")
        n=$(cat "$PWD/poll_count" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$PWD/poll_count"
        if [[ $n -lt 2 ]]; then
            printf "build\tpending\t0s\thttps://example.invalid/1\n"
            exit 8
        fi
        printf "build\tpass\t1m\thttps://example.invalid/1\n" ;;
    *)
        echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh poll-ci 42
assert_eq "$RUN_EXIT" "0" "a pending check should be waited out, not failed"
assert_eq "$(cat .reviewer/outputs/pr_status)" "success"
assert_eq "$(cat poll_count)" "2" "polling should have taken a second pass"
cleanup_repo

it "blocks when checks never stop pending"
_setup_poll
write_settings <<'EOF'
{
  "ci": { "timeout": 1, "poll_interval": 1 }
}
EOF
stub_command gh '
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view 42 --json headRefOid --jq .headRefOid")
        echo "abc123" ;;
    "pr checks 42")
        printf "build\tpending\t0s\thttps://example.invalid/1\n"
        exit 8 ;;
    *)
        echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
'
run_script stop_hook_pr_and_ci.sh poll-ci 42
assert_eq "$RUN_EXIT" "2" "a CI timeout is reported as a failure"
assert_eq "$(cat .reviewer/outputs/pr_status)" "failure"
cleanup_repo

# --- dispatch --------------------------------------------------------------
it "rejects poll-ci without a PR number"
_setup
run_script stop_hook_pr_and_ci.sh poll-ci
assert_eq "$RUN_EXIT" "1"
assert_contains "$RUN_OUT" "poll-ci requires a PR number argument"
cleanup_repo

it "prints usage for an unknown subcommand"
_setup
run_script stop_hook_pr_and_ci.sh frobnicate
assert_eq "$RUN_EXIT" "1"
assert_contains "$RUN_OUT" "Usage:"
assert_contains "$RUN_OUT" "{ensure-pr|poll-ci <pr_number>}"
cleanup_repo

it "prints usage when given no subcommand"
_setup
run_script stop_hook_pr_and_ci.sh
assert_eq "$RUN_EXIT" "1"
assert_contains "$RUN_OUT" "Usage:"
cleanup_repo

report
