---
name: autofix
description: Automatically find and fix code issues in the current branch. Iteratively verifies, plans fixes, and implements them with separate commits. Defers all review to the end.
allowed-tools: Bash(git status *), Bash(git rev-parse *), Bash(git log *), Bash(git revert *), Bash(git -C *), Bash(git diff *), Bash(jq *), Bash(date -u +%Y-%m-%dT%H:%M:%SZ), Bash(echo "${GIT_BASE_BRANCH:-main}"), Read, Write, Agent, AskUserQuestion
---

# Autofix

Iteratively verify the current branch for code issues, plan and implement fixes (each in a separate commit), and repeat until clean. At the end, present each fix for user review and revert any the user does not want.

This command runs **once per stop cycle** and covers **every reviewed directory** -- the root repo plus any `stop_hook.additional_git_directories`. Do not run it separately per directory. Each reviewed repo is self-contained (its own git repo, base branch, and `.reviewer/` markers); one fix loop runs per directory, but a single agent (you) coordinates them all so cross-repo interactions can be reasoned about.

## Phase 0: Determine the target directories

1. Read `.reviewer/settings.json` (and `.reviewer/settings.local.json` if present). Collect the list `stop_hook.additional_git_directories` (may be empty). The **target directories** are `.` (the root repo) followed by each additional dir.
2. For each target dir `{dir}`, determine its base branch: read `stop_hook.base_branch` from `{dir}/.reviewer/settings.json` (fall back to `${GIT_BASE_BRANCH:-main}` for the root). Determine whether it has reviewable changes: `git -C {dir} diff --name-only {base}...HEAD` shows at least one non-`.md` file.
3. Keep only the target dirs that have reviewable changes. Those are the ones you will autofix. If a dir has no changes, skip it.

If there is only one target dir (the root, no additional dirs), everything below is exactly the classic single-repo flow -- just with `{dir}` = `.`.

## Phase 1: Setup (per target dir)

Autofix requires a clean git state in every target dir. For each, check for uncommitted changes:

```bash
git -C {dir} status --porcelain
```

If any target dir has untracked, staged, or unstaged changes, commit them first (or gitignore them if they should not be tracked). Do NOT proceed until every target dir's `git -C {dir} status --porcelain` is empty.

For each target dir, record:
- Initial HEAD (`initial_head`): `git -C {dir} rev-parse HEAD`
- Base branch (`base_branch`): from Phase 0

If you do not already know what the changes on these branches are supposed to accomplish, STOP and ask the user before continuing.

Write a brief description of what each target dir's branch is trying to do. This helps the diff validation and fix agents distinguish intentional changes from issues.

## Phase 1b: Cross-repo context (only when there is more than one target dir)

When more than one dir is being reviewed, related changes may live in a *different* repo (e.g. dir B consumes an interface that changed in dir A). For each target dir, prepare a short, **relevance-filtered** summary of the *other* target dirs' changes to hand to that dir's fix agent:

- Ground it in the actual diffs: `git -C {other} diff {other_base}...HEAD` (do not rely on memory).
- Focus only on the parts of the other dirs that this dir depends on or shares a surface with (interfaces, APIs, schemas, contracts). Leave out unrelated churn.
- Calibrate the effort you ask of the fix agent by your own confidence in the relationship: if you already understand how the dirs relate, say so and keep the summary tight, telling the agent it should not need to explore the other repos much; if you are unsure, spend a short moment orienting yourself, then tell the agent to do additional grounding in the other repo where relevant.
- Ideally each repo's changes stand on their own; the summary is a safety net for genuine cross-repo coupling, not a licence to review the other repos in depth here.

## Phase 2: Fix loop (per target dir)

Run the following loop **independently for each target dir**. You may interleave dirs, but keep each dir's `initial_head`, `base_branch`, and cross-repo summary straight.

### Phase 2a: Validate the diff

Spawn a `validate-diff` Agent. Provide the **target directory** `{dir}`, its base branch name, and the problem description.

