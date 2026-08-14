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
#   4. Absent additional dir -> skipped, root still reviewed
#   5/6. Misconfigured additional dir (non-repo / no settings) -> hard error
#   7. Uncommitted changes in a secondary dir -> block, dir-tagged
#   8. Composite stuck hatch -> lets through after N identical-state blocks
#   9. Secondary dir's append_to_prompt flows into the unified command
#   10. Anchors to CLAUDE_PROJECT_DIR when CWD is inside a secondary dir
#   11. uncommitted_exempt_paths: exempt subtree dirt passes, other dirt blocks
#   12. Stray settings nested in a larger repo's tree -> hook skips, no action
#   13. Additional dir that is a subdir inside another repo -> hard error
#   14. Root-scoped base-branch env override does not leak into a secondary dir
#   15. Detached-HEAD (pinned) checkouts are skipped entirely (no merge/push)
#   16. Merge blocked by exempt-path dirt -> distinct error, state left intact
#   17. Merge blocked by non-exempt dirt -> the generic conflict error
#   18. Exempt-path dirt the merge does not touch -> merge proceeds untouched
#   19. Exempt subtree too large for git's refusal message -> still classifies

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
# CLAUDE_PROJECT_DIR is unset: it leaks in when the tests run inside a Claude
# Code session, and the orchestrator's anchor would then aim every scenario at
# the developer's real repo instead of the scenario's temp repo.
run_hook() { # <root> <errfile>
    ( cd "$1" && env -u CLAUDE_PROJECT_DIR bash "$ORCH" </dev/null 2>"$2" >/dev/null ); echo $?
}

