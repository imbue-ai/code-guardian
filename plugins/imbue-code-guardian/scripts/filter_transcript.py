#!/usr/bin/env python3
"""Filter and format Claude Code session transcript JSONL files.

Reads a JSONL transcript file and outputs a filtered, human-readable view
with line numbers. The line numbers correspond to the original JSONL file,
so you can use `sed -n '<N>p' <file>` to get the raw JSON for any line.

Default output shows user and assistant messages, plus text that arrived mid-turn
while the assistant was working -- steering from the user, or a message from a peer
agent. Use flags to include other message types.

Usage:
    filter_transcript.py [options] <file.jsonl>
    cat <file.jsonl> | filter_transcript.py [options]

Examples:
    # Default: user, assistant and mid-turn messages, with line numbers
    filter_transcript.py session.jsonl

    # Include tool results
    filter_transcript.py --tool-results session.jsonl

    # Include subagent completion notifications
    filter_transcript.py --task-notifications session.jsonl

    # Include everything
    filter_transcript.py --all session.jsonl

    # Raw JSON output instead of formatted text
    filter_transcript.py --json session.jsonl

    # Size estimate (bytes of filtered output)
    filter_transcript.py --size session.jsonl
"""

import argparse
import json
import sys

# How much of a payload that is shown for diagnosis rather than read as conversation
# (a tool result, an attachment under --all) is worth printing.
PREVIEW_LIMIT = 200


def _preview(text):
    """Abridge a payload that is shown for diagnosis rather than read as conversation."""
    if len(text) <= PREVIEW_LIMIT:
        return text
    return text[:PREVIEW_LIMIT] + " ...(truncated)"