Based on the agent's response:
- If the diff is empty, STOP and ask the user whether the work has been committed yet or whether the base branch is wrong.
- If it reports changes that don't belong to this branch (i.e., changes you didn't make / the implementer agent wouldn't have made), STOP. Downstream agents review the entire diff and will act on out-of-scope code -- regardless of how the extra changes got there (wrong base branch, stale local ref, a merge, or incidental edits). Proceeding wastes context and causes the fix agent to review and potentially "fix" irrelevant code. There is no valid reason to skip this step, even if the extra changes are "expected." The available remedies are: (1) check whether a different base branch produces a clean diff (e.g., if the branch merged in another feature branch, that feature branch may be a better base), (2) ask the user for the correct base branch, or (3) ask the user which changes to focus on (then explicitly tell the fix agent to ignore the rest). Note that sometimes no clean merge base exists -- e.g., the merged branch was based on an older main, so comparing to either base shows unrelated changes. In that case, ask the user.
- If it reports the work looks incomplete, note this but proceed -- autofix works on whatever is there.

### Phase 2b: Fix iterations

Repeat up to 10 times (for this dir):

1. Record the *full* current HEAD as `pre_iteration_head`: `git -C {dir} rev-parse HEAD`.
2. Print a message telling the user that issues for this iteration will be saved to: `{dir}/.reviewer/outputs/autofix/issues/{pre_iteration_head}.jsonl`
3. Spawn a single `verify-and-fix` Agent, providing:
   - The **target directory** `{dir}` (it must treat this as the repo root for all git, edits, tests, and markers)
   - The base branch (`{base_branch}`)
   - The *full* current HEAD hash (`{pre_iteration_head}`)
   - The issue categories path: `{dir}/.reviewer/code-issue-categories.md` if it exists, otherwise `.reviewer/code-issue-categories.md` at the root, otherwise `${CLAUDE_PLUGIN_ROOT}/agents/categories/code-issue-categories.md`
   - The cross-repo summary from Phase 1b (if any)
4. Wait for the agent to finish.
5. Check if HEAD moved: compare `git -C {dir} rev-parse HEAD` to `pre_iteration_head`.
6. If HEAD did not move, no fixes were made. This dir is clean (or remaining issues are unfixable). Stop looping for this dir.
7. If HEAD moved, continue to the next iteration.

Important:
- Do NOT explore code, plan, or fix anything yourself. The agent does all the work.
- Each iteration gets a fresh-context agent, which is the whole point.
- Do NOT pass the agent any information about previous iterations or previous fixes. It operates from a clean slate every time (the cross-repo summary is the one exception -- it is stable context about the other repos, not about prior iterations).
- You MUST explicitly wait for the `verify-and-fix` agent task to finish--do *not* simply finish your response!
- You MUST use your ability to wait for your own Task or Agent primitives in order to wait for the agent! Do not try to sleep or poll--that is inefficient and unreliable.
- Do *NOT* make any changes or run any tests or commands yourself while the above loop is running! That will be handled by the agent.

## Phase 3: Review (per target dir)

After the loop ends for a dir:

1. Collect all fix commits: `git -C {dir} log --reverse --format="%H %s" {initial_head}..HEAD`
2. If there are no new commits, skip to step 8.
3. Check if `{dir}/.reviewer/autofix/auto-accept.md` exists. If it does, read it. This file contains free-text rules describing which kinds of fixes should be automatically accepted without prompting the user (e.g. "accept all naming fixes", "auto-accept anything in test files").
4. For each commit, check its full commit message against the auto-accept rules. If a commit matches, keep it automatically -- do not ask the user about it.
5. Ask about the remaining commits in a single `AskUserQuestion` call. Use one question per commit (up to 4 per call; if there are more than 4 commits, use multiple calls but still gather all answers before doing any git operations). Each question should:
   - Note which directory the commit is in (when more than one dir was reviewed).
   - Show the full commit message (which contains the problem and the fix).
   - Options: "Keep" and "Revert"
6. Only after ALL answers have been collected, revert the rejected commits. Run `git -C {dir} revert --no-edit {hash}` for each, in reverse chronological order (newest first) to avoid conflicts.
7. Report the final summary per dir: how many fixes kept (noting which were auto-accepted), how many reverted. Note how many total issues were identified (from `{dir}/.reviewer/outputs/autofix/issues/*.jsonl` files).
8. Ensure the verification marker exists for this dir at its current HEAD (the `verify-and-fix` agent writes it; if the dir had no changes it is not needed).

# RUN TIME OVERRIDE

For *this particular run* of the `autofix` command, follow these adjustments from the user to the normal process:

```
$ARGUMENTS
```
