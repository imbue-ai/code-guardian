#!/usr/bin/env bash
#
# Shared helpers in stop_hook_common.sh: the .reviewer gitignore, retries,
# JSON escaping, and logging.
#
# The failure the gitignore covers: the uncommitted-changes gate blocks on any
# untracked file, and the hook's own logs and outputs are untracked -- so
# without the ignore rules the hook blocks on artifacts it wrote itself.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMON="$SCRIPTS_DIR/stop_hook_common.sh"

# Run a snippet with the target sourced. Sets SNIP_OUT, SNIP_ERR, SNIP_EXIT.
#
# The target sets `set -e` and defines RED/GREEN/STOP_HOOK_* at source time, so
# it goes into a child shell instead of the harness. `set +e` after sourcing
# keeps a snippet's expected failure from killing the child.
SNIP_OUT=""
SNIP_ERR=""
SNIP_EXIT=0
run_common() {
    local err_file
    err_file=$(mktemp -t cg-err-XXXXXX)
    SNIP_OUT=$(bash -c 'source "$1"; set +e; eval "$2"' _ "$COMMON" "$1" 2>"$err_file")
    SNIP_EXIT=$?
    SNIP_ERR=$(cat "$err_file")
    rm -f "$err_file"
}

assert_valid_json() {
    local ok=yes
    printf '%s' "$1" | jq -e . >/dev/null 2>&1 || ok=no
    assert_eq "$ok" "yes" "${2:-should parse as JSON}: $1"
}

assert_matches() {
    local matched=no
    [[ "$1" =~ $2 ]] && matched=yes
    assert_eq "$matched" "yes" "${3:-should match /$2/}: $1"
}

# ---------------------------------------------------------------------------
# ensure_reviewer_gitignore
# ---------------------------------------------------------------------------
it "writes the ignore rules, creating the directory"
make_repo
run_common 'ensure_reviewer_gitignore'
assert_file_exists ".reviewer/.gitignore"
rules=$(cat .reviewer/.gitignore)
assert_contains "$rules" "logs/"
assert_contains "$rules" "outputs/"
assert_contains "$rules" "settings.local.json"
assert_contains "$rules" ".gitignore"
cleanup_repo

it "leaves an existing .gitignore alone"
make_repo
mkdir -p .reviewer
echo "hand-written" > .reviewer/.gitignore
run_common 'ensure_reviewer_gitignore'
assert_eq "$(cat .reviewer/.gitignore)" "hand-written" "existing rules must survive"
cleanup_repo

it "honors a custom directory argument"
make_repo
run_common 'ensure_reviewer_gitignore custom-reviewer'
assert_file_exists "custom-reviewer/.gitignore"
assert_file_absent ".reviewer/.gitignore"
assert_contains "$(cat custom-reviewer/.gitignore)" "outputs/"
cleanup_repo

# The point of the whole function: git must not see the hook's own artifacts.
it "hides the hook's own logs and outputs from git"
make_repo
run_common 'ensure_reviewer_gitignore'
mkdir -p .reviewer/logs .reviewer/outputs
echo '{"level":"INFO"}' > .reviewer/logs/x.jsonl
echo "3" > .reviewer/outputs/stop_hook_consecutive_blocks
# -uall: plain --porcelain collapses to a bare "?? .reviewer/", which would
# make these assertions pass whether the rules exist or not.
status=$(git status --porcelain -uall)
assert_not_contains "$status" ".reviewer/logs"
assert_not_contains "$status" ".reviewer/outputs"
untracked=$(git ls-files --others --exclude-standard)
assert_not_contains "$untracked" ".reviewer/logs"
assert_not_contains "$untracked" ".reviewer/outputs"

it "hides the generated .gitignore itself"
assert_not_contains "$untracked" ".reviewer/.gitignore"

it "keeps settings.json trackable"
echo '{}' > .reviewer/settings.json
untracked=$(git ls-files --others --exclude-standard)
assert_contains "$untracked" ".reviewer/settings.json"
cleanup_repo

# ---------------------------------------------------------------------------
# retry_command
# ---------------------------------------------------------------------------

# A command that fails until its invocation count reaches SUCCEED_AT, counting
# every attempt in ./count.
_make_flaky() {
    _assert_scratch
    cat > flaky.sh <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat count) + 1 ))
printf '%s' "$n" > count
[[ $n -ge ${SUCCEED_AT:-1} ]]
EOF
    chmod +x flaky.sh
    printf '0' > count
}

it "runs the command once when it succeeds"
make_repo
_make_flaky
run_common 'export SUCCEED_AT=1; retry_command 3 ./flaky.sh'
assert_eq "$SNIP_EXIT" "0" "a first-try success should return 0"
assert_eq "$(cat count)" "1" "a success must not be retried"
cleanup_repo

it "retries until the command succeeds"
make_repo
_make_flaky
run_common 'export SUCCEED_AT=2; retry_command 3 ./flaky.sh'
assert_eq "$SNIP_EXIT" "0" "a later success should still return 0"
assert_eq "$(cat count)" "2" "should stop retrying once it succeeds"
assert_contains "$SNIP_ERR" "attempt 1/3"
cleanup_repo

it "gives up after max_retries attempts"
make_repo
_make_flaky
run_common 'export SUCCEED_AT=99; retry_command 3 ./flaky.sh'
assert_eq "$SNIP_EXIT" "1" "exhausted retries should return non-zero"
assert_eq "$(cat count)" "3" "should attempt exactly max_retries times"
assert_contains "$SNIP_ERR" "Command failed after 3 attempts"
cleanup_repo

# ---------------------------------------------------------------------------
# _json_escape
# ---------------------------------------------------------------------------

