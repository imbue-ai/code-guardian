#!/usr/bin/env bash
#
# Integration smoke test for the multi-directory stop hook.
#
# Exercises the pure-bash pipeline (orchestrator + dir pipeline + gate checker)
# without needing gh/CI/network: fetch_and_merge and ci are disabled in config,
# and gate satisfaction is simulated by touching marker files.
#
# Run: bash tests/test_multi_dir_stop_hook.sh
#
# Verifies:
#   1. Backward-compat: root-only, changes, no markers -> block (classic report)
#   2. Secondary-only changes -> block, dir-tagged unified report (the bug fix)
#   3. All markers present -> pass (exit 0)
#   4/5/6. Misconfigured additional dir (missing / non-repo / no settings) -> hard error
#   7. Uncommitted changes in a secondary dir -> block, dir-tagged
#   8. Composite stuck hatch -> lets through after N identical-state blocks

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$REPO_ROOT/plugins/imbue-code-guardian/scripts/stop_hook_orchestrator.sh"

PASS=0
FAIL=0
_ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
_bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Assert exit code.
assert_exit() { # <expected> <actual> <label>
    if [[ "$1" == "$2" ]]; then _ok "$3 (exit $2)"; else _bad "$3 (expected exit $1, got $2)"; fi
}
# Assert stderr file contains a substring.
assert_has() { # <file> <needle> <label>
    if grep -qF "$2" "$1"; then _ok "$3"; else _bad "$3 -- missing: $2"; fi
}
assert_not() { # <file> <needle> <label>
    if grep -qF "$2" "$1"; then _bad "$3 -- unexpected: $2"; else _ok "$3"; fi
}

# ---------------------------------------------------------------------------
# Repo helpers
# ---------------------------------------------------------------------------
_gitq() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# Create a repo at <path> with a bare origin and main pushed, so origin/main
# exists for the hook's docs-only diff detection.
make_repo() { # <path>
    local p="$1" origin
    mkdir -p "$p"
    # Bare origin lives OUTSIDE every worktree so it never shows up in a repo's
    # own `git status` (a real remote would be on GitHub, not in the tree).
    origin="$(mktemp -d "$WORK/origin.XXXXXX")/repo.git"
    git init -q --bare "$origin"
    _gitq "$p" init -q -b main
    _gitq "$p" remote add origin "$origin"
    echo "# base" > "$p/README.md"
    printf 'x = 1\n' > "$p/code.py"
    _gitq "$p" add -A
    _gitq "$p" commit -q -m "base"
    _gitq "$p" push -q -u origin main
}

# Add a committed code change on a feature branch (so diff vs origin/main is non-empty).
add_feature_change() { # <path> <branch>
    _gitq "$1" checkout -q -b "$2"
    printf 'x = 2  # changed\n' > "$1/code.py"
    _gitq "$1" add -A
    _gitq "$1" commit -q -m "feature change"
}

# Commit whatever is staged/working on main and push (settings + gitignore live
# on the base branch, just like a real self-contained repo).
commit_push() { # <dir>
    _gitq "$1" add -A
    _gitq "$1" commit -q -m "reviewer setup"
    _gitq "$1" push -q origin main
}

# Write a .gitignore that ignores the reviewer runtime dirs (outputs/logs are
# never committed) plus any extra lines (e.g. nested repos).
write_gitignore() { # <dir> [extra_lines...]
    { printf '.reviewer/outputs/\n.reviewer/logs/\n'; printf '%s\n' "${@:2}"; } > "$1/.gitignore"
}

write_root_settings() { # <root> <additional_json_array>
    mkdir -p "$1/.reviewer"
    cat > "$1/.reviewer/settings.json" <<EOF
{
  "stop_hook": {
    "enabled_when": "true",
    "base_branch": "main",
    "fetch_and_merge": false,
    "require_committed": true,
    "skip_informational": true,
    "max_consecutive_blocks": 3,
    "additional_git_directories": $2,
    "log_file": ".reviewer/logs/stop_hook.jsonl"
  },
  "ci": { "is_enabled": false },
  "autofix": { "is_enabled": true },
  "verify_conversation": { "is_enabled": true },
  "verify_architecture": { "is_enabled": true }
}
EOF
}

