"""Claude transcript discovery tests. Run: python3 -m unittest discover -s tests -p test_export_transcript_paths.py"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "plugins/imbue-code-guardian/scripts/export_transcript_paths.sh"


class ClaudeAgentDirTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="guardian claude ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.home = self.root / "home"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("CODEX_", "CODE_GUARDIAN_", "CLAUDE_", "MNGR_", "INCLUDE_"))}
        self.env.update(HOME=str(self.home), CODE_GUARDIAN_HARNESS="claude",
                        CLAUDE_CODE_SESSION_ID="current-session",
                        INCLUDE_CURRENT="true", INCLUDE_TRACKED="true",
                        INCLUDE_AGENT_DIR="true", INCLUDE_SUBAGENTS="false")

    def session(self, config_dir, project, sid):
        path = config_dir / "projects" / project / f"{sid}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{"type":"user","message":{"content":"hello"}}\n')
        return path

    def run_script(self):
        return subprocess.run(["bash", str(SCRIPT)], text=True, capture_output=True,
                              cwd=self.repo, env=self.env, timeout=20)

    def test_default_config_dir_is_not_scanned(self):
        default_dir = self.home / ".claude"
        current = self.session(default_dir, "this-repo", "current-session")
        self.session(default_dir, "this-repo", "earlier-session")
        self.session(default_dir, "unrelated-repo", "unrelated-session")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"current\t{current}\n")
        self.assertIn("CLAUDE_CONFIG_DIR", result.stderr)

    def test_explicit_config_dir_is_scanned(self):
        config_dir = self.root / "agent config"
        self.env["CLAUDE_CONFIG_DIR"] = str(config_dir)
        current = self.session(config_dir, "this-repo", "current-session")
        earlier = self.session(config_dir, "this-repo", "earlier-session")
        other_worktree = self.session(config_dir, "other-worktree", "resumed-session")
        self.session(self.home / ".claude", "unrelated-repo", "unrelated-session")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            f"current\t{current}", f"agent_dir\t{other_worktree}", f"agent_dir\t{earlier}",
        ])
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
