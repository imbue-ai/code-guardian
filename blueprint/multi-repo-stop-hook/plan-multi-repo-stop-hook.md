# Plan: Multi-repo stop hook

Run the code-guardian stop-hook pipeline across multiple git working directories, not just the CWD repo root — so changes landing in a nested, separately-versioned repo (e.g. `.external_worktrees/default-workspace-template`) get reviewed instead of silently skipped.

## Overview

- **Problem:** The stop hook only inspects the CWD repo's git state. When all real changes land in a nested repo with its own `.git`/remote/base branch (gitignored from the outer repo), the hook sees an empty diff vs base and skips every gate — the changes go completely unreviewed.
- **Core idea:** Add `stop_hook.additional_git_directories` (a plain list of path strings) to the root `.reviewer/settings.json`. The root repo is always reviewed; listed dirs are reviewed *in addition*. Each listed dir is a **fully self-contained repo** — its own `.reviewer/` (config + `outputs/` + `logs/`) is the sole source of truth for how it's reviewed.
- **Two-tier pipeline:** The *non-review* steps (uncommitted check, fetch/merge/push, ensure-PR, poll-CI) run **per dir**, concurrently, each scoped via `git -C <dir>` to that repo's own config/base/remote/CI. The *review gates* run **once per cycle** across all dirs (next bullet). Results aggregate: block (exit 2) if any per-dir step or any review gate is unsatisfied, reported together.
- **Unified review gates:** Exactly **one** `/autofix` and **one** `/verify-architecture` per stop cycle — not one per dir. Each is invoked once, receives the changes/context from *all* reviewed dirs, and reviews across them, so a single agent holds the whole cross-repo picture and can reason about interactions directly. (`/verify-conversation` is already once-per-cycle, root-only.)
- **Retargeting:** The gate skills and their sub-agents are modified to operate on an explicit *set* of target repos (`git -C <dir>`, dir-local markers/config) instead of hardcoding the session CWD. The skill spawns a **single** sub-agent (`validate-diff`, `verify-and-fix`, `analyze-architecture`) that reviews the **whole set in one pass**, holding every repo's full diff at once — not one sub-agent per dir.
- **Cross-repo reasoning:** Because one agent reviews all dirs with every full diff in context, shared surfaces (e.g. an interface in A consumed by B) are handled natively: when judging B's code it weighs the *relevant* parts of A's changes directly and ignores unrelated churn. No summary is passed between siloed reviews — the focus is emergent because a single agent sees everything, and fixes land in whichever repo the issue lives in.

## Expected behavior

- **Backward compatible:** When `additional_git_directories` is absent/empty, the hook behaves exactly as today (root-only, no per-dir machinery). Root is always reviewed implicitly; the field only *adds* directories.
- **Self-contained per repo:** To review a secondary dir, it must supply its own `.reviewer/settings.json` governing its `base_branch`, which gates run, `ci.*`, and whether to push/PR/CI. Its gate markers, logs, and PR/CI outputs all live inside its own `.reviewer/`, exactly as if the hook ran there standalone.
- **Master switch stays global:** `stop_hook.enabled_when` is evaluated once from the *root* config. If false, the whole hook exits and no dir is processed. Additional dirs do not carry their own `enabled_when`.
- **Non-review steps, per dir, in parallel:** Each dir's uncommitted-check / fetch / merge / push / ensure-PR / poll-CI run against that repo's own remote and base via `git -C <dir>`. A merge conflict or missing PR in one dir blocks with that dir named, without masking the others' results. The gitignored nested repo is invisible to the root's own git steps (root's uncommitted check honors `.gitignore`), so the two repos never cross-contaminate.
- **Review gates, once per cycle, across all dirs:** After the per-dir non-review steps settle, the gate checker computes whether the *unified* autofix and architecture gates are satisfied over the whole set of reviewed dirs. If not, the report tells the agent to run `/autofix` once and `/verify-architecture` once — each covering every dir that has code changes, with all dirs in scope.
- **Gate satisfaction across dirs (per-dir markers, unified gate):** The single review pass still writes a **dir-local marker per reviewed dir** (autofix: `<dir>/.reviewer/outputs/autofix/${HEAD}_verified.md`; architecture: `<dir>/.reviewer/outputs/architecture/${branch}.md`) — preserving each repo's self-contained history. A gate is **satisfied only when every dir with code changes has a current marker**; if any dir's HEAD/branch advances, its marker goes stale and the one `/autofix` (or `/verify-architecture`) is prompted again, re-covering the changed dirs.
- **Aggregated report:** The hook blocks if any per-dir step OR either unified review gate is unsatisfied, and reports everything together — per-dir git/PR/CI failures grouped by dir, plus the (global) review-gate gaps naming which dirs still need coverage. All dirs' CI states are surfaced.
- **Hard error on misconfiguration:** A listed dir that is missing, is not a git repo, or lacks its own `.reviewer/settings.json` causes a hard error / block (exit 2) — a misconfigured or absent dir can never silently go unreviewed.
- **Conversation review stays global:** Because it reviews the session transcript (agent behavior), not a repo diff, `/verify-conversation` runs once at root only.
- **Cross-repo reasoning inside the single review pass (autofix + architecture):**
  - A **single** sub-agent reviews all dirs at once, gathering each dir's changes via `git -C <dir> diff` (source of truth, not memory) — so it inherently holds the whole cross-repo picture.
  - It judges each repo's changes both on their own and against the *relevant* changes in the sibling repos (a shared interface/schema/contract), de-emphasizing unrelated churn. This relevance-focus is emergent (the agent sees every diff), not a summary handed between siloed reviews.
  - Fixes land in whichever repo the issue lives in; each reviewed dir gets its own marker.
- **Stuck hatch (reconciliation — see open question):** With unified review gates, the consecutive-block/stuck-agent safety hatch is keyed on the whole cycle's composite state (all reviewed dirs' HEADs) rather than one dir. Per-dir non-review failures (e.g. a persistent merge conflict) keep the composite state from advancing, so they still count toward the hatch. *(This supersedes the earlier per-dir-hatch decision, which assumed per-dir review gates — flagged below for confirmation.)*
- **Cross-repo staleness (largely mitigated, residual limitation):** The single-pass model helps here — when dir A changes a surface dir B consumes, A's stale marker triggers the one `/autofix`, which reviews A *with B in scope* and can flag/fix B. The residual gap: if B itself never changes, its own marker stays current, so the model relies on the reviewing agent noticing the cross-repo impact rather than a forced re-review of B. Forcing marker invalidation on an unchanged consuming dir is out of scope.

