#!/usr/bin/env bash
#
# The gates stop_hook_orchestrator.sh applies before it looks at any diff:
# enabled_when (Step 1), the stuck-agent safety hatch (Step 2), the
# uncommitted-changes check (Step 3), and the EXIT trap that records blocks.
#
# Base resolution and docs-only skipping (Step 5) live in
# test_orchestrator_base_resolution.sh.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The stop_hook fields the Step 2/3 tests share, at their documented defaults.
_HOOK_ON='"enabled_when": "true", "require_committed": true, "max_consecutive_blocks": 3'

# Scratch repo on `feature`, branched off a `main` that has real code, with
# settings.json committed. $1 is spliced into stop_hook, so each test states
# only the fields it varies. fetch_and_merge and ci stay off: no network here.
_setup() {
    local overrides="${1:-}"
    make_repo main
    write_settings <<EOF
{
  "stop_hook": {
    "base_branch": "main",
    "fetch_and_merge": false,
    "skip_informational": true${overrides:+,
    $overrides}
  },
  "ci": { "is_enabled": false }
}
EOF
    echo "code" > app.py
    commit_all init
    git checkout -q -b feature
}

# A commit whose diff vs main is real code, so the review gates have something
# to fire on and the run blocks (exit 2) unless an earlier step stops it.
_commit_code() {
    _assert_scratch
    echo "more code" >> app.py
    commit_all work
}

# Pre-load the block tracker with <hash> repeated <count> times, as previous
# blocking runs would have left it.
_seed_tracker() {
    _assert_scratch
    mkdir -p .reviewer/outputs
    local i
    for ((i = 0; i < $2; i++)); do
        echo "$1" >> .reviewer/outputs/stop_hook_consecutive_blocks
    done
}

BLOCK_TRACKER=".reviewer/outputs/stop_hook_consecutive_blocks"
STOP_HOOK_LOG=".reviewer/logs/stop_hook.jsonl"

# ===========================================================================
# Step 1: enabled_when
#
# The hook is opt-in, and logging starts only once it has opted in -- a
# disabled hook must leave no trace in the repo at all.
# ===========================================================================
it "treats an absent enabled_when as disabled"
_setup
_commit_code
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "0" "absent enabled_when should disable the hook, not block"
assert_file_absent "$STOP_HOOK_LOG" "a disabled hook must not start logging"
cleanup_repo

it "treats an empty enabled_when as disabled"
_setup '"enabled_when": ""'
_commit_code
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "0" "empty enabled_when should disable the hook"
assert_file_absent "$STOP_HOOK_LOG" "a disabled hook must not start logging"
cleanup_repo

it "treats a failing enabled_when command as disabled"
_setup '"enabled_when": "false"'
_commit_code
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "0" "a failing enabled_when should disable the hook"
assert_file_absent "$STOP_HOOK_LOG" "a disabled hook must not start logging"
cleanup_repo

it "runs the pipeline when the enabled_when command succeeds"
_setup "$_HOOK_ON"
_commit_code
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2" "an enabled hook must reach the review gates"
assert_contains "$RUN_OUT" "gates have not been satisfied"
assert_file_exists "$STOP_HOOK_LOG" "an enabled hook logs from Step 1 onward"
cleanup_repo

# ===========================================================================
# Step 3: uncommitted changes
#
# Each dirty state is reported under its own heading, naming the files, so the
# agent knows whether to add, commit, or gitignore.
# ===========================================================================
it "blocks on an untracked file and names it"
_setup "$_HOOK_ON"
_commit_code
echo "scratch" > notes.txt
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2" "an untracked file must block"
assert_contains "$RUN_OUT" "Uncommitted changes detected"
assert_contains "$RUN_OUT" "Untracked files"
assert_contains "$RUN_OUT" "notes.txt"
cleanup_repo

it "blocks on an unstaged modification and names it"
_setup "$_HOOK_ON"
_commit_code
echo "uncommitted edit" >> app.py
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2" "an unstaged modification must block"
assert_contains "$RUN_OUT" "Unstaged changes"
assert_contains "$RUN_OUT" "app.py"
assert_not_contains "$RUN_OUT" "Untracked files" "a tracked file is not untracked"
cleanup_repo

