"""PR discovery and CI polling in stop_hook_pr_and_ci.sh.

Every test stubs gh: this is the only script in the hook that talks to
GitHub, and a test that reaches the real API can hang, leak, or reopen
someone's PR.
"""

from __future__ import annotations

import shutil
from typing import Mapping

OUTPUTS = ".reviewer/outputs"


def _setup(repo) -> None:
    """A branch with no remote, so nothing can reach the network without a stub."""
    repo.write("app.py", "code\n")
    repo.commit_all("init")
    repo.checkout_new("feature")


def _setup_poll(repo) -> None:
    """ci.timeout and ci.poll_interval turned right down: the defaults are
    600s and 15s, which no test suite can afford."""
    _setup(repo)
    repo.settings({"ci": {"timeout": 5, "poll_interval": 1}})
    (repo.path / ".reviewer" / "outputs").mkdir(parents=True, exist_ok=True)


def _gh_calls(repo) -> str:
    try:
        return repo.read("gh_calls")
    except FileNotFoundError:
        return ""


def _gh_stub(cases: Mapping[str, str], *, log_calls: bool = True) -> str:
    """A gh stub dispatching on the full argument string, refusing anything
    not listed."""
    lines = ['echo "$*" >> "$PWD/gh_calls"'] if log_calls else []
    lines.append('case "$*" in')
    for call, body in cases.items():
        lines.append(f'    "{call}")')
        lines.extend(f"        {line}" for line in body.splitlines())
        lines.append("        ;;")
    lines.append("    *)")
    lines.append('        echo "unexpected gh call: $*" >&2; exit 1 ;;')
    lines.append("esac")
    return "\n".join(lines)


# --- ensure-pr: an open PR exists -------------------------------------------
def test_records_the_pr_number_and_url_and_looks_it_up_by_branch(repo):
    _setup(repo)
    repo.stub(
        "gh",
        _gh_stub(
            {
                "pr view feature --json number,state": """echo '{"number":42,"state":"OPEN"}'""",
                "pr view 42 --json url --jq .url": 'echo "https://github.com/acme/repo/pull/42"',
            }
        ),
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "ensure-pr")

    assert result.exit_code == 0, "an open PR satisfies ensure-pr"
    assert repo.read(f"{OUTPUTS}/pr_number").strip() == "42"
    assert repo.read(f"{OUTPUTS}/pr_url").strip() == "https://github.com/acme/repo/pull/42"
    assert repo.read(f"{OUTPUTS}/pr_status").strip() == "pending", "CI has not run yet"
    assert "pr view feature --json number,state" in _gh_calls(repo)


# --- ensure-pr: no PR --------------------------------------------------------
def test_blocks_when_no_pr_exists_and_one_is_required(repo):
    _setup(repo)
    repo.stub(
        "gh",
        """
echo "$*" >> "$PWD/gh_calls"
echo 'no pull requests found for branch "feature"' >&2
exit 1
""",
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "ensure-pr")

    assert result.exit_code == 2, "ci.require_pr defaults to true"
    assert "No PR found for branch feature" in result.output
    assert "gh pr create --draft" in result.output
    assert not repo.exists(f"{OUTPUTS}/pr_number")


def test_passes_and_blanks_pr_number_when_no_pr_exists_and_none_is_required(repo):
    _setup(repo)
    repo.settings({"ci": {"require_pr": False}})
    repo.stub(
        "gh",
        """
echo "$*" >> "$PWD/gh_calls"
exit 1
""",
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "ensure-pr")

    assert result.exit_code == 0, "ci.require_pr=false makes the PR optional"
    assert "skipping CI" in result.output
    assert repo.exists(f"{OUTPUTS}/pr_number")
    assert repo.read(f"{OUTPUTS}/pr_number").strip() == "", "an empty PR number means no CI"


