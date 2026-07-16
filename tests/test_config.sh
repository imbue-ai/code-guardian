#!/usr/bin/env bash
#
# Key resolution in config_utils.sh (read_json_config) and its CLI wrapper
# get_config.sh.
#
# The contract these cover: env var CODE_GUARDIAN_<KEY> > settings.local.json >
# settings.json > provided default. A layer only wins when it yields a non-empty
# value, so null and empty entries fall through to the layer below.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# read_json_config against .reviewer/settings.json. Sets CFG_OUT (combined
# output) and CFG_EXIT.
#
# The subshell is load-bearing: config_utils.sh runs `set -euo pipefail` at
# top level, which would otherwise land on the test harness itself and abort
# the run on the first non-zero assertion.
CFG_OUT=""
CFG_EXIT=0
read_config() {
    _assert_scratch
    CFG_OUT=$(bash -c '
        source "$1/config_utils.sh"
        read_json_config "$2" "$3" "$4"
    ' _ "$SCRIPTS_DIR" ".reviewer/settings.json" "$1" "${2:-}" 2>&1 </dev/null)
    CFG_EXIT=$?
}

# write_local_settings <<'EOF' ... EOF -- writes .reviewer/settings.local.json
write_local_settings() {
    _assert_scratch
    mkdir -p .reviewer
    cat > .reviewer/settings.local.json
}

# get_config.sh with stderr dropped, to pin down what reaches stdout alone.
GC_STDOUT=""
GC_EXIT=0
get_config_stdout() {
    _assert_scratch
    GC_STDOUT=$(bash "$SCRIPTS_DIR/get_config.sh" "$@" 2>/dev/null </dev/null)
    GC_EXIT=$?
}

# --- precedence: default is the floor ---------------------------------------
it "returns the default when no config file exists at all"
make_repo main
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "fallback"
assert_eq "$CFG_EXIT" "0"
cleanup_repo

it "returns the default for a key absent from an existing file"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "trunk" } }
EOF
read_config ci.is_enabled fallback
assert_eq "$CFG_OUT" "fallback"
cleanup_repo

# --- precedence: settings.json over the default ------------------------------
it "prefers settings.json over the provided default"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "trunk" } }
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "trunk"
cleanup_repo

# --- precedence: settings.local.json over settings.json ----------------------
it "prefers settings.local.json over settings.json"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "from_settings" } }
EOF
write_local_settings <<'EOF'
{ "stop_hook": { "base_branch": "from_local" } }
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "from_local"

it "still reads settings.json for keys the local file does not define"
read_config ci.is_enabled fallback
assert_eq "$CFG_OUT" "fallback"
cleanup_repo

it "reads a key defined only in settings.local.json"
make_repo main
write_settings <<'EOF'
{ "ci": { "is_enabled": false } }
EOF
write_local_settings <<'EOF'
{ "stop_hook": { "base_branch": "local_only" } }
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "local_only"

it "reads a key defined only in settings.json when a local file exists"
read_config ci.is_enabled fallback
assert_eq "$CFG_OUT" "false"
cleanup_repo

# --- precedence: env var over everything -------------------------------------
it "prefers the env var over settings.local.json"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "from_settings" } }
EOF
write_local_settings <<'EOF'
{ "stop_hook": { "base_branch": "from_local" } }
EOF
export CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH=from_env
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "from_env" "env var must outrank every file layer"
unset CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH

it "falls back through the whole stack once the env var is gone"
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "from_local"
cleanup_repo

it "prefers the env var with no config file present"
make_repo main
export CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH=from_env
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "from_env"
unset CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH
cleanup_repo

it "ignores an empty env var and falls through to the file"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "trunk" } }
EOF
export CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH=""
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "trunk" "an empty env var must not shadow the file"
unset CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH
cleanup_repo