it "blocks on a staged but uncommitted change and names it"
_setup "$_HOOK_ON"
_commit_code
echo "staged" > staged.py
git add staged.py
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2" "a staged change must block"
assert_contains "$RUN_OUT" "Staged but not committed"
assert_contains "$RUN_OUT" "staged.py"
assert_not_contains "$RUN_OUT" "Untracked files" "git add moved it out of untracked"
cleanup_repo

it "lets a clean tree past the uncommitted check"
_setup "$_HOOK_ON"
_commit_code
run_script stop_hook_orchestrator.sh
assert_not_contains "$RUN_OUT" "Uncommitted changes detected"
assert_contains "$RUN_OUT" "gates have not been satisfied" "a clean tree reaches Step 7"
cleanup_repo

it "ignores a dirty tree when require_committed is false"
_setup '"enabled_when": "true", "require_committed": false, "max_consecutive_blocks": 3'
_commit_code
echo "scratch" > notes.txt
run_script stop_hook_orchestrator.sh
assert_not_contains "$RUN_OUT" "Uncommitted changes detected"
assert_contains "$RUN_OUT" "gates have not been satisfied" "the run continues past Step 3"
cleanup_repo

# ===========================================================================
# Step 2: stuck-agent safety hatch
#
# Blocking the same commit forever is worse than letting an unreviewed one
# through, so after max_consecutive_blocks blocks at one hash the hook stands
# down and resets the count.
# ===========================================================================
it "lets the agent through after max_consecutive_blocks blocks at one commit"
_setup "$_HOOK_ON"
_commit_code
_seed_tracker "$(git rev-parse HEAD)" 3
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "0" "the hatch must let the agent through"
assert_contains "$RUN_OUT" "The agent appears stuck"
assert_contains "$RUN_OUT" "still unsatisfied"

it "clears the tracker when the hatch fires, and the EXIT trap leaves it cleared"
assert_file_absent "$BLOCK_TRACKER" "a fired hatch must reset the count, not re-arm it"
cleanup_repo

it "keeps the hatch shut below max_consecutive_blocks"
_setup "$_HOOK_ON"
_commit_code
_seed_tracker "$(git rev-parse HEAD)" 2
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2" "two prior blocks are not yet three"
assert_not_contains "$RUN_OUT" "appears stuck"
cleanup_repo

it "counts only blocks at the current HEAD toward the hatch"
_setup "$_HOOK_ON"
_commit_code
_seed_tracker "0000000000000000000000000000000000000000" 3
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2" "blocks recorded at another commit must not open the hatch"
assert_not_contains "$RUN_OUT" "appears stuck"
cleanup_repo

# ===========================================================================
# EXIT trap: block accounting
#
# The tracker feeds Step 2, so it must gain exactly one entry per blocking run
# and nothing on any other exit.
# ===========================================================================
it "records exactly one entry, the current HEAD, for a blocking run"
_setup "$_HOOK_ON"
_commit_code
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2"
assert_eq "$(cat "$BLOCK_TRACKER")" "$(git rev-parse HEAD)" "one line, and it is HEAD"
cleanup_repo

# Docs-only is the one clean exit that leaves the tracker alone -- the success
# path deletes it, which would hide an append.
it "records nothing for a clean exit"
_setup "$_HOOK_ON"
echo "# doc" > README.md
commit_all docs
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "0"
assert_file_absent "$BLOCK_TRACKER" "only a blocking run counts"
cleanup_repo

it "accumulates one entry per blocking run at the same commit"
_setup '"enabled_when": "true", "require_committed": true, "max_consecutive_blocks": 5'
_commit_code
run_script stop_hook_orchestrator.sh
run_script stop_hook_orchestrator.sh
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2" "a max of 5 keeps the hatch shut for three blocks"
assert_eq "$(grep -c . "$BLOCK_TRACKER")" "3" "one entry per blocking run"
assert_eq "$(sort -u "$BLOCK_TRACKER")" "$(git rev-parse HEAD)" "every entry is the current HEAD"
cleanup_repo

report
