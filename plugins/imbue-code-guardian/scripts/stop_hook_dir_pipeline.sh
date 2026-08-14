#!/usr/bin/env bash
#
# stop_hook_dir_pipeline.sh
#
# Runs the NON-REVIEW pipeline steps for a single git working directory:
#
#   3. Uncommitted changes enforcement
#   4. Fetch and merge base branch (+ push, + per-commit marker carry-forward)
#   5. Docs-only / empty-diff detection (decides whether this dir needs review)
#   6. Push + ensure PR exists (so CI starts early)
#
# Review gates (autofix / architecture / conversation) are NOT run here -- those
# are unified across all dirs by the orchestrator (stop_hook_gates.sh). CI
# polling is launched separately by the orchestrator once review gates pass.
#
# All git operations are scoped to $DIR via `git -C`, and all config/markers are
# resolved relative to $DIR (each reviewed repo is self-contained).
#
# Usage:
#   ./stop_hook_dir_pipeline.sh <dir> <result_file>
#
# Communicates back to the orchestrator by writing KEY=VALUE lines to
# <result_file>:
#   HEAD=<sha>            settled HEAD after any base-branch merge
#   BRANCH=<name>         current branch
#   HAS_CHANGES=true|false whether this dir has non-doc code changes vs base
#   PR_NUMBER=<n>         PR number if one exists (empty otherwise)
#   POLL_CI=true|false    whether the orchestrator should poll CI for this dir
#
# Exit codes:
#   0 -- non-review steps satisfied for this dir
#   2 -- a non-review step blocks (uncommitted / merge conflict / push / no PR);
#        a human-readable reason is written to stderr (captured per-dir by the
#        orchestrator and relayed in the aggregated report).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIR="${1:?usage: stop_hook_dir_pipeline.sh <dir> <result_file>}"
RESULT_FILE="${2:?usage: stop_hook_dir_pipeline.sh <dir> <result_file>}"

# Config + markers for this dir live inside the dir itself.
REVIEWER_SETTINGS="$DIR/.reviewer/settings.json"

