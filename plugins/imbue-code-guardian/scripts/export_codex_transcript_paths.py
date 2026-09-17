#!/usr/bin/env python3
"""Discover Codex rollouts for the current task, without scanning Claude sessions."""

import json
import os
import sys
from pathlib import Path


def session_metadata(path):
    with path.open() as stream:
        record = json.loads(stream.readline())
    if record.get("type") != "session_meta":
        raise ValueError(f"No Codex session metadata in {path}")
    return record["payload"]


def parent_id(meta):
    source = meta.get("source")
    if isinstance(source, dict):
        subagent = source.get("subagent", {})
        if isinstance(subagent, dict):
            spawn = subagent.get("thread_spawn", {})
            if isinstance(spawn, dict):
                return spawn.get("parent_thread_id")
    return None


def discover():
    session_id = os.environ.get("CODEX_THREAD_ID") or os.environ.get("CODEX_SESSION_ID")
    home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    records = Path(".reviewer/outputs/codex")
    include_current = os.environ["INCLUDE_CURRENT"] == "true"
    include_tracked = os.environ["INCLUDE_TRACKED"] == "true"
    include_all = os.environ["INCLUDE_AGENT_DIR"] == "true"
    include_children = os.environ["INCLUDE_SUBAGENTS"] == "true"
    paths = {}

    def locate(sid):
        record = records / f"{sid}.json"
        if record.is_file():
            path = json.loads(record.read_text()).get("transcript_path")
            if path and Path(path).is_file():
                return Path(path)
        for directory in (home / "sessions", home / "archived_sessions"):
            matches = sorted(directory.rglob(f"*-{sid}.jsonl"))
            if matches:
                return matches[0]
        return None

    if include_current:
        if not session_id or not (current := locate(session_id)):
            raise ValueError("Current Codex transcript is unavailable; conversation review cannot pass.")
        session_metadata(current)
        paths[current] = "current"

    if include_tracked:
        for record in sorted(records.glob("*.json")):
            sid = record.stem
            if sid == session_id:
                continue
            path = locate(sid)
            if path is None:
                raise ValueError(f"Tracked Codex transcript is unavailable: {sid}")
            session_metadata(path)
            paths.setdefault(path, "tracked")

    if include_all or include_children:
        rollouts = {}
        for directory in (home / "sessions", home / "archived_sessions"):
            for path in sorted(directory.rglob("*.jsonl")):
                try:
                    meta = session_metadata(path)
                except (OSError, ValueError, KeyError):
                    continue
                rollouts[path] = meta
                # A shared Codex home holds unrelated projects, unlike mngr's private home.
                if include_all and not parent_id(meta) and meta.get("cwd"):
                    if Path(meta["cwd"]).resolve() == Path.cwd().resolve():
                        paths.setdefault(path, "agent_dir")
        if include_children:
            parents = {}
            for path, source in paths.items():
                meta = session_metadata(path)
                parents[meta.get("id") or meta.get("session_id")] = source
            while True:
                added = False
                for path, meta in rollouts.items():
                    parent = parent_id(meta)
                    if path not in paths and parent in parents:
                        source = parents[parent].split(":")[0] + ":subagent"
                        paths[path] = source
                        parents[meta.get("id") or meta.get("session_id")] = source
                        added = True
                if not added:
                    break

    for path, source in paths.items():
        print(f"{source}\t{path}")


if __name__ == "__main__":
    try:
        discover()
    except (OSError, ValueError, KeyError) as error:
        print(f"Codex transcript discovery failed: {error}", file=sys.stderr)
        sys.exit(1)
