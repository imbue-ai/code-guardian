# imbue-code-guardian-antigravity

Antigravity port of [imbue-code-guardian](../imbue-code-guardian/README.md).
Same scope as the [codex port](../imbue-code-guardian-codex/README.md) —
enforcement gate only, not the reviews themselves. See that README for the
full explanation of why (applies identically here).

**Off by default**, same convention as the claude plugin.

## Install

```
agy plugin install imbue-code-guardian-antigravity@<marketplace>
```

**Honesty note on this install line**: antigravity's third-party plugin
publishing docs (antigravity.google/docs/cli-plugins) did not render
usable content for this change (JS-rendered page, fetched empty). What's
confirmed instead, empirically, against a real local `agy` install:

- `agy plugin validate <path>` — real command, used to validate this
  plugin's structure during development (passed: `plugin.json` + root
  `hooks.json`, both required at plugin root, not nested — confirmed by
  iterating on the validator's own error messages, not by guessing).
- `agy plugin install <target>` and `agy plugin link <marketplace> <target>`
  are real commands (`agy plugin --help`), but the exact end-to-end flow
  for registering *this* plugin under a specific marketplace name has not
  been exercised — `agy plugin import claude` (which sounded like it might
  auto-convert an existing Claude-Code-formatted plugin) was tested and
  does not do that; it looks for locally-configured claude extensions,
  found none, and did nothing with this repo's claude plugin. Treat the
  install line above as the closest correct shape, not a confirmed
  end-to-end verified command — needs a maintainer with a real
  marketplace-publishing setup to confirm/fix.

## What's ported

- `scripts/config_utils.sh`, `scripts/stop_hook_gates.sh` — verbatim
  copies, unmodified (see the codex README — same reasoning).
- `scripts/reviewer_stop.sh` — adds the `enabled_when` gate, then wraps
  `stop_hook_gates.sh`'s exit-code + stderr result in antigravity's JSON
  `Stop` contract: `{"decision": "continue", "reason": ...}` blocks the
  stop and re-enters the loop (no confirmed bare exit-code fallback for
  antigravity, unlike codex).
- `hooks.json` — bare (unwrapped) `{"Stop": [...]}`, confirmed to be the
  correct plugin-level shape via `agy plugin validate` (the workspace-level
  `.agents/hooks.json` convention wraps hooks in a named group; the
  plugin-level file does not — these are two different formats, confirmed
  by testing both against the real validator).

## Known gaps / unverified

- Only the gate-check is ported, not the actual reviews.
- The relative path `./scripts/reviewer_stop.sh` in `hooks.json` passed
  structural validation but its runtime resolution (does antigravity run
  hook commands with cwd set to the plugin's own directory, the way the
  structure implies, or does it need an explicit plugin-root variable the
  way codex does?) has not been confirmed against a live running session.
