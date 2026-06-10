---
name: reviewer-disable
description: Disable the code review stop hook entirely by short-circuiting stop_hook.enabled_when in .reviewer/settings.local.json.
allowed-tools: Bash(jq *)
---

Disables the master switch (`stop_hook.enabled_when`) by rewriting it as
`false && (<original>)`, so the orchestrator exits immediately.
`reviewer-enable` (no args) restores the original expression.
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
