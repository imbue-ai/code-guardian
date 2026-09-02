#!/usr/bin/env python3
"""Unit test for filter_transcript.py.

Builds a synthetic transcript covering the record shapes that a real session
produces, then checks what the filter surfaces at each flag setting.

Run: python3 tests/test_filter_transcript.py

Verifies:
  1. Ordinary user and assistant turns are shown by default
  2. Steering messages (mid-turn user text) are shown by default, in position
  3. Peer-agent messages are shown by default and labeled distinctly
  4. Subagent completion notices are hidden by default, shown with --task-notifications
  5. Attachments that are not queued commands stay hidden by default, and are
     shown with their subtype under --all
  6. A mid-turn message with no recorded sender is shown but not attributed to the user
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FILTER = REPO_ROOT / "plugins" / "imbue-code-guardian" / "scripts" / "filter_transcript.py"

RECORDS = [
    {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "do the thing"}]}},
    {
        "type": "assistant",
        "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]},
    },
    {"type": "attachment", "attachment": {"type": "total_tokens_reminder", "text": "<total_tokens>5</total_tokens>"}},
    {
        "type": "attachment",
        "attachment": {
            "type": "queued_command",
            "prompt": "actually, stop doing that",
            "commandMode": "prompt",
            "origin": {"kind": "human"},
        },
    },
    {
        "type": "attachment",
        "attachment": {
            "type": "queued_command",
            "prompt": "<task-notification>subagent finished</task-notification>",
            "commandMode": "task-notification",
        },
    },
    {
        "type": "attachment",
        "attachment": {
            "type": "queued_command",
            "prompt": "heads up from your fork",
            "commandMode": "prompt",
            "origin": {"kind": "peer", "from": "uds:/tmp/sock"},
        },
    },
    # No `origin`, and not a task notification: sender unknown. Real sessions do not
    # currently produce this shape, but a reader must not fill the gap with "the user".
    {
        "type": "attachment",
        "attachment": {
            "type": "queued_command",
            "prompt": "message from nobody in particular",
            "commandMode": "prompt",
        },
    },
    {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "ok, stopped"}]}},
]

PASS = 0
FAIL = 0


def _check(name, condition):
    global PASS, FAIL
    if condition:
        print(f"  PASS {name}")
        PASS += 1
    else:
        print(f"  FAIL {name}")
        FAIL += 1


def _run(path, *flags):
    result = subprocess.run(
        [sys.executable, str(FILTER), *flags, str(path)], capture_output=True, text=True, check=True
    )
    return result.stdout


def main():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "session.jsonl"
        path.write_text("\n".join(json.dumps(record) for record in RECORDS) + "\n")

        default = _run(path)
        _check("user turn shown", "do the thing" in default)
        _check("assistant turn shown", "ok, stopped" in default)
        _check("steering message shown", "[steering]\tactually, stop doing that" in default)
        _check("peer message shown", "[peer-message]\theads up from your fork" in default)
        _check("task notification hidden", "subagent finished" not in default)

        # Sender is read from origin.kind, never inferred from what is missing: an
        # unsigned message is surfaced, but under its own label rather than [steering].
        _check(
            "unsigned message shown",
            "[queued-message]\tmessage from nobody in particular" in default,
        )
        _check("unsigned message not called steering", "[steering]\tmessage from nobody" not in default)
        _check("unrelated attachment hidden", "total_tokens" not in default)

        # The steering message must land between the tool call it interrupted and the
        # reply that followed it, so a reviewer can see what prompted the change of course.
        _check(
            "steering message keeps its position",
            default.index("[Bash] ls") < default.index("actually, stop") < default.index("ok, stopped"),
        )

        with_notifications = _run(path, "--task-notifications")
        _check("task notification shown with flag", "subagent finished" in with_notifications)
        _check(
            "task notification not called steering",
            "[task-notification]\t<task-notification>subagent finished" in with_notifications,
        )

        every = _run(path, "--all")
        _check("--all includes steering", "actually, stop doing that" in every)
        _check("--all includes other attachments", "total_tokens" in every)
        _check("--all labels the attachment subtype", "[attachment:total_tokens_reminder]" in every)

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