export STOP_HOOK_SCRIPT_NAME="dir_pipeline"
# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"
# Per-dir log: each reviewed repo keeps its own pipeline history, as though the
# hook had run there standalone.
STOP_HOOK_LOG=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.log_file" ".reviewer/logs/stop_hook.jsonl")
# Anchor a relative log path inside the dir.
case "$STOP_HOOK_LOG" in
    /*) : ;;
    *) STOP_HOOK_LOG="$DIR/$STOP_HOOK_LOG" ;;
esac
export STOP_HOOK_LOG
# shellcheck source=stop_hook_common.sh
source "$SCRIPT_DIR/stop_hook_common.sh"

# Helper: git scoped to this dir.
_git() { git -C "$DIR" "$@"; }

_log_to_file "INFO" "dir pipeline started (dir=$DIR, pid=$$)"

# Defaults written to the result file; overwritten as we learn more.
HEAD=$(_git rev-parse HEAD 2>/dev/null || echo "unknown")
BRANCH=$(_git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
PR_NUMBER=""
POLL_CI=false

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap
_write_result() {
    {
        echo "HEAD=$HEAD"
        echo "BRANCH=$BRANCH"
        echo "HAS_CHANGES=${HAS_CHANGES:-false}"
        echo "PR_NUMBER=$PR_NUMBER"
        echo "POLL_CI=$POLL_CI"
    } > "$RESULT_FILE"
}
# Always emit a result file, even on early exit, so the orchestrator can parse it.
trap '_write_result' EXIT

# Prefix stderr messages with the dir so the aggregated report is unambiguous.
_dir_err() { echo "[$DIR] $*" >&2; }

# =========================================================================
# Step 2b: Pinned (detached-HEAD) checkouts are left alone entirely
# =========================================================================
# A detached HEAD means the checkout is deliberately pinned to a tag or exact
# SHA (e.g. a release checkout parked for side-by-side testing) rather than
# being worked on: there is no branch to merge the base into, nothing to push
# (a bare `push -u <remote> HEAD` from a detached HEAD resolves to the refspec
# `HEAD:refs/heads/HEAD` and mints a literal branch named HEAD on the remote),
# and no branch to open a PR from. Worse, merging the base branch into a clean
# detached checkout of an ancestor commit silently FAST-FORWARDS it -- moving
# the pinned files out from under whatever is using them, which is exactly
# what a pin exists to prevent. Skip the whole pipeline for such a dir.
if [[ "$BRANCH" == "HEAD" ]]; then
    HAS_CHANGES=false
    _log_to_file "INFO" "$DIR has a detached HEAD (pinned checkout) -- skipping merge/push/review pipeline"
    _dir_err "NOTE: '$DIR' has a detached HEAD (pinned checkout); the stop hook is leaving it untouched."
    exit 0
fi

# =========================================================================
# Step 3: Uncommitted changes enforcement
# =========================================================================
REQUIRE_COMMITTED=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.require_committed" "true")

# Paths whose uncommitted changes are expected machine-generated state
# (e.g. a vendored subtree a dev loop rsyncs into the working tree).
# Excluded from the clean-tree check below; committed changes under these
# paths are still diffed, reviewed, and pushed like any others. Read outside
# that check because step 4 needs them too: git refuses to merge over a dirty
# working tree whatever this check was told to ignore, so step 4 tells apart a
# merge that was blocked purely by this generated state from a real conflict.
EXEMPT_PATHS=()
EXEMPT_PATHSPECS=()
while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    EXEMPT_PATHS+=("$_p")
    EXEMPT_PATHSPECS+=(":(exclude)$_p")
done < <(read_json_array "$REVIEWER_SETTINGS" "stop_hook.uncommitted_exempt_paths")

if [[ "$REQUIRE_COMMITTED" == "true" ]]; then
    untracked=$(_git ls-files --others --exclude-standard -- ${EXEMPT_PATHSPECS[@]+"${EXEMPT_PATHSPECS[@]}"})
    staged=$(_git diff --cached --name-only -- ${EXEMPT_PATHSPECS[@]+"${EXEMPT_PATHSPECS[@]}"})
    unstaged=$(_git diff --name-only -- ${EXEMPT_PATHSPECS[@]+"${EXEMPT_PATHSPECS[@]}"})

    if [[ -n "$untracked" ]] || [[ -n "$staged" ]] || [[ -n "$unstaged" ]]; then
        _dir_err "ERROR: Uncommitted changes detected. All changes must be committed before this hook can run."
        _dir_err "ERROR: Please commit or gitignore all files before stopping."
        if [[ -n "$untracked" ]]; then
            _dir_err ""
            _dir_err "Untracked files (need to git add or add to .gitignore):"
            while IFS= read -r _f; do _dir_err "  $_f"; done <<< "$untracked"
        fi
        if [[ -n "$unstaged" ]]; then
            _dir_err ""
            _dir_err "Unstaged changes (need to git add):"
            while IFS= read -r _f; do _dir_err "  $_f"; done <<< "$unstaged"
        fi
        if [[ -n "$staged" ]]; then
            _dir_err ""
            _dir_err "Staged but not committed (need to git commit):"
            while IFS= read -r _f; do _dir_err "  $_f"; done <<< "$staged"
        fi
        _dir_err ""
        _dir_err "All files must be either gitignored or committed before stopping."
        _dir_err "If you're not ready to commit yet because the task is not yet complete (ex: tests do not pass or you have a question for the user), simply prefix your commit message with WIP:"
        _log_to_file "ERROR" "Uncommitted changes detected in $DIR, exiting with 2"
        exit 2
    fi
fi

# =========================================================================
# Step 4: Fetch and merge base branch
# =========================================================================
# The base-branch env override (CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH) is
# per-agent config for the agent's OWN repo -- e.g. mngr exports the agent's
# base branch for every agent it creates. A secondary dir's base branch is its
# own settings' concern (each reviewed repo is self-contained), so blank the
# override for non-root dirs; read_json_config treats an empty env var as
# unset and falls through to the dir's settings(.local).json.
if [[ "$DIR" == "." ]]; then
    BASE_BRANCH=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.base_branch" "main")
else
    BASE_BRANCH=$(CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH="" read_json_config "$REVIEWER_SETTINGS" "stop_hook.base_branch" "main")
fi
REMOTE=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.remote" "origin")
FETCH_AND_MERGE=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.fetch_and_merge" "true")

# Every path git names in a "would be overwritten by merge" refusal is, by
# definition, dirty in the working tree -- so the exempt ones are exactly the
# dirty paths matching the exempt pathspecs. Asking git to do the matching
# keeps real pathspec semantics (globs, negation) rather than reimplementing
# them with string prefixes.
_exempt_dirty_files() {
    # No exempt paths configured: bare `--` would match everything. (Indexed
    # rather than ${#...[@]}, which trips `set -u` on an empty array in bash 3.2.)
    [[ -n "${EXEMPT_PATHS[0]:-}" ]] || return 0
    # core.quotePath=false: these two commands honor it and would otherwise
    # C-quote any path with a non-ASCII byte ("vendor/mngr/caf\303\251.py"),
    # while the merge refusal prints the same path raw -- so the caller's
    # comparison would never match it and would misreport an exempt-path block
    # as a merge conflict.
    {
        _git -c core.quotePath=false ls-files --modified --others --exclude-standard -- "${EXEMPT_PATHS[@]}"
        _git -c core.quotePath=false diff --cached --name-only -- "${EXEMPT_PATHS[@]}"
    } | sort -u
}

# Merge one base-branch ref, distinguishing the two ways it can fail.
#
# Git refuses to merge over paths whose working-tree state the merge would
# overwrite, no matter what the clean-tree check above was told to ignore --
# and the base branch is the very place machine-generated state gets updated,
# so exempt paths collide as a matter of course. That refusal is not a merge
# conflict and the generic "resolve the conflicts" advice does not fit it: the
# fix is to drop the generated state, merge, and regenerate. Only the repo
# knows how to regenerate, so say what is blocking and stop -- discarding it
# here would silently strip a dev loop's working state (and, since a passing
# dir's stderr is never relayed, do so invisibly).
_merge_ref() { # <ref>
    local ref="$1" out blocked non_exempt f
    out=$(mktemp)
    if _git merge "$ref" --no-edit >"$out" 2>&1; then
        rm -f "$out"
        return 0
    fi
    # Git lists the paths it refused to overwrite, one per line, tab-indented.
    # The tab is written literally ($'...'): BSD sed does not expand \t.
    blocked=""
    if grep -q "would be overwritten by merge" "$out"; then
        blocked=$(sed -n $'s/^\t//p' "$out")
    fi
    if [[ -n "$blocked" ]]; then
        # Any blocked path that is not also an exempt dirty path. A revendor of
        # a large subtree blocks on thousands of paths, so match the whole list
        # in one pass rather than forking a grep per line. `|| true`: grep exits
        # 1 when nothing matches, which set -e would turn into an exit. With no
        # exempt paths the pattern file is empty, grep -F matches nothing, and
        # -v yields every blocked path -- i.e. not an exempt-path block.
        non_exempt=$(grep -vxFf <(_exempt_dirty_files) <<< "$blocked" || true)
        if [[ -z "$non_exempt" ]]; then
            # Git's own advice here ("commit your changes or stash them") is the
            # wrong fix for generated state, so it is not relayed.
            rm -f "$out"
            _dir_err "ERROR: Merge blocked by uncommitted changes under an exempt path while merging $ref."
            _dir_err "ERROR: These paths are declared machine-generated (stop_hook.uncommitted_exempt_paths),"
            _dir_err "ERROR: so this hook will not discard them for you -- it cannot know how to regenerate them."
            _dir_err ""
            _dir_err "Blocking the merge:"
            while IFS= read -r f; do _dir_err "  $f"; done <<< "$blocked"
            _dir_err ""
            _dir_err "Discard the generated state under those paths, re-run the merge, then regenerate it."
            # Don't claim the instructions live in $DIR: what generates a vendored
            # subtree is typically the *other* checkout it was copied from, so its
            # regeneration command lives there, not in the dir whose merge broke.
            _dir_err "Check your project instructions for the regeneration command -- it may belong to the checkout this state is generated from, not to $DIR."
            _log_to_file "ERROR" "Merge of $ref blocked by exempt-path dirt in $DIR, exiting with 2"
            exit 2
        fi
    fi
    cat "$out" >&2
    rm -f "$out"
    _dir_err "ERROR: Merge conflict detected while merging $ref."
    _dir_err "ERROR: Please resolve the merge conflicts before continuing."
    exit 2
}

if [[ "$FETCH_AND_MERGE" == "true" ]]; then
    _log_to_file "INFO" "Fetching all remotes in $DIR (base_branch=$BASE_BRANCH, remote=$REMOTE)"
    _git fetch --all

    # Push base branch if it doesn't exist on the remote yet
    if ! _git rev-parse --verify "$REMOTE/$BASE_BRANCH" >/dev/null 2>&1; then
        if ! retry_command 3 git -C "$DIR" push "$REMOTE" "$BASE_BRANCH"; then
            _dir_err "ERROR: Failed to push base branch after retries."
            exit 2
        fi
    fi

    # Merge remote base branch
    if _git rev-parse --verify "$REMOTE/$BASE_BRANCH" >/dev/null 2>&1; then
        _merge_ref "$REMOTE/$BASE_BRANCH"
    fi

    # Merge local base branch
    if _git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
        _merge_ref "$BASE_BRANCH"
    fi

    # Push merge commits (if any), setting upstream tracking. Push the branch
    # by name, never the bare HEAD refspec: from a detached HEAD (excluded in
    # Step 2b, but kept structurally impossible here too) `push HEAD` would
    # mint a remote branch literally named HEAD.
    if ! retry_command 3 git -C "$DIR" push -u "$REMOTE" "$BRANCH"; then
        _dir_err "ERROR: Failed to push after retries. Perhaps you forgot to commit something? Or pre-commit hooks changed something?"
        exit 2
    fi

    # Update HEAD after merge (may have changed). Carry the per-commit gate
    # markers forward to the new commit so the gates don't re-fire purely
    # because of a clean base-branch merge -- the branch's own contribution
    # (git diff base...HEAD) is unchanged, which is all these gates review.
    NEW_HEAD=$(_git rev-parse HEAD 2>/dev/null || echo "unknown")
    if [[ "$NEW_HEAD" != "$HEAD" ]]; then
        # Autofix marker is per-commit for every dir. The conversation marker is
        # per-commit but only tracked at the root repo (conversation review is a
        # single, session-scoped gate), so carry it only there.
        _carry=("autofix/${HEAD}_verified.md")
        if [[ "$DIR" == "." ]]; then
            _carry+=("conversation/${HEAD}.json")
        fi
        for _f in "${_carry[@]}"; do
            _src="$DIR/.reviewer/outputs/${_f}"
            if [[ -f "$_src" ]]; then
                cp "$_src" "${_src/${HEAD}/${NEW_HEAD}}" 2>/dev/null || true
            fi
        done
    fi
    HEAD="$NEW_HEAD"
fi

# =========================================================================
# Step 5: Docs-only / empty-diff detection -- decides review participation
# =========================================================================
SKIP_INFORMATIONAL=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.skip_informational" "true")
HAS_CHANGES=true

if [[ "$SKIP_INFORMATIONAL" == "true" ]]; then
    if [[ "$BRANCH" == "$BASE_BRANCH" ]]; then
        _log_to_file "INFO" "$DIR on base branch ($BASE_BRANCH) -- no review needed"
        HAS_CHANGES=false
    else
        # A diff with no files, or only .md files, both leave NON_MD_FILES empty.
        CHANGED_FILES=$(_git diff --name-only "$REMOTE/$BASE_BRANCH"...HEAD 2>/dev/null || echo "")
        NON_MD_FILES=$(echo "$CHANGED_FILES" | grep -v '\.md$' || true)
        if [[ -z "$NON_MD_FILES" ]]; then
            _log_to_file "INFO" "$DIR diff vs $BASE_BRANCH is empty or docs-only -- skipping review/PR"
            HAS_CHANGES=false
        fi
    fi
fi

if [[ "$HAS_CHANGES" != "true" ]]; then
    # Nothing to review or PR for this dir; it passes cleanly.
    _log_to_file "INFO" "$DIR has no reviewable changes, exiting 0"
    exit 0
fi

# =========================================================================
# Step 6: Ensure PR exists (so CI can start early)
# =========================================================================
CI_ENABLED=$(read_json_config "$REVIEWER_SETTINGS" "ci.is_enabled" "true")

if [[ "$CI_ENABLED" == "true" ]]; then
    if "$SCRIPT_DIR/stop_hook_pr_and_ci.sh" ensure-pr "$DIR"; then
        PR_NUMBER=$(cat "$DIR/.reviewer/outputs/pr_number" 2>/dev/null || echo "")
        if [[ -n "$PR_NUMBER" ]]; then
            POLL_CI=true
        fi
        _log_to_file "INFO" "$DIR PR check passed (pr_number=$PR_NUMBER, poll_ci=$POLL_CI)"
    else
        _log_to_file "INFO" "$DIR PR check failed"
        exit 2
    fi
fi

exit 0