# --- ensure-pr: merged and closed PRs ---------------------------------------
def test_skips_ci_for_an_already_merged_pr(repo):
    _setup(repo)
    repo.stub(
        "gh",
        _gh_stub({"pr view feature --json number,state": """echo '{"number":7,"state":"MERGED"}'"""}),
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "ensure-pr")

    assert result.exit_code == 0, "a merged PR needs no further CI"
    assert "already merged" in result.output
    assert repo.read(f"{OUTPUTS}/pr_number").strip() == ""
    assert not repo.exists(f"{OUTPUTS}/pr_status")


def test_reopens_a_closed_pr_and_carries_on(repo):
    _setup(repo)
    repo.stub(
        "gh",
        _gh_stub(
            {
                "pr view feature --json number,state": """echo '{"number":9,"state":"CLOSED"}'""",
                "pr reopen 9 --comment Reopening PR for continued work.": 'echo "reopened"',
                "pr view 9 --json url --jq .url": 'echo "https://github.com/acme/repo/pull/9"',
            }
        ),
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "ensure-pr")

    assert result.exit_code == 0
    assert "pr reopen 9 --comment Reopening PR for continued work." in _gh_calls(repo)
    assert repo.read(f"{OUTPUTS}/pr_number").strip() == "9"
    assert repo.read(f"{OUTPUTS}/pr_status").strip() == "pending"


def test_fails_when_a_closed_pr_cannot_be_reopened(repo):
    _setup(repo)
    repo.stub(
        "gh",
        """
echo "$*" >> "$PWD/gh_calls"
case "$*" in
    "pr view feature --json number,state")
        echo '{"number":9,"state":"CLOSED"}' ;;
    *)
        exit 1 ;;
esac
""",
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "ensure-pr")

    assert result.exit_code == 1, "a failed reopen is an error, not a gate block"
    assert "Failed to reopen PR #9" in result.output


# --- ensure-pr: the outputs directory ---------------------------------------
# The early returns above write into .reviewer/outputs, so ensure-pr has to
# create it before it can take one.
def test_creates_the_outputs_directory_even_on_an_early_return(repo):
    _setup(repo)
    repo.settings({"ci": {"require_pr": False}})
    shutil.rmtree(repo.path / ".reviewer" / "outputs", ignore_errors=True)
    repo.stub("gh", "\nexit 1\n")

    result = repo.run_script("stop_hook_pr_and_ci.sh", "ensure-pr")

    assert result.exit_code == 0
    assert repo.exists(f"{OUTPUTS}/pr_number"), "the early return must still be able to write"


def test_creates_the_outputs_directory_before_failing_on_a_missing_pr(repo):
    _setup(repo)
    shutil.rmtree(repo.path / ".reviewer" / "outputs", ignore_errors=True)
    repo.stub("gh", "\nexit 1\n")

    result = repo.run_script("stop_hook_pr_and_ci.sh", "ensure-pr")

    assert result.exit_code == 2
    assert repo.exists(OUTPUTS), ".reviewer/outputs should exist after ensure-pr"


# --- poll-ci -----------------------------------------------------------------
def test_passes_when_every_check_passes(repo):
    _setup_poll(repo)
    repo.stub(
        "gh",
        _gh_stub(
            {
                "pr view 42 --json headRefOid --jq .headRefOid": 'echo "abc123"',
                "pr checks 42": (
                    'printf "build\\tpass\\t1m\\thttps://example.invalid/1\\n"\n'
                    'printf "lint\\tpass\\t20s\\thttps://example.invalid/2\\n"'
                ),
            }
        ),
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "poll-ci", "42")

    assert result.exit_code == 0, "green CI should not block"
    assert "success" in result.output
    assert repo.read(f"{OUTPUTS}/pr_status").strip() == "success"


