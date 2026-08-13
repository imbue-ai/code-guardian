---
name: verify-architecture
description: Assess whether the approach taken on a branch is the right way to solve the problem.
allowed-tools: Bash(git rev-parse *), Bash(git diff *), Bash(git log *), Bash(git show *), Bash(git ls-tree *), Bash(git -C * rev-parse *), Bash(git -C * diff *), Bash(git -C * log *), Bash(git -C * show *), Bash(git -C * ls-tree *), Bash(ls *), Bash(find *), Bash(grep *), Bash(echo "${GIT_BASE_BRANCH:-main}"), Bash(date -u +%Y-%m-%dT%H:%M:%SZ), Read, Write, Agent, AskUserQuestion
---

# Architecture Verification

Assess whether the approach taken on this branch is the right way to solve its problem. Specifically: does it fit existing codebase patterns and information flow, does it introduce unnecessary coupling or implicit dependencies, and is there a better alternative?

This command runs **once per stop cycle** and covers **every reviewed directory** -- the root repo plus any `stop_hook.additional_git_directories`. Do not run it separately per directory. Each reviewed repo is self-contained (its own git repo, base branch, and `.reviewer/` markers), but the analysis agent evaluates them **together, in a single pass**, so it can reason about how the repos fit as one change (including any surface they share).

## Phase 0: Determine the target directories

1. Read `.reviewer/settings.json` (and `.reviewer/settings.local.json` if present). Collect `stop_hook.additional_git_directories` (may be empty), dropping any entry that does not exist on disk -- the list is shared config, and a nested repo is only present in the checkouts working on it. The **target directories** are `.` (root) followed by each remaining additional dir.
2. For each target dir `{dir}`, read its base branch (`stop_hook.base_branch`) from `{dir}/.reviewer/settings.local.json`, falling back to `{dir}/.reviewer/settings.json` (then to `${GIT_BASE_BRANCH:-main}` for the root). **Every** dir's settings resolve this way, not just the root's -- the local file is gitignored and wins, so reading only the committed one gives you the wrong answer whenever a worktree overrides something. Determine whether it has reviewable changes: `git -C {dir} diff --name-only {base}...HEAD` shows at least one non-`.md` file.

   Do not read any dir's gate toggles (`autofix.is_enabled`, `verify_architecture.is_enabled`, `ci.is_enabled`). Which gates apply to which dir is the stop hook's decision, made in `stop_hook_gates.sh`; a dir is in the review set here purely because it has changes.
3. Keep only the target dirs with reviewable changes -- the **review set**.

If the review set is a single dir (the root), the flow below is exactly the classic single-repo flow with `{dir}` = `.`.

## Phase 1: Summarize the problem (per dir)

If you do not already know what a target dir's branch is supposed to accomplish, STOP and ask the user before continuing.

For each dir in the review set, write a CONCISE description of the problem that dir's branch is trying to solve, based on your knowledge of the work so far. This description must contain ONLY the problem -- not any part of the solution. Describe what should work differently afterward, what is currently broken, or what structural problem exists. Do not mention any mechanism, technique, data structure, or approach used to fix it. The analysis agent evaluates the approach independently, so any hint about the implementation will bias its judgment.

## Context

- Default base branch: !`echo "${GIT_BASE_BRANCH:-main}"` (root default; each dir uses its own configured base)
- Current root HEAD: !`git rev-parse HEAD`

## Phase 2: Validate the diff

Spawn ONE `validate-diff` Agent, giving it the whole review set: for each dir, its path, base branch, and problem description.

Based on its response:
- If any dir's diff is empty, STOP and ask the user whether the work has been committed yet or whether that dir's base branch is wrong.
- If it reports changes that don't belong (i.e., changes you didn't make / the implementer agent wouldn't have made -- and not merely changes that live in another target dir), STOP. Downstream agents review the entire diff and will act on out-of-scope code -- regardless of how the extra changes got there (wrong base branch, stale local ref, a merge, or incidental edits). Proceeding wastes context and causes the analysis agent to review irrelevant code. There is no valid reason to skip this step, even if the extra changes are "expected." The available remedies are: (1) check whether a different base branch produces a clean diff (e.g., if the branch merged in another feature branch, that feature branch may be a better base), (2) ask the user for the correct base branch, or (3) ask which changes to focus on (then explicitly tell the analysis agent in Phase 3 to ignore the rest). Note that sometimes no clean merge base exists -- e.g., the merged branch was based on an older main, so comparing to either base shows unrelated changes. In that case, ask the user.
- If it reports the work looks incomplete, flag that to the user and ask whether to proceed anyway.

## Phase 3: Spawn analysis agent

Resolve each dir's base commit hash (`git -C {dir} rev-parse {base_branch}`) and tip hash (`git -C {dir} rev-parse HEAD`).

Spawn a single `analyze-architecture` Agent, providing it with the **whole review set**: for each dir, its path, problem description, base commit hash, and tip commit hash.

## Phase 4: Report

Relay the agent's findings to the user, grouped by directory, plus its cross-repo observations when more than one dir was analyzed. Report every point from the fit, unexpected choices, and verdict sections. Don't reproduce the structural footprint section on its own -- the user already knows what they built -- but reference specific details from it where needed to make the other points clear.

## Phase 5: Create verification markers

Architecture verification is per-branch. For EACH dir in the review set, after reporting, create its verification marker so the stop hook knows architecture has been verified for that dir's branch. Get the branch name and timestamp:

```bash
git -C {dir} rev-parse --abbrev-ref HEAD
date -u +%Y-%m-%dT%H:%M:%SZ
```

Replace any `/` in the branch name with `_` (e.g., `mngr/my-feature` becomes `mngr_my-feature`). Then use the Write tool (without checking if the directory exists) to create `{dir}/.reviewer/outputs/architecture/{sanitized_branch_name}.md` with the content `Verified at {timestamp}`.

## Important: when to re-run

Architecture verification is per-branch, not per-commit. You do NOT need to re-run it after every commit. However, if you later make changes that fundamentally alter the approach (new abstractions, changed data flow, different module boundaries) in any reviewed dir, you should run /verify-architecture again to confirm the new direction is sound.

# RUN TIME OVERRIDE

For *this particular run* of the `verify-architecture` command, follow these adjustments from the user to the normal process:

```
$ARGUMENTS
```
