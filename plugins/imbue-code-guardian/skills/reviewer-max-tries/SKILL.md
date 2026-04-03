---
name: reviewer-max-tries
description: Set the maximum number of times the stop hook will block before letting the agent through
allowed-tools: Bash(jq *)
args: N
---

The user should provide a number N as an argument. If they didn't, ask them for it.

Run this command (replacing $N with the user's value):

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" --argjson n $N '$existing * {"stop_hook": {"max_consecutive_blocks": $n}}' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that the stop hook max consecutive blocks has been set to the requested value.
