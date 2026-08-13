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

To turn enforcement off entirely, run `/imbue-code-guardian:reviewer-disable`; re-running `reviewer-enable` restores the prior expression. Individual gates toggle separately via the per-gate skills below (e.g. `reviewer-ci-disable`).

## Pipeline

When enabled, the stop hook orchestrator runs every time Claude finishes a response. It reviews the root repo plus any [additional directories](#reviewing-multiple-directories). The full pipeline:

1. **Stuck agent detection** -- if the hook has blocked N consecutive times at the same state (across all reviewed dirs), let the agent through to prevent infinite loops.
2. **Per-dir non-review steps** (run concurrently, one set per reviewed dir, each scoped to that repo):
   - **Uncommitted changes check** -- all changes must be committed (or gitignored) before the hook passes.
   - **Fetch and merge base branch** -- fetches all remotes, merges the base branch, and pushes merge commits.
   - **Docs-only / empty-diff detection** -- if only `.md` files changed (or nothing changed) vs base, that dir needs no review/PR.
   - **Push + PR check** -- pushes to the remote and verifies a PR exists (so CI starts early). If no PR exists and `ci.require_pr` is true, blocks to create one.
3. **Unified review gates** (once per cycle, covering every reviewed dir): autofix (per-commit), architecture verification (per-branch), conversation review (per-commit, session-scoped/root-only). One `/autofix` and one `/verify-architecture` cover all dirs.
4. **CI gate** -- once review gates pass, polls each dir's PR check status until complete.
5. **Unified report** -- all unsatisfied dirs/gates are reported together so the agent knows everything it still needs to do.

## Skills

- **autofix** -- Iteratively find and fix code issues on a branch. Spawns fresh-context agents for each pass, presents fixes for review, and reverts any you reject.
- **verify-architecture** -- Assess whether the approach on a branch fits existing codebase patterns. Generates independent solution proposals before examining the diff to avoid confirmation bias. Runs once per branch (not per commit), but should be re-run after fundamental architecture changes.
- **verify-conversation** -- Review the conversation transcript for behavioral issues (misleading behavior, disobeyed instructions, feedback worth saving).

## Configuration

Settings live in `.reviewer/settings.json` (checked-in project defaults) with `.reviewer/settings.local.json` overrides (gitignored, per-worktree). The `.reviewer/` directory must sit at the repo's toplevel: a settings file found anywhere else (e.g. a vendored copy of a repo that ships one, nested inside a larger repo's tree) does not govern the repo it happens to sit in, and the hook skips rather than act on it.

Every config key also has a corresponding environment variable that takes precedence over both files. The mapping is `key.subkey` → `CODE_GUARDIAN_KEY__SUBKEY` (uppercased, dots replaced with double underscores so the section boundary stays recoverable from the env var name). For example:

- `stop_hook.base_branch` → `CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH`
- `ci.is_enabled` → `CODE_GUARDIAN_CI__IS_ENABLED`
- `autofix.append_to_prompt` → `CODE_GUARDIAN_AUTOFIX__APPEND_TO_PROMPT`

Lookup precedence (first non-empty wins): env var → `settings.local.json` → `settings.json` → built-in default. An unset env var, or one set to the empty string, falls through to the file lookup.

### Enable/disable skills