## Changes

**Config**
- Add `stop_hook.additional_git_directories` to the root `.reviewer/settings.json` schema — a plain list of path strings, relative to the root repo root, default empty. No orchestrator-level per-entry overrides; each dir self-configures.
- Document that each listed dir must be a distinct git repo carrying its own `.reviewer/settings.json`; validated at runtime.

**Orchestrator (`stop_hook_orchestrator.sh`)**
- Evaluate `enabled_when` once (root), then build the review list `["."] + additional_git_directories`.
- Validate each additional dir (exists, is a git repo, has its own `.reviewer/settings.json`) → hard-error/block on failure.
- Factor the *non-review* steps (uncommitted → fetch/merge/push → docs-only/empty-diff → ensure-PR → poll-CI → per-commit marker carry-forward) into a unit that runs scoped to a given dir via `git -C <dir>` and that dir's own config; run that unit **per dir, concurrently**.
- Run the *review-gate* check **once per cycle** over the whole set of dirs (not per dir).
- Aggregate exit codes across the per-dir steps and the unified gate check; block (exit 2) if anything is unsatisfied.
- Report failures grouped: per-dir git/PR/CI issues by dir, plus the unified review-gate gaps naming which dirs still need coverage; surface all dirs' CI status.
- Track consecutive blocks / stuck hatch keyed on the composite cycle state (all dirs' HEADs) — see open question.
- Keep the conversation gate root-only.

**Logging**
- Each dir writes its own `.reviewer/logs/stop_hook.jsonl` for *its* non-review pipeline steps (its history, as if run standalone).
- The root logs the coordination/fan-out and the unified review-gate outcome.

**Gate checker (`stop_hook_gates.sh`)**
- Change from single-repo to a **cross-dir** check: for autofix and architecture, a gate is satisfied only when every dir with code changes has a current dir-local marker (`<dir>/.reviewer/outputs/...`, keyed on that dir's HEAD/branch).
- Emit a unified missing-gate report that says to run `/autofix` / `/verify-architecture` once, listing the dirs still needing coverage.

**PR/CI (`stop_hook_pr_and_ci.sh`)**
- Accept a target dir; resolve branch, PR, CI, and outputs relative to that dir (`git -C <dir>`, `<dir>/.reviewer/...`); tag its CI status with the dir for grouped reporting. (Remains per-dir.)

**Config utilities (`config_utils.sh`)**
- Allow reading a config rooted at an arbitrary dir (so per-dir steps and the review pass read `<dir>/.reviewer/settings.json` + `.local.json`) rather than a hardcoded CWD-relative path.

**Gate skills + sub-agents**
- `autofix`, `verify-architecture`: become **single, cross-cutting** commands. Each discovers the *set* of target dirs (those with changes) and spawns ONE sub-agent over the whole set (autofix loops that single agent until no dir's HEAD moves). Replace CWD-bound frontmatter (`!`git ...``, `${GIT_BASE_BRANCH:-main}`) with per-dir resolution. Markers are still written per dir.
- Their sub-agents (`validate-diff`, `verify-and-fix`, `analyze-architecture`): accept the *set* of target dirs (each with its base branch / hashes) and review across ALL of them in one invocation — scoping every git/read/write/marker op per repo via `git -C <dir>`, fixing each issue in the repo it lives in.
- Cross-repo reasoning is inherent (the one agent holds every diff); it weighs the relevant sibling changes when judging a repo's code, with no summary passed between siloed reviews.
- `verify-conversation` remains root/session-scoped (unchanged in targeting).

**Toggle skills**
- The per-gate toggle skills (`reviewer-autofix-enable/disable`, `reviewer-ci-enable/disable`, `reviewer-verify-architecture-enable/disable`, `reviewer-verify-conversation-enable/disable`, etc.) gain an optional directory argument to target a specific dir's `.reviewer/settings.local.json` instead of only the root's.

**Docs**
- Update the README: document `additional_git_directories`, the self-contained per-repo model, per-dir logs/outputs, the global `enabled_when` and root-only conversation gate, the hard-error validation, the cross-repo summary behavior, and the documented staleness limitation.

**Self-review / dogfood**
- This change is to the plugin itself, so the plugin repo (as root) reviews it through its own gates. Validation should include a self-review pass plus a two-repo smoke test: a root repo with one `additional_git_directories` entry pointing at a self-contained secondary repo, confirming (a) changes only in the secondary dir still trigger its gates, (b) failures aggregate and report per dir, (c) an absent/misconfigured dir hard-errors, and (d) the secondary dir's markers/logs/outputs land inside its own `.reviewer/`.
