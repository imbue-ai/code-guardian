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
  5. Attachments that are not queued commands stay hidden by default, and are shown
     with their subtype under --all, including ones whose payload sits under no
     recognized text key -- capped, so one bulky record cannot swamp the output
  6. A mid-turn message with no recorded sender is shown but not attributed to the user
  7. A record whose sender field is malformed is surfaced rather than crashing the run
  8. A record's text always comes from whatever the line is labeled as
  9. A malformed attachment is skipped rather than crashing the run
 10. --size and --total-size agree with the output they claim to measure, which is
     what the verify-conversation skill picks a model off
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
    # Several real subtypes keep nothing under a text-ish key at all; --all still owes
    # the reader the record rather than an empty line that the filter then skips.
    {"type": "attachment", "attachment": {"type": "bash_output_audience_note", "toolUseID": "toolu_abc"}},
    # An attachment that is not an object at all: nothing to render, and nothing to crash on.
    {"type": "attachment", "attachment": "oops"},
    # Same fallback, but a subtype whose payload is a whole file body.
    {"type": "attachment", "attachment": {"type": "nested_memory", "path": "sub/CLAUDE.md", "content": {"body": "z" * 5000}}},
    # A record labeled `user` must render the user's own words, whatever else it carries.
    {
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": "and check the logs"}]},
        "attachment": {"type": "file", "filename": "irrelevant.txt"},
    },
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
    # `origin` is a dict in every shape the harness records today. A reader of a
    # long-lived on-disk format still cannot assume that: one unreadable record must
    # not take the rest of the transcript down with it.
    {
        "type": "attachment",
        "attachment": {
            "type": "queued_command",
            "prompt": "message with an unreadable origin",
            "commandMode": "prompt",
            "origin": "human",
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


def _run(path, *flags, stdin_text=None):
    argv = [sys.executable, str(FILTER), *flags]
    if path is not None:
        argv.append(str(path))
    result = subprocess.run(argv, input=stdin_text, capture_output=True, text=True, check=True)
    return result.stdout


def main():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "session.jsonl"
        path.write_text("\n".join(json.dumps(record) for record in RECORDS) + "\n")

        default = _run(path)
        _check("user turn shown", "do the thing" in default)
        _check("assistant turn shown", "ok, stopped" in default)
        _check(
            "user turn carrying an attachment shows the user's text",
            "[user]\tand check the logs" in default and "irrelevant.txt" not in default,
        )
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
        _check(
            "malformed origin does not crash the run",
            "[queued-message]\tmessage with an unreadable origin" in default,
        )
        _check("unrelated attachment hidden", "total_tokens" not in default and "toolu_abc" not in default)

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
        _check(
            "--all includes an attachment with no text key",
            "[attachment:bash_output_audience_note]" in every and "toolu_abc" in every,
        )
        _check(
            "--all caps a bulky attachment payload",
            "[attachment:nested_memory]" in every and "...(truncated)" in every and "z" * 400 not in every,
        )
        _check("malformed attachment does not crash --all", "oops" not in every)

        # The verify-conversation skill picks the reviewer's model off --total-size, so the
        # count has to track the output it claims to measure -- _compute_filtered_size
        # reimplements the main loop's filtering and can drift from it.
        size = int(_run(path, "--size").strip())
        _check("--size counts the bytes it emits", size == len(default.encode("utf-8")))
        _check(
            "--total-size reads plain paths from stdin",
            int(_run(None, "--total-size", stdin_text=f"{path}\n").strip()) == size,
        )
        _check(
            "--total-size reads the source-tagged paths the discovery script emits",
            int(_run(None, "--total-size", stdin_text=f"current\t{path}\n").strip()) == size,
        )

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
