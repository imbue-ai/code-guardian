---
name: reviewer-blocking-disable
description: Make the stop hook non-blocking (remind once, then let the agent through)
allowed-tools: Bash(jq *)
---

Run this command:

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" '$existing * {"stop_hook": {"max_consecutive_blocks": 1}}' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that the stop hook has been set to non-blocking mode (remind once, then let through).
