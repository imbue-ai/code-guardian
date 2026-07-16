"""The gates stop_hook_orchestrator.sh applies before it looks at any diff:
enabled_when (Step 1), the stuck-agent safety hatch (Step 2), the
uncommitted-changes check (Step 3), and the EXIT trap that records blocks.

Base resolution and docs-only skipping (Step 5) live in
test_orchestrator_base_resolution.py.
"""

from __future__ import annotations

from typing import Any, Mapping

import pytest

# The stop_hook fields the Step 2/3 tests share, at their documented defaults.
_HOOK_ON = {"enabled_when": "true", "require_committed": True, "max_consecutive_blocks": 3}

BLOCK_TRACKER = ".reviewer/outputs/stop_hook_consecutive_blocks"
STOP_HOOK_LOG = ".reviewer/logs/stop_hook.jsonl"


# Scratch repo on `feature`, branched off a `main` that has real code, with
# settings.json committed. `overrides` is merged into stop_hook, so each test
# states only the fields it varies. fetch_and_merge and ci stay off: no
# network here.
def _setup(repo, overrides: Mapping[str, Any] | None = None) -> None:
    stop_hook = {"base_branch": "main", "fetch_and_merge": False, "skip_informational": True}
    if overrides:
        stop_hook.update(overrides)
    repo.settings({"stop_hook": stop_hook, "ci": {"is_enabled": False}})
    repo.write("app.py", "code\n")
    repo.commit_all("init")
    repo.checkout_new("feature")


# A commit whose diff vs main is real code, so the review gates have something
# to fire on and the run blocks (exit 2) unless an earlier step stops it.
def _commit_code(repo) -> None:
    repo.write("app.py", repo.read("app.py") + "more code\n")
    repo.commit_all("work")


# Pre-load the block tracker with `commit_hash` repeated `count` times, as
# previous blocking runs would have left it.
def _seed_tracker(repo, commit_hash: str, count: int) -> None:
    repo.write(BLOCK_TRACKER, (commit_hash + "\n") * count)


# ==============================================================================
# Step 0: config validation
#
# Unparseable JSON reads as "no value for any key", which is indistinguishable
# from an unset enabled_when -- so a stray comma used to disable every gate
# and say nothing about it.
# ==============================================================================
def test_reports_malformed_settings_instead_of_silently_disabling(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)
    repo.settings('{ "stop_hook": { "enabled_when": "true", } }\n')

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 1, "a typo must be reported (1), never silently skipped (0)"
    assert "not valid JSON" in result.output
    assert ".reviewer/settings.json" in result.output


def test_reports_malformed_settings_local_too(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)
    repo.local_settings('{ "stop_hook": { "base_branch": "main",, } }\n')

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 1, "the local override is read first and must be validated"
    assert "settings.local.json" in result.output


