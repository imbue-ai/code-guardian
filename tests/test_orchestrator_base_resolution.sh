#!/usr/bin/env bash
#
# Base branch resolution in stop_hook_orchestrator.sh (Step 5).
#
# The failure these cover: when the base ref could not be resolved, the
# docs-only check saw an empty diff and skipped every gate on a branch full
# of code.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

_setup() {
    make_repo main
    write_settings <<EOF
{
  "stop_hook": {
    "enabled_when": "true",
    "base_branch": "${1:-main}",
    "fetch_and_merge": false,
    "require_committed": true,
    "skip_informational": true,
    "max_consecutive_blocks": 3
  },
  "ci": { "is_enabled": false }
}
EOF
    echo "code" > app.py
    commit_all init
    git checkout -q -b feature
}

# --- unresolvable base -----------------------------------------------------
it "exits 1, non-blocking, when the base resolves nowhere"
_setup trunk
echo "more code" >> app.py
commit_all work
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "1" "unresolvable base should exit 1, not block or skip"
assert_contains "$RUN_OUT" "Cannot resolve base branch 'trunk'"

it "does not silently claim a code diff is docs-only"
assert_not_contains "$RUN_OUT" "docs-only"

it "does not count a non-blocking exit against the stuck hatch"
assert_file_absent ".reviewer/outputs/stop_hook_consecutive_blocks"
cleanup_repo

# --- local base, no remote -------------------------------------------------
it "falls back to the local base when origin/<base> is absent"
_setup main
echo "more code" >> app.py
commit_all work
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "2" "real code changes must reach the gates"
assert_contains "$RUN_OUT" "gates have not been satisfied"

it "counts a blocking exit against the stuck hatch"
assert_file_exists ".reviewer/outputs/stop_hook_consecutive_blocks"
cleanup_repo

# --- docs-only still skips -------------------------------------------------
it "still skips the gates for a docs-only diff"
_setup main
echo "# doc" > README.md
commit_all docs
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "0" "docs-only should skip cleanly"
assert_contains "$RUN_OUT" "docs-only"
cleanup_repo

# --- empty diff still skips ------------------------------------------------
it "still skips the gates when nothing changed"
_setup main
run_script stop_hook_orchestrator.sh
assert_eq "$RUN_EXIT" "0" "empty diff should skip cleanly"
cleanup_repo

report