write_secondary_settings() { # <dir>
    mkdir -p "$1/.reviewer"
    cat > "$1/.reviewer/settings.json" <<'EOF'
{
  "stop_hook": { "base_branch": "main", "fetch_and_merge": false, "require_committed": true, "skip_informational": true },
  "ci": { "is_enabled": false },
  "autofix": { "is_enabled": true },
  "verify_conversation": { "is_enabled": false },
  "verify_architecture": { "is_enabled": true }
}
EOF
}

# Simulate gate satisfaction for a dir at its current HEAD/branch.
mark_autofix() { # <dir>
    local h; h=$(_gitq "$1" rev-parse HEAD)
    mkdir -p "$1/.reviewer/outputs/autofix"; echo ok > "$1/.reviewer/outputs/autofix/${h}_verified.md"
}
mark_arch() { # <dir>
    local b; b=$(_gitq "$1" rev-parse --abbrev-ref HEAD); b="${b//\//_}"
    mkdir -p "$1/.reviewer/outputs/architecture"; echo ok > "$1/.reviewer/outputs/architecture/${b}.md"
}
mark_convo_root() { # <root>
    local h; h=$(_gitq "$1" rev-parse HEAD)
    mkdir -p "$1/.reviewer/outputs/conversation"; echo '{}' > "$1/.reviewer/outputs/conversation/${h}.json"
}

