"""Key resolution in config_utils.sh (read_json_config) and its CLI wrapper get_config.sh.

The contract these cover: env var CODE_GUARDIAN_<KEY> > settings.local.json >
settings.json > provided default. A layer only wins when it yields a non-empty
value, so null and empty entries fall through to the layer below.
"""

from __future__ import annotations

import pytest

BASE_BRANCH = "stop_hook.base_branch"
ENV_BASE_BRANCH = "CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH"


# --- precedence -------------------------------------------------------------
@pytest.mark.parametrize(
    "settings, local, env_value, expected, why",
    [
        (None, None, None, "fallback", "the default is the floor"),
        (
            {"stop_hook": {"base_branch": "trunk"}},
            None,
            None,
            "trunk",
            "settings.json outranks the provided default",
        ),
        (
            {"stop_hook": {"base_branch": "from_settings"}},
            {"stop_hook": {"base_branch": "from_local"}},
            None,
            "from_local",
            "settings.local.json outranks settings.json",
        ),
        (
            {"stop_hook": {"base_branch": "from_settings"}},
            {"stop_hook": {"base_branch": "from_local"}},
            "from_env",
            "from_env",
            "the env var outranks every file layer",
        ),
        (None, None, "from_env", "from_env", "the env var wins with no file present"),
    ],
    ids=["default-only", "settings", "local-over-settings", "env-over-all", "env-no-files"],
)
def test_precedence(repo, settings, local, env_value, expected, why):
    if settings is not None:
        repo.settings(settings)
    if local is not None:
        repo.local_settings(local)
    env = {ENV_BASE_BRANCH: env_value} if env_value else None

    assert repo.read_config(BASE_BRANCH, "fallback", env=env).output == expected, why


def test_default_is_returned_for_a_key_absent_from_an_existing_file(repo):
    repo.settings({"stop_hook": {"base_branch": "trunk"}})

    assert repo.read_config("ci.is_enabled", "fallback").output == "fallback"


def test_an_empty_env_var_does_not_shadow_the_file(repo):
    repo.settings({"stop_hook": {"base_branch": "trunk"}})

    result = repo.read_config(BASE_BRANCH, "fallback", env={ENV_BASE_BRANCH: ""})

    assert result.output == "trunk"


# --- per-key layering -------------------------------------------------------
# The layers are consulted per key, not per file: a local file that defines one
# key must not hide the rest of settings.json.
def test_a_key_only_in_settings_still_resolves_when_a_local_file_exists(repo):
    repo.settings({"ci": {"is_enabled": False}})
    repo.local_settings({"stop_hook": {"base_branch": "local_only"}})

    assert repo.read_config("ci.is_enabled", "fallback").output == "false"
    assert repo.read_config(BASE_BRANCH, "fallback").output == "local_only"


# --- env var name mapping ---------------------------------------------------
@pytest.mark.parametrize(
    "var, value, key, expected, why",
    [
        (
            "CODE_GUARDIAN_CI__IS_ENABLED",
            "true",
            "ci.is_enabled",
            "true",
            "a dotted key maps to CODE_GUARDIAN_<UPPER> with dots as double underscores",
        ),
        (
            "CODE_GUARDIAN_ENABLED",
            "yes",
            "enabled",
            "yes",
            "a simple key maps with no underscore doubling",
        ),
        (
            "CODE_GUARDIAN_CI_IS_ENABLED",
            "true",
            "ci.is_enabled",
            "false",
            "a single underscore must not resolve a dotted key",
        ),
        (
            "code_guardian_ci__is_enabled",
            "true",
            "ci.is_enabled",
            "false",
            "the mapping uppercases, so a lowercase name must not hit",
        ),
        (
            "CI__IS_ENABLED",
            "true",
            "ci.is_enabled",
            "false",
            "the CODE_GUARDIAN_ prefix is required",
        ),
    ],
    ids=["dotted", "simple", "single-underscore", "lowercase", "unprefixed"],
)
def test_env_var_name_mapping(repo, var, value, key, expected, why):
    repo.settings({"enabled": "from_file", "ci": {"is_enabled": False}})

    assert repo.read_config(key, "fallback", env={var: value}).output == expected, why


# --- key shapes -------------------------------------------------------------
def test_reads_a_simple_top_level_key(repo):
    repo.settings({"enabled": "sure", "stop_hook": {"base_branch": "trunk"}})

    assert repo.read_config("enabled", "fallback").output == "sure"
    assert repo.read_config(BASE_BRANCH, "fallback").output == "trunk"


def test_an_absent_parent_section_returns_the_default_without_erroring(repo):
    repo.settings({"stop_hook": {"base_branch": "trunk"}})

    result = repo.read_config("nosuch.child", "fallback")

    assert result.output == "fallback", "a missing parent must not error out"
    assert result.exit_code == 0


def test_a_default_containing_spaces_passes_through_untouched(repo):
    repo.settings({"stop_hook": {"base_branch": "trunk"}})

    assert repo.read_config("nosuch.child", "a b c").output == "a b c"


