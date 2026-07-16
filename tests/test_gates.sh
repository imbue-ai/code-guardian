#!/usr/bin/env bash
#
# Gate checking in stop_hook_gates.sh.
#
# The markers are the whole contract: autofix and conversation review are keyed
# by commit, architecture by branch, and the block of text below is what the
# agent actually reads when a gate is unsatisfied.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A branch with real code changes vs the base, so the empty-diff skip never
# masks the gate logic. Extra config keys are merged in from stdin.
_setup() {
    make_repo main
    write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "main" }
}
EOF
    echo "code" > app.py
    commit_all init
    git checkout -q -b "${1:-feature}"
    echo "more code" >> app.py
    commit_all work
    HASH=$(git rev-parse HEAD)
}

_mark_autofix() {
    mkdir -p .reviewer/outputs/autofix
    touch ".reviewer/outputs/autofix/${1}_verified.md"
}

_mark_convo() {
    mkdir -p .reviewer/outputs/conversation
    touch ".reviewer/outputs/conversation/${1}.json"
}

_mark_arch() {
    mkdir -p .reviewer/outputs/architecture
    touch ".reviewer/outputs/architecture/${1}.md"
}

# --- nothing satisfied -----------------------------------------------------
it "blocks and names every gate when no markers exist"
_setup
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2" "missing gates must block"
assert_contains "$RUN_OUT" "architecture verification (/verify-architecture)"
assert_contains "$RUN_OUT" "autofix (/autofix)"
assert_contains "$RUN_OUT" "conversation review (/verify-conversation)"

it "prints exactly the block the agent is meant to read"
assert_eq "$RUN_OUT" "$(cat <<'EOF'
The following review gates have not been satisfied:
  - architecture verification (/verify-architecture)
  - autofix (/autofix)
  - conversation review (/verify-conversation)

Run these before finishing. Address any issues raised by /verify-architecture before running /autofix, since architecture changes may make autofix results obsolete. If possible, run /verify-conversation in the background while running the others.

Note: these gates may fire again after you make changes. /verify-conversation is incremental and only reviews new content. For /autofix, the default is to run the full check, but if your changes since the last autofix run are focused, you may pass instructions telling it to focus on the diff since the last run (while still providing the true base branch).
EOF
)" "the gate report is a user-facing contract"
cleanup_repo

# --- everything satisfied --------------------------------------------------
it "passes when every marker is present for the hash under test"
_setup
_mark_autofix "$HASH"
_mark_convo "$HASH"
_mark_arch feature
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "0" "all markers present should pass"
assert_eq "$RUN_OUT" "" "a passing run says nothing"
cleanup_repo

it "honors an explicit hash argument over HEAD"
_setup
_mark_autofix deadbeef
_mark_convo deadbeef
_mark_arch feature
run_script stop_hook_gates.sh deadbeef
assert_eq "$RUN_EXIT" "0" "markers for the passed hash should satisfy the gates"
cleanup_repo

# --- markers are per-commit ------------------------------------------------
it "re-requires the per-commit gates when the markers are for another hash"
_setup
_mark_autofix "$HASH"
_mark_convo "$HASH"
_mark_arch feature
run_script stop_hook_gates.sh deadbeef
assert_eq "$RUN_EXIT" "2" "stale per-commit markers must not satisfy the gates"
assert_contains "$RUN_OUT" "autofix (/autofix)"
assert_contains "$RUN_OUT" "conversation review (/verify-conversation)"

it "keeps architecture satisfied across hashes, since it is keyed by branch"
assert_not_contains "$RUN_OUT" "architecture verification"
cleanup_repo

it "keys architecture by branch, with slashes flattened to underscores"
_setup feat/nested
_mark_autofix "$HASH"
_mark_convo "$HASH"
_mark_arch feat_nested
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "0" "feat/nested should read .reviewer/outputs/architecture/feat_nested.md"
cleanup_repo

# --- one gate at a time ----------------------------------------------------
it "reports only the others when architecture is satisfied"
_setup
_mark_arch feature
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2"
assert_not_contains "$RUN_OUT" "architecture verification"
assert_contains "$RUN_OUT" "autofix (/autofix)"
assert_contains "$RUN_OUT" "conversation review (/verify-conversation)"

it "drops the architecture-before-autofix ordering advice once architecture is done"
assert_not_contains "$RUN_OUT" "may make autofix results obsolete"
cleanup_repo

