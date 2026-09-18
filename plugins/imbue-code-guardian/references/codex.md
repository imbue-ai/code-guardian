# Running the shared skills in Codex

Use the same review procedure, categories, and verification markers as Claude
Code. The differences below apply to every skill and to its delegated agents.

- Invoke skills as `$imbue-code-guardian:autofix`, `$imbue-code-guardian:verify-architecture`, or `$imbue-code-guardian:verify-conversation`.
  Slash-command references in the shared instructions refer to these skills.
- Resolve the plugin root from this skill's location: two directories above
  `skills/<name>/SKILL.md`. Substitute that absolute path for
  `${CLAUDE_PLUGIN_ROOT}` in shell examples and file references. Keep shell path
  arguments quoted, including after substituting the absolute path. Codex sets that
  environment variable for hooks, but it may not be set in agent shell tools.
- Use native Codex shell/file tools instead of Claude's Bash, Read, and Write.
  Create missing output directories before writing files. Treat allowed-tools
  frontmatter and `!` command substitutions as Claude-specific syntax; execute
  needed commands with Codex tools. `$ARGUMENTS` means the user's actual request.
- A named `Agent` means a fresh Codex subagent given the instructions from
  `<plugin-root>/agents/<name>.md`. Pass it the applicable guidance here and the
  inputs the skill requests. Use Codex's native spawn and wait tools. If those
  tools are unavailable, report that the independent review cannot run; do not
  replace it with self-review or write a pass marker.
- Inherit the current Codex model instead of requesting `haiku`, `opus`, or
  `opus[1m]`. The transcript size limit still applies; if the model cannot fit
  the selected transcripts, narrow the scope with the user before reviewing.
- Use the shared transcript discovery and filter scripts. They recognize Codex
  rollouts, including tool calls and messages received mid-turn. Do not pass a
  Codex transcript to an older Claude-only version of the filter.

Codex's default transcript sources are the current thread and earlier threads
recorded by this plugin's Stop hook in this checkout. The hook stores only
session identifiers and transcript paths in `.reviewer/outputs/codex/`, not
transcript copies. Before the first Stop, discovery uses `CODEX_THREAD_ID`
(or `CODEX_SESSION_ID`) and `CODEX_HOME` to find the current rollout.
When the skill runs in a background subagent, discovery follows its recorded
parent chain to the user-facing root conversation. A missing parent is an error;
the review must not silently substitute the reviewer's own conversation.

`include_all_agent_sessions` includes other top-level Codex sessions with the
same working directory, rather than every project in the shared Codex home.
`include_subagents` follows recorded parent-thread relationships recursively.
The `source` labels distinguish these transcripts from the user's current
conversation. A subagent's user-role messages are delegation inputs, not human
instructions. Missing current or tracked transcripts are review errors.
