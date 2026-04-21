---
name: reviewer-blocking-enable
description: Restore the stop hook to blocking mode (default: block up to 3 times before letting through)
allowed-tools: Bash(jq *)
---

Run this command to remove the max_consecutive_blocks override, restoring the default (3):

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" '$existing | if .stop_hook then .stop_hook |= del(.max_consecutive_blocks) | if .stop_hook == {} then del(.stop_hook) else . end else . end' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that the stop hook has been restored to blocking mode (default: 3 consecutive blocks before safety hatch).
