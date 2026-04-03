---
name: autofix
description: Automatically find and fix code issues in the current branch. Iteratively verifies, plans fixes, and implements them with separate commits. Defers all review to the end.
allowed-tools: Bash:*, Read, Write, Agent, AskUserQuestion
---

# Autofix

Iteratively verify the current branch for code issues, plan and implement fixes (each in a separate commit), and repeat until clean. At the end, present each fix for user review and revert any the user does not want.

## Instructions

### Phase 1: Setup

- Initial HEAD (`initial_head`): !`git rev-parse HEAD`

Determine the base branch: check the GIT_BASE_BRANCH environment variable. If it is set, use its value. Otherwise default to main.

If you do not already know what the changes on this branch are supposed to accomplish, STOP and ask the user before continuing.

Write a brief description of what the branch is trying to do. This helps the diff validation and fix agents distinguish intentional changes from issues.

### Phase 2: Validate the Diff

Read the diff validation prompt from [../validate-diff.md](../validate-diff.md). Spawn an Agent (`subagent_type: "general-purpose"`, `model: "haiku"`) with that prompt, providing the base branch name and the problem description.

Based on the agent's response:
- If the diff is empty, STOP and ask the user whether the work has been committed yet or whether the base branch is wrong.
- If it reports significant unrelated changes, STOP and ask the user. This includes cases where the branch has diverged from the base branch due to merges or other work -- even if the extra changes are "expected," they are not in scope. Proceeding with out-of-scope changes wastes context and causes the fix agent to review and potentially "fix" irrelevant code. There is no valid reason to skip this step. The available remedies are: (1) check whether a different base branch produces a clean diff (e.g., if the branch merged in another feature branch, that feature branch may be a better base), (2) ask the user for the correct base branch, or (3) ask the user which changes to focus on (then explicitly tell the fix agent to ignore the rest). Note that sometimes no clean merge base exists -- e.g., the merged branch was based on an older main, so comparing to either base shows unrelated changes. In that case, ask the user.
- If it reports the work looks incomplete, note this but proceed -- autofix works on whatever is there.

### Phase 3: Fix Loop

Create the .autofix/plans directory if it does not already exist.

Repeat up to 10 times:

1. Record the current HEAD as `pre_iteration_head`.
2. Read the supporting file [verify-and-fix.md](verify-and-fix.md) from this skill's directory. Spawn a single Agent (`subagent_type: "general-purpose"`) with its contents as the prompt. Prepend the line `Base branch for this project: {base_branch}` to the prompt.

4. After the agent finishes, check if HEAD moved: compare `git rev-parse HEAD` to `pre_iteration_head`.
5. If HEAD did not move, no fixes were made. The branch is clean (or remaining issues are unfixable). Stop looping.
6. If HEAD moved, continue to the next iteration.

Important:
- Do NOT explore code, plan, or fix anything yourself. The agent does all the work.
- Each iteration gets a fresh-context agent, which is the whole point.
- Do NOT pass the agent any information about previous iterations or previous fixes. It operates from a clean slate every time.

### Phase 4: Review

After the loop ends:

1. Collect all fix commits: `git log --reverse --format="%H %s" {initial_head}..HEAD`
2. If there are no new commits, report that no issues were found and provide a brief description of what the agent found.
3. Check if `.autofix/config/auto-accept.md` exists. If it does, read it. This file contains free-text rules describing which kinds of fixes should be automatically accepted without prompting the user (e.g. "accept all naming fixes", "auto-accept anything in test files").
4. For each commit, check its full commit message against the auto-accept rules. If a commit matches, keep it automatically — do not ask the user about it.
5. Ask about the remaining commits in a single `AskUserQuestion` call. Use one question per commit (up to 4 per call; if there are more than 4 commits, use multiple calls but still gather all answers before doing any git operations). Each question should:
   - Show the full commit message (which contains the problem and the fix).
   - Options: "Keep" and "Revert"
6. Only after ALL answers have been collected, revert the rejected commits. Run `git revert --no-edit {hash}` for each, in reverse chronological order (newest first) to avoid conflicts.
7. Report the final summary: how many fixes kept (noting which were auto-accepted), how many reverted.

