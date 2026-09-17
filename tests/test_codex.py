"""Codex hook, discovery, and rollout tests. Run: python3 -m unittest discover -s tests -p test_codex.py"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[1] / "plugins/imbue-code-guardian"
SCRIPTS = PLUGIN / "scripts"


class CodexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="guardian codex ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.home = self.root / "codex home"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("CODEX_", "CODE_GUARDIAN_", "CLAUDE_", "MNGR_", "INCLUDE_", "PLUGIN_"))}
        self.env.update(CODEX_HOME=str(self.home), CODEX_THREAD_ID="parent",
                        INCLUDE_CURRENT="true", INCLUDE_TRACKED="true",
                        INCLUDE_AGENT_DIR="false", INCLUDE_SUBAGENTS="false")

    def run_script(self, name, *args, input="", env=None, cwd=None):
        return subprocess.run(
            ["bash" if name.endswith(".sh") else "python3", str(SCRIPTS / name), *args],
            input=input, text=True, capture_output=True, cwd=cwd or self.repo,
            env=env or self.env, timeout=20,
        )

    def rollout(self, sid, cwd=None, parent=None, archived=False):
        path = self.home / ("archived_sessions" if archived else "sessions/2026/09/17") / f"rollout-date-{sid}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        meta = {"id": sid, "cwd": str(cwd or self.repo), "source": "cli"}
        if parent:
            meta["source"] = {"subagent": {"thread_spawn": {"parent_thread_id": parent}}}
        path.write_text(json.dumps({"type": "session_meta", "payload": meta}) + "\n")
        return path

    def track(self, sid, path):
        target = self.repo / ".reviewer/outputs/codex" / f"{sid}.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps({"session_id": sid, "transcript_path": str(path)}))

    def test_default_sources_include_current_and_tracked_only(self):
        current = self.rollout("parent")
        tracked = self.rollout("previous", archived=True)
        self.rollout("unrelated", cwd=self.root)
        self.track("parent", current)
        self.track("previous", tracked)
        result = self.run_script("export_transcript_paths.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [f"current\t{current}", f"tracked\t{tracked}"])

    def test_hook_path_takes_precedence_over_rollout_filename(self):
        path = self.rollout("nonstandard-filename")
        self.track("parent", path)
        result = self.run_script("export_transcript_paths.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"current\t{path}\n")

    def test_all_sessions_stays_in_checkout_and_children_are_recursive(self):
        current = self.rollout("parent")
        sibling = self.rollout("sibling")
        child = self.rollout("child", cwd=self.root, parent="parent")
        grandchild = self.rollout("grandchild", parent="child")
        self.rollout("other", cwd=self.root)
        self.rollout("other-child", parent="other")
        self.env.update(INCLUDE_AGENT_DIR="true", INCLUDE_SUBAGENTS="true")
        result = self.run_script("export_transcript_paths.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(result.stdout.splitlines()), {
            f"current\t{current}", f"agent_dir\t{sibling}",
            f"current:subagent\t{child}", f"current:subagent\t{grandchild}",
        })

    def test_missing_current_fails_without_partial_output(self):
        result = self.run_script("export_transcript_paths.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("unavailable", result.stderr)

    def test_missing_tracked_fails_without_partial_output(self):
        self.rollout("parent")
        self.track("missing", self.root / "absent")
        result = self.run_script("export_transcript_paths.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Tracked", result.stderr)

    def test_explicit_current_exclusion_does_not_require_current_transcript(self):
        self.env.update(INCLUDE_CURRENT="false")
        previous = self.rollout("previous")
        self.track("previous", previous)
        result = self.run_script("export_transcript_paths.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"tracked\t{previous}\n")

    def test_codex_filter_retains_provenance_order_and_line_numbers(self):
        payloads = [
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "please fix it"}]},
            {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "working"}]},
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "a hook reminder"}],
             "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["hook.feedback"]}},
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "actually stop"}],
             "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["user.text"]}},
            {"type": "function_call", "name": "exec_command", "arguments": '{"cmd":"pwd"}'},
            {"type": "custom_tool_call", "name": "exec", "input": "text(42)"},
            {"type": "custom_tool_call_output", "output": "tool result"},
            {"type": "reasoning", "summary": [{"type": "summary_text", "text": "thinking"}]},
        ]
        raw = "\n".join(json.dumps({"type": "response_item", "payload": p}) for p in payloads) + "\n"
        result = self.run_script("filter_transcript.py", "--json", input=raw)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([(r["line"], r["type"], r["text"]) for r in records], [
            (1, "user", "please fix it"), (2, "assistant", "working"),
            (3, "harness-note", "a hook reminder"), (4, "user", "actually stop"),
        ])
        all_result = self.run_script("filter_transcript.py", "--all", input=raw)
        self.assertIn("[exec_command]", all_result.stdout)
        self.assertIn("[exec] text(42)", all_result.stdout)
        self.assertIn("[tool_result]", all_result.stdout)
        self.assertIn("[thinking]", all_result.stdout)
        size = self.run_script("filter_transcript.py", "--all", "--size", input=raw)
        self.assertEqual(int(size.stdout), len(all_result.stdout.encode()))

    def init_repo(self, enabled=True):
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        settings = self.repo / ".reviewer/settings.json"
        settings.parent.mkdir(exist_ok=True)
        settings.write_text(json.dumps({"stop_hook": {"enabled_when": "true" if enabled else "false"}}))
        self.env["PLUGIN_ROOT"] = str(PLUGIN)
        self.payload = json.dumps({"cwd": str(self.repo), "session_id": "parent", "transcript_path": str(self.rollout("parent"))})

    def test_native_hook_blocks_dirty_worktree_and_records_transcript(self):
        self.init_repo()
        result = self.run_script("stop_hook.sh", input=self.payload, cwd=self.root)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("Uncommitted changes", result.stderr)
        record = json.loads((self.repo / ".reviewer/outputs/codex/parent.json").read_text())
        self.assertEqual(record, json.loads(self.payload))

    def test_disabled_hook_does_not_write_state(self):
        self.init_repo(enabled=False)
        result = self.run_script("stop_hook.sh", input=self.payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.repo / ".reviewer/outputs").exists())

    def test_native_hook_skips_non_git_session(self):
        self.env["PLUGIN_ROOT"] = str(PLUGIN)
        result = self.run_script("stop_hook.sh", input=json.dumps({"cwd": str(self.repo)}))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_native_input_blocks(self):
        self.env["PLUGIN_ROOT"] = str(PLUGIN)
        result = self.run_script("stop_hook.sh", input="not json")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_gate_feedback_uses_native_skill_names(self):
        manifest = self.root / "manifest"
        manifest.write_text(".\tdeadbeef\tfeature\ttrue\n")
        self.env["CODE_GUARDIAN_HARNESS"] = "codex"
        result = self.run_script("stop_hook_gates.sh", str(manifest))
        self.assertEqual(result.returncode, 2, result.stderr)
        for name in ("autofix", "verify-architecture", "verify-conversation"):
            self.assertIn(f"$imbue-code-guardian:{name}", result.stderr)

    def test_claude_entry_point_preserves_disabled_behavior(self):
        result = self.run_script("stop_hook.sh", input="{}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
