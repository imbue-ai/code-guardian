"""Base branch resolution in stop_hook_orchestrator.sh (Step 5).

The failure these cover: when the base ref could not be resolved, the
docs-only check saw an empty diff and skipped every gate on a branch full
of code.
"""

from __future__ import annotations

BLOCK_TRACKER = ".reviewer/outputs/stop_hook_consecutive_blocks"


def _setup(repo, base_branch: str = "main") -> None:
    repo.settings(
        {
            "stop_hook": {
                "enabled_when": "true",
                "base_branch": base_branch,
                "fetch_and_merge": False,
                "require_committed": True,
                "skip_informational": True,
                "max_consecutive_blocks": 3,
            },
            "ci": {"is_enabled": False},
        }
    )
    repo.write("app.py", "code\n")
    repo.commit_all("init")
    repo.checkout_new("feature")


def _append(repo, rel: str, line: str) -> None:
    repo.write(rel, repo.read(rel) + line + "\n")


# --- unresolvable base -------------------------------------------------------
def test_unresolvable_base_exits_1_non_blocking_and_does_not_skip_or_count(repo):
    _setup(repo, "trunk")
    _append(repo, "app.py", "more code")
    repo.commit_all("work")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 1, "unresolvable base should exit 1, not block or skip"
    assert "Cannot resolve base branch 'trunk'" in result.output
    assert "docs-only" not in result.output
    assert not repo.exists(BLOCK_TRACKER), "must not count a non-blocking exit against the stuck hatch"


# --- local base, no remote ---------------------------------------------------
def test_local_base_fallback_reaches_gates_and_counts_toward_hatch(repo):
    _setup(repo, "main")
    _append(repo, "app.py", "more code")
    repo.commit_all("work")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 2, "real code changes must reach the gates"
    assert "gates have not been satisfied" in result.output
    assert repo.exists(BLOCK_TRACKER), "a blocking exit should count against the stuck hatch"


# --- docs-only still skips ---------------------------------------------------
def test_docs_only_diff_still_skips_the_gates(repo):
    _setup(repo, "main")
    repo.write("README.md", "# doc\n")
    repo.commit_all("docs")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 0, "docs-only should skip cleanly"
    assert "docs-only" in result.output


# --- empty diff still skips ---------------------------------------------------
def test_empty_diff_still_skips_the_gates(repo):
    _setup(repo, "main")

    result = repo.run_script("stop_hook_orchestrator.sh")

    assert result.exit_code == 0, "empty diff should skip cleanly"