def test_creates_the_outputs_directory_when_run_without_a_prior_ensure_pr(repo):
    _setup_poll(repo)
    shutil.rmtree(repo.path / ".reviewer" / "outputs", ignore_errors=True)
    repo.stub(
        "gh",
        _gh_stub(
            {
                "pr view 42 --json headRefOid --jq .headRefOid": 'echo "abc123"',
                "pr checks 42": 'printf "build\\tpass\\t1m\\thttps://example.invalid/1\\n"',
            },
            log_calls=False,
        ),
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "poll-ci", "42")

    assert result.exit_code == 0, "green CI must not fail on a missing outputs dir"
    assert "No such file or directory" not in result.output
    assert repo.read(f"{OUTPUTS}/pr_status").strip() == "success"


def test_blocks_when_a_check_fails(repo):
    _setup_poll(repo)
    repo.stub(
        "gh",
        _gh_stub(
            {
                "pr view 42 --json headRefOid --jq .headRefOid": 'echo "abc123"',
                "pr checks 42": (
                    'printf "build\\tpass\\t1m\\thttps://example.invalid/1\\n"\n'
                    'printf "lint\\tfail\\t20s\\thttps://example.invalid/2\\n"\n'
                    "exit 1"
                ),
            }
        ),
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "poll-ci", "42")

    assert result.exit_code == 2, "failing CI must block"
    assert "CI tests have failed for the PR!" in result.output
    assert repo.read(f"{OUTPUTS}/pr_status").strip() == "failure"
    assert "NEVER just re-trigger the pipeline!" in result.output


def test_waits_for_pending_checks_and_passes_once_they_finish(repo):
    _setup_poll(repo)
    repo.stub(
        "gh",
        _gh_stub(
            {
                "pr view 42 --json headRefOid --jq .headRefOid": 'echo "abc123"',
                "pr checks 42": (
                    'n=$(cat "$PWD/poll_count" 2>/dev/null || echo 0)\n'
                    "n=$((n + 1))\n"
                    'echo "$n" > "$PWD/poll_count"\n'
                    "if [[ $n -lt 2 ]]; then\n"
                    '    printf "build\\tpending\\t0s\\thttps://example.invalid/1\\n"\n'
                    "    exit 8\n"
                    "fi\n"
                    'printf "build\\tpass\\t1m\\thttps://example.invalid/1\\n"'
                ),
            }
        ),
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "poll-ci", "42")

    assert result.exit_code == 0, "a pending check should be waited out, not failed"
    assert repo.read(f"{OUTPUTS}/pr_status").strip() == "success"
    assert repo.read("poll_count").strip() == "2", "polling should have taken a second pass"


def test_blocks_when_checks_never_stop_pending(repo):
    _setup_poll(repo)
    repo.settings({"ci": {"timeout": 1, "poll_interval": 1}})
    repo.stub(
        "gh",
        _gh_stub(
            {
                "pr view 42 --json headRefOid --jq .headRefOid": 'echo "abc123"',
                "pr checks 42": ('printf "build\\tpending\\t0s\\thttps://example.invalid/1\\n"\nexit 8'),
            }
        ),
    )

    result = repo.run_script("stop_hook_pr_and_ci.sh", "poll-ci", "42")

    assert result.exit_code == 2, "a CI timeout is reported as a failure"
    assert repo.read(f"{OUTPUTS}/pr_status").strip() == "failure"


# --- dispatch ----------------------------------------------------------------
def test_rejects_poll_ci_without_a_pr_number(repo):
    _setup(repo)

    result = repo.run_script("stop_hook_pr_and_ci.sh", "poll-ci")

    assert result.exit_code == 1
    assert "poll-ci requires a PR number argument" in result.output


def test_prints_usage_for_an_unknown_subcommand(repo):
    _setup(repo)

    result = repo.run_script("stop_hook_pr_and_ci.sh", "frobnicate")

    assert result.exit_code == 1
    assert "Usage:" in result.output
    assert "{ensure-pr|poll-ci <pr_number>}" in result.output


def test_prints_usage_when_given_no_subcommand(repo):
    _setup(repo)

    result = repo.run_script("stop_hook_pr_and_ci.sh")

    assert result.exit_code == 1
    assert "Usage:" in result.output
