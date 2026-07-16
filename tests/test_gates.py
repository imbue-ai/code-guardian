"""Gate checking in stop_hook_gates.sh.

The markers are the whole contract: autofix and conversation review are keyed
by commit, architecture by branch, and the block of text below is what the
agent actually reads when a gate is unsatisfied.
"""

from __future__ import annotations

import pytest


def _setup(repo, branch: str = "feature") -> str:
    """A branch with real code changes vs the base, so the empty-diff skip never
    masks the gate logic."""
    repo.settings({"stop_hook": {"base_branch": "main"}})
    repo.write("app.py", "code\n")
    repo.commit_all("init")
    repo.checkout_new(branch)
    repo.write("app.py", "code\nmore code\n")
    repo.commit_all("work")
    return repo.head


def _mark_autofix(repo, hash_: str) -> None:
    repo.write(f".reviewer/outputs/autofix/{hash_}_verified.md", "")


def _mark_convo(repo, hash_: str) -> None:
    repo.write(f".reviewer/outputs/conversation/{hash_}.json", "")


def _mark_arch(repo, branch: str) -> None:
    repo.write(f".reviewer/outputs/architecture/{branch}.md", "")


# --- nothing satisfied -------------------------------------------------------
def test_blocks_and_prints_the_exact_gate_report_when_nothing_is_satisfied(repo):
    """Every gate blocks with no markers, and the block is a user-facing contract."""
    _setup(repo)

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2, "missing gates must block"
    assert "architecture verification (/verify-architecture)" in result.output
    assert "autofix (/autofix)" in result.output
    assert "conversation review (/verify-conversation)" in result.output
    assert result.output == """The following review gates have not been satisfied:
  - architecture verification (/verify-architecture)
  - autofix (/autofix)
  - conversation review (/verify-conversation)

Run these before finishing. Address any issues raised by /verify-architecture before running /autofix, since architecture changes may make autofix results obsolete. If possible, run /verify-conversation in the background while running the others.

Note: these gates may fire again after you make changes. /verify-conversation is incremental and only reviews new content. For /autofix, the default is to run the full check, but if your changes since the last autofix run are focused, you may pass instructions telling it to focus on the diff since the last run (while still providing the true base branch).""", "the gate report is a user-facing contract"


# --- everything satisfied ----------------------------------------------------
def test_passes_when_every_marker_is_present_for_the_hash_under_test(repo):
    hash_ = _setup(repo)
    _mark_autofix(repo, hash_)
    _mark_convo(repo, hash_)
    _mark_arch(repo, "feature")

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 0, "all markers present should pass"
    assert result.output == "", "a passing run says nothing"


def test_honors_an_explicit_hash_argument_over_head(repo):
    _setup(repo)
    _mark_autofix(repo, "deadbeef")
    _mark_convo(repo, "deadbeef")
    _mark_arch(repo, "feature")

    result = repo.run_script("stop_hook_gates.sh", "deadbeef")

    assert result.exit_code == 0, "markers for the passed hash should satisfy the gates"


# --- markers are per-commit ---------------------------------------------------
def test_stale_per_commit_markers_still_leave_architecture_satisfied(repo):
    """Markers for another hash re-require the per-commit gates, but architecture
    is keyed by branch, so a hash mismatch alone must not re-require it."""
    hash_ = _setup(repo)
    _mark_autofix(repo, hash_)
    _mark_convo(repo, hash_)
    _mark_arch(repo, "feature")

    result = repo.run_script("stop_hook_gates.sh", "deadbeef")

    assert result.exit_code == 2, "stale per-commit markers must not satisfy the gates"
    assert "autofix (/autofix)" in result.output
    assert "conversation review (/verify-conversation)" in result.output
    assert "architecture verification" not in result.output


def test_keys_architecture_by_branch_with_slashes_flattened_to_underscores(repo):
    hash_ = _setup(repo, "feat/nested")
    _mark_autofix(repo, hash_)
    _mark_convo(repo, hash_)
    _mark_arch(repo, "feat_nested")

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 0, "feat/nested should read .reviewer/outputs/architecture/feat_nested.md"


# --- one gate at a time -------------------------------------------------------
def test_architecture_satisfied_reports_only_the_others_and_drops_ordering_advice(repo):
    """Once architecture is done, its ordering advice (run it before autofix) is
    moot and must go with it."""
    _setup(repo)
    _mark_arch(repo, "feature")

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2
    assert "architecture verification" not in result.output
    assert "autofix (/autofix)" in result.output
    assert "conversation review (/verify-conversation)" in result.output
    assert "may make autofix results obsolete" not in result.output


