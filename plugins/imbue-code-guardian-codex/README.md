# imbue-code-guardian-codex

Codex port of [imbue-code-guardian](../imbue-code-guardian/README.md). Covers
the enforcement gate only: a `Stop` hook blocks the session from finishing
until autofix, architecture verification, and conversation review have run
(tracked via marker files under `.reviewer/outputs/`, same as the claude
plugin). It does **not** run those reviews itself yet — the skills that do
(`/autofix`, `/verify-conversation`, `/verify-architecture` in the claude
plugin) are genuinely Claude-Code-specific orchestration (spawn sub-agents
by name via Claude's own Agent/Task tool, use Claude's `` !`command` ``
inline-bash frontmatter execution) and need rewriting in codex's own
subagent-spawning idiom, not a straight port. Until that exists, a blocked
codex agent is told what's missing but not how to run it via codex-native
commands.

**Off by default**, same convention as the claude plugin: nothing happens
until `.reviewer/settings.json`'s `stop_hook.enabled_when` is set (see the
claude plugin's `reviewer-enable` skill for the settings shape — no codex
equivalent skill exists yet, so set it directly for now).

## Install

```
codex plugin marketplace add imbue-ai/code-guardian
codex plugin install imbue-code-guardian-codex@imbue-code-guardian
```

## What's ported

- `scripts/config_utils.sh`, `scripts/stop_hook_gates.sh` — verbatim
  copies of the claude plugin's own files. Both are already
  harness-agnostic (pure bash, marker-file checks, no Claude-specific
  paths) — zero changes needed.
- `scripts/reviewer_stop.sh` — new; adds the `enabled_when` gate
  `stop_hook_gates.sh` itself doesn't check, then calls it directly.
  codex's `Stop` hook accepts the same exit-code-2 + stderr-reason
  contract as claude's, confirmed via developers.openai.com/codex/hooks,
  so no output-format translation was needed.
- `hooks/hooks.json` — wires the above to codex's `Stop` event, using
  `${PLUGIN_ROOT}` (confirmed real, per developers.openai.com/codex/plugins/build
  — codex also accepts `${CLAUDE_PLUGIN_ROOT}` for backward compatibility,
  but the native name is used here).

## Known gaps / unverified

- Only the gate-check is ported, not the actual reviews (see above).
- `${PLUGIN_ROOT}` resolution and the `Stop` hook's exit-code-2 fallback
  are documented but not exercised against a live codex session in this
  change — review-and-static-validation only (bash syntax checked, JSON
  validated, the `enabled_when` gating logic tested standalone).