# --- env var name mapping ----------------------------------------------------
it "maps a dotted key to CODE_GUARDIAN_<UPPER> with dots as double underscores"
make_repo main
write_settings <<'EOF'
{ "ci": { "is_enabled": false } }
EOF
export CODE_GUARDIAN_CI__IS_ENABLED=true
read_config ci.is_enabled fallback
assert_eq "$CFG_OUT" "true"
unset CODE_GUARDIAN_CI__IS_ENABLED

it "maps a simple key to CODE_GUARDIAN_<UPPER> with no underscore doubling"
export CODE_GUARDIAN_ENABLED=yes
read_config enabled fallback
assert_eq "$CFG_OUT" "yes"
unset CODE_GUARDIAN_ENABLED

it "ignores a single-underscore name in place of the double-underscore one"
export CODE_GUARDIAN_CI_IS_ENABLED=true
read_config ci.is_enabled fallback
assert_eq "$CFG_OUT" "false" "single underscore must not resolve a dotted key"
unset CODE_GUARDIAN_CI_IS_ENABLED

it "ignores a lowercase env var name"
export code_guardian_ci__is_enabled=true
read_config ci.is_enabled fallback
assert_eq "$CFG_OUT" "false" "the name mapping uppercases; lowercase must not hit"
unset code_guardian_ci__is_enabled

it "ignores an unprefixed env var name"
export CI__IS_ENABLED=true
read_config ci.is_enabled fallback
assert_eq "$CFG_OUT" "false" "the CODE_GUARDIAN_ prefix is required"
unset CI__IS_ENABLED
cleanup_repo

# --- key shapes --------------------------------------------------------------
it "reads a simple top-level key"
make_repo main
write_settings <<'EOF'
{ "enabled": "sure", "stop_hook": { "base_branch": "trunk" } }
EOF
read_config enabled fallback
assert_eq "$CFG_OUT" "sure"

it "reads a nested key"
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "trunk"

it "returns the default when the parent section is absent"
read_config nosuch.child fallback
assert_eq "$CFG_OUT" "fallback" "a missing parent must not error out"
assert_eq "$CFG_EXIT" "0"
cleanup_repo

# --- null and empty values fall through --------------------------------------
it "treats a JSON null as absent and returns the default"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": null } }
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "fallback"
cleanup_repo

it "treats a null in settings.local.json as absent and falls to settings.json"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "from_settings" } }
EOF
write_local_settings <<'EOF'
{ "stop_hook": { "base_branch": null } }
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "from_settings" "a null local entry must not shadow settings.json"
cleanup_repo

# An empty string is indistinguishable from "no value" here: the jq result is
# tested with [ -n ], so "" falls through exactly like null does.
it "treats an empty string as absent and returns the default"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "" } }
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "fallback" "an empty string cannot be selected; it falls through"
cleanup_repo

it "treats an empty string in settings.local.json as absent and falls to settings.json"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "from_settings" } }
EOF
write_local_settings <<'EOF'
{ "stop_hook": { "base_branch": "" } }
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "from_settings" "an empty local entry must not shadow settings.json"
cleanup_repo

# --- value shapes ------------------------------------------------------------
it "preserves a value containing spaces"
make_repo main
write_settings <<'EOF'
{
  "stop_hook": { "enabled_when": "git branch --show-current | grep -q feature" },
  "spaced": "a b c",
  "num": 42,
  "float": 1.5,
  "bool_true": true,
  "bool_false": false,
  "zero": 0,
  "numeric_string": "42"
}
EOF
read_config spaced fallback
assert_eq "$CFG_OUT" "a b c"

it "preserves a shell-looking value with spaces and pipes"
read_config stop_hook.enabled_when fallback
assert_eq "$CFG_OUT" "git branch --show-current | grep -q feature"

it "renders a JSON number unquoted"
read_config num fallback
assert_eq "$CFG_OUT" "42"

it "renders a JSON float unquoted"
read_config float fallback
assert_eq "$CFG_OUT" "1.5"

