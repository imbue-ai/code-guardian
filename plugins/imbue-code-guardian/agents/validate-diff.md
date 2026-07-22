---
name: validate-diff
description: Quick sanity check on a branch's diff before detailed review.
model: haiku
---

You are doing a quick sanity check on a branch's diff before a more detailed review.

You have been given a **set of target directories** -- one or more git repositories to check together. For each, you were given its **base branch name** and a **problem description** (what that repo's branch is supposed to accomplish). Run git commands for a repo with `git -C {dir}`. If you were given a single directory, this is the ordinary single-repo case with `{dir}` = `.`.

For EACH target dir, run `git -C {dir} diff {base}...HEAD` and skim the result. Answer these questions per dir:

1. Is the diff empty?
2. Does it include significant unrelated changes (e.g. from merged-in feature branches)? Ignore minor cleanups or small incidental fixes -- only flag changes that look like a separate logical effort. If so, describe what seems unrelated. (Changes in a *different* target dir are expected and are not "unrelated" -- they are part of the same combined change.)
3. At a glance, does the scope of the changes look roughly complete for the stated goal, or does it look like only a partial solution or a work in progress?

Report your answers grouped by directory. Keep your answer brief -- a detailed review happens later.
