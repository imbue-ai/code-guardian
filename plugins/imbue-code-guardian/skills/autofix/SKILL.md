---
name: autofix
description: Automatically find and fix code issues in the current branch. Iteratively verifies, plans fixes, and implements them with separate commits. Defers all review to the end.
allowed-tools: Bash(git status *), Bash(git rev-parse *), Bash(git log *), Bash(git diff *), Bash(git revert *), Bash(git -C * status *), Bash(git -C * rev-parse *), Bash(git -C * log *), Bash(git -C * diff *), Bash(git -C * revert *), Bash(date -u +%Y-%m-%dT%H:%M:%SZ), Bash(echo "${GIT_BASE_BRANCH:-main}"), Bash(echo "${CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH:-}"), Read, Write, Agent, AskUserQuestion
---

# Autofix

Iteratively verify the current branch for code issues, plan and implement fixes (each in a separate commit), and repeat until clean. At the end, present each fix for user review and revert any the user does not want.

This command runs **once per stop cycle** and covers **every reviewed directory** -- the root repo plus any `stop_hook.additional_git_directories`. Do not run it separately per directory. Each reviewed repo is self-contained (its own git repo, base branch, and `.reviewer/` markers), but the fix agent reviews them **together, in a single pass**, so it holds the whole cross-repo picture and can catch issues where one repo's change interacts with another's.

## Phase 0: Determine the target directories

1. Read `.reviewer/settings.json` (and `.reviewer/settings.local.json` if present). Collect the list `stop_hook.additional_git_directories` (may be empty), dropping any entry that does not exist on disk -- the list is shared config, and a nested repo is only present in the checkouts working on it. The **target directories** are `.` (the root repo) followed by each remaining additional dir.
2. For each target dir `{dir}`, determine its base branch (`stop_hook.base_branch`) using the hook's own precedence: `${CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH}` **for the root dir only**, then `{dir}/.reviewer/settings.local.json`, then `{dir}/.reviewer/settings.json`, then `main`. The env var is an agent-scoped override for the agent's own repo, so the hook blanks it for every other dir -- honoring it there would let the root's base leak into a secondary repo. **Every** dir's settings resolve through the `.local.json` sibling, not just the root's: that file is gitignored and wins, so reading only the committed one gives you the wrong answer whenever a worktree overrides something. Determine whether it has reviewable changes: `git -C {dir} diff --name-only {base}...HEAD` shows at least one non-`.md` file.

   Do not read any dir's gate toggles (`autofix.is_enabled`, `verify_architecture.is_enabled`, `ci.is_enabled`). Which gates apply to which dir is the stop hook's decision, made in `stop_hook_gates.sh`; a dir is in the review set here purely because it has changes.
3. Keep only the target dirs that have reviewable changes -- call this the **review set**. If a dir has no changes, drop it.

If the review set is a single dir (the root, no additional dirs), everything below is exactly the classic single-repo flow with `{dir}` = `.`.

## Phase 1: Setup

Autofix requires a clean git state in every dir in the review set. For each, check for uncommitted changes:

```bash
git -C {dir} status --porcelain
```

If any is non-empty, commit those changes first (or gitignore them if they should not be tracked). Do NOT proceed until every dir in the review set is clean.

For each dir in the review set, record:
- Initial HEAD (`initial_head`): `git -C {dir} rev-parse HEAD`
- Base branch (`base_branch`): from Phase 0

If you do not already know what the changes on these branches are supposed to accomplish, STOP and ask the user before continuing. Write a brief problem description per dir -- this helps the diff-validation and fix agents distinguish intentional changes from issues, and understand how the repos relate.

## Phase 2: Validate the diff

Spawn ONE `validate-diff` Agent, giving it the whole review set: for each dir, its path, base branch, and problem description.

