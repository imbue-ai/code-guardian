---
name: reviewer-enable
description: Enable the code review stop hook in .reviewer/settings.local.json. Optionally takes a shell expression for when to enforce (defaults to restoring the prior expression, or always).
argument-hint: [shell_expression]
allowed-tools: Bash(jq *)
---

The user may provide a shell expression as an argument.

**If an expression is provided**, set `enabled_when` to it directly:

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" --arg expr "<expression>" '$existing * {"stop_hook": {"enabled_when": $expr}}' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Examples of expressions the user might provide:
- `true` -- always enforce
- `test -n "${CI:-}"` -- only in CI environments
- `test "$(git rev-parse --abbrev-ref HEAD)" != "main"` -- only on feature branches

**If no expression is provided**, strip a leading `false && (` and the trailing
`)` left by `reviewer-disable` to restore the prior expression; otherwise default
to `true`:

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" '
  ($existing.stop_hook.enabled_when // "") as $cur
  | $existing * {"stop_hook": {"enabled_when": (
      if ($cur | startswith("false && (")) then ($cur | ltrimstr("false && (") | rtrimstr(")"))
      else "true"
      end
    )}}
' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that the stop hook has been enabled and show the configured expression.
