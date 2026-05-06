#!/usr/bin/env python3
"""Detect which tools the assistant used since the most recent human turn.

Reads a Claude Code session transcript (JSONL) and prints, one per line, the
unique set of tool_use names that appear in assistant messages after the most
recent human user turn. A "human user turn" is a user message whose content
does not consist entirely of tool_result blocks (tool results come back as
synthetic user messages, but a real human turn has plain-text content).

Usage:
    detect_tools_used.py <transcript.jsonl>

Exit codes:
    0 -- success (output written even if empty)
    1 -- transcript not found, unreadable, or malformed beyond recovery
"""

import json
import sys
from pathlib import Path


def _content_blocks(message):
    if not isinstance(message, dict):
        return []
    content = message.get("content", [])
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return content
    return []


def _is_human_user_turn(obj):
    """Return True if obj is a user message representing a real human turn.

    Synthetic user messages carrying tool_result blocks are not human turns;
    they are continuations of the assistant's prior turn.
    """
    msg = obj.get("message", {})
    if not isinstance(msg, dict) or msg.get("role") != "user":
        return False
    blocks = _content_blocks(msg)
    if not blocks:
        return False
    for block in blocks:
        if isinstance(block, dict) and block.get("type") == "tool_result":
            return False
    return True


def _assistant_tool_names(obj):
    msg = obj.get("message", {})
    if not isinstance(msg, dict) or msg.get("role") != "assistant":
        return []
    names = []
    for block in _content_blocks(msg):
        if isinstance(block, dict) and block.get("type") == "tool_use":
            name = block.get("name")
            if isinstance(name, str) and name:
                names.append(name)
    return names


def main():
    if len(sys.argv) != 2:
        print("usage: detect_tools_used.py <transcript.jsonl>", file=sys.stderr)
        sys.exit(1)

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"transcript not found: {path}", file=sys.stderr)
        sys.exit(1)

    records = []
    with path.open() as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                records.append(json.loads(raw))
            except json.JSONDecodeError:
                continue

    last_human_idx = -1
    for idx in range(len(records) - 1, -1, -1):
        if _is_human_user_turn(records[idx]):
            last_human_idx = idx
            break

    seen = []
    for obj in records[last_human_idx + 1:]:
        for name in _assistant_tool_names(obj):
            if name not in seen:
                seen.append(name)

    for name in seen:
        print(name)


if __name__ == "__main__":
    main()