it "renders JSON booleans as true/false"
read_config bool_true fallback
assert_eq "$CFG_OUT" "true"
read_config bool_false fallback
assert_eq "$CFG_OUT" "false" "false is a value, not an absence"

it "renders a zero as 0 rather than falling through"
read_config zero fallback
assert_eq "$CFG_OUT" "0" "0 is non-empty as a string, so it must win"

it "renders a numeric string identically to a number"
read_config numeric_string fallback
assert_eq "$CFG_OUT" "42"

it "passes a default containing spaces through untouched"
read_config nosuch.child "a b c"
assert_eq "$CFG_OUT" "a b c"
cleanup_repo

# --- malformed JSON ----------------------------------------------------------
# jq's parse failure is silenced with 2>/dev/null, but `set -e` from
# config_utils.sh still acts on its non-zero status, so the read aborts with
# jq's exit code and prints nothing. See the note in the test report.
it "aborts with jq's exit code on malformed settings.json"
make_repo main
write_settings <<'EOF'
{ this is not valid json
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_EXIT" "5" "malformed JSON currently aborts rather than falling back"
assert_eq "$CFG_OUT" "" "the jq parse error stays silenced"

it "does not leak a jq parse error to the caller's output"
assert_not_contains "$CFG_OUT" "parse error"
assert_not_contains "$CFG_OUT" "fallback"
cleanup_repo

it "aborts the same way on malformed settings.local.json"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "from_settings" } }
EOF
write_local_settings <<'EOF'
{ nope
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_EXIT" "5" "a malformed local file aborts before settings.json is tried"
assert_eq "$CFG_OUT" ""
cleanup_repo

it "reads an empty settings.json as absent rather than aborting"
make_repo main
write_settings <<'EOF'
EOF
read_config stop_hook.base_branch fallback
assert_eq "$CFG_OUT" "fallback" "an empty file parses to nothing, not an error"
assert_eq "$CFG_EXIT" "0"
cleanup_repo

# --- get_config.sh CLI -------------------------------------------------------
it "prints the resolved value for a nested key on stdout"
make_repo main
write_settings <<'EOF'
{
  "stop_hook": { "base_branch": "trunk" },
  "ci": { "is_enabled": false },
  "spaced": "a b c"
}
EOF
run_script get_config.sh stop_hook.base_branch main
assert_eq "$RUN_EXIT" "0"
assert_eq "$RUN_OUT" "trunk"

it "prints a value containing spaces intact"
run_script get_config.sh spaced fallback
assert_eq "$RUN_OUT" "a b c"

it "prints a boolean from a nested key"
run_script get_config.sh ci.is_enabled true
assert_eq "$RUN_OUT" "false"

it "uses the [default] arg when the key is absent"
run_script get_config.sh nosuch.child fallback
assert_eq "$RUN_EXIT" "0"
assert_eq "$RUN_OUT" "fallback"

it "defaults to the empty string when [default] is omitted"
run_script get_config.sh nosuch.child
assert_eq "$RUN_EXIT" "0"
assert_eq "$RUN_OUT" ""

it "honors the env var override through the CLI"
export CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH=from_env
run_script get_config.sh stop_hook.base_branch main
assert_eq "$RUN_OUT" "from_env"
unset CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH
cleanup_repo

it "errors on stdout-free usage when given no args"
make_repo main
write_settings <<'EOF'
{ "stop_hook": { "base_branch": "trunk" } }
EOF
run_script get_config.sh
assert_eq "$RUN_EXIT" "1" "no args must be a usage error"
assert_contains "$RUN_OUT" "Usage:"
assert_contains "$RUN_OUT" "<key> [default]"

it "sends the usage error to stderr, not stdout"
get_config_stdout
assert_eq "$GC_EXIT" "1"
assert_eq "$GC_STDOUT" "" "usage text must not pollute a caller capturing stdout"
cleanup_repo

report