# Escape the input, embed it in an object, and read the original back out.
assert_escape_roundtrip() {
    local input="$1" label="$2"
    export INPUT="$input"
    run_common 'printf "{\"m\":\"%s\"}" "$(_json_escape "$INPUT")"'
    unset INPUT
    assert_valid_json "$SNIP_OUT" "escaped $label must embed as JSON"
    assert_eq "$(printf '%s' "$SNIP_OUT" | jq -r '.m')" "$input" "$label should round-trip"
}

make_repo

it "escapes double quotes"
assert_escape_roundtrip 'he said "hi"' "quotes"

it "escapes backslashes"
assert_escape_roundtrip 'C:\path\to\thing' "backslashes"

it "does not double-escape a literal backslash-n"
assert_escape_roundtrip 'literal \n here' "literal escape"

it "escapes newlines"
assert_escape_roundtrip $'first\nsecond' "newlines"

it "escapes tabs"
assert_escape_roundtrip $'col1\tcol2' "tabs"

it "escapes carriage returns"
assert_escape_roundtrip $'before\rafter' "carriage returns"

it "escapes all of them at once"
assert_escape_roundtrip $'a "q" b\\c\nd\te\rf' "the lot"

cleanup_repo

# ---------------------------------------------------------------------------
# _log_to_file
# ---------------------------------------------------------------------------
it "writes one valid JSON object per line"
make_repo
export STOP_HOOK_LOG="$PWD/.reviewer/logs/hook.jsonl"
export STOP_HOOK_SCRIPT_NAME="test_script"
run_common '_log_to_file "INFO" "first"; _log_to_file "ERROR" "second"'
assert_file_exists ".reviewer/logs/hook.jsonl"
lines=0
bad=0
while IFS= read -r line; do
    lines=$((lines + 1))
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad=$((bad + 1))
done < .reviewer/logs/hook.jsonl
assert_eq "$lines" "2" "one line per call"
assert_eq "$bad" "0" "every line must be valid JSON"

it "records the level, message, and source"
assert_eq "$(jq -r 'select(.level == "ERROR") | .message' .reviewer/logs/hook.jsonl)" "second"
assert_eq "$(jq -r 'select(.level == "INFO") | .message' .reviewer/logs/hook.jsonl)" "first"
assert_eq "$(jq -r '.source' .reviewer/logs/hook.jsonl | sort -u)" "test_script"
assert_eq "$(jq -r '.type' .reviewer/logs/hook.jsonl | sort -u)" "stop_hook"

it "escapes messages that would otherwise break the line"
export MSG=$'say "hi"\nand\ttab'
run_common '_log_to_file "WARNING" "$MSG"'
unset MSG
tail_line=$(tail -n 1 .reviewer/logs/hook.jsonl)
assert_valid_json "$tail_line" "a message with quotes and newlines"
assert_eq "$(printf '%s' "$tail_line" | jq -r '.message')" $'say "hi"\nand\ttab'
cleanup_repo
unset STOP_HOOK_LOG STOP_HOOK_SCRIPT_NAME

it "creates the parent directory"
make_repo
export STOP_HOOK_LOG="$PWD/deep/nested/dir/hook.jsonl"
run_common '_log_to_file "INFO" "hi"'
assert_file_exists "deep/nested/dir/hook.jsonl"
unset STOP_HOOK_LOG
cleanup_repo

it "writes nothing when STOP_HOOK_LOG is empty"
make_repo
commit_all init
export STOP_HOOK_LOG=""
run_common '_log_to_file "INFO" "goes nowhere"'
assert_eq "$(git status --porcelain -uall)" "" "an empty log path must not create files"
unset STOP_HOOK_LOG
cleanup_repo

it "defaults the source to unknown"
make_repo
export STOP_HOOK_LOG="$PWD/hook.jsonl"
run_common '_log_to_file "INFO" "hi"'
assert_eq "$(jq -r '.source' hook.jsonl)" "unknown"
unset STOP_HOOK_LOG
cleanup_repo

# ---------------------------------------------------------------------------
# log_error / log_warn / log_info / log_debug
# ---------------------------------------------------------------------------
make_repo
export STOP_HOOK_LOG="$PWD/hook.jsonl"
run_common 'log_error "boom"; log_warn "careful"; log_info "fyi"; log_debug "quiet"'

it "sends log_error to stderr only"
assert_contains "$SNIP_ERR" "ERROR: boom"
assert_not_contains "$SNIP_OUT" "boom"

it "sends log_warn to stderr only"
assert_contains "$SNIP_ERR" "WARN: careful"
assert_not_contains "$SNIP_OUT" "careful"

it "sends log_info to stdout only"
assert_contains "$SNIP_OUT" "fyi"
assert_not_contains "$SNIP_ERR" "fyi"

it "keeps log_debug off the console"
assert_not_contains "$SNIP_OUT" "quiet"
assert_not_contains "$SNIP_ERR" "quiet"

it "sends every level to the log file"
assert_eq "$(jq -r 'select(.message == "boom") | .level' hook.jsonl)" "ERROR"
assert_eq "$(jq -r 'select(.message == "careful") | .level' hook.jsonl)" "WARNING"
assert_eq "$(jq -r 'select(.message == "fyi") | .level' hook.jsonl)" "INFO"
assert_eq "$(jq -r 'select(.message == "quiet") | .level' hook.jsonl)" "DEBUG"
unset STOP_HOOK_LOG
cleanup_repo

# ---------------------------------------------------------------------------
# _timestamp
# ---------------------------------------------------------------------------
make_repo

it "produces a fractional-second ISO-8601 UTC timestamp"
run_common '_timestamp'
assert_matches "$SNIP_OUT" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+Z$'

it "reports the current time in UTC"
assert_contains "$SNIP_OUT" "$(date -u +%Y-%m-%dT%H)"

cleanup_repo

report
