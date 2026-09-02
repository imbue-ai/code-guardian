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
     recognized text key -- capped under every key get_content reads, so one bulky
     record cannot swamp the output, while conversational text is never abridged
  6. A mid-turn message with no recorded sender is shown but not attributed to the user
  7. A record whose sender field is malformed is surfaced under a neutral label
  8. A record's text always comes from whatever the line is labeled as
  9. Every run over the fixture exits cleanly, so no malformed record crashes the
     filter, and a tool argument that is not a string is rendered rather than sliced
 10. --size and --total-size agree with the output they claim to measure, which is
     what the verify-conversation skill picks a model off
 11. A message delivered in the `user` role is tagged by the sender it names, so a
     notification or another agent's message is not attributed to the user
 12. A note the harness wrote into the user's slot is tagged as such, and an `origin`
     naming a sender outranks that mark in both directions
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
    # Synthetic: no real record carries both a `message` and an `attachment`, in either
    # direction. It pins the gate that keeps get_content reading an attachment payload only
    # for records the classifier also labels from one, so that the text on a line always
    # comes from whatever that line is labeled as.
    {
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": "and check the logs"}]},
        "attachment": {"type": "file", "filename": "irrelevant.txt"},
    },
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
    # The bulkiest real subtypes do keep their payload under a recognized key -- just not
    # under `text`: a skill listing keeps it under `content`, an edited file under
    # `snippet`. Between them and the reminder above, every key get_content prefers is
    # exercised by the subtype that actually uses it. Being readable is no reason to
    # escape the cap.
    {"type": "attachment", "attachment": {"type": "skill_listing", "content": "y" * 5000, "skillCount": 3}},
    {"type": "attachment", "attachment": {"type": "edited_text_file", "filename": "a.py", "snippet": "s" * 5000}},
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
    # Steering is conversation, not filler: real ones reach tens of thousands of
    # characters, and abridging one would hide what the user asked for.
    {
        "type": "attachment",
        "attachment": {
            "type": "queued_command",
            "prompt": "one long thought: " + "w" * 5000,
            "commandMode": "prompt",
            "origin": {"kind": "human"},
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
    # The same senders also deliver text in the `user` role, naming themselves in a
    # top-level `origin` rather than inside an attachment payload.
    {
        "type": "user",
        "message": {"role": "user", "content": "<task-notification>run 2 finished</task-notification>"},
        "origin": {"kind": "task-notification"},
        "isMeta": True,
        "promptSource": "system",
    },
    {
        "type": "user",
        "message": {"role": "user", "content": "Another Claude session sent a message: rebased for you"},
        "origin": {"kind": "peer", "from": "general-purpose"},
        "isMeta": True,
    },
    {
        "type": "user",
        "message": {"role": "user", "content": "The coordinator sent a message while you were working"},
        "origin": {"kind": "coordinator"},
        "isMeta": True,
    },
    # Notes the harness writes into the user's slot on nobody's behalf: hook feedback,
    # system reminders, local-command caveats, skill preambles. They carry the same
    # `isMeta` mark and no `origin`, and are the bulk of what wears it.
    {
        "type": "user",
        "message": {"role": "user", "content": "Stop hook feedback: the reviewer found 2 issues"},
        "isMeta": True,
    },
    # The harness also wraps a message the user sends mid-turn, and marks the wrapper --
    # but names the user in `origin`, which outranks the mark.
    {
        "type": "user",
        "message": {"role": "user", "content": "The user sent a new message while you were working: use the other branch"},
        "origin": {"kind": "human"},
        "isMeta": True,
    },
    {
        "type": "user",
        "message": {"role": "user", "content": "and one more thing"},
        "origin": {"kind": "human"},
        "promptSource": "typed",
    },
    # A tool result comes back in the `user` slot. Like any other payload shown for
    # diagnosis, a long one is abridged -- and has to say so, or it reads as the whole
    # result.
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "r" * 5000}]}},
    # These three keys hold a string for every tool that has one, but nothing stops a tool
    # from taking a structured argument under the same name.
    {
        "type": "assistant",
        "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Grep", "input": {"pattern": ["a", "b"]}}]},
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


def _line_with(output, needle):
    """Return the one output line containing `needle`, or "" if there is not exactly one."""
    matches = [line for line in output.split("\n") if needle in line]
    return matches[0] if len(matches) == 1 else ""


def _run(path, *flags, stdin_text=None):
    """Run the filter over the fixture and return its stdout.

    A crash is reported as a failed check rather than raised, so one malformed-record
    regression does not take the rest of the suite's report down with it.
    """
    argv = [sys.executable, str(FILTER), *flags]
    if path is not None:
        argv.append(str(path))
    result = subprocess.run(argv, input=stdin_text, capture_output=True, text=True)
    _check(
        f"the filter survives the whole fixture with {' '.join(flags) or 'no flags'}",
        result.returncode == 0 and not result.stderr,
    )
    return result.stdout


