---
name: reviewer-disable
description: Disable the code review stop hook entirely by short-circuiting stop_hook.enabled_when in .reviewer/settings.local.json.
allowed-tools: Bash(jq *)
---

Disables the master switch (`stop_hook.enabled_when`) by rewriting it as
`false && (<original>)`, so the orchestrator exits immediately. The original
expression is wrapped in parentheses — without them, an expression containing
`||` (e.g. `a || b`) would become `false && a || b`, which parses as
`(false && a) || b` and would *not* be disabled. The parenthesized original is
preserved after the prefix, so `reviewer-enable` (no args) can strip it and
restore the prior state.
A re-disable is a no-op (it won't stack the prefix), and an empty expression is
simply set to `false`.

Run this command:

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" '
  ($existing.stop_hook.enabled_when // "") as $cur
  | $existing * {"stop_hook": {"enabled_when": (
      if $cur == "" or $cur == "false" then "false"
      elif ($cur | startswith("false && (")) then $cur
      else "false && (" + $cur + ")"
      end
    )}}
' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that the stop hook has been disabled entirely.