def test_reports_only_the_others_when_autofix_is_satisfied(repo):
    hash_ = _setup(repo)
    _mark_autofix(repo, hash_)

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2
    assert "autofix (/autofix)" not in result.output
    assert "architecture verification (/verify-architecture)" in result.output
    assert "conversation review (/verify-conversation)" in result.output


def test_conversation_satisfied_reports_only_the_others_and_drops_background_advice(repo):
    """Once conversation review is done, the advice to run it in the background
    is moot and must go with it."""
    hash_ = _setup(repo)
    _mark_convo(repo, hash_)

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2
    assert "conversation review" not in result.output
    assert "architecture verification (/verify-architecture)" in result.output
    assert "autofix (/autofix)" in result.output
    assert "in the background while running the others" not in result.output


def test_omits_the_multi_gate_guidance_when_a_single_gate_remains(repo):
    hash_ = _setup(repo)
    _mark_arch(repo, "feature")
    _mark_convo(repo, hash_)

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2
    assert "autofix (/autofix)" in result.output
    assert "Run these before finishing." not in result.output


# --- config toggles ------------------------------------------------------------
@pytest.mark.parametrize(
    "disabled_key, mark_autofix, mark_convo, mark_arch, forbidden",
    [
        ("verify_conversation", True, False, True, "conversation review"),
        ("autofix", False, True, True, "autofix"),
        ("verify_architecture", True, True, False, "architecture verification"),
    ],
    ids=["conversation", "autofix", "architecture"],
)
def test_does_not_require_a_disabled_gate(repo, disabled_key, mark_autofix, mark_convo, mark_arch, forbidden):
    hash_ = _setup(repo)
    repo.settings({"stop_hook": {"base_branch": "main"}, disabled_key: {"is_enabled": False}})
    if mark_autofix:
        _mark_autofix(repo, hash_)
    if mark_convo:
        _mark_convo(repo, hash_)
    if mark_arch:
        _mark_arch(repo, "feature")

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 0, "a disabled gate must not be required"
    assert forbidden not in result.output


def test_passes_with_no_markers_at_all_when_every_gate_is_disabled(repo):
    _setup(repo)
    repo.settings(
        {
            "stop_hook": {"base_branch": "main"},
            "autofix": {"is_enabled": False},
            "verify_conversation": {"is_enabled": False},
            "verify_architecture": {"is_enabled": False},
        }
    )

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 0
    assert result.output == ""


def test_drops_the_repeat_firing_note_when_both_per_commit_gates_are_disabled(repo):
    _setup(repo)
    repo.settings(
        {
            "stop_hook": {"base_branch": "main"},
            "autofix": {"is_enabled": False},
            "verify_conversation": {"is_enabled": False},
        }
    )

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2, "architecture is still required"
    assert "architecture verification (/verify-architecture)" in result.output
    assert "these gates may fire again" not in result.output


def test_keeps_the_repeat_firing_note_while_a_per_commit_gate_is_enabled_but_satisfied(repo):
    hash_ = _setup(repo)
    _mark_autofix(repo, hash_)
    _mark_convo(repo, hash_)

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2, "architecture is still required"
    assert "these gates may fire again" in result.output


# --- prompt suffixes -------------------------------------------------------------
def test_appends_configured_arguments_to_the_suggested_commands(repo):
    _setup(repo)
    repo.settings(
        {
            "stop_hook": {"base_branch": "main"},
            "autofix": {"append_to_prompt": "--effort high"},
            "verify_conversation": {"append_to_prompt": "be brief"},
            "verify_architecture": {"append_to_prompt": "focus on layering"},
        }
    )

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2
    assert "architecture verification (/verify-architecture focus on layering)" in result.output
    assert "autofix (/autofix --effort high)" in result.output
    assert "conversation review (/verify-conversation be brief)" in result.output


# --- no code changes ---------------------------------------------------------
def test_skips_the_gates_when_nothing_changed_vs_the_base(repo):
    repo.settings({"stop_hook": {"base_branch": "main"}})
    repo.write("app.py", "code\n")
    repo.commit_all("init")
    repo.checkout_new("feature")

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 0, "an empty diff needs no review"
    assert result.output == ""


def test_still_checks_the_gates_when_the_base_branch_does_not_resolve(repo):
    _setup(repo)
    repo.settings({"stop_hook": {"base_branch": "trunk"}})

    result = repo.run_script("stop_hook_gates.sh")

    assert result.exit_code == 2, "an unresolvable base must not be read as an empty diff"
    assert "gates have not been satisfied" in result.output
