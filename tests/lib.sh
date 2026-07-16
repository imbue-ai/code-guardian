#!/usr/bin/env bash
#
# lib.sh
#
# Assertions and scratch-repo helpers for the stop hook tests. Source this,
# then call the assert_* helpers; the runner reports whatever they record.
#
# Tests must be hermetic: no network, no dependence on the developer's git
# config, and no CODE_GUARDIAN_* leaking in from the surrounding session.

SCRIPTS_DIR="${SCRIPTS_DIR:?SCRIPTS_DIR must be set by the runner}"

TESTS_RUN=0
TESTS_FAILED=0
_CURRENT_TEST=""

# CODE_GUARDIAN_* outrank every config file, and the mngr integration exports
# them into each session -- so without this, tests read the developer's
# settings instead of their own.
for _v in $(env | sed -n 's/^\(CODE_GUARDIAN_[A-Z_]*\)=.*/\1/p'); do
    unset "$_v"
done

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $_CURRENT_TEST"
    echo "    $1"
    [[ -n "${2:-}" ]] && echo "    expected: $2"
    [[ -n "${3:-}" ]] && echo "    actual:   $3"
    return 0
}

it() {
    _CURRENT_TEST="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
}

# assert_eq <actual> <expected> [message] -- every caller passes the value
# under test first, so _fail's slots are filled in the opposite order.
assert_eq() {
    [[ "$1" == "$2" ]] || _fail "${3:-values differ}" "$2" "$1"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || _fail "${3:-substring missing}" "*$2*" "$1"
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] || _fail "${3:-substring should be absent}" "no *$2*" "$1"
}

assert_file_exists() {
    [[ -f "$1" ]] || _fail "${2:-missing file: $1}"
}

assert_file_absent() {
    [[ ! -f "$1" ]] || _fail "${2:-file should not exist: $1}"
}

# ---------------------------------------------------------------------------
# Scratch repos
# ---------------------------------------------------------------------------

# Guard for every helper that writes, commits, or runs a hook. A helper that
# fails to cd would otherwise operate on the developer's own checkout, and
# `git add -A` there is unrecoverable-looking at best. The marker lives in
# .git/ because git never tracks anything inside it.
_assert_scratch() {
    if [[ ! -f "$PWD/.git/.cg-scratch" || "$PWD" != /tmp/* ]]; then
        echo "REFUSING: not inside a scratch repo (pwd=$PWD)" >&2
        exit 99
    fi
}

# Create a throwaway git repo, cd into it, and set REPO_DIR.
# Call it directly -- REPO=$(make_repo) cds in a subshell and leaves the
# caller sitting in the real repo.
#
# core.excludesFile is neutralized because a developer with a global .reviewer/
# rule would otherwise mask the behavior the gitignore tests exist to check.
REPO_DIR=""
make_repo() {
    REPO_DIR=$(mktemp -d -t cg-test-XXXXXX)
    cd "$REPO_DIR" || { echo "cannot cd to $REPO_DIR" >&2; exit 99; }
    git init -q -b "${1:-main}" .
    touch .git/.cg-scratch
    git config user.email test@example.com
    git config user.name "Test"
    git config commit.gpgsign false
    git config core.excludesFile /dev/null
    _assert_scratch
}

cleanup_repo() {
    local dir="${1:-$REPO_DIR}"
    cd / || true
    if [[ -n "$dir" && "$dir" == /tmp/* && -f "$dir/.git/.cg-scratch" ]]; then
        rm -rf "$dir"
    fi
    REPO_DIR=""
}

# write_settings <<'EOF' ... EOF  -- writes .reviewer/settings.json from stdin
write_settings() {
    _assert_scratch
    mkdir -p .reviewer
    cat > .reviewer/settings.json
}

commit_all() {
    _assert_scratch
    git add -A
    git commit -q -m "${1:-commit}" --allow-empty
}

# Put a fake executable early on PATH, so tests never reach the real gh/git.
# Usage: stub_command gh 'echo "[]"; exit 0'
stub_command() {
    _assert_scratch
    local name="$1" body="$2"
    mkdir -p "$PWD/.stubs"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$PWD/.stubs/$name"
    chmod +x "$PWD/.stubs/$name"
    export PATH="$PWD/.stubs:$PATH"
}

# Run a hook script. Sets RUN_OUT (combined output) and RUN_EXIT.
# Call it directly -- $(run_script ...) would trap both in a subshell.
RUN_OUT=""
RUN_EXIT=0
run_script() {
    _assert_scratch
    local script="$1"; shift
    RUN_OUT=$(bash "$SCRIPTS_DIR/$script" "$@" 2>&1 </dev/null)
    RUN_EXIT=$?
}

report() {
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo "  $TESTS_RUN run, $TESTS_FAILED failed"
        exit 1
    fi
    echo "  $TESTS_RUN run, all passed"
    exit 0
}
