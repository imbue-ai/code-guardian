# imbue-code-guardian

A [Claude Code plugin](https://code.claude.com/docs/en/plugins) for automated code review enforcement. When enabled, a Stop hook blocks Claude from finishing until autofix, architecture verification, and conversation review have been run.

## How it works

1. **Verify** - A fresh agent diffs your branch against the base and scans for ~30 categories of issues (logic errors, security problems, missing tests, naming violations, etc.)
2. **Fix** - Each issue gets a plan, an implementation, and its own commit
3. **Repeat** - New iterations run with a clean context until no more issues are found (up to 10 rounds)
4. **Review** - Every fix is presented for your approval. Rejected fixes are reverted automatically

## Installation

Requires [Claude Code](https://code.claude.com/docs/en/quickstart) v1.0.33 or later.

```
claude plugin marketplace add imbue-ai/code-guardian && claude plugin install imbue-code-guardian@imbue-code-guardian
```

## Usage

Check out the branch you want to verify, then run:

```
/imbue-code-guardian:autofix
```
or
```
/autofix
```

The plugin will diff against `main` by default. To use a different base branch, set the `GIT_BASE_BRANCH` environment variable:

```bash
export GIT_BASE_BRANCH=origin/main
```

## Enabling the stop hook

The stop hook is off by default. After installing, enable enforcement:

```
/imbue-code-guardian:reviewer-enable
```

See [plugins/imbue-code-guardian/README.md](plugins/imbue-code-guardian/README.md) for full documentation on configuration, skills, and enforcement behavior.

## What it checks

The verifier scans for issues across these categories:

- **Correctness** - logic errors, incorrect algorithms, runtime error risk, syntax issues
- **Code quality** - poor naming, duplicate code, refactoring opportunities, abstraction violations
- **Reliability** - missing error handling, silent failures, resource leaks
- **Security** - hardcoded secrets, insecure patterns
- **Completeness** - missing test coverage, incomplete integration, dependency issues
- **Consistency** - commit message/implementation mismatch, documentation drift, instruction file violations, leftover artifacts from the change process