it "reports only the others when autofix is satisfied"
_setup
_mark_autofix "$HASH"
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2"
assert_not_contains "$RUN_OUT" "autofix (/autofix)"
assert_contains "$RUN_OUT" "architecture verification (/verify-architecture)"
assert_contains "$RUN_OUT" "conversation review (/verify-conversation)"
cleanup_repo

it "reports only the others when conversation review is satisfied"
_setup
_mark_convo "$HASH"
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2"
assert_not_contains "$RUN_OUT" "conversation review"
assert_contains "$RUN_OUT" "architecture verification (/verify-architecture)"
assert_contains "$RUN_OUT" "autofix (/autofix)"

it "drops the background advice once conversation review is done"
assert_not_contains "$RUN_OUT" "in the background while running the others"
cleanup_repo

it "omits the multi-gate guidance when a single gate remains"
_setup
_mark_arch feature
_mark_convo "$HASH"
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2"
assert_contains "$RUN_OUT" "autofix (/autofix)"
assert_not_contains "$RUN_OUT" "Run these before finishing."
cleanup_repo

# --- config toggles --------------------------------------------------------
it "does not require a disabled conversation gate"
_setup
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "main" },
  "verify_conversation": { "is_enabled": false }
}
EOF
_mark_autofix "$HASH"
_mark_arch feature
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "0" "a disabled gate must not be required"
assert_not_contains "$RUN_OUT" "conversation review"
cleanup_repo

it "does not require a disabled autofix gate"
_setup
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "main" },
  "autofix": { "is_enabled": false }
}
EOF
_mark_convo "$HASH"
_mark_arch feature
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "0"
assert_not_contains "$RUN_OUT" "autofix"
cleanup_repo

it "does not require a disabled architecture gate"
_setup
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "main" },
  "verify_architecture": { "is_enabled": false }
}
EOF
_mark_autofix "$HASH"
_mark_convo "$HASH"
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "0"
assert_not_contains "$RUN_OUT" "architecture verification"
cleanup_repo

it "passes with no markers at all when every gate is disabled"
_setup
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "main" },
  "autofix": { "is_enabled": false },
  "verify_conversation": { "is_enabled": false },
  "verify_architecture": { "is_enabled": false }
}
EOF
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "0"
assert_eq "$RUN_OUT" ""
cleanup_repo

it "drops the repeat-firing note when both per-commit gates are disabled"
_setup
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "main" },
  "autofix": { "is_enabled": false },
  "verify_conversation": { "is_enabled": false }
}
EOF
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2" "architecture is still required"
assert_contains "$RUN_OUT" "architecture verification (/verify-architecture)"
assert_not_contains "$RUN_OUT" "these gates may fire again"
cleanup_repo

it "keeps the repeat-firing note while a per-commit gate is enabled but satisfied"
_setup
_mark_autofix "$HASH"
_mark_convo "$HASH"
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2" "architecture is still required"
assert_contains "$RUN_OUT" "these gates may fire again"
cleanup_repo

# --- prompt suffixes -------------------------------------------------------
it "appends configured arguments to the suggested commands"
_setup
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "main" },
  "autofix": { "append_to_prompt": "--effort high" },
  "verify_conversation": { "append_to_prompt": "be brief" },
  "verify_architecture": { "append_to_prompt": "focus on layering" }
}
EOF
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2"
assert_contains "$RUN_OUT" "architecture verification (/verify-architecture focus on layering)"
assert_contains "$RUN_OUT" "autofix (/autofix --effort high)"
assert_contains "$RUN_OUT" "conversation review (/verify-conversation be brief)"
cleanup_repo

# --- no code changes -------------------------------------------------------
it "skips the gates when nothing changed vs the base"
make_repo main
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "main" }
}
EOF
echo "code" > app.py
commit_all init
git checkout -q -b feature
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "0" "an empty diff needs no review"
assert_eq "$RUN_OUT" ""
cleanup_repo

it "still checks the gates when the base branch does not resolve"
_setup
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "trunk" }
}
EOF
run_script stop_hook_gates.sh
assert_eq "$RUN_EXIT" "2" "an unresolvable base must not be read as an empty diff"
assert_contains "$RUN_OUT" "gates have not been satisfied"
cleanup_repo

report