def extract_text(content):
    """Extract readable text from a message content field."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text":
                text = item.get("text", "")
                if text.strip():
                    parts.append(text)
            elif item.get("type") == "tool_result":
                # Show tool result content if it's text
                result_content = item.get("content", "")
                if isinstance(result_content, str) and result_content.strip():
                    parts.append(f"[tool_result] {result_content[:PREVIEW_LIMIT]}")
            elif item.get("type") == "tool_use":
                name = item.get("name", "?")
                inp = item.get("input", {})
                if isinstance(inp, dict):
                    # Show command for Bash, file_path for Read/Write, pattern for Grep
                    detail = inp.get("command", inp.get("file_path", inp.get("pattern", "")))
                    if detail:
                        parts.append(f"[{name}] {detail[:PREVIEW_LIMIT]}")
                    else:
                        parts.append(f"[{name}]")
                else:
                    parts.append(f"[{name}]")
        return "\n".join(parts)
    return ""


# Senders that `origin.kind` names positively as somebody other than the user, and the
# tag each one gets. `human` is the user and is handled per record form; a kind that is
# missing or unrecognized identifies nobody and must never be resolved by elimination --
# the harness's own task notifications used to carry no `origin` at all, so "unmarked" is
# as much the machine's signature as the user's.
NON_USER_SENDERS = {
    "peer": "peer-message",
    "coordinator": "peer-message",
    "task-notification": "task-notification",
}


def get_origin_kind(record):
    """Read the sender named by a record's (or an attachment payload's) `origin` field."""
    origin = record.get("origin")
    return origin.get("kind") if isinstance(origin, dict) else None


def classify_queued_command(attachment):
    """Map a `queued_command` attachment to a message type.

    Text that arrives while the assistant is already working -- a steering message
    from the user, a message from a peer agent, or a subagent completion notice -- is
    recorded as an `attachment` record with a `queued_command` payload, NOT as a
    `user` message, and its text lives under `attachment.prompt` rather than
    `message.content`. A reader that only walks user/assistant records drops it
    silently, which makes the assistant look like it changed course for no reason.

    Anything that identifies no sender is reported as `queued-message` -- still shown,
    since dropping conversational text is the worse error, but never attributed to the
    user.
    """
    kind = get_origin_kind(attachment)
    if kind == "human":
        return "steering"
    if kind in NON_USER_SENDERS:
        return NON_USER_SENDERS[kind]
    if attachment.get("commandMode") == "task-notification":
        return "task-notification"
    return "queued-message"


def classify_user_record(obj):
    """Map a record delivered in the `user` role to a message type.

    The `user` role is a slot in the API conversation, not a claim about authorship:
    subagent completion notices and messages relayed from another agent are delivered in
    it too, and name themselves in the same top-level `origin.kind` a queued command uses.
    Tagging those `[user]` invites a reader to hold the user answerable for text the
    machine wrote. A record that names no sender stays `user`, since most of what the
    user actually types carries no `origin` either.
    """
    return NON_USER_SENDERS.get(get_origin_kind(obj), "user")


def get_message_type(obj):
    """Determine the message type from a JSONL object."""
    # Top-level type field
    msg_type = obj.get("type", "")

    if msg_type == "attachment":
        attachment = obj.get("attachment")
        if not isinstance(attachment, dict):
            return msg_type
        if attachment.get("type") == "queued_command":
            return classify_queued_command(attachment)
        # Tag the subtype so --all output distinguishes e.g. hook results from file reads
        return "attachment:%s" % attachment.get("type", "?")

    # Check nested message type
    message = obj.get("message", {})
    if isinstance(message, dict):
        role = message.get("role", "")
        if role == "user":
            return classify_user_record(obj)
        if role == "assistant":
            return role

    # Check for content with tool_result (user turn with tool results)
    if msg_type == "user":
        return classify_user_record(obj)

    return msg_type


def get_content(obj):
    """Extract the content field from a JSONL object."""
    # Attachments carry their payload under a different key than ordinary messages, and
    # which key varies by subtype. Read it only for records the classifier also treats as
    # attachments, so that the text shown always comes from whatever the line is labeled as.
    if obj.get("type") == "attachment":
        attachment = obj.get("attachment")
        if isinstance(attachment, dict):
            # A queued command is conversation and shows by default, so it is rendered
            # whole -- real steering messages run to tens of thousands of characters and
            # abridging one would hide what the user asked for. Every other subtype is
            # diagnostic filler that only --all asks for, and several (a skill listing, an
            # edited file body) are large enough that one record would swamp the output.
            verbatim = attachment.get("type") == "queued_command"
            for key in ("prompt", "text", "snippet", "content"):
                value = attachment.get(key)
                if isinstance(value, str) and value.strip():
                    return value if verbatim else _preview(value)
            # No recognized text key: dump the payload so that --all, which claims to
            # include everything, does not lose the record to the empty-text guard.
            dumped = json.dumps({k: v for k, v in attachment.items() if k != "type"})
            return dumped if verbatim else _preview(dumped)

    # Try message.content first (standard format)
    message = obj.get("message", {})
    if isinstance(message, dict):
        content = message.get("content")
        if content is not None:
            return content

    # Fall back to top-level content
    return obj.get("content", "")


def should_include(msg_type, args):
    """Decide whether to include a message based on its type and flags."""
    if args.all:
        return True

    if msg_type in ("user", "assistant", "steering", "peer-message", "queued-message"):
        return True
    if msg_type == "task-notification" and args.task_notifications:
        return True
    if msg_type == "tool_use" and args.tool_use:
        return True
    if msg_type == "tool_result" and args.tool_results:
        return True
    if msg_type == "thinking" and args.thinking:
        return True
    if msg_type == "system" and args.system:
        return True
    if msg_type == "progress" and args.progress:
        return True

    return False


def format_line(line_num, msg_type, text, use_json, show_line_numbers=True):
    """Format a single output line."""
    if use_json:
        record = {"type": msg_type, "text": text}
        if show_line_numbers:
            record["line"] = line_num
        return json.dumps(record)

    # Indent continuation lines
    if show_line_numbers:
        prefix = f"L{line_num}\t[{msg_type}]\t"
        indent = "\t\t\t"
    else:
        prefix = f"[{msg_type}]\t"
        indent = "\t\t"
    lines = text.split("\n")
    if len(lines) == 1:
        return f"{prefix}{lines[0]}"
    else:
        formatted = [f"{prefix}{lines[0]}"]
        for continuation in lines[1:]:
            formatted.append(f"{indent}{continuation}")
        return "\n".join(formatted)


def _compute_filtered_size(path, args):
    """Compute the filtered output size in bytes for a single file."""
    total = 0
    with open(path) as f:
        for line_num, raw_line in enumerate(f, start=1):
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                obj = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            msg_type = get_message_type(obj)
            if not should_include(msg_type, args):
                continue
            content = get_content(obj)
            text = extract_text(content)
            if not text.strip():
                continue
            output = format_line(line_num, msg_type, text, args.json, show_line_numbers=not args.no_line_numbers)
            total += len(output.encode("utf-8")) + 1
    return total


def main():
    parser = argparse.ArgumentParser(description="Filter and format Claude Code session transcript JSONL files.")
    parser.add_argument("file", nargs="?", help="JSONL file to filter (reads stdin if omitted)")
    parser.add_argument("--tool-use", action="store_true", help="Include tool_use messages")
    parser.add_argument("--tool-results", action="store_true", help="Include tool_result messages")
    parser.add_argument("--thinking", action="store_true", help="Include thinking messages")
    parser.add_argument("--system", action="store_true", help="Include system messages")
    parser.add_argument("--progress", action="store_true", help="Include progress messages")
    parser.add_argument(
        "--task-notifications",
        action="store_true",
        help="Include subagent completion notifications (queued mid-turn, but machine-generated)",
    )
    parser.add_argument("--all", action="store_true", help="Include all message types")
    parser.add_argument("--json", action="store_true", help="Output as JSON instead of formatted text")
    parser.add_argument("--no-line-numbers", action="store_true", help="Omit line numbers")
    parser.add_argument("--size", action="store_true", help="Only output total byte count of filtered output")
    parser.add_argument(
        "--total-size",
        action="store_true",
        help="Read file paths (one per line, optionally tab-prefixed) from stdin and print total filtered size",
    )
    args = parser.parse_args()

    if args.total_size:
        total = 0
        for line in sys.stdin:
            # Support both plain paths and "source\tpath" format from export_transcript_paths.sh
            parts = line.strip().split("\t")
            path = parts[-1]
            if not path:
                continue
            try:
                total += _compute_filtered_size(path, args)
            except (FileNotFoundError, PermissionError):
                pass
        print(total)
        return

    if args.file:
        try:
            infile = open(args.file)
        except FileNotFoundError:
            print(f"File not found: {args.file}", file=sys.stderr)
            sys.exit(1)
    else:
        infile = sys.stdin

    total_size = 0
    try:
        for line_num, raw_line in enumerate(infile, start=1):
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                obj = json.loads(raw_line)
            except json.JSONDecodeError:
                continue

            msg_type = get_message_type(obj)
            if not should_include(msg_type, args):
                continue

            content = get_content(obj)
            text = extract_text(content)
            if not text.strip():
                continue

            output = format_line(line_num, msg_type, text, args.json, show_line_numbers=not args.no_line_numbers)

            if args.size:
                total_size += len(output.encode("utf-8")) + 1  # +1 for newline
            else:
                print(output)

    finally:
        if args.file and infile is not sys.stdin:
            infile.close()

    if args.size:
        print(total_size)


if __name__ == "__main__":
    main()
