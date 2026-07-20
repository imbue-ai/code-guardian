---
name: reviewer-autofix-all-issues
description: Configure autofix to fix all issues (unattended mode)
allowed-tools: Bash(jq *)
---

This gate is configured per reviewed directory. By default it edits the **root** repo's `.reviewer/settings.local.json`. If the user named a target directory below, edit that directory's `.reviewer/settings.local.json` instead: prefix each `.reviewer/settings.local.json` path in the command with `<dir>/`. Each reviewed repo (the root plus any `stop_hook.additional_git_directories`) keeps its own local settings.

Target directory (optional):

$ARGUMENTS

Run this command:

```bash
jq -n --argjson existing "$(cat .reviewer/settings.local.json 2>/dev/null || echo '{}')" '$existing * {"autofix": {"append_to_prompt": "Please autofix as normal, except: Never ask questions. You are running unattended and the user is not there to answer your questions. Instead, think hard about whether to accept each given patch. If you decide *not* to accept it, then create a *new* branch with that fix commit. Call the branch (current_branch_name)___(fix_description) *and be sure to push it remotely* then by sure to check the normal branch back out when you'\''re done. Also be sure to tell the user that you did this."}}' > .reviewer/settings.local.json.tmp && mv .reviewer/settings.local.json.tmp .reviewer/settings.local.json
```

Then confirm that autofix has been configured to fix all issues.