- **reviewer-enable** -- Enable the stop hook. Optionally takes a shell expression for when to enforce.
- **reviewer-disable** -- Disable the stop hook entirely (short-circuits the master switch; reviewer-enable restores it).
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
| `stop_hook.enabled_when` | string | `""` | Shell expression; hook runs only when this exits 0. Empty = disabled. Evaluated once, from the **root** config -- it is the master switch for the whole hook. |
| `stop_hook.base_branch` | string | `"main"` | Base branch for merge/diff operations. |
| `stop_hook.remote` | string | `"origin"` | Git remote to fetch/merge/push against. |
| `stop_hook.require_committed` | bool | `true` | Enforce all changes committed before hook passes. |
| `stop_hook.uncommitted_exempt_paths` | list | `[]` | Git pathspecs whose uncommitted changes the `require_committed` check ignores -- for expected machine-generated state, e.g. a vendored subtree a dev loop rsyncs into the working tree. The hook never discards this state: git still refuses to merge over it, and when that is the *only* thing blocking the base-branch merge the hook fails with a distinct message naming those paths (rather than reporting a merge conflict that isn't one), leaving it to the repo to drop and regenerate them. Committed changes under these paths are still diffed, reviewed, and pushed normally. |
| `stop_hook.fetch_and_merge` | bool | `true` | Fetch/merge/push base branch on each stop. |
| `stop_hook.skip_informational` | bool | `true` | Skip checks when only .md files changed (or nothing changed) vs base. |
| `stop_hook.log_file` | string | `".reviewer/logs/stop_hook.jsonl"` | JSONL log file path (per reviewed dir; anchored inside each dir). |
| `stop_hook.max_consecutive_blocks` | int | `3` | Safety hatch: let agent through after this many consecutive blocks at the same state. |
| `stop_hook.additional_git_directories` | list | `[]` | Extra self-contained repos to review alongside the root (root config only). See [Reviewing multiple directories](#reviewing-multiple-directories). |

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

## Reviewing multiple directories

By default the hook reviews only the repo it runs in. To also review other git working directories -- for example a separately-versioned repo nested inside your checkout (its own `.git`, remote, and base branch, gitignored from the outer repo) -- list them in the **root** config:

```json
{ "stop_hook": { "additional_git_directories": [".external_worktrees/default-workspace-template"] } }
```

Key properties:

- **Self-contained per repo.** Each listed dir must be a distinct git repo with its own `.reviewer/settings.json` (plus optional `.local.json`). That config is the sole source of truth for how the dir is reviewed: its `base_branch`, `remote`, which gates run, `ci.*`, etc. Its markers, logs, and PR/CI outputs all live inside its own `.reviewer/`, exactly as if the hook ran there standalone.
- **Root is always reviewed** implicitly; the list only *adds* directories. Paths are relative to the root repo.
- **Absent dirs are skipped.** The root config is shared by every checkout, but a nested repo is typically only present in the checkouts actively working on it. A listed dir that doesn't exist is quietly ignored (noted in the log), so the list can name a dir that is only sometimes cloned.
- **Hard error on misconfiguration.** A listed dir that *does* exist but is not a distinct git repo, is not the toplevel of its own repo, or lacks its own `.reviewer/settings.json`, blocks the hook -- so a dir that is really there can never silently go unreviewed.
- **Global vs. per-dir.** `stop_hook.enabled_when` (master switch) is read once from the root config; the conversation-review gate is session-scoped and runs once at the root. Everything else (base branch, remote, autofix/architecture/CI, uncommitted enforcement, docs-only skip) is per-dir. The `CODE_GUARDIAN_STOP_HOOK__BASE_BRANCH` env override is likewise root-scoped: it is per-agent config for the agent's own repo (e.g. mngr exports it per worktree), so a secondary dir's base branch always comes from that dir's own settings.
- **Unified review gates.** There is one `/autofix` and one `/verify-architecture` per stop cycle covering all dirs -- not one per dir. Each spawns a **single** review sub-agent that holds every reviewed repo's full diff at once and reviews them together, so cross-repo coupling (e.g. one repo consuming an interface another repo changed) is caught natively; fixes land in whichever repo the issue lives in. Each dir keeps its own dir-local markers, so a gate is satisfied only when every changed dir has a current marker. Because the invocation is unified, each changed dir's own `autofix.append_to_prompt` / `verify_architecture.append_to_prompt` is folded (deduped) into the single command hint -- a secondary dir's extra instructions are not dropped. (`verify_conversation.append_to_prompt` stays root-only, since conversation review is root-scoped.)
- **Toggling a dir's gates.** The per-gate toggle skills (`reviewer-autofix-*`, `reviewer-ci-*`, `reviewer-verify-architecture-*`) accept an optional directory argument to target that dir's `.reviewer/settings.local.json`; without one they edit the root's.
- **Gitignore the runtime dirs.** Each reviewed repo must gitignore `.reviewer/outputs/` and `.reviewer/logs/` (the hook writes there every run); otherwise the uncommitted-changes check will trip. `.reviewer/settings.json` is committed.
- **Known limitation.** Gates key off each dir's own HEAD/diff. If a sibling changes a surface a dependent dir consumes while the dependent dir's own diff is unchanged, the single review pass still sees both dirs and can flag the impact, but there is no forced re-review of the unchanged consuming dir.

## Stuck agent detection

The orchestrator tracks consecutive blocked attempts at the same *composite state* (all reviewed dirs' HEADs) in `.reviewer/outputs/stop_hook_consecutive_blocks`. After `stop_hook.max_consecutive_blocks` (default 3) consecutive blocks, it lets the agent through with a warning. This is a unified safety hatch covering all dirs and gates (review gates and CI).

## Issue categories

The plugin ships default issue categories. To customize them for your project, run `/imbue-code-guardian:reviewer-init-categories` to copy the defaults to `.reviewer/code-issue-categories.md` and `.reviewer/conversation-issue-categories.md`, then edit directly. The skills check `.reviewer/` first, falling back to plugin defaults.

## Agents

- **verify-and-fix** -- Autonomous code verifier and fixer (used by autofix)
- **analyze-architecture** -- Evaluates whether branch changes fit codebase patterns (used by verify-architecture)
- **validate-diff** -- Quick sanity check on a branch's diff (used by autofix and verify-architecture)
- **review-conversation** -- Reviews conversation transcripts for behavioral issues (used by verify-conversation)