# --- null and empty values fall through -------------------------------------
# The jq result is tested with [ -n ], so an empty string is indistinguishable
# from "no value" and falls through exactly like null does.
@pytest.mark.parametrize("value", [None, ""], ids=["null", "empty-string"])
def test_a_null_or_empty_entry_falls_through_to_the_default(repo, value):
    repo.settings({"stop_hook": {"base_branch": value}})

    assert repo.read_config(BASE_BRANCH, "fallback").output == "fallback"


@pytest.mark.parametrize("value", [None, ""], ids=["null", "empty-string"])
def test_a_null_or_empty_local_entry_falls_through_to_settings(repo, value):
    repo.settings({"stop_hook": {"base_branch": "from_settings"}})
    repo.local_settings({"stop_hook": {"base_branch": value}})

    result = repo.read_config(BASE_BRANCH, "fallback")

    assert result.output == "from_settings", "an unset local entry must not shadow settings.json"


# --- value shapes -----------------------------------------------------------
VALUE_SHAPES = {
    "stop_hook": {"enabled_when": "git branch --show-current | grep -q feature"},
    "spaced": "a b c",
    "num": 42,
    "float": 1.5,
    "bool_true": True,
    "bool_false": False,
    "zero": 0,
    "numeric_string": "42",
}


@pytest.mark.parametrize(
    "key, expected, why",
    [
        ("spaced", "a b c", "a value containing spaces survives"),
        (
            "stop_hook.enabled_when",
            "git branch --show-current | grep -q feature",
            "a shell-looking value keeps its spaces and pipes",
        ),
        ("num", "42", "a JSON number renders unquoted"),
        ("float", "1.5", "a JSON float renders unquoted"),
        ("bool_true", "true", "a JSON true renders as true"),
        ("bool_false", "false", "false is a value, not an absence"),
        ("zero", "0", "0 is non-empty as a string, so it must win"),
        ("numeric_string", "42", "a numeric string renders identically to a number"),
    ],
)
def test_value_shapes(repo, key, expected, why):
    repo.settings(VALUE_SHAPES)

    assert repo.read_config(key, "fallback").output == expected, why


# --- malformed JSON ---------------------------------------------------------
# `set -e` from config_utils.sh acts on jq's non-zero status, so the read aborts
# with jq's exit code rather than falling back to the default. The parse error
# itself must reach the caller: a config typo that kills the hook with no
# explanation is the failure this whole area is about.
def test_malformed_settings_aborts_and_says_why(repo):
    repo.settings("{ this is not valid json\n")

    result = repo.read_config(BASE_BRANCH, "fallback")

    assert result.exit_code == 5, "malformed JSON aborts rather than falling back"
    assert "parse error" in result.output, "it must say why, instead of failing silently"
    assert "fallback" not in result.output, "the default must not be passed off as a real value"


def test_malformed_local_settings_aborts_before_settings_is_tried(repo):
    repo.settings({"stop_hook": {"base_branch": "from_settings"}})
    repo.local_settings("{ nope\n")

    result = repo.read_config(BASE_BRANCH, "fallback")

    assert result.exit_code == 5, "the local override is read first, so it aborts first"
    assert "parse error" in result.output
    assert "from_settings" not in result.output, "a broken local file must not silently fall through"


def test_an_empty_settings_file_reads_as_absent_rather_than_aborting(repo):
    repo.settings("")

    result = repo.read_config(BASE_BRANCH, "fallback")

    assert result.output == "fallback", "an empty file parses to nothing, not an error"
    assert result.exit_code == 0


# --- get_config.sh CLI ------------------------------------------------------
CLI_SETTINGS = {
    "stop_hook": {"base_branch": "trunk"},
    "ci": {"is_enabled": False},
    "spaced": "a b c",
}


@pytest.mark.parametrize(
    "args, expected, why",
    [
        ((BASE_BRANCH, "main"), "trunk", "a nested key resolves to its configured value"),
        (("spaced", "fallback"), "a b c", "a value containing spaces prints intact"),
        (("ci.is_enabled", "true"), "false", "a nested boolean prints as false"),
        (("nosuch.child", "fallback"), "fallback", "the [default] arg is used when the key is absent"),
        (("nosuch.child",), "", "an omitted [default] is the empty string"),
    ],
    ids=["nested", "spaced", "boolean", "default-used", "default-omitted"],
)
def test_cli_prints_the_resolved_value(repo, args, expected, why):
    repo.settings(CLI_SETTINGS)

    result = repo.run_script("get_config.sh", *args)

    assert result.exit_code == 0
    assert result.output == expected, why


def test_cli_honors_the_env_var_override(repo):
    repo.settings(CLI_SETTINGS)

    result = repo.run_script("get_config.sh", BASE_BRANCH, "main", env={ENV_BASE_BRANCH: "from_env"})

    assert result.output == "from_env"


def test_cli_errors_on_no_args(repo):
    repo.settings({"stop_hook": {"base_branch": "trunk"}})

    result = repo.run_script("get_config.sh")

    assert result.exit_code == 1, "no args must be a usage error"
    assert "Usage:" in result.output
    assert "<key> [default]" in result.output


def test_cli_sends_the_usage_error_to_stderr_not_stdout(repo):
    repo.settings({"stop_hook": {"base_branch": "trunk"}})

    result = repo.run_script_stdout("get_config.sh")

    assert result.exit_code == 1
    assert result.stdout == "", "usage text must not pollute a caller capturing stdout"
