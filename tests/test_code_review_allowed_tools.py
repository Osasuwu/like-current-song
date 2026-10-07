"""Drift guard for the code-review action's `--allowed-tools` / `--disallowed-tools` lists.

The reviewer runs HEADLESS (`anthropics/claude-code-action@v1`): a tool absent
from `--allowed-tools` is DENIED outright, there is no human to approve it. Both
lists are the contract with the harness, so they are pinned here: the grants the
reviewer needs, the wholesale `git`/`gh` read grants, the mutating verbs carved
back out, and the one write grant, `Edit(./.review/findings.json)`.

The reviewer no longer posts a PR comment; its only output is the findings file.
`Edit(path)` is the one path-scoped write rule the harness consults (a
`Write(path)` rule is never matched, so an unscoped `Write` could write anywhere).
`gh pr comment` is denied so the review has exactly one output channel.
Design: Osasuwu/jarvis#1964, ported in #226.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = next(
    p for p in Path(__file__).resolve().parents if (p / ".github" / "workflows").is_dir()
)
LIVE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "code-review.yml"

FINDINGS_PATH = ".review/findings.json"
FINDINGS_GRANT = f"Edit(./{FINDINGS_PATH})"

REQUIRED_TOOLS = (
    # Native file-reading tools; the reviewer prompt steers it to these.
    "Read",
    "Grep",
    "Glob",
    "Bash(wc:*)",
    # `gh api` stays on narrow grants: its `-X <method>`/`--input` mutation flags can
    # appear anywhere in the command line, so a prefix-matched disallow cannot catch
    # every spelling the way it can for `gh pr`/`gh issue`.
    "Bash(gh api repos/*/commits/*:*)",
    "Bash(gh api repos/*/compare/*:*)",
    # Headless permission matching splits compound commands on ; | && and newlines and
    # checks each part, so an un-allowlisted `echo` prefix denies the whole command.
    "Bash(echo:*)",
    # The findings file is the reviewer's only output.
    FINDINGS_GRANT,
)

# Wholesale grants: the allowlist model of one entry per git/gh verb needed a patch
# for every unenumerated read verb the reviewer reached for.
WHOLESALE_GRANTS = (
    "Bash(git:*)",
    "Bash(gh pr:*)",
    "Bash(gh issue:*)",
    "Bash(gh search:*)",
    "Bash(gh label:*)",
)

# The mutating verbs in the wholesale-granted noun-groups must stay carved out, or
# the grants become a real mutation surface if the job token ever widens.
REQUIRED_DISALLOWED = (
    "Bash(gh pr merge:*)",
    "Bash(gh pr close:*)",
    "Bash(gh pr edit:*)",
    "Bash(gh pr reopen:*)",
    "Bash(gh pr review:*)",
    "Bash(gh pr ready:*)",
    "Bash(gh pr create:*)",
    "Bash(gh pr lock:*)",
    "Bash(gh pr unlock:*)",
    # The PR comment is for humans and not produced by this job.
    "Bash(gh pr comment:*)",
    "Bash(gh issue create:*)",
    "Bash(gh issue edit:*)",
    "Bash(gh issue close:*)",
    "Bash(gh issue reopen:*)",
    "Bash(gh issue delete:*)",
    "Bash(gh issue lock:*)",
    "Bash(gh issue unlock:*)",
    "Bash(gh issue pin:*)",
    "Bash(gh issue unpin:*)",
    "Bash(gh issue transfer:*)",
    "Bash(gh issue comment:*)",
    "Bash(gh label create:*)",
    "Bash(gh label edit:*)",
    "Bash(gh label delete:*)",
    "Bash(git push:*)",
    "Bash(git commit:*)",
    "Bash(git merge:*)",
    "Bash(git reset:*)",
    "Bash(git rebase:*)",
    "Bash(git cherry-pick:*)",
    "Bash(git stash:*)",
    "Bash(git clean:*)",
    "Bash(git rm:*)",
    "Bash(git mv:*)",
    "Bash(git apply:*)",
    "Bash(git am:*)",
    "Bash(git checkout:*)",
    "Bash(git switch:*)",
    "Bash(git restore:*)",
)

_ALLOWED_TOOLS_RE = re.compile(r'--allowed-tools\s+"([^"]*)"')
_DISALLOWED_TOOLS_RE = re.compile(r'--disallowed-tools\s+((?:"[^"]*"\s*)+)')


def _allowed_tools_blocks(path: Path) -> list[str]:
    """Every `--allowed-tools "..."` string in the file."""
    text = path.read_text(encoding="utf-8")
    blocks = _ALLOWED_TOOLS_RE.findall(text)
    assert blocks, f"no --allowed-tools line found in {path}"
    return blocks


def _disallowed_tools_blocks(path: Path) -> list[list[str]]:
    """Every `--disallowed-tools "a" "b" ...` entry list in the file."""
    text = path.read_text(encoding="utf-8")
    raw_blocks = _DISALLOWED_TOOLS_RE.findall(text)
    assert raw_blocks, f"no --disallowed-tools line found in {path}"
    return [re.findall(r'"([^"]*)"', raw) for raw in raw_blocks]


@pytest.mark.parametrize("path", [LIVE_WORKFLOW], ids=["live"])
def test_required_git_tools_present(path: Path) -> None:
    for block in _allowed_tools_blocks(path):
        for tool in REQUIRED_TOOLS:
            assert tool in block, (
                f"{path.name}: allowlist missing {tool!r} — headless action will "
                f"DENY it. Allowlist was: {block}"
            )


@pytest.mark.parametrize("path", [LIVE_WORKFLOW], ids=["live"])
def test_wholesale_git_and_gh_grants_present(path: Path) -> None:
    """Dropping a wholesale grant re-opens the per-verb whack-a-mole."""
    for block in _allowed_tools_blocks(path):
        for tool in WHOLESALE_GRANTS:
            assert tool in block, (
                f"{path.name}: allowlist missing wholesale grant {tool!r}. Allowlist was: {block}"
            )


@pytest.mark.parametrize("path", [LIVE_WORKFLOW], ids=["live"])
def test_mutating_verbs_disallowed(path: Path) -> None:
    """Every mutating verb of the wholesale-granted noun-groups stays disallowed."""
    for block in _disallowed_tools_blocks(path):
        for tool in REQUIRED_DISALLOWED:
            assert tool in block, (
                f"{path.name}: --disallowed-tools missing {tool!r} — the wholesale "
                f"allow grants make this a mutation surface without it. Disallowed-tools was: {block}"
            )


@pytest.mark.parametrize("path", [LIVE_WORKFLOW], ids=["live"])
def test_only_write_grant_is_the_findings_file(path: Path) -> None:
    """An unscoped `Write` or bare `Edit` lets the reviewer — an LLM
    reading attacker-controlled text — write anywhere in the workspace. The one
    write grant is `Edit(./.review/findings.json)`."""
    for block in _allowed_tools_blocks(path):
        entries = block.split(",")
        writers = [e for e in entries if e.split("(")[0] in ("Write", "Edit", "MultiEdit")]
        assert writers == [FINDINGS_GRANT], (
            f"{path.name}: write-capable grants must be exactly [{FINDINGS_GRANT!r}], got {writers}"
        )


def test_findings_path_in_job_env_matches_the_edit_grant() -> None:
    """The job seeds, validates and uploads $FINDINGS; the reviewer may edit only
    the granted path. Two artifacts that must agree."""
    spec = yaml.safe_load(LIVE_WORKFLOW.read_text(encoding="utf-8"))
    assert spec["jobs"]["review"]["env"]["FINDINGS"] == FINDINGS_PATH
