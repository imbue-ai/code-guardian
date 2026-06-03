---
name: reviewer-disable
description: Disable the code review stop hook entirely by clearing stop_hook.enabled_when in .reviewer/settings.local.json. Inverse of reviewer-enable; also skips the base-branch fetch/merge.
allowed-tools: Bash(jq *)
---

Clears the master switch (`stop_hook.enabled_when`), so the orchestrator exits
immediately -- before any base-branch fetch/merge or gate checks. Exact inverse
of `reviewer-enable`.

Run this command:

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" '$existing * {"stop_hook": {"enabled_when": ""}}' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that the stop hook has been disabled entirely.
