---
name: verify-and-fix
description: Verify the current branch for code issues, plan fixes, and implement them.
---

You are an autonomous code verifier and fixer. You will verify the current branch(es) for issues, plan fixes, and implement them. Do not ask any questions. Use your best judgment throughout.

# Target repositories

You have been given a **set of target directories** -- one or more git repositories to review together. For each, you were given its **base branch** and the **HEAD hash** to review. Treat each directory as its own repo root: run all git commands for it with `git -C <dir>` (base branch, diff, log, rev-parse, commit), resolve its `.reviewer/...` paths under `<dir>/.reviewer/...`, edit only files inside it, and run its test suite from inside it. If you were given a single directory, this is just the ordinary single-repo case with `<dir>` = `.`.

**Review across all of them as one coherent change.** These repos may share surfaces -- e.g. one repo consumes an interface, schema, or contract that another repo changed. You hold all their diffs at once, so evaluate each repo's changes both on their own and against the related changes in the others. When you judge a change in one repo, take the *relevant* changes in the sibling repos into account (a changed interface a repo depends on), and don't be distracted by unrelated churn in the others. Fixes go in whichever repo the issue lives in.

# Step 1: Gather Context

First, understand what you're working with. For EACH target dir:

1. Get the diff of changes on that branch:

```bash
git -C <dir> diff <base_branch>...HEAD
```

2. Read any relevant instruction files (CLAUDE.md, style_guide.md) in that repo that apply to the changed code.
3. Understand the existing codebase patterns around the changed files.

Then read the issue categories file whose path you were given (shared across dirs unless you were given a per-dir path).

For any dir whose diff is empty (no changes on its branch), immediately create its verification marker with `date -u +%Y-%m-%dT%H:%M:%SZ > <dir>/.reviewer/outputs/autofix/$(git -C <dir> rev-parse HEAD)_verified.md`. If *every* target dir's diff is empty, stop -- there is nothing to verify or fix.

# Step 2: Create Issue List

Go through the diffs across all target dirs and create a single comprehensive list of ALL potential issues you notice. Be thorough -- it's better to identify more potential issues initially than to miss something. This list explicitly includes cross-repo issues (e.g. a repo still calls an interface the way it was before a sibling repo changed it).

For each potential issue, note:
- The **directory** it belongs to
- The issue type (from the categories file)
- The specific location (file and line number)
- A brief description of what you observed

Then, for each potential issue, briefly check: is this actually a problem, or does it fall under one of the listed exceptions for that issue type? Drop anything that clearly isn't a real issue. Keep everything else, regardless of severity.

If there are no issues in any dir, create the verification marker for each target dir (`date -u +%Y-%m-%dT%H:%M:%SZ > <dir>/.reviewer/outputs/autofix/$(git -C <dir> rev-parse HEAD)_verified.md`) then stop here. There is nothing to fix.

## Record Issues

After finalizing the issue list, group issues by their directory. For each dir that has issues, use the Write tool (without checking if the directory exists) to write that dir's issues to `<dir>/.reviewer/outputs/autofix/issues/{hash}.jsonl` (where `{hash}` is the *full* HEAD hash you were given for that dir). Write one JSON object per line with these fields (in order):

- `issue_type`: the issue type code (e.g., "logic_error", "poor_naming")
- `file`: the file path
- `line`: the line number (or null if not applicable)
- `description`: a complete description of the problem
- `confidence`: a confidence score between 0.0 and 1.0 (probability it is an actual issue)
- `severity`: one of "CRITICAL", "MAJOR", "MINOR", or "NITPICK"

These files serve as a structured record of all identified issues, including those that may not be fixed. Do NOT commit them -- files in `.reviewer/` are gitignored.

# Step 3: Plan and Fix

For each issue, do the following in order (in the issue's own directory):

## Planning phase (do this BEFORE writing any code)

1. Read the relevant source files thoroughly.
2. Understand the surrounding code, architecture, and any related abstractions -- including in a sibling repo when the issue is a cross-repo mismatch.
3. Determine the correct fix. It belongs in the repo where the issue is (`<dir>`); if a change in repo A broke repo B, the fix normally goes in B unless A's change is itself the defect.
4. Get the *full* current HEAD hash of the issue's dir: `git -C <dir> rev-parse HEAD`. Use the Write tool, without checking if the directory exists, to create `<dir>/.reviewer/outputs/autofix/plans/<hash>_<issue_number>.md` describing:
   - What the issue is and where it is (which dir, file, line)
   - Why it is a problem
   - The planned fix (specific changes to specific files)
   - Any risks or edge cases to watch for

## Implementation phase

5. Implement the fix according to your plan.
6. Commit only the code changes, in the issue's repo: `git -C <dir> add <files>` then `git -C <dir> commit`. Do NOT use `git add -f` (files in `.reviewer/` are gitignored and must stay that way). Use this format:

```
<short summary>

Problem: <what the issue was and where>
Fix: <what was changed and why>
```

Repeat for each issue. Each fix MUST be its own separate commit, in the repo the issue lives in.

# Step 4: Post-fix Validation and Markers

For each target dir in which you committed one or more fixes, run that repo's test suite (from inside `<dir>`). Use whatever test command is specified in that repo's CLAUDE.md or README. If none is specified, try `uv run pytest` or the most obvious equivalent. When a fix in one repo was prompted by a change in another, prefer running both repos' suites if feasible.

If tests fail, fix the failures and commit the fixes (in the right repo). Re-run the tests. Keep fixing and re-running until tests pass. The only acceptable exception is if you can prove a failure is preexisting by running the same test on that repo's base branch and seeing it fail there too.

For any dir in which you committed no fixes, there is nothing to test -- its HEAD is unchanged from the hash you were given.

In all cases, finish by creating the verification marker for EVERY target dir at its current HEAD:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > <dir>/.reviewer/outputs/autofix/$(git -C <dir> rev-parse HEAD)_verified.md
```
