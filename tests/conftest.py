"""Fixtures for the stop hook tests.

Tests are hermetic: no network, no dependence on the developer's git config, and
no CODE_GUARDIAN_* leaking in from the surrounding session. Every test gets its
own git repo under tmp_path, and the test process never changes directory -- the
scripts are driven as subprocesses with an explicit cwd and env.

The scripts are shell, so every helper here is a black-box call: assertions are
on exit code, output, and files on disk, never on internal state.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "imbue-code-guardian" / "scripts"

# gh is the only thing in the hook that talks to GitHub, and a test that reaches
# the real API can hang, leak, or reopen someone's PR. Every repo gets this stub,
# so reaching gh without meaning to is a refusal rather than a network call;
# tests that expect gh calls overwrite it via repo.stub.
_REFUSING_GH = """
echo "unexpected gh call: $*" >&2
exit 1
"""


@dataclass(frozen=True)
class Result:
    """The outcome of one script run."""

    exit_code: int
    stdout: str
    stderr: str = ""

    @property
    def output(self) -> str:
        """Both streams as one string.

        Runs that capture combined leave stderr empty, so this is their real
        interleaved stream. Runs that keep the streams apart concatenate here.
        """
        return self.stdout + self.stderr


class Repo:
    """A throwaway git repo, plus the ways the tests drive the hook against it."""

    def __init__(self, path: Path, stub_dir: Path) -> None:
        self.path = path
        # Outside the work tree: a stub directory inside it would show up as an
        # untracked file and trip the very gate several tests are checking.
        self.stub_dir = stub_dir
        self.stub_dir.mkdir(parents=True, exist_ok=True)
        self.stub("gh", _REFUSING_GH)

    # -- files ---------------------------------------------------------------
    def write(self, rel: str, content: str) -> Path:
        path = self.path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def read(self, rel: str) -> str:
        return (self.path / rel).read_text()

    def exists(self, rel: str) -> bool:
        return (self.path / rel).exists()

    def settings(self, config: Mapping[str, Any] | str) -> Path:
        return self._write_config(".reviewer/settings.json", config)

    def local_settings(self, config: Mapping[str, Any] | str) -> Path:
        return self._write_config(".reviewer/settings.local.json", config)

    def _write_config(self, rel: str, config: Mapping[str, Any] | str) -> Path:
        # A str is written verbatim, so tests can hand over malformed JSON.
        text = config if isinstance(config, str) else json.dumps(config, indent=2)
        return self.write(rel, text)

    def stub(self, name: str, body: str) -> Path:
        """Put a fake executable on PATH, ahead of the real one."""
        path = self.stub_dir / name
        path.write_text(f"#!/usr/bin/env bash\n{body}\n")
        path.chmod(0o755)
        return path

    # -- git -----------------------------------------------------------------
    def git(self, *args: str) -> str:
        proc = subprocess.run(
            ["git", *args],
            cwd=self.path,
            env=self.env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=True,
        )
        return proc.stdout.strip()

    def commit_all(self, message: str = "commit") -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message, "--allow-empty")

    def checkout_new(self, branch: str) -> None:
        self.git("checkout", "-q", "-b", branch)

    @property
    def head(self) -> str:
        return self.git("rev-parse", "HEAD")

    # -- running -------------------------------------------------------------
    def env(self, extra: Mapping[str, str] | None = None) -> dict[str, str]:
        """The environment every subprocess gets.

        CODE_GUARDIAN_* outranks every config file and the mngr integration
        exports several into each session, so they are stripped -- otherwise the
        tests read the developer's settings instead of their own. The git config
        files are neutralized for the same reason: a personal `.reviewer/` ignore
        rule would mask exactly what the gitignore tests check.
        """
        env = {k: v for k, v in os.environ.items() if not k.startswith("CODE_GUARDIAN_")}
        env["PATH"] = os.pathsep.join([str(self.stub_dir), env["PATH"]])
        env["GIT_CONFIG_GLOBAL"] = os.devnull
        env["GIT_CONFIG_SYSTEM"] = os.devnull
        if extra:
            env.update({k: str(v) for k, v in extra.items()})
        return env

    def _run(
        self,
        argv: list[str],
        *,
        env: Mapping[str, str] | None,
        combine: bool,
        stderr_to_devnull: bool = False,
    ) -> Result:
        if combine:
            stderr = subprocess.STDOUT
        elif stderr_to_devnull:
            stderr = subprocess.DEVNULL
        else:
            stderr = subprocess.PIPE
        proc = subprocess.run(
            argv,
            cwd=self.path,
            env=self.env(env),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=stderr,
            text=True,
        )
        # Trailing newlines go, matching what `$(...)` handed the shell tests.
        return Result(proc.returncode, proc.stdout.rstrip("\n"), (proc.stderr or "").rstrip("\n"))

    def run_script(self, script: str, *args: str, env: Mapping[str, str] | None = None) -> Result:
        """Run a hook script with both streams combined, in write order."""
        return self._run(["bash", str(SCRIPTS_DIR / script), *args], env=env, combine=True)

    def run_script_stdout(self, script: str, *args: str, env: Mapping[str, str] | None = None) -> Result:
        """Run a hook script, dropping stderr, to pin down what stdout alone carries."""
        return self._run(
            ["bash", str(SCRIPTS_DIR / script), *args],
            env=env,
            combine=False,
            stderr_to_devnull=True,
        )

    def run_common(self, snippet: str, env: Mapping[str, str] | None = None) -> Result:
        """Evaluate a snippet with stop_hook_common.sh sourced, streams kept apart.

        The target runs `set -e` and defines its colours at source time, so it
        gets its own shell; `set +e` after sourcing keeps a snippet's expected
        failure from killing that shell before it reports.
        """
        return self._run(
            [
                "bash",
                "-c",
                'source "$1"; set +e; eval "$2"',
                "_",
                str(SCRIPTS_DIR / "stop_hook_common.sh"),
                snippet,
            ],
            env=env,
            combine=False,
        )

    def read_config(self, key: str, default: str = "", env: Mapping[str, str] | None = None) -> Result:
        """Call read_json_config against .reviewer/settings.json, streams combined.

        config_utils.sh runs `set -euo pipefail` at top level, so it gets its own
        shell rather than landing on the test runner.
        """
        return self._run(
            [
                "bash",
                "-c",
                'source "$1"; read_json_config "$2" "$3" "$4"',
                "_",
                str(SCRIPTS_DIR / "config_utils.sh"),
                ".reviewer/settings.json",
                key,
                default,
            ],
            env=env,
            combine=True,
        )


@pytest.fixture
def repo(tmp_path: Path) -> Repo:
    """An empty git repo on `main`, isolated from the developer's git config."""
    work_tree = tmp_path / "repo"
    work_tree.mkdir()
    repo = Repo(work_tree, stub_dir=tmp_path / "stubs")
    repo.git("init", "-q", "-b", "main", ".")
    repo.git("config", "user.email", "test@example.com")
    repo.git("config", "user.name", "Test")
    repo.git("config", "commit.gpgsign", "false")
    return repo
