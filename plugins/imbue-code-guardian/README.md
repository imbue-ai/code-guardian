# imbue-code-guardian

Automated code review enforcement for Claude Code. When enabled, a Stop hook runs a full pipeline: commit enforcement, branch syncing, PR/CI checks, and review gates (autofix, architecture, conversation).

**The hook is off by default.** Enable it after installing.

## Install

```
claude plugin marketplace add imbue-ai/code-guardian && claude plugin install imbue-code-guardian@imbue-code-guardian
```

## Enabling the stop hook

After installing, enable enforcement:

```
/imbue-code-guardian:reviewer-enable
```

The argument is an optional shell expression controlling when enforcement fires. For example, to only enforce when a specific env var is set:

```
/imbue-code-guardian:reviewer-enable test -n "${MY_AGENT_ENV_VAR:-}"
```

Individual gates can be disabled with `/imbue-code-guardian:reviewer-disable`.

## Pipeline

When enabled, the stop hook orchestrator runs every time Claude finishes a response. The full pipeline:

1. **Stuck agent detection** -- if the hook has blocked N consecutive times at the same commit, let the agent through to prevent infinite loops.
2. **Uncommitted changes check** -- all changes must be committed (or gitignored) before the hook passes.
3. **Fetch and merge base branch** -- fetches all remotes, merges the base branch, and pushes merge commits.
4. **Push + PR check** -- pushes to origin and verifies a PR exists (so CI starts early). If no PR exists and `ci.require_pr` is true, blocks the agent to create one.
5. **Informational session detection** -- if only `.md` files changed (or no changes vs base), the session is informational and the hook passes without further checks.
6. **Parallel gate checks** -- all remaining gates are checked in parallel:
   - **Review gates**: autofix (per-commit), architecture verification (per-branch), conversation review (per-commit)
   - **CI gate**: polls PR check status until all checks complete
7. **Unified report** -- all unsatisfied gates are reported together so the agent knows everything it still needs to do.

## Skills

- **autofix** -- Iteratively find and fix code issues on a branch. Spawns fresh-context agents for each pass, presents fixes for review, and reverts any you reject.
- **verify-architecture** -- Assess whether the approach on a branch fits existing codebase patterns. Generates independent solution proposals before examining the diff to avoid confirmation bias. Runs once per branch (not per commit), but should be re-run after fundamental architecture changes.
- **verify-conversation** -- Review the conversation transcript for behavioral issues (misleading behavior, disobeyed instructions, feedback worth saving).

## Configuration

Settings live in `.reviewer/settings.json` (checked-in project defaults) with `.reviewer/settings.local.json` overrides (gitignored, per-worktree).

### Enable/disable skills

- **reviewer-enable** -- Enable the stop hook. Optionally takes a shell expression for when to enforce.
- **reviewer-disable** -- Disable all review gates at once.
- **reviewer-init-categories** -- Copy the default issue categories to `.reviewer/` for customization.
- **reviewer-autofix-enable / disable** -- Toggle the autofix gate.
- **reviewer-autofix-all-issues / ignore-minor-issues** -- Control issue severity threshold for unattended autofix.
- **reviewer-ci-enable / disable** -- Toggle the CI gate.
- **reviewer-verify-conversation-enable / disable** -- Toggle the conversation review gate.
- **reviewer-verify-architecture-enable / disable** -- Toggle the architecture verification gate.

### Config keys

#### Stop hook pipeline

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `stop_hook.enabled_when` | string | `""` | Shell expression; hook runs only when this exits 0. Empty = disabled. |
| `stop_hook.base_branch` | string | `"main"` | Base branch for merge/diff operations. |
| `stop_hook.require_committed` | bool | `true` | Enforce all changes committed before hook passes. |
| `stop_hook.fetch_and_merge` | bool | `true` | Fetch/merge/push base branch on each stop. |
| `stop_hook.skip_informational` | bool | `true` | Skip checks for .md-only sessions. |
| `stop_hook.log_file` | string | `".reviewer/logs/stop_hook.jsonl"` | JSONL log file path. |
| `stop_hook.max_consecutive_blocks` | int | `3` | Safety hatch: let agent through after this many consecutive blocks at the same commit. |

#### CI

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ci.is_enabled` | bool | `true` | Enable CI polling as a gate. |
| `ci.require_pr` | bool | `true` | If true, block when no PR exists. If false, skip CI when no PR. |
| `ci.timeout` | int | `600` | Max seconds for CI polling. |
| `ci.poll_interval` | int | `15` | Seconds between CI polls. |

#### Review gates

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `autofix.is_enabled` | bool | `true` | Enable autofix gate (per-commit). |
| `autofix.append_to_prompt` | string | `""` | Extra instructions appended to autofix skill invocation. |
| `verify_conversation.is_enabled` | bool | `true` | Enable conversation review gate (per-commit). |
| `verify_conversation.append_to_prompt` | string | `""` | Extra instructions appended to verify-conversation skill invocation. |
| `verify_architecture.is_enabled` | bool | `true` | Enable architecture verification gate (per-branch). |
| `verify_architecture.append_to_prompt` | string | `""` | Extra instructions appended to verify-architecture skill invocation. |

## Stuck agent detection

The orchestrator tracks consecutive blocked attempts at the same commit in `.reviewer/outputs/stop_hook_consecutive_blocks`. After `stop_hook.max_consecutive_blocks` (default 3) consecutive blocks, it lets the agent through with a warning. This is a unified safety hatch covering all gates (review gates and CI).

## Issue categories

The plugin ships default issue categories. To customize them for your project, run `/imbue-code-guardian:reviewer-init-categories` to copy the defaults to `.reviewer/code-issue-categories.md` and `.reviewer/conversation-issue-categories.md`, then edit directly. The skills check `.reviewer/` first, falling back to plugin defaults.

## Agents

- **verify-and-fix** -- Autonomous code verifier and fixer (used by autofix)
- **analyze-architecture** -- Evaluates whether branch changes fit codebase patterns (used by verify-architecture)
- **validate-diff** -- Quick sanity check on a branch's diff (used by autofix and verify-architecture)
- **review-conversation** -- Reviews conversation transcripts for behavioral issues (used by verify-conversation)