# Run the orchestrator the way Claude Code does when the agent has cd'd
# somewhere else: CWD=<cwd> but CLAUDE_PROJECT_DIR=<root>.
run_hook_from() { # <cwd> <root> <errfile>
    ( cd "$1" && CLAUDE_PROJECT_DIR="$2" bash "$ORCH" </dev/null 2>"$3" >/dev/null ); echo $?
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
echo "Scenario 4: additional dir does not exist -> skipped, root still reviewed"
R4="$WORK/s4/root"; make_repo "$R4"
write_root_settings "$R4" '["ghost"]'; write_gitignore "$R4"; commit_push "$R4"
add_feature_change "$R4" feature/v
E4="$WORK/s4.err"; rc=$(run_hook "$R4" "$E4")
assert_exit 2 "$rc" "blocks on the root's own gates"
assert_has "$E4" "autofix (/autofix)" "reports the root's autofix gate"
assert_not "$E4" "ghost" "absent dir is not mentioned"
assert_not "$E4" "needed in:" "absent dir is dropped from the reviewed set"
# ...and once the root's markers are in place, the absent dir doesn't hold it back.
mark_autofix "$R4"; mark_arch "$R4"; mark_convo_root "$R4"
rc=$(run_hook "$R4" "$WORK/s4b.err")
assert_exit 0 "$rc" "passes with only the root marked"

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
# Stop hooks run in the agent's CURRENT directory, which follows `cd`. If the
# agent cd'd into a secondary reviewed dir, the orchestrator must still anchor
# to the project root (CLAUDE_PROJECT_DIR) -- otherwise it would read the
# secondary dir's config as the root config, so that dir's enabled_when would
# gate the whole hook and additional_git_directories would be lost, silently
# skipping all review. This mirrors the real mngr + nested-repo case.
echo "Scenario 10: hook anchors to CLAUDE_PROJECT_DIR when CWD is inside a secondary dir"
R10="$WORK/s10/root"; N10="$R10/nested"; make_repo "$R10"
write_root_settings "$R10" '["nested"]'; write_gitignore "$R10" "nested/"; commit_push "$R10"
make_repo "$N10"
# Secondary config that would DISABLE the hook if it were mistaken for the root.
mkdir -p "$N10/.reviewer"
cat > "$N10/.reviewer/settings.json" <<'EOF'
{
  "stop_hook": { "enabled_when": "false", "base_branch": "main", "fetch_and_merge": false, "require_committed": true, "skip_informational": true },
  "ci": { "is_enabled": false },
  "autofix": { "is_enabled": true },
  "verify_conversation": { "is_enabled": false },
  "verify_architecture": { "is_enabled": true }
}
EOF
write_gitignore "$N10"; commit_push "$N10"
add_feature_change "$N10" feature/anchored
E10="$WORK/s10.err"; rc=$(run_hook_from "$N10" "$R10" "$E10")
assert_exit 2 "$rc" "still blocks when CWD is the secondary dir"
assert_has "$E10" "needed in: nested" "still attributes the change to the nested dir"

# ===========================================================================
echo "Scenario 11: uncommitted_exempt_paths -- exempt subtree dirt passes, other dirt blocks"
R11="$WORK/s11/root"; make_repo "$R11"
mkdir -p "$R11/vendor/mngr"
printf 'lib = 1\n' > "$R11/vendor/mngr/lib.py"
write_root_settings "$R11" '[]'
jq '.stop_hook.uncommitted_exempt_paths = ["vendor/mngr"]' "$R11/.reviewer/settings.json" > "$R11/.reviewer/settings.json.tmp" \
    && mv "$R11/.reviewer/settings.json.tmp" "$R11/.reviewer/settings.json"
write_gitignore "$R11"; commit_push "$R11"
# Dirty the exempt subtree both ways: modify a tracked file, add an untracked one.
printf 'lib = 2\n' > "$R11/vendor/mngr/lib.py"
echo new > "$R11/vendor/mngr/generated.py"
E11="$WORK/s11.err"; rc=$(run_hook "$R11" "$E11")
assert_exit 0 "$rc" "passes with only exempt-path dirt (root on main, nothing to review)"
# Dirt OUTSIDE the exempt path still blocks, and the report doesn't name exempt files.
echo stray > "$R11/stray.py"
rc=$(run_hook "$R11" "$E11")
assert_exit 2 "$rc" "blocks on non-exempt dirt"
assert_has "$E11" "stray.py" "reports the non-exempt file"
assert_not "$E11" "generated.py" "exempt file is not listed"

# ===========================================================================
# Mirror of the vendored-copy incident: a repo's tree contains a nested copy of
# another repo that ships its own .reviewer/settings.json (no .git of its own).
# If the hook lands there (cwd fallback, no CLAUDE_PROJECT_DIR), bare git
# resolves to the ENCLOSING repo while the config came from the subtree. The
# hook must skip -- not run that config against the enclosing repo.
echo "Scenario 12: stray settings nested in a larger repo's tree -> hook skips"
R12="$WORK/s12/root"; make_repo "$R12"
mkdir -p "$R12/vendor/inner/.reviewer"
cat > "$R12/vendor/inner/.reviewer/settings.json" <<'EOF'
{
  "stop_hook": { "enabled_when": "true", "base_branch": "main", "fetch_and_merge": false, "require_committed": true },
  "ci": { "is_enabled": false }
}
EOF
write_gitignore "$R12"; commit_push "$R12"
# Dirty the enclosing repo: pre-invariant, the subtree's config would block on this.
echo dirty > "$R12/uncommitted.py"
E12="$WORK/s12.err"; rc=$(run_hook "$R12/vendor/inner" "$E12")
assert_exit 0 "$rc" "skips when the settings dir is not the repo toplevel"
assert_not "$E12" "Uncommitted changes detected" "takes no action on the enclosing repo"

# ===========================================================================
echo "Scenario 13: additional dir that is a subdir inside another repo -> hard error"
R13="$WORK/s13/root"; N13="$R13/nested"; make_repo "$R13"
write_root_settings "$R13" '["nested/sub"]'; write_gitignore "$R13" "nested/"; commit_push "$R13"
make_repo "$N13"
write_secondary_settings "$N13"; write_gitignore "$N13"; commit_push "$N13"
# The entry points INSIDE the nested repo, at a subdir carrying its own settings.
mkdir -p "$N13/sub/.reviewer"
cp "$N13/.reviewer/settings.json" "$N13/sub/.reviewer/settings.json"
E13="$WORK/s13.err"; rc=$(run_hook "$R13" "$E13")
assert_exit 2 "$rc" "blocks"
assert_has "$E13" "not the toplevel" "rejects a non-toplevel additional dir"

# ===========================================================================
# The CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH env override is per-agent config for
# the agent's OWN repo (e.g. mngr exports the agent's base branch). A secondary
# dir's base branch comes from its own settings. If the override leaked in, the
# nested dir would be diffed against a branch that doesn't exist there -- an
# empty-looking diff that silently drops the dir from review.
echo "Scenario 14: root-scoped base-branch env override does not leak into a secondary dir"
R14="$WORK/s14/root"; N14="$R14/nested"; make_repo "$R14"
write_root_settings "$R14" '["nested"]'; write_gitignore "$R14" "nested/"; commit_push "$R14"
make_repo "$N14"
write_secondary_settings "$N14"; write_gitignore "$N14"; commit_push "$N14"
add_feature_change "$N14" feature/envleak
# root stays clean on main -> only the nested dir has changes
E14="$WORK/s14.err"
rc=$(CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH="agent-base-branch" run_hook "$R14" "$E14")
assert_exit 2 "$rc" "still blocks on the nested dir's changes"
assert_has "$E14" "needed in: nested" "nested dir reviewed against its own base branch"

# ===========================================================================
# A detached HEAD marks a deliberately pinned checkout (a tag or exact SHA).
# The hook must leave it entirely alone: no base-branch merge (which would
# silently fast-forward a clean pinned checkout of an ancestor commit), no
# push (a bare `push HEAD` refspec from a detached HEAD would mint a remote
# branch literally named HEAD), no uncommitted-changes enforcement.
echo "Scenario 15: detached-HEAD (pinned) checkouts are skipped entirely"
R15="$WORK/s15/root"; make_repo "$R15"
write_root_settings "$R15" '[]'; write_gitignore "$R15"; commit_push "$R15"
# Enable fetch_and_merge so the detached guard (not the config) is what
# prevents the merge.
sed -i.bak 's/"fetch_and_merge": false/"fetch_and_merge": true/' "$R15/.reviewer/settings.json" && rm -f "$R15/.reviewer/settings.json.bak"
_gitq "$R15" add -A; _gitq "$R15" commit -q -m "enable fetch_and_merge"; _gitq "$R15" push -q origin main
# Pin the checkout at an ancestor of main, so an (unwanted) merge would
# fast-forward it off the pin.
PIN15=$(_gitq "$R15" rev-parse HEAD~1)
_gitq "$R15" checkout -q --detach "$PIN15"
E15="$WORK/s15.err"; rc=$(run_hook "$R15" "$E15")
assert_exit 0 "$rc" "pinned root passes without action"
# The skip note goes to the per-dir log (stderr of a dir that exits 0 is not
# relayed by the orchestrator).
assert_has "$R15/.reviewer/logs/stop_hook.jsonl" "detached HEAD (pinned checkout)" "logs the skip"
if [[ "$(_gitq "$R15" rev-parse HEAD)" == "$PIN15" ]]; then
    _ok "pinned HEAD not moved by a base-branch merge"
else
    _bad "pinned HEAD moved (was $PIN15, now $(_gitq "$R15" rev-parse HEAD))"
fi
if [[ -z "$(_gitq "$R15" ls-remote origin refs/heads/HEAD)" ]]; then
    _ok "no remote branch named HEAD was created"
else
    _bad "a remote branch literally named HEAD was pushed"
fi

# ...and a pinned ADDITIONAL dir is skipped while the root is still reviewed.
R15B="$WORK/s15b/root"; N15B="$R15B/nested"; make_repo "$R15B"
write_root_settings "$R15B" '["nested"]'; write_gitignore "$R15B" "nested/"; commit_push "$R15B"
add_feature_change "$R15B" feature/pinned-nested
make_repo "$N15B"
write_secondary_settings "$N15B"; write_gitignore "$N15B"; commit_push "$N15B"
sed -i.bak 's/"fetch_and_merge": false/"fetch_and_merge": true/' "$N15B/.reviewer/settings.json" && rm -f "$N15B/.reviewer/settings.json.bak"
_gitq "$N15B" add -A; _gitq "$N15B" commit -q -m "enable fetch_and_merge"; _gitq "$N15B" push -q origin main
PIN15B=$(_gitq "$N15B" rev-parse HEAD~1)
_gitq "$N15B" checkout -q --detach "$PIN15B"
E15B="$WORK/s15b.err"; rc=$(run_hook "$R15B" "$E15B")
assert_exit 2 "$rc" "root's own gates still block"
assert_has "$E15B" "autofix (/autofix)" "root's autofix gate still reported"
assert_has "$N15B/.reviewer/logs/stop_hook.jsonl" "detached HEAD (pinned checkout)" "pinned nested dir logs its skip"
if [[ "$(_gitq "$N15B" rev-parse HEAD)" == "$PIN15B" ]]; then
    _ok "pinned nested HEAD not moved"
else
    _bad "pinned nested HEAD moved (was $PIN15B, now $(_gitq "$N15B" rev-parse HEAD))"
fi

# ===========================================================================
# Exempting a path from the clean-tree check does not exempt it from git, which
# refuses to merge over working-tree state the merge would overwrite -- and the
# base branch is the very place machine-generated state gets updated, so this
# collision is routine. The hook must name it as its own failure rather than
# report a merge conflict that isn't one, and must NOT resolve it by discarding
# the state: only the repo knows how to regenerate it, and a dev loop's live
# working copy would be silently lost.
echo "Scenario 16: merge blocked by exempt-path dirt -> distinct error, state intact"
R16="$WORK/s16/root"; make_repo "$R16"
mkdir -p "$R16/vendor/mngr"
printf 'lib = 1\n' > "$R16/vendor/mngr/lib.py"
printf 'acc = 1\n' > "$R16/vendor/mngr/café.py"
write_root_settings "$R16" '[]'
jq '.stop_hook.uncommitted_exempt_paths = ["vendor/mngr"] | .stop_hook.fetch_and_merge = true' \
    "$R16/.reviewer/settings.json" > "$R16/.reviewer/settings.json.tmp" \
    && mv "$R16/.reviewer/settings.json.tmp" "$R16/.reviewer/settings.json"
write_gitignore "$R16"; commit_push "$R16"
# origin/main advances, touching the exempt subtree -- both by editing a file
# already there and by adding one the dev loop also generates.
C16="$WORK/s16/clone"; git clone -q "$(_gitq "$R16" remote get-url origin)" "$C16"
printf 'lib = 99  # from main\n' > "$C16/vendor/mngr/lib.py"
printf 'gen = 99  # from main\n' > "$C16/vendor/mngr/generated.py"
printf 'acc = 99  # from main\n' > "$C16/vendor/mngr/café.py"
_gitq "$C16" add -A; _gitq "$C16" commit -q -m "advance main"; _gitq "$C16" push -q origin main
# The local dev loop has rewritten the exempt subtree (tracked + untracked).
printf 'lib = 2  # local rsync\n' > "$R16/vendor/mngr/lib.py"
echo generated > "$R16/vendor/mngr/generated.py"
# ...including a non-ASCII name. `git ls-files` / `git diff --name-only` C-quote
# such a path ("vendor/mngr/caf\303\251.py") while the merge refusal prints it
# raw, so both sides must be read in the same form or this file alone drags the
# whole block into the generic merge-conflict report.
printf 'acc = 2  # local rsync\n' > "$R16/vendor/mngr/café.py"
E16="$WORK/s16.err"; rc=$(run_hook "$R16" "$E16")
assert_exit 2 "$rc" "blocks rather than merging over the generated state"
assert_has "$E16" "Merge blocked by uncommitted changes under an exempt path" "reports the exempt-path cause"
assert_has "$E16" "vendor/mngr/lib.py" "names the blocking file"
assert_has "$E16" "vendor/mngr/café.py" "names the non-ASCII blocking file, unquoted"
assert_not "$E16" "Merge conflict detected" "not reported as a merge conflict"
# The whole point: the live working state survives for the repo to regenerate.
assert_has "$R16/vendor/mngr/lib.py" "local rsync" "the local copy is left untouched"
if [[ -e "$R16/vendor/mngr/generated.py" ]]; then
    _ok "untracked exempt file left in place"
else
    _bad "untracked exempt file left in place"
fi
# Restoring only the tracked file leaves the generated UNTRACKED file colliding
# with a file main now adds -- git's other refusal, which must classify the same
# way. This is the likelier real case: a dev loop generates files that a later
# base-branch sync then commits.
_gitq "$R16" checkout -q HEAD -- vendor/mngr
E16b="$WORK/s16b.err"; rc=$(run_hook "$R16" "$E16b")
assert_exit 2 "$rc" "an untracked exempt collision blocks too"
assert_has "$E16b" "Merge blocked by uncommitted changes under an exempt path" "untracked collision gets the same cause"
assert_has "$E16b" "vendor/mngr/generated.py" "names the untracked blocking file"
# Once the generated state is dropped (what the message asks for), the merge lands.
rm -f "$R16/vendor/mngr/generated.py"
rc=$(run_hook "$R16" "$WORK/s16c.err")
assert_exit 0 "$rc" "merge lands after the generated state is dropped"
assert_has "$R16/vendor/mngr/lib.py" "from main" "base-branch change to the exempt subtree landed"

# ===========================================================================
# The exempt-path message is a claim about a specific cause, not a catch-all for
# every refused merge: dirt outside the list must still get the generic report.
echo "Scenario 17: merge blocked by non-exempt dirt -> the generic conflict error"
R17="$WORK/s17/root"; make_repo "$R17"
mkdir -p "$R17/vendor/mngr"
printf 'lib = 1\n' > "$R17/vendor/mngr/lib.py"
write_root_settings "$R17" '[]'
jq '.stop_hook.uncommitted_exempt_paths = ["vendor/mngr"] | .stop_hook.fetch_and_merge = true | .stop_hook.require_committed = false' \
    "$R17/.reviewer/settings.json" > "$R17/.reviewer/settings.json.tmp" \
    && mv "$R17/.reviewer/settings.json.tmp" "$R17/.reviewer/settings.json"
write_gitignore "$R17"; commit_push "$R17"
C17="$WORK/s17/clone"; git clone -q "$(_gitq "$R17" remote get-url origin)" "$C17"
printf 'x = 3  # from main\n' > "$C17/code.py"
_gitq "$C17" add -A; _gitq "$C17" commit -q -m "advance main"; _gitq "$C17" push -q origin main
# Dirty a NON-exempt file the incoming merge also touches, alongside exempt dirt
# -- the exempt dirt must not be enough to claim the merge was blocked by it.
printf 'x = 2  # local edit\n' > "$R17/code.py"
printf 'lib = 2  # local rsync\n' > "$R17/vendor/mngr/lib.py"
E17="$WORK/s17.err"; rc=$(run_hook "$R17" "$E17")
assert_exit 2 "$rc" "blocks on non-exempt dirt"
assert_has "$E17" "Merge conflict detected" "reports the merge failure generically"
assert_not "$E17" "Merge blocked by uncommitted changes under an exempt path" "does not misattribute it to the exempt path"
assert_has "$R17/code.py" "local edit" "the non-exempt local edit is left untouched"

# ===========================================================================
# Git only refuses the merge when the incoming change actually touches the dirty
# paths. When it doesn't, exempt-path dirt is a non-event and must not block --
# nor be disturbed.
echo "Scenario 18: exempt-path dirt the merge does not touch -> merge proceeds"
R18="$WORK/s18/root"; make_repo "$R18"
mkdir -p "$R18/vendor/mngr"
printf 'lib = 1\n' > "$R18/vendor/mngr/lib.py"
write_root_settings "$R18" '[]'
jq '.stop_hook.uncommitted_exempt_paths = ["vendor/mngr"] | .stop_hook.fetch_and_merge = true' \
    "$R18/.reviewer/settings.json" > "$R18/.reviewer/settings.json.tmp" \
    && mv "$R18/.reviewer/settings.json.tmp" "$R18/.reviewer/settings.json"
write_gitignore "$R18"; commit_push "$R18"
# origin/main advances, touching only ordinary code.
C18="$WORK/s18/clone"; git clone -q "$(_gitq "$R18" remote get-url origin)" "$C18"
printf 'x = 3  # from main\n' > "$C18/code.py"
_gitq "$C18" add -A; _gitq "$C18" commit -q -m "advance main"; _gitq "$C18" push -q origin main
printf 'lib = 2  # local rsync\n' > "$R18/vendor/mngr/lib.py"
echo generated > "$R18/vendor/mngr/generated.py"
E18="$WORK/s18.err"; rc=$(run_hook "$R18" "$E18")
assert_exit 0 "$rc" "merge proceeds with untouched exempt-path dirt"
assert_has "$R18/code.py" "from main" "base-branch change landed"
assert_has "$R18/vendor/mngr/lib.py" "local rsync" "the local copy is left untouched"

# ===========================================================================
# The real exempt subtree is a vendored monorepo -- thousands of files -- so a
# base-branch revendor blocks on far more paths than git's refusal message can
# hold: git formats that message into a fixed 4096-byte buffer and cuts it off
# mid-line, leaving a path fragment as the final entry. Classification must not
# be read out of that message, or the motivating case reports as a merge
# conflict while the small ones (scenario 16) look fine.
echo "Scenario 19: an exempt subtree too large for git's message still classifies"
R19="$WORK/s19/root"; make_repo "$R19"
mkdir -p "$R19/vendor/mngr"
for i in $(seq 1 400); do printf 'v = 1\n' > "$R19/vendor/mngr/f$i.py"; done
write_root_settings "$R19" '[]'
jq '.stop_hook.uncommitted_exempt_paths = ["vendor/mngr"] | .stop_hook.fetch_and_merge = true' \
    "$R19/.reviewer/settings.json" > "$R19/.reviewer/settings.json.tmp" \
    && mv "$R19/.reviewer/settings.json.tmp" "$R19/.reviewer/settings.json"
write_gitignore "$R19"; commit_push "$R19"
# origin/main revendors the whole subtree...
C19="$WORK/s19/clone"; git clone -q "$(_gitq "$R19" remote get-url origin)" "$C19"
for i in $(seq 1 400); do printf 'v = 99  # from main\n' > "$C19/vendor/mngr/f$i.py"; done
_gitq "$C19" add -A; _gitq "$C19" commit -q -m "revendor"; _gitq "$C19" push -q origin main
# ...while the dev loop has rewritten every one of them locally.
for i in $(seq 1 400); do printf 'v = 2  # local rsync\n' > "$R19/vendor/mngr/f$i.py"; done
E19="$WORK/s19.err"; rc=$(run_hook "$R19" "$E19")
assert_exit 2 "$rc" "blocks on a subtree larger than git's message buffer"
assert_has "$E19" "Merge blocked by uncommitted changes under an exempt path" "reports the exempt-path cause"
assert_not "$E19" "Merge conflict detected" "not reported as a merge conflict"
assert_has "$E19" "(400 path(s))" "counts every blocked path, not just the listed sample"
assert_has "$R19/vendor/mngr/f400.py" "local rsync" "the local copy is left untouched"
# The whole per-dir stderr is relayed to the agent verbatim, so the listing is a
# capped sample rather than the entire subtree.
if [[ $(grep -c '^\[' "$E19") -lt 40 ]]; then
    _ok "the blocked listing is capped, not one line per path"
else
    _bad "the blocked listing is capped, not one line per path ($(grep -c '^\[' "$E19") lines)"
fi

# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
