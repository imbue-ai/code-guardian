# imbue-code-guardian-opencode

OpenCode port of [imbue-code-guardian](../imbue-code-guardian/README.md).
Same scope as the [codex port](../imbue-code-guardian-codex/README.md) —
enforcement gate only, not the reviews themselves.

**Off by default**, same convention as the claude plugin.

## Install

OpenCode has no curated plugin marketplace — its own docs confirm the
`plugin` config array sources from npm, so that's the idiomatic
distribution channel here (this is the most-confirmed of the three ports,
since it matches OpenCode's actual, documented convention rather than an
inferred/unverified command). Once published to npm:

```jsonc
// opencode.json
{
  "plugin": ["imbue-code-guardian-opencode"]
}
```

## Mechanism

OpenCode's plugin `Hooks` interface has no event that can block or force a
session to continue — confirmed by reading the actual typed interface, not
assumed. The only related hook, `event`, is purely observational (no
output channel). So this port is structurally different from the
codex/antigravity ones, which use a real blocking `Stop` hook:

- On `session.idle` (root session only), it runs the bundled
  `stop_hook_gates.sh` directly.
- If gates aren't satisfied, it uses the plugin's live SDK `client` (given
  to every opencode plugin) to call `client.session.promptAsync` and inject
  the same reason text back into the session — a real, generated/versioned
  SDK API, not a workaround built on scraped internals.
- A flag file (`.reviewer/outputs/.opencode_last_nagged_head`), keyed on
  the current commit hash, ensures each commit is nagged at most once no
  matter how many times the session goes idle without `HEAD` moving —
  without this, the injected prompt making the session busy again could
  re-trigger the same idle event indefinitely.

**Path handling**: this package's bundled `scripts/config_utils.sh` /
`scripts/stop_hook_gates.sh` are resolved via `import.meta.dir` (this
module's own installed location), not the user's project directory — so
they resolve correctly regardless of where npm installs this package,
unlike referencing the user's own `directory` for script paths (which
would only happen to work if a project's own tree already contained
copies, which isn't guaranteed for an npm-installed package).

## Known gaps / unverified

- Only the gate-check is ported, not the actual reviews.
- `session.idle` is one confirmed event name with no fallback. If a future
  opencode version renames it, this plugin silently stops firing rather
  than breaking anything.
- `client.session.promptAsync`'s exact shape was confirmed against the
  installed SDK's generated type definitions, not exercised end-to-end
  against a live opencode server in this change.