# Run the orchestrator with CWD=<root>; capture stderr to <errfile>; echo exit code.
run_hook() { # <root> <errfile>
    ( cd "$1" && bash "$ORCH" </dev/null 2>"$2" >/dev/null ); echo $?
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
echo "Scenario 1: backward-compat (root-only, changes, no markers -> block)"
R1="$WORK/s1/root"; make_repo "$R1"
write_root_settings "$R1" '[]'; write_gitignore "$R1"; commit_push "$R1"
add_feature_change "$R1" feature/x
E1="$WORK/s1.err"; rc=$(run_hook "$R1" "$E1")
assert_exit 2 "$rc" "blocks"
assert_has "$E1" "autofix (/autofix)" "reports autofix"
assert_has "$E1" "architecture verification (/verify-architecture)" "reports architecture"
assert_has "$E1" "conversation review (/verify-conversation)" "reports conversation"
assert_not "$E1" "needed in:" "no per-dir suffix for single root"
assert_not "$E1" "runs ONCE" "no multi-dir note for single root"

# ===========================================================================
echo "Scenario 2: secondary-only changes -> block with dir-tagged unified report"
R2="$WORK/s2/root"; N2="$R2/nested"
make_repo "$R2"
write_root_settings "$R2" '["nested"]'; write_gitignore "$R2" "nested/"; commit_push "$R2"
make_repo "$N2"
write_secondary_settings "$N2"; write_gitignore "$N2"; commit_push "$N2"
add_feature_change "$N2" feature/y
# root stays clean on main (no reviewable changes)
E2="$WORK/s2.err"; rc=$(run_hook "$R2" "$E2")
assert_exit 2 "$rc" "blocks"
assert_has "$E2" "needed in: nested" "autofix/arch tagged to nested"
assert_has "$E2" "conversation review (/verify-conversation)" "conversation fires (root-scoped) on secondary work"
assert_has "$E2" "runs ONCE" "multi-dir unified-command note present"

# ===========================================================================
echo "Scenario 3: all markers present -> pass"
mark_autofix "$N2"; mark_arch "$N2"; mark_convo_root "$R2"
E3="$WORK/s3.err"; rc=$(run_hook "$R2" "$E3")
assert_exit 0 "$rc" "passes once every changed dir is marked"

# ===========================================================================
echo "Scenario 4: additional dir does not exist -> hard error"
R4="$WORK/s4/root"; make_repo "$R4"
write_root_settings "$R4" '["ghost"]'; write_gitignore "$R4"; commit_push "$R4"
E4="$WORK/s4.err"; rc=$(run_hook "$R4" "$E4")
assert_exit 2 "$rc" "blocks"
assert_has "$E4" "does not exist" "explains missing dir"

# ===========================================================================
echo "Scenario 5: additional dir shares the root repo (not distinct) -> hard error"
R5="$WORK/s5/root"; make_repo "$R5"; mkdir -p "$R5/plain"; echo hi > "$R5/plain/f.txt"
write_root_settings "$R5" '["plain"]'; write_gitignore "$R5" "plain/"; commit_push "$R5"
E5="$WORK/s5.err"; rc=$(run_hook "$R5" "$E5")
assert_exit 2 "$rc" "blocks"
assert_has "$E5" "resolves to the root repository" "rejects a subdir of the root repo"

# ===========================================================================
echo "Scenario 6: additional dir lacks its own .reviewer/settings.json -> hard error"
R6="$WORK/s6/root"; N6="$R6/nested"; make_repo "$R6"
write_root_settings "$R6" '["nested"]'; write_gitignore "$R6" "nested/"; commit_push "$R6"
make_repo "$N6"  # no write_secondary_settings
E6="$WORK/s6.err"; rc=$(run_hook "$R6" "$E6")
assert_exit 2 "$rc" "blocks"
assert_has "$E6" "no .reviewer/settings.json" "explains missing self-contained config"

# ===========================================================================
echo "Scenario 7: uncommitted changes in a secondary dir -> block, dir-tagged"
R7="$WORK/s7/root"; N7="$R7/nested"; make_repo "$R7"
write_root_settings "$R7" '["nested"]'; write_gitignore "$R7" "nested/"; commit_push "$R7"
make_repo "$N7"
write_secondary_settings "$N7"; write_gitignore "$N7"; commit_push "$N7"
echo "uncommitted" > "$N7/dirty.py"  # untracked, not gitignored
E7="$WORK/s7.err"; rc=$(run_hook "$R7" "$E7")
assert_exit 2 "$rc" "blocks"
assert_has "$E7" "[nested]" "message tagged to the nested dir"
assert_has "$E7" "Uncommitted changes detected" "reports uncommitted changes"

# ===========================================================================
echo "Scenario 8: composite stuck hatch lets through after N identical-state blocks"
R8="$WORK/s8/root"; make_repo "$R8"
write_root_settings "$R8" '[]'; write_gitignore "$R8"; commit_push "$R8"
add_feature_change "$R8" feature/z
E8="$WORK/s8.err"
rc=$(run_hook "$R8" "$E8"); assert_exit 2 "$rc" "block 1"
rc=$(run_hook "$R8" "$E8"); assert_exit 2 "$rc" "block 2"
rc=$(run_hook "$R8" "$E8"); assert_exit 2 "$rc" "block 3"
rc=$(run_hook "$R8" "$E8"); assert_exit 0 "$rc" "let through on 4th (stuck)"
assert_has "$E8" "appears stuck" "explains stuck hatch"

# ===========================================================================
echo "Scenario 9: a secondary dir's append_to_prompt flows into the unified command"
R9="$WORK/s9/root"; N9="$R9/nested"; make_repo "$R9"
write_root_settings "$R9" '["nested"]'; write_gitignore "$R9" "nested/"; commit_push "$R9"
make_repo "$N9"
# Secondary settings carrying an autofix append_to_prompt of its own.
mkdir -p "$N9/.reviewer"
cat > "$N9/.reviewer/settings.json" <<'EOF'
{
  "stop_hook": { "base_branch": "main", "fetch_and_merge": false, "require_committed": true, "skip_informational": true },
  "ci": { "is_enabled": false },
  "autofix": { "is_enabled": true, "append_to_prompt": "FOCUS_ON_NESTED_XYZ" },
  "verify_conversation": { "is_enabled": false },
  "verify_architecture": { "is_enabled": true }
}
EOF
write_gitignore "$N9"; commit_push "$N9"
add_feature_change "$N9" feature/w
# root stays clean on main -> only the nested dir has changes
E9="$WORK/s9.err"; rc=$(run_hook "$R9" "$E9")
assert_exit 2 "$rc" "blocks"
assert_has "$E9" "/autofix FOCUS_ON_NESTED_XYZ" "secondary dir's autofix append_to_prompt reaches the unified command"

# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
