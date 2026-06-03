---
name: reviewer-disable
description: Disable the code review stop hook entirely by short-circuiting stop_hook.enabled_when in .reviewer/settings.local.json. Also skips the base-branch fetch/merge.
allowed-tools: Bash(jq *)
---

Disables the master switch (`stop_hook.enabled_when`) by prefixing it with
`false && `, so the orchestrator exits immediately -- before any base-branch
fetch/merge or gate checks. The original expression is preserved after the
prefix, so `reviewer-enable` (no args) can strip it and restore the prior state.
A re-disable is a no-op (it won't stack the prefix), and an empty expression is
simply set to `false`.

Run this command:

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" '
  ($existing.stop_hook.enabled_when // "") as $cur
  | $existing * {"stop_hook": {"enabled_when": (
      if $cur == "" or $cur == "false" then "false"
      elif ($cur | startswith("false && ")) then $cur
      else "false && " + $cur
      end
    )}}
' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that the stop hook has been disabled entirely.
