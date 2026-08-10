---
name: reviewer-autofix-enable
description: Enable the autofix gate in .reviewer/settings.local.json
allowed-tools: Bash(jq *)
---

This gate is configured per reviewed directory. By default it edits the **root** repo's `.reviewer/settings.local.json`. If the user named a target directory below, edit that directory's `.reviewer/settings.local.json` instead: prefix each `.reviewer/settings.local.json` path in the command with `<dir>/`. Each reviewed repo (the root plus any `stop_hook.additional_git_directories`) keeps its own local settings.

Target directory (optional):

$ARGUMENTS

Run this command:

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" '$existing * {"autofix": {"is_enabled": true}}' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that the autofix gate has been enabled.
