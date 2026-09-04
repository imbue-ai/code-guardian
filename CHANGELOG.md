# Changelog

Notable changes to the `imbue-code-guardian` plugin. The version is the `version`
field in `plugins/imbue-code-guardian/.claude-plugin/plugin.json`; Claude Code caches
each version separately, so a release is a version bump plus a merge to `main`.

This file starts at 0.5.0. For earlier releases, read the git history.

## [0.5.0]

### Changed

- **Conversation review now defaults to the session it is scoped to.** `verify_conversation.include_all_agent_sessions`
  and `verify_conversation.include_subagents` both changed from `true` to `false`. The gate previously
  reviewed every transcript in the whole `~/.claude/projects` tree, plus every subagent transcript
  under each -- on one machine, 680 files and 34MB, well past the skill's own 3MB refusal threshold.
  It now reviews the current session, plus the tracked session chain for the task when running under
  mngr. Set either key back to `true` in `.reviewer/settings.json` to restore the old scope; a repo
  that already sets them explicitly is unaffected, since a default only applies when the key is absent.

  `include_subagents` is off for a second reason beyond volume: in a subagent transcript the `[user]`
  record is never a person. The first is the parent agent's spawn prompt and the rest are almost
  entirely tool results, while the issue categories are written in terms of what "the user" said.

- `/verify-conversation`'s argument examples now state what is included by default, and cover
  widening the scope as well as narrowing it.

### Fixed

- **Messages sent mid-turn were invisible to the conversation reviewer.** Text typed while the
  assistant was working is recorded as a `queued_command` attachment, not a `user` record, and its
  text lives under a different key. The filter dropped it entirely -- so an assistant that changed
  course on a correction looked like it had deviated on its own. These now render as `[steering]`,
  in position within the turn.

- **Machine-written records were attributed to the user.** Harness task notifications, system
  reminders, stop-hook feedback, and messages relayed from other agents all rendered as `[user]`.
  Sender is now read from `origin.kind` and `isMeta`, which name the author positively: harness
  notes and relayed peer messages carry their own `[harness-note]` and `[peer-message]` tags, and
  task notifications are held back unless `--task-notifications` asks for them.

- The current session could not be found outside mngr: the `current` source keyed only on
  `$MNGR_CLAUDE_SESSION_ID`. It now falls back to `$CLAUDE_CODE_SESSION_ID`, which Claude Code sets
  natively.

- `filter_transcript.py` aborted the whole run on a record whose `origin` was not an object, losing
  the entire transcript rather than one line.

- A `user` record carrying an attachment rendered the attachment's metadata in place of the user's
  own words.

- `--help` printed no usage text at all.

- `--all` silently dropped every attachment record, despite claiming to show everything. Attachment
  payloads are now shown, capped at 200 characters like other payloads, with the cut marked. Steering
  text is exempt from the cap and never truncated.

- `test_multi_dir_stop_hook.sh` failed 14 of 75 checks on any machine: the bare origin the fixture
  builds was created without `-b main`, so its HEAD pointed at an unborn `master` and the four
  scenarios that clone it got an empty working tree.

### Added

- `tests/test_filter_transcript.py` -- 53 checks over a synthetic transcript, run with
  `python3 tests/test_filter_transcript.py`. No pytest dependency.

- `--task-notifications` flag on `filter_transcript.py`, to include the subagent completion notices
  that are hidden by default.