def main():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "session.jsonl"
        path.write_text("\n".join(json.dumps(record) for record in RECORDS) + "\n")

        default = _run(path)
        _check("user turn shown", "do the thing" in default)
        _check("assistant turn shown", "ok, stopped" in default)
        _check(
            "a line's text comes from the payload it is labeled from",
            "[user]\tand check the logs" in default and "irrelevant.txt" not in default,
        )
        _check("steering message shown", "[steering]\tactually, stop doing that" in default)
        _check("a long steering message is never abridged", "one long thought: " + "w" * 5000 in default)
        _check("peer message shown", "[peer-message]\theads up from your fork" in default)
        _check("task notification hidden", "subagent finished" not in default)

        # An abridged payload has to be distinguishable from a complete one, whichever
        # kind of payload it is.
        _check(
            "a long tool result says that it was abridged",
            _line_with(default, "[tool_result] ").endswith(" ...(truncated)"),
        )
        _check("a long tool result is capped", "r" * 400 not in default)
        _check("a structured tool argument is rendered", '[Grep] ["a", "b"]' in default)

        # Sender is read from origin.kind, never inferred from what is missing: an
        # unsigned message is surfaced, but under its own label rather than [steering].
        _check(
            "unsigned message shown",
            "[queued-message]\tmessage from nobody in particular" in default,
        )
        _check("unsigned message not called steering", "[steering]\tmessage from nobody" not in default)
        _check(
            "a malformed sender field names nobody",
            "[queued-message]\tmessage with an unreadable origin" in default,
        )
        _check("unrelated attachment hidden", "total_tokens" not in default and "toolu_abc" not in default)

        # The `user` role is a delivery slot, not a claim of authorship: the same senders
        # that queue text mid-turn also speak in it, and must keep their own labels there.
        _check("delivered notification hidden", "run 2 finished" not in default)
        _check(
            "delivered peer message not attributed to the user",
            "[peer-message]\tAnother Claude session sent a message: rebased for you" in default,
        )
        _check(
            "coordinator message not attributed to the user",
            "[peer-message]\tThe coordinator sent a message while you were working" in default,
        )
        _check("a signed human turn is still the user", "[user]\tand one more thing" in default)

        # The harness writes into the user's slot too, and marks what it writes `isMeta`.
        # Those notes are shown -- a reviewer needs to see the hook feedback an assistant
        # was answering -- but never over the user's signature.
        _check(
            "a harness note is not attributed to the user",
            "[harness-note]\tStop hook feedback: the reviewer found 2 issues" in default,
        )
        _check("a harness note is not called user", "[user]\tStop hook feedback" not in default)
        _check(
            "a marked wrapper around the user's own words is still the user",
            "[user]\tThe user sent a new message while you were working: use the other branch" in default,
        )
        _check(
            "a marked wrapper around a peer's words is still the peer",
            "[peer-message]\tAnother Claude session sent a message: rebased for you" in default,
        )

        # The steering message must land between the tool call it interrupted and the
        # reply that followed it, so a reviewer can see what prompted the change of course.
        _check(
            "steering message keeps its position",
            default.index("[Bash] ls") < default.index("actually, stop") < default.index("ok, stopped"),
        )

        with_notifications = _run(path, "--task-notifications")
        _check("task notification shown with flag", "subagent finished" in with_notifications)
        _check(
            "task notification carries its own tag",
            "[task-notification]\t<task-notification>subagent finished" in with_notifications,
        )
        _check(
            "a delivered notification is gated by the same flag",
            "[task-notification]\t<task-notification>run 2 finished" in with_notifications,
        )
        # The flag reveals one message type. A gate that returns True whenever the flag is
        # set turns it into --all, and every positive check above still passes.
        _check(
            "--task-notifications reveals nothing else",
            "total_tokens" not in with_notifications and "toolu_abc" not in with_notifications,
        )

        every = _run(path, "--all")
        _check("--all includes steering", "actually, stop doing that" in every)
        # The payload has to follow the tag directly: when get_content finds no key it
        # recognizes it dumps the whole payload as JSON, which still contains the text and
        # so satisfies a bare substring check.
        _check(
            "--all includes other attachments",
            "[attachment:total_tokens_reminder]\t<total_tokens>5</total_tokens>" in every,
        )
        _check("--all labels the attachment subtype", "[attachment:total_tokens_reminder]" in every)
        _check(
            "--all includes an attachment with no text key",
            "[attachment:bash_output_audience_note]" in every and "toolu_abc" in every,
        )
        _check(
            "--all caps a bulky attachment payload",
            "[attachment:nested_memory]" in every and "...(truncated)" in every and "z" * 400 not in every,
        )
        _check(
            "--all caps a bulky payload that sits under `content`",
            "[attachment:skill_listing]\ty" in every and "y" * 400 not in every,
        )
        _check(
            "--all caps a bulky payload that sits under `snippet`",
            "[attachment:edited_text_file]\ts" in every and "s" * 400 not in every,
        )
        _check("a non-dict attachment renders nothing rather than its raw value", "oops" not in every)

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