def test_still_runs_when_the_config_is_valid(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "valid config must reach the gates"
    assert "not valid JSON" not in result.output


# ==============================================================================
# Step 1: enabled_when
#
# The hook is opt-in, and logging starts only once it has opted in -- a
# disabled hook must leave no trace in the repo at all.
# ==============================================================================
@pytest.mark.parametrize(
    "overrides, why",
    [
        (None, "absent enabled_when should disable the hook, not block"),
        ({"enabled_when": ""}, "empty enabled_when should disable the hook"),
        ({"enabled_when": "false"}, "a failing enabled_when should disable the hook"),
    ],
    ids=["absent", "empty", "failing"],
)
def test_treats_a_falsy_enabled_when_as_disabled(repo, overrides, why):
    _setup(repo, overrides)
    _commit_code(repo)

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 0, why
    assert not repo.exists(STOP_HOOK_LOG), "a disabled hook must not start logging"


def test_runs_the_pipeline_when_the_enabled_when_command_succeeds(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "an enabled hook must reach the review gates"
    assert "gates have not been satisfied" in result.output
    assert repo.exists(STOP_HOOK_LOG), "an enabled hook logs from Step 1 onward"


# ==============================================================================
# Step 3: uncommitted changes
#
# Each dirty state is reported under its own heading, naming the files, so the
# agent knows whether to add, commit, or gitignore.
# ==============================================================================
def test_blocks_on_an_untracked_file_and_names_it(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)
    repo.write("notes.txt", "scratch\n")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "an untracked file must block"
    assert "Uncommitted changes detected" in result.output
    assert "Untracked files" in result.output
    assert "notes.txt" in result.output


def test_blocks_on_an_unstaged_modification_and_names_it(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)
    repo.write("app.py", repo.read("app.py") + "uncommitted edit\n")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "an unstaged modification must block"
    assert "Unstaged changes" in result.output
    assert "app.py" in result.output
    assert "Untracked files" not in result.output, "a tracked file is not untracked"


def test_blocks_on_a_staged_but_uncommitted_change_and_names_it(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)
    repo.write("staged.py", "staged\n")
    repo.git("add", "staged.py")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "a staged change must block"
    assert "Staged but not committed" in result.output
    assert "staged.py" in result.output
    assert "Untracked files" not in result.output, "git add moved it out of untracked"


def test_lets_a_clean_tree_past_the_uncommitted_check(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert "Uncommitted changes detected" not in result.output
    assert "gates have not been satisfied" in result.output, "a clean tree reaches Step 7"


def test_ignores_a_dirty_tree_when_require_committed_is_false(repo):
    _setup(repo, {"enabled_when": "true", "require_committed": False, "max_consecutive_blocks": 3})
    _commit_code(repo)
    repo.write("notes.txt", "scratch\n")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert "Uncommitted changes detected" not in result.output
    assert "gates have not been satisfied" in result.output, "the run continues past Step 3"


# ==============================================================================
# Step 2: stuck-agent safety hatch
#
# Blocking the same commit forever is worse than letting an unreviewed one
# through, so after max_consecutive_blocks blocks at one hash the hook stands
# down and resets the count.
# ==============================================================================
def test_hatch_lets_the_agent_through_and_clears_the_tracker(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)
    _seed_tracker(repo, repo.head, 3)

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 0, "the hatch must let the agent through"
    assert "The agent appears stuck" in result.output
    assert "still unsatisfied" in result.output
    assert not repo.exists(BLOCK_TRACKER), "a fired hatch must reset the count, not re-arm it"


def test_hatch_stays_shut_below_max_consecutive_blocks(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)
    _seed_tracker(repo, repo.head, 2)

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "two prior blocks are not yet three"
    assert "appears stuck" not in result.output


def test_hatch_counts_only_blocks_at_the_current_head(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)
    _seed_tracker(repo, "0000000000000000000000000000000000000000", 3)

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "blocks recorded at another commit must not open the hatch"
    assert "appears stuck" not in result.output


# ==============================================================================
# EXIT trap: block accounting
#
# The tracker feeds Step 2, so it must gain exactly one entry per blocking run
# and nothing on any other exit.
# ==============================================================================
def test_records_exactly_one_entry_the_current_head_for_a_blocking_run(repo):
    _setup(repo, _HOOK_ON)
    _commit_code(repo)

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2
    assert repo.read(BLOCK_TRACKER).strip() == repo.head, "one line, and it is HEAD"


# Docs-only is the one clean exit that leaves the tracker alone -- the success
# path deletes it, which would hide an append.
def test_records_nothing_for_a_clean_exit(repo):
    _setup(repo, _HOOK_ON)
    repo.write("README.md", "# doc\n")
    repo.commit_all("docs")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 0
    assert not repo.exists(BLOCK_TRACKER), "only a blocking run counts"


def test_accumulates_one_entry_per_blocking_run_at_the_same_commit(repo):
    _setup(repo, {"enabled_when": "true", "require_committed": True, "max_consecutive_blocks": 5})
    _commit_code(repo)

    repo.run_script("stop_hook_orchestrator.sh")
    repo.run_script("stop_hook_orchestrator.sh")
    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "a max of 5 keeps the hatch shut for three blocks"
    lines = repo.read(BLOCK_TRACKER).splitlines()
    assert len(lines) == 3, "one entry per blocking run"
    assert set(lines) == {repo.head}, "every entry is the current HEAD"
