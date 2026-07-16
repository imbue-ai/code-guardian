"""Shared helpers in stop_hook_common.sh: the .reviewer gitignore, retries,
JSON escaping, and logging.

The failure the gitignore covers: the uncommitted-changes gate blocks on any
untracked file, and the hook's own logs and outputs are untracked -- so
without the ignore rules the hook blocks on artifacts it wrote itself.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone

import pytest


# --- ensure_reviewer_gitignore ----------------------------------------------
def test_writes_the_ignore_rules_creating_the_directory(repo):
    repo.run_common("ensure_reviewer_gitignore")

    assert repo.exists(".reviewer/.gitignore")
    rules = repo.read(".reviewer/.gitignore")
    assert "logs/" in rules
    assert "outputs/" in rules
    assert "settings.local.json" in rules
    assert ".gitignore" in rules


def test_leaves_an_existing_gitignore_alone(repo):
    repo.write(".reviewer/.gitignore", "hand-written\n")

    repo.run_common("ensure_reviewer_gitignore")

    assert repo.read(".reviewer/.gitignore").rstrip("\n") == "hand-written", "existing rules must survive"


def test_honors_a_custom_directory_argument(repo):
    repo.run_common("ensure_reviewer_gitignore custom-reviewer")

    assert repo.exists("custom-reviewer/.gitignore")
    assert not repo.exists(".reviewer/.gitignore")
    assert "outputs/" in repo.read("custom-reviewer/.gitignore")


# The point of the whole function: git must not see the hook's own artifacts,
# including the generated .gitignore, while settings.json stays trackable.
def test_hides_the_hooks_own_artifacts_but_keeps_settings_trackable(repo):
    repo.run_common("ensure_reviewer_gitignore")
    repo.write(".reviewer/logs/x.jsonl", '{"level":"INFO"}\n')
    repo.write(".reviewer/outputs/stop_hook_consecutive_blocks", "3\n")

    # -uall: plain --porcelain collapses to a bare "?? .reviewer/", which would
    # make these assertions pass whether the rules exist or not.
    status = repo.git("status", "--porcelain", "-uall")
    assert ".reviewer/logs" not in status
    assert ".reviewer/outputs" not in status

    untracked = repo.git("ls-files", "--others", "--exclude-standard")
    assert ".reviewer/logs" not in untracked
    assert ".reviewer/outputs" not in untracked
    assert ".reviewer/.gitignore" not in untracked

    repo.write(".reviewer/settings.json", "{}\n")
    untracked = repo.git("ls-files", "--others", "--exclude-standard")
    assert ".reviewer/settings.json" in untracked


# --- retry_command -----------------------------------------------------------
def make_flaky(repo) -> None:
    """A command that fails until its invocation count reaches SUCCEED_AT,
    counting every attempt in ./count."""
    script = repo.write(
        "flaky.sh",
        "#!/usr/bin/env bash\n"
        "n=$(( $(cat count) + 1 ))\n"
        "printf '%s' \"$n\" > count\n"
        "[[ $n -ge ${SUCCEED_AT:-1} ]]\n",
    )
    script.chmod(0o755)
    repo.write("count", "0")


def test_retry_runs_the_command_once_when_it_succeeds(repo):
    make_flaky(repo)

    result = repo.run_common("export SUCCEED_AT=1; retry_command 3 ./flaky.sh")

    assert result.exit_code == 0, "a first-try success should return 0"
    assert repo.read("count") == "1", "a success must not be retried"


def test_retry_retries_until_the_command_succeeds(repo):
    make_flaky(repo)

    result = repo.run_common("export SUCCEED_AT=2; retry_command 3 ./flaky.sh")

    assert result.exit_code == 0, "a later success should still return 0"
    assert repo.read("count") == "2", "should stop retrying once it succeeds"
    assert "attempt 1/3" in result.stderr


def test_retry_gives_up_after_max_retries_attempts(repo):
    make_flaky(repo)

    result = repo.run_common("export SUCCEED_AT=99; retry_command 3 ./flaky.sh")

    assert result.exit_code == 1, "exhausted retries should return non-zero"
    assert repo.read("count") == "3", "should attempt exactly max_retries times"
    assert "Command failed after 3 attempts" in result.stderr


# --- _json_escape --------------------------------------------------------
# Escape the input, embed it in an object, and read the original back out.
def assert_escape_roundtrip(repo, input_str: str, label: str) -> None:
    result = repo.run_common(
        r'printf "{\"m\":\"%s\"}" "$(_json_escape "$INPUT")"',
        env={"INPUT": input_str},
    )
    try:
        parsed = json.loads(result.stdout)
    except json.JSONDecodeError:
        pytest.fail(f"escaped {label} must embed as JSON: {result.stdout}")
    assert parsed["m"] == input_str, f"{label} should round-trip"


@pytest.mark.parametrize(
    "input_str, label",
    [
        ('he said "hi"', "quotes"),
        (r"C:\path\to\thing", "backslashes"),
        (r"literal \n here", "literal escape"),
        ("first\nsecond", "newlines"),
        ("col1\tcol2", "tabs"),
        ("before\rafter", "carriage returns"),
        ('a "q" b\\c\nd\te\rf', "the lot"),
    ],
    ids=[
        "escapes double quotes",
        "escapes backslashes",
        "does not double-escape a literal backslash-n",
        "escapes newlines",
        "escapes tabs",
        "escapes carriage returns",
        "escapes all of them at once",
    ],
)
def test_json_escape_round_trips(repo, input_str, label):
    assert_escape_roundtrip(repo, input_str, label)


# --- _log_to_file ------------------------------------------------------------
def test_log_to_file_writes_one_json_line_per_call(repo):
    repo.run_common(
        '_log_to_file "INFO" "first"; _log_to_file "ERROR" "second"',
        env={"STOP_HOOK_LOG": ".reviewer/logs/hook.jsonl", "STOP_HOOK_SCRIPT_NAME": "test_script"},
    )

    assert repo.exists(".reviewer/logs/hook.jsonl")
    lines = repo.read(".reviewer/logs/hook.jsonl").splitlines()
    assert len(lines) == 2, "one line per call"

    bad = 0
    records = []
    for line in lines:
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            bad += 1
    assert bad == 0, "every line must be valid JSON"

    by_level = {r["level"]: r for r in records}
    assert by_level["ERROR"]["message"] == "second"
    assert by_level["INFO"]["message"] == "first"
    assert {r["source"] for r in records} == {"test_script"}
    assert {r["type"] for r in records} == {"stop_hook"}


def test_log_to_file_escapes_messages_that_would_otherwise_break_the_line(repo):
    msg = 'say "hi"\nand\ttab'

    repo.run_common('_log_to_file "WARNING" "$MSG"', env={"STOP_HOOK_LOG": "hook.jsonl", "MSG": msg})

    tail_line = repo.read("hook.jsonl").splitlines()[-1]
    try:
        parsed = json.loads(tail_line)
    except json.JSONDecodeError:
        pytest.fail(f"a message with quotes and newlines: {tail_line}")
    assert parsed["message"] == msg


def test_log_to_file_creates_the_parent_directory(repo):
    repo.run_common('_log_to_file "INFO" "hi"', env={"STOP_HOOK_LOG": "deep/nested/dir/hook.jsonl"})

    assert repo.exists("deep/nested/dir/hook.jsonl")


def test_log_to_file_writes_nothing_when_stop_hook_log_is_empty(repo):
    repo.commit_all("init")

    repo.run_common('_log_to_file "INFO" "goes nowhere"', env={"STOP_HOOK_LOG": ""})

    assert repo.git("status", "--porcelain", "-uall") == "", "an empty log path must not create files"


def test_log_to_file_defaults_the_source_to_unknown(repo):
    repo.run_common('_log_to_file "INFO" "hi"', env={"STOP_HOOK_LOG": "hook.jsonl"})

    record = json.loads(repo.read("hook.jsonl").splitlines()[0])
    assert record["source"] == "unknown"


# --- log_error / log_warn / log_info / log_debug -----------------------------
# Each level has a console stream it belongs on -- or none, in log_debug's case
# -- and every level reaches the log file regardless.
def test_log_levels_route_to_the_right_streams_and_all_reach_the_file(repo):
    result = repo.run_common(
        'log_error "boom"; log_warn "careful"; log_info "fyi"; log_debug "quiet"',
        env={"STOP_HOOK_LOG": "hook.jsonl"},
    )

    assert "ERROR: boom" in result.stderr
    assert "boom" not in result.stdout

    assert "WARN: careful" in result.stderr
    assert "careful" not in result.stdout

    assert "fyi" in result.stdout
    assert "fyi" not in result.stderr

    assert "quiet" not in result.stdout
    assert "quiet" not in result.stderr

    records = [json.loads(line) for line in repo.read("hook.jsonl").splitlines()]
    by_message = {r["message"]: r for r in records}
    assert by_message["boom"]["level"] == "ERROR"
    assert by_message["careful"]["level"] == "WARNING"
    assert by_message["fyi"]["level"] == "INFO"
    assert by_message["quiet"]["level"] == "DEBUG"


# --- _timestamp ----------------------------------------------------------
def test_timestamp_is_a_fractional_second_iso8601_utc_stamp_for_now(repo):
    result = repo.run_common("_timestamp")

    assert re.search(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+Z$", result.stdout)
    assert datetime.now(timezone.utc).strftime("%Y-%m-%dT%H") in result.stdout
