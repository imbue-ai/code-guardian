"""Claude Code Stop hook entry point tests. Run: python3 -m unittest discover -s tests -p test_stop_hook_entrypoint.py"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ENTRYPOINT = Path(__file__).resolve().parents[1] / "plugins/imbue-code-guardian/scripts/stop_hook_entrypoint.sh"


class ClaudeStopHookEntrypointTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="guardian entrypoint ")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / "untracked.py").write_text("x = 1\n")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("CODEX_", "CODE_GUARDIAN_", "CLAUDE_", "MNGR_", "PLUGIN_"))}
        self.env["CLAUDE_PROJECT_DIR"] = str(self.repo)

    def write_settings(self, enabled_when, name="settings.json"):
        settings = self.repo / ".reviewer" / name
        settings.parent.mkdir(exist_ok=True)
        # No fetch, merge or CI, so an enabled run stays local and stops at the dirty worktree
        settings.write_text(json.dumps({
            "stop_hook": {"enabled_when": enabled_when, "fetch_and_merge": False, "require_committed": True},
            "ci": {"is_enabled": False},
        }))

    def run_hook(self, env=None, cwd=None):
        return subprocess.run(
            ["bash", str(ENTRYPOINT)], input="{}", text=True, capture_output=True,
            cwd=cwd or self.repo, env=env or self.env, timeout=20,
        )

    def assert_skipped(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse((self.repo / ".reviewer/logs").exists())

    def test_switched_off_hook_runs_nothing_but_bash_and_jq(self):
        self.write_settings("false")
        tools = self.root / "only bash and jq"
        tools.mkdir()
        for tool in ("bash", "jq"):
            (tools / tool).symlink_to(shutil.which(tool))
        self.assert_skipped(self.run_hook(env={**self.env, "PATH": str(tools)}))

    def test_enabled_when_that_evaluates_false_skips_the_review(self):
        self.write_settings('test -n "${GUARDIAN_TEST_UNSET_VARIABLE:-}"')
        self.assert_skipped(self.run_hook())

    def test_env_override_switches_off_a_hook_the_settings_enable(self):
        self.write_settings("true")
        self.assert_skipped(self.run_hook(env={**self.env, "CODE_GUARDIAN_STOP_HOOK__ENABLED_WHEN": "false"}))

    def test_switched_off_hook_reads_the_project_dir_not_the_cwd(self):
        self.write_settings("false")
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        self.assert_skipped(self.run_hook(cwd=elsewhere))

    def test_local_override_that_enables_the_hook_still_reviews(self):
        self.write_settings("false")
        self.write_settings("true", name="settings.local.json")
        result = self.run_hook()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Uncommitted changes", result.stderr)


if __name__ == "__main__":
    unittest.main()
