---
name: analyze-architecture
description: Analyze whether the approach taken on a branch fits existing codebase patterns.
---

# Architecture Analysis

You are analyzing whether the approach taken on a feature branch is the right way to solve its stated problem. You have been given a **set of target directories** -- one or more git repositories, reviewed together as one coherent change. For each, you were given:
- A **problem description** (what that repo's branch is trying to accomplish)
- A **base commit hash** and **tip commit hash** (for diffing)

Run all git commands for a repo with `git -C <dir>` (e.g. `git -C <dir> show {base}:path/to/file` to read pre-change files; `git -C <dir> diff {base}...{tip}` for the diff). Read current (post-change) files with the Read tool, using paths under that repo's `<dir>`. If you were given a single directory, this is the ordinary single-repo case with `<dir>` = `.`.

**Analyze all target dirs together.** These repos may share surfaces (an interface, schema, data flow, or contract that crosses the repo boundary). Evaluate each repo's approach on its own AND as part of the combined change: does the way one repo evolves a shared surface fit how the consuming repo uses it? Focus on the surfaces where they genuinely interact; ignore unrelated churn.

Perform these steps in order. Where a step is per-repo, do it for each target dir; where it is about the whole change, reason across all of them.

## Step 1: Understand the existing codebase (per repo)

For each target dir, build a thorough understanding of the code before looking at any changes. Read (using `git -C <dir> show {base}:path`):
- Project instructions and conventions: CLAUDE.md, style_guide.md, AGENTS.md
- Design and architecture docs
- The parts of the codebase relevant to that repo's stated problem -- the files and modules you would expect to touch if you were implementing a solution yourself

The goal is to understand not just what the code does, but how each codebase is organized: its patterns, how modules relate, where the boundaries are -- including any boundary that is shared with a sibling repo.

## Step 2: Generate independent approaches (per repo)

For each target dir, before looking at its actual changes, think of at least 3 ways you would solve its stated problem. For each, write one or two paragraphs covering the strategy, its tradeoffs, and which existing codebase patterns it leverages. Where a problem inherently spans repos (a shared surface), consider how each approach would coordinate the two sides. This establishes an unbiased baseline for evaluating the actual implementation later.

## Step 3: Study the actual changes

Now read each repo's diff (`git -C <dir> diff {base}...{tip}`) and the modified files in detail. Build a combined picture of what changed across all the repos.

## Step 4: Characterize the structural footprint

Describe what the changes add at a structural level, across the whole change:
- New functions, classes, modules, or external dependencies (note which repo each is in)
- How data flows through the new code and connects to existing data flows -- including data flow that crosses a repo boundary
- Any new coupling between previously independent parts (new imports, shared state, cross-module calls) -- and especially any new coupling *between the repos*
- Any new reliance on side information: environment variables, files on disk, global/mutable state, wall-clock time, process-level state, or anything else not passed in as an explicit argument. This is especially important to flag.

## Step 5: Evaluate fit with existing code (per repo)

For each repo, judge whether the changes feel like they belong:
- Do they follow the same patterns used for similar functionality elsewhere in that repo?
- Is there existing code they could have extended or reused instead of building something new?
- Where they diverge from established patterns, note it explicitly -- even if the divergence seems justified.
- For a shared surface: does each side's change fit the other side's usage, or is there a mismatch/impedance between the repos?

## Step 6: Compare against your independent approaches

For each repo, compare the actual implementation to the approaches you proposed in Step 2:
- Which of your approaches does it most resemble, and how closely?
- Does it do anything you would not have predicted? Flag anything unexpected, even if it turns out to be well-motivated.
- Does it address the root cause, or work around it? Does it fully solve the stated goal, or only part of it?
- For cross-repo problems: is the split of responsibility between the repos sensible?

## Step 7: Verdict

State whether you think this is the right approach, per repo and for the combined change. If you think there is a meaningfully better alternative -- one that fits the codebase(s) more naturally, avoids unnecessary side information, maintains cleaner boundaries, or coordinates the repos better -- describe it concretely.

## Step 8: Report

Return a structured report, grouped by directory, plus a short cross-repo section when more than one dir was analyzed:
- **Structural footprint** -- what the changes add and how data flows through them, including across repos (Step 4)
- **Fit with existing code** -- where the changes follow or break from established patterns, per repo and at the shared surfaces (Step 5)
- **Unexpected choices** -- anything surprising relative to your independent approaches (Step 6)
- **Verdict** -- overall judgment and any concrete alternatives (Step 7)
