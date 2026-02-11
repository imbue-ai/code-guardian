---
name: autofix
description: Automatically find and fix code issues in the current branch. Iteratively verifies, plans fixes, and implements them with separate commits. Defers all review to the end.
allowed-tools: Bash:*, Read, Write, Task, AskUserQuestion
---

# Autofix

Iteratively verify the current branch for code issues, plan and implement fixes (each in a separate commit), and repeat until clean. At the end, present each fix for user review and revert any the user does not want.

## Instructions

### Phase 1: Setup

1. Determine the base branch from `$GIT_BASE_BRANCH` (fall back to `main`).
2. Record the current HEAD: `git rev-parse HEAD`. Save this as `initial_head`.
3. Create a working directory for plans: `mkdir -p .autofix/plans`

### Phase 2: Fix Loop

Repeat up to 10 times:

1. Record the current HEAD as `pre_iteration_head`.
2. Read the supporting file [verify-and-fix.md](verify-and-fix.md) from this skill's directory. Spawn a single Task subagent (`subagent_type: "general-purpose"`) with its contents as the prompt. Prepend the line `Base branch for this project: {base_branch}` to the prompt.

4. After the subagent finishes, check if HEAD moved: compare `git rev-parse HEAD` to `pre_iteration_head`.
5. If HEAD did not move, no fixes were made. The branch is clean (or remaining issues are unfixable). Stop looping.
6. If HEAD moved, continue to the next iteration.

Important:
- Do NOT explore code, plan, or fix anything yourself. The subagent does all the work.
- Each iteration gets a fresh-context subagent, which is the whole point.
- Do NOT pass the subagent any information about previous iterations or previous fixes. It operates from a clean slate every time.

### Phase 3: Review

After the loop ends:

1. Collect all fix commits: `git log --reverse --format="%H %s" {initial_head}..HEAD`
2. If there are no new commits, report that no issues were found and stop.
3. For each commit, use `AskUserQuestion` to ask whether to keep it:
   - Show the full commit message (which contains the problem and the fix).
   - Options: "Keep" and "Revert"
4. For each commit the user wants to revert, run `git revert --no-edit {hash}`. Revert in reverse chronological order (newest first) to avoid conflicts.
5. Report the final summary: how many fixes kept, how many reverted.

