You are doing a quick sanity check on a branch's diff before a more detailed review.

You have been given:
- A **base branch name** (for the git diff command)
- A **problem description** (what the branch is supposed to accomplish)

Run `git diff {base}...HEAD` and skim the result. Answer these questions:

1. Is the diff empty?
2. Does it include significant unrelated changes? This includes changes brought in by merge commits (e.g. merging another feature branch or the base branch), even if those merges were intentional -- they are still unrelated to this branch's stated goal. Also run `git log --merges --oneline {base}...HEAD` and note any merge commits. Ignore minor cleanups or small incidental fixes -- only flag changes that look like a separate logical effort. If so, describe what seems unrelated and how it got there.
3. At a glance, does the scope of the changes look roughly complete for the stated goal, or does it look like only a partial solution or a work in progress?

Keep your answer brief -- a detailed review happens later.