Based on its response:
- If any dir's diff is empty, STOP and ask the user whether the work has been committed yet or whether that dir's base branch is wrong.
- If it reports changes that don't belong (i.e., changes you didn't make / the implementer agent wouldn't have made -- and not merely changes that live in another target dir), STOP. Downstream agents review the entire diff and will act on out-of-scope code -- regardless of how the extra changes got there (wrong base branch, stale local ref, a merge, or incidental edits). Proceeding wastes context and causes the fix agent to review and potentially "fix" irrelevant code. There is no valid reason to skip this step, even if the extra changes are "expected." The available remedies are: (1) check whether a different base branch produces a clean diff (e.g., if the branch merged in another feature branch, that feature branch may be a better base), (2) ask the user for the correct base branch, or (3) ask the user which changes to focus on (then explicitly tell the fix agent to ignore the rest). Note that sometimes no clean merge base exists -- e.g., the merged branch was based on an older main, so comparing to either base shows unrelated changes. In that case, ask the user.
- If it reports the work looks incomplete, note this but proceed -- autofix works on whatever is there.

## Phase 3: Fix loop

Repeat up to 10 times:

1. For every dir in the review set, record the *full* current HEAD as its `pre_iteration_head`: `git -C {dir} rev-parse HEAD`.
2. Print a message telling the user that issues for this iteration will be saved to `{dir}/.reviewer/outputs/autofix/issues/{pre_iteration_head}.jsonl` for each dir.
3. Spawn a single `verify-and-fix` Agent, providing it with the **whole review set**:
   - For each dir: its path, its `base_branch`, and its `pre_iteration_head`.
   - The issue categories path: `.reviewer/code-issue-categories.md` at the root if it exists, otherwise `${CLAUDE_PLUGIN_ROOT}/agents/categories/code-issue-categories.md`. (If a dir has its own `{dir}/.reviewer/code-issue-categories.md`, pass that for that dir.)
4. Wait for the agent to finish.
5. Check whether HEAD moved in ANY dir: compare `git -C {dir} rev-parse HEAD` to that dir's `pre_iteration_head`.
6. If no dir's HEAD moved, no fixes were made anywhere. The change is clean (or remaining issues are unfixable). Stop looping.
7. If any dir's HEAD moved, continue to the next iteration.

Important:
- Do NOT explore code, plan, or fix anything yourself. The agent does all the work, across all repos.
- Each iteration gets a fresh-context agent, which is the whole point.
- Do NOT pass the agent any information about previous iterations or previous fixes. It operates from a clean slate every time.
- You MUST explicitly wait for the `verify-and-fix` agent task to finish--do *not* simply finish your response!
- You MUST use your ability to wait for your own Task or Agent primitives in order to wait for the agent! Do not try to sleep or poll--that is inefficient and unreliable.
- Do *NOT* make any changes or run any tests or commands yourself while the above loop is running! That will be handled by the agent.

## Phase 4: Review

After the loop ends, gather the fix commits across ALL dirs in the review set. For each dir:

1. Collect its fix commits: `git -C {dir} log --reverse --format="%H %s" {initial_head}..HEAD`
2. Check if `{dir}/.reviewer/autofix/auto-accept.md` exists. If it does, read it -- it contains free-text rules describing which kinds of fixes should be auto-accepted without prompting (e.g. "accept all naming fixes", "auto-accept anything in test files").
3. For each commit, check its full commit message against that dir's auto-accept rules. If a commit matches, keep it automatically.

Then, across all dirs:

4. Ask about the remaining (non-auto-accepted) commits in `AskUserQuestion` calls. Use one question per commit (up to 4 per call; use multiple calls if needed, but gather all answers before doing any git operations). Each question should:
   - State which directory the commit is in (when the review set has more than one dir).
   - Show the full commit message (which contains the problem and the fix).
   - Options: "Keep" and "Revert"
5. Only after ALL answers are collected, revert the rejected commits in their own repos: `git -C {dir} revert --no-edit {hash}`, in reverse chronological order per dir (newest first) to avoid conflicts.
6. Report the final summary, grouped by dir: how many fixes kept (noting which were auto-accepted), how many reverted, and how many total issues were identified (from `{dir}/.reviewer/outputs/autofix/issues/*.jsonl`).

The `verify-and-fix` agent writes each dir's verification marker; a dir with no changes needs none.

# RUN TIME OVERRIDE

For *this particular run* of the `autofix` command, follow these adjustments from the user to the normal process:

```
$ARGUMENTS
```
