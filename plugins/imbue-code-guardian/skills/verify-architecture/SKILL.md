---
name: verify-architecture
description: Assess whether the approach taken on a branch is the right way to solve the problem.
allowed-tools: Bash(git rev-parse *), Bash(git -C *), Bash(git diff *), Bash(git log *), Bash(git show *), Bash(git ls-tree *), Bash(jq *), Bash(ls *), Bash(find *), Bash(grep *), Bash(echo "${GIT_BASE_BRANCH:-main}"), Bash(date -u +%Y-%m-%dT%H:%M:%SZ), Read, Write, Agent, AskUserQuestion
---

# Architecture Verification

Assess whether the approach taken on this branch is the right way to solve its problem. Specifically: does it fit existing codebase patterns and information flow, does it introduce unnecessary coupling or implicit dependencies, and is there a better alternative?

This command runs **once per stop cycle** and covers **every reviewed directory** -- the root repo plus any `stop_hook.additional_git_directories`. Do not run it separately per directory. Each reviewed repo is self-contained (its own git repo, base branch, and `.reviewer/` markers); you assess each one, but as a single coordinating agent so cross-repo interactions can be reasoned about.

## Phase 0: Determine the target directories

1. Read `.reviewer/settings.json` (and `.reviewer/settings.local.json` if present). Collect `stop_hook.additional_git_directories` (may be empty). The **target directories** are `.` (root) followed by each additional dir.
2. For each target dir `{dir}`, read its base branch from `{dir}/.reviewer/settings.json` (`stop_hook.base_branch`; fall back to `${GIT_BASE_BRANCH:-main}` for the root). Determine whether it has reviewable changes: `git -C {dir} diff --name-only {base}...HEAD` shows at least one non-`.md` file.
3. Keep only the target dirs with reviewable changes.

If there is only one target dir (the root), the flow below is exactly the classic single-repo flow with `{dir}` = `.`.

## Phase 1: Summarize the problem (per target dir)

If you do not already know what the changes on a target dir's branch are supposed to accomplish, STOP and ask the user before continuing.

For each target dir, write a CONCISE description of the problem that dir's branch is trying to solve, based on your knowledge of the work done so far. This description must contain ONLY the problem -- not any part of the solution. Describe what should work differently afterward, what is currently broken, or what structural problem exists in the code. Do not mention any mechanism, technique, data structure, or approach used to fix it. The analysis agent needs to evaluate the approach independently, so any hint about the implementation will bias its judgment.

## Phase 1b: Cross-repo context (only when there is more than one target dir)

For each target dir, prepare a short, **relevance-filtered** summary of the *other* target dirs' changes, to hand to that dir's analysis agent so it can judge structural fit against surfaces that live in another repo:

- Ground it in the actual diffs (`git -C {other} diff {other_base}...HEAD`), not memory.
- Focus on structural/coupling changes in the other dirs that this dir interacts with (shared interfaces, data flow crossing the repo boundary, contracts). Leave out unrelated churn.
- Calibrate the grounding you ask of the analysis agent by your confidence in the relationship: confident -> keep it tight and say the agent needn't explore the other repo much; unsure -> orient yourself briefly, then tell the agent to ground further in the other repo where relevant.

## Context

- Default base branch: !`echo "${GIT_BASE_BRANCH:-main}"` (root default; each dir uses its own configured base)
- Current root HEAD: !`git rev-parse HEAD`

## Phase 2: Validate the diff (per target dir)

For each target dir, spawn a `validate-diff` Agent. Provide the **target directory** `{dir}`, its base branch name, and the problem description from Phase 1.

Based on the agent's response:
- If the diff is empty, STOP and ask the user whether the work has been committed yet or whether the base branch is wrong.
- If it reports changes that don't belong to this branch (i.e., changes you didn't make / the implementer agent wouldn't have made), STOP. Downstream agents review the entire diff and will act on out-of-scope code -- regardless of how the extra changes got there (wrong base branch, stale local ref, a merge, or incidental edits). Proceeding wastes context and causes the analysis agent to review irrelevant code. There is no valid reason to skip this step, even if the extra changes are "expected." The available remedies are: (1) check whether a different base branch produces a clean diff (e.g., if the branch merged in another feature branch, that feature branch may be a better base), (2) ask the user for the correct base branch, or (3) ask which changes to focus on (then explicitly tell the analysis agent in Phase 3 to ignore the rest). Note that sometimes no clean merge base exists -- e.g., the merged branch was based on an older main, so comparing to either base shows unrelated changes. In that case, ask the user.
- If it reports the work looks incomplete, flag that to the user and ask whether to proceed anyway.

## Phase 3: Spawn analysis agent (per target dir)

For each target dir, resolve the base branch commit hash:

```bash
git -C {dir} rev-parse {base_branch}
```

Spawn a single `analyze-architecture` Agent. Provide:
- The **target directory** `{dir}`
- The problem description from Phase 1
- The base commit hash and feature branch tip hash (`git -C {dir} rev-parse HEAD`)
- The cross-repo summary from Phase 1b (if any)

## Phase 4: Report

Relay each agent's findings to the user, grouped by directory. Report every point from the fit, unexpected choices, and verdict sections. Don't reproduce the structural footprint section on its own -- the user already knows what they built -- but reference specific details from it where needed to make the other points clear.

## Phase 5: Create verification markers

Architecture verification is per-branch. For EACH target dir, after reporting, create its verification marker so the stop hook knows architecture has been verified for that dir's branch. Get the branch name and timestamp:

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
