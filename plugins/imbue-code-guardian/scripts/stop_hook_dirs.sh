#!/usr/bin/env bash
#
# stop_hook_dirs.sh
#
# Resolves the set of git working directories the stop hook reviews:
# always the root repo ("."), plus any validated entries from
# stop_hook.additional_git_directories in the ROOT .reviewer/settings.json.
#
# Each additional dir is a self-contained repo (its own .git, remote, base
# branch, and .reviewer/ config). A misconfigured entry hard-errors (exit 2)
# so a listed dir can never silently go unreviewed.
#
# Requires config_utils.sh and stop_hook_common.sh to be sourced first
# (for read_json_array and log_error).
#
# Usage:
#   resolve_review_dirs "<root_settings_path>"   # populates REVIEW_DIRS array

# shellcheck disable=SC2034  # REVIEW_DIRS is consumed by the sourcing script
resolve_review_dirs() {
    local root_settings="$1"
    REVIEW_DIRS=(".")

    local root_gitdir
    root_gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null || echo "")

    local dir this_gitdir
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        # Root is always reviewed implicitly; ignore an explicit "." entry.
        [ "$dir" == "." ] && continue

        if [[ ! -d "$dir" ]]; then
            log_error "additional_git_directories: '$dir' does not exist."
            exit 2
        fi
        if ! this_gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null); then
            log_error "additional_git_directories: '$dir' is not a git repository."
            exit 2
        fi
        if [[ -n "$root_gitdir" && "$this_gitdir" == "$root_gitdir" ]]; then
            log_error "additional_git_directories: '$dir' resolves to the root repository, not a distinct repo."
            exit 2
        fi
        if [[ ! -f "$dir/.reviewer/settings.json" ]]; then
            log_error "additional_git_directories: '$dir' has no .reviewer/settings.json (each reviewed repo must be self-contained)."
            exit 2
        fi

        REVIEW_DIRS+=("$dir")
    done < <(read_json_array "$root_settings" "stop_hook.additional_git_directories")
}
