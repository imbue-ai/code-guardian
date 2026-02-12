# hammer-verify

A [Claude Code plugin](https://code.claude.com/docs/en/plugins) that automatically finds and fixes code issues on your current branch. It iteratively verifies your changes, plans and implements fixes as separate commits, then lets you review and keep or revert each one.

## How it works

1. **Verify** - A fresh subagent diffs your branch against the base and scans for ~30 categories of issues (logic errors, security problems, missing tests, naming violations, etc.)
2. **Fix** - Each issue gets a plan, an implementation, and its own commit
3. **Repeat** - New iterations run with a clean context until no more issues are found (up to 10 rounds)
4. **Review** - Every fix is presented for your approval. Rejected fixes are reverted automatically

## Installation

Requires [Claude Code](https://code.claude.com/docs/en/quickstart) v1.0.33 or later.

Clone the repo and install the plugin:

```bash
git clone https://github.com/imbue-ai/hammer-verify.git
```

```
/plugin marketplace add ./hammer-verify
/plugin install hammer-verify@hammer-verify
```

## Usage

Check out the branch you want to verify, then run:

```
/hammer-verify:autofix
```

The plugin will diff against `main` by default. To use a different base branch, set the `GIT_BASE_BRANCH` environment variable:

```bash
export GIT_BASE_BRANCH=origin/main
```

## What it checks

The verifier scans for issues across these categories:

- **Correctness** - logic errors, incorrect algorithms, runtime error risk, syntax issues
- **Code quality** - poor naming, duplicate code, refactoring opportunities, abstraction violations
- **Reliability** - missing error handling, silent failures, resource leaks
- **Security** - hardcoded secrets, insecure patterns
- **Completeness** - missing test coverage, incomplete integration, dependency issues
- **Consistency** - commit message/implementation mismatch, documentation drift, instruction file violations, leftover artifacts from the change process
