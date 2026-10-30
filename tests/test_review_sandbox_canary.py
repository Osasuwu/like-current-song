"""The sandbox canary's judgement (#228): what counts as the sandbox holding.

The canary's CI run is the only evidence bubblewrap held. These tests pin the
script that reads that run, so a canary that attacked nothing, or a sandbox that
blocked nothing, cannot read as green.
"""

from __future__ import annotations

import importlib.util
import json
import re
from pathlib import Path

import pytest
import yaml

ROOT = next(p for p in Path(__file__).resolve().parents if (p / ".github" / "workflows").is_dir())

_spec = importlib.util.spec_from_file_location(
    "review_sandbox_canary", ROOT / ".github" / "scripts" / "review_sandbox_canary.py"
)
canary = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(canary)

WS = "/work/repo"
TMP = "/work/_temp"
HOME = "/home/runner"
SHA = "a" * 40
EROFS = "fatal: could not create file: Read-only file system"


def _targets():
    return canary.attack_commands(WS, TMP, HOME)


def _log(*runs):
    """An execution log holding (command, output, is_error) Bash calls in order."""
    log = []
    for i, (command, output, is_error) in enumerate(runs):
        tool_id = f"toolu_{i}"
        log.append(
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": tool_id,
                            "name": "Bash",
                            "input": {"command": command},
                        }
                    ]
                },
            }
        )
        log.append(
            {
                "type": "user",
                "message": {
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": tool_id,
                            "content": output,
                            "is_error": is_error,
                        }
                    ]
                },
            }
        )
    return log


def _attacks_blocked():
    return [(command, EROFS, True) for command, _ in _targets()]


def _controls_passed():
    return [
        (canary.tmpdir_write_command(), "", False),
        (canary.tmpdir_read_command(), f"canary-ok-{SHA}\n", False),
        (canary.network_command("o/r", SHA), f"{SHA}\n", False),
    ]


def _errors(log, **overrides):
    return canary.run_errors(log, WS, TMP, HOME, overrides.get("repo", "o/r"), SHA)


# --- what the execution log says ---------------------------------------------


def test_every_attack_blocked_and_every_control_passing_is_clean():
    assert _errors(_log(*_attacks_blocked(), *_controls_passed())) == []


def test_attacks_cover_all_five_commands_and_all_three_trees():
    commands = [command for command, _ in _targets()]
    for verb in ("git log", "git show", "git diff", "git blame", "git rev-list"):
        assert any(c.startswith(verb) for c in commands)
    targets = [target for _, target in _targets()]
    assert f"{WS}/.github/scripts/code_gate_verdict.py" in targets
    assert f"{WS}/.git/info/exclude" in targets
    assert f"{WS}/.git/index" in targets
    assert f"{WS}/CLAUDE.md" in targets
    assert any(t.startswith(f"{TMP}/") for t in targets)
    assert any(t.startswith(f"{HOME}/") for t in targets)


def test_every_attack_spells_the_flag_past_the_deny_pattern():
    for command, _ in _targets():
        assert "--o''utput=" in command


def test_an_attack_that_never_ran_is_an_error():
    runs = _attacks_blocked()
    skipped_command = runs[0][0]
    errors = _errors(_log(*runs[1:], *_controls_passed()))
    assert any(skipped_command in e and "never ran" in e for e in errors)


def test_an_attack_that_succeeded_is_an_error():
    runs = _attacks_blocked()
    runs[2] = (runs[2][0], "", False)
    errors = _errors(_log(*runs, *_controls_passed()))
    assert any(runs[2][0] in e and "was not blocked" in e for e in errors)


@pytest.mark.parametrize(
    "refusal",
    [
        "Claude requested permissions to use Bash, but you haven't granted it yet.",
        "fatal: unrecognized argument: --output",
    ],
    ids=["harness-refusal", "git-usage-error"],
)
def test_an_attack_stopped_by_anything_but_the_filesystem_is_an_error(refusal):
    runs = _attacks_blocked()
    runs[1] = (runs[1][0], refusal, True)
    errors = _errors(_log(*runs, *_controls_passed()))
    assert any(runs[1][0] in e and "was not blocked" in e for e in errors)


def test_an_attack_the_harness_denied_is_an_error_whatever_it_printed():
    log = _log(*_attacks_blocked(), *_controls_passed())
    log.append({"type": "system", "subtype": "permission_denied", "tool_use_id": "toolu_0"})
    errors = _errors(log)
    assert any(_targets()[0][0] in e and "was not blocked" in e for e in errors)


def test_a_failed_tmpdir_write_is_an_error():
    controls = _controls_passed()
    controls[0] = (controls[0][0], EROFS, True)
    controls[1] = (controls[1][0], "cat: no such file", True)
    errors = _errors(_log(*_attacks_blocked(), *controls))
    assert any("$TMPDIR" in e for e in errors)


def test_a_tmpdir_control_that_never_ran_is_an_error():
    errors = _errors(_log(*_attacks_blocked()))
    assert any("$TMPDIR" in e for e in errors)


def test_a_network_control_without_the_sha_is_an_error():
    controls = _controls_passed()
    controls[2] = (controls[2][0], "connection refused", True)
    errors = _errors(_log(*_attacks_blocked(), *controls))
    assert any("network" in e for e in errors)


# --- what the disk says ------------------------------------------------------


def _tree(tmp_path):
    (tmp_path / ".github" / "scripts").mkdir(parents=True)
    (tmp_path / ".github" / "scripts" / "code_gate_verdict.py").write_text("gate\n")
    (tmp_path / ".git" / "info").mkdir(parents=True)
    (tmp_path / ".git" / "info" / "exclude").write_text("# ignore\n")
    (tmp_path / "CLAUDE.md").write_text("rules\n")
    (tmp_path / ".claude").mkdir()
    (tmp_path / ".claude" / "settings.json").write_text("{}\n")
    return tmp_path


@pytest.mark.parametrize(
    "path",
    [
        ".github/scripts/code_gate_verdict.py",
        ".git/info/exclude",
        "CLAUDE.md",
        ".claude/settings.json",
    ],
)
def test_a_changed_guarded_file_differs(tmp_path, path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    (root / path).write_text("rewritten\n")
    assert canary.changed(before, canary.snapshot(root, index="index")) == [path]


@pytest.mark.parametrize(
    "path",
    [".ripgreprc", ".mcp.json", ".gitmodules", ".claude/settings.local.json", ".github/scripts/x.py"],
)
def test_a_guarded_file_created_during_the_run_differs(tmp_path, path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    (root / path).write_text("planted\n")
    assert canary.changed(before, canary.snapshot(root, index="index")) == [path]


def test_a_deleted_guarded_file_differs(tmp_path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    (root / "CLAUDE.md").unlink()
    assert canary.changed(before, canary.snapshot(root, index="index")) == ["CLAUDE.md"]


def test_an_unchanged_tree_does_not_differ(tmp_path):
    root = _tree(tmp_path)
    assert canary.changed(canary.snapshot(root, index="index"), canary.snapshot(root, index="index")) == []


def test_a_changed_index_listing_differs(tmp_path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="100644 abc 0\tREADME.md\n")
    after = canary.snapshot(root, index="garbage")
    assert canary.changed(before, after) == [".git/index"]


def test_an_unreadable_index_differs_from_a_readable_one(tmp_path):
    (tmp_path / "not-a-repo").mkdir()
    assert "unreadable" in canary.index_listing(tmp_path / "not-a-repo")


def test_a_file_written_outside_the_workspace_is_an_error(tmp_path):
    (tmp_path / "review-sandbox-canary").write_text("written\n")
    targets = [("cmd", str(tmp_path / "review-sandbox-canary")), ("cmd", str(tmp_path / "other"))]
    assert canary.outside_errors(targets, str(tmp_path / "ws")) == [
        f"{tmp_path / 'review-sandbox-canary'} exists"
    ]


def test_workspace_targets_are_left_to_the_snapshot():
    targets = [("cmd", f"{WS}/CLAUDE.md")]
    assert canary.outside_errors(targets, WS) == []


# --- the verify command ------------------------------------------------------


def _verify(tmp_path, monkeypatch, log):
    root = _tree(tmp_path)
    snap = tmp_path.parent / f"{tmp_path.name}-snap.json"
    exec_log = tmp_path.parent / f"{tmp_path.name}-exec.json"
    exec_log.write_text(json.dumps(log), encoding="utf-8")
    monkeypatch.chdir(root)
    monkeypatch.setenv("GITHUB_WORKSPACE", str(root))
    monkeypatch.setenv("RUNNER_TEMP", str(root.parent / "no-temp"))
    monkeypatch.setenv("HOME", str(root.parent / "no-home"))
    assert canary.main(["snapshot", "--out", str(snap)]) == 0
    return root, canary.main(
        ["verify", "--snapshot", str(snap), "--execution-log", str(exec_log),
         "--repo", "o/r", "--sha", SHA]
    )


def _clean_log(root):
    workspace, temp, home = str(root), str(root.parent / "no-temp"), str(root.parent / "no-home")
    attacks = [(c, EROFS, True) for c, _ in canary.attack_commands(workspace, temp, home)]
    return _log(*attacks, *_controls_passed())


def test_verify_passes_a_run_where_the_sandbox_held(tmp_path, monkeypatch):
    assert _verify(tmp_path, monkeypatch, _clean_log(tmp_path))[1] == 0


def test_verify_fails_a_missing_execution_log(tmp_path, monkeypatch, capsys):
    root = _tree(tmp_path)
    snap = tmp_path.parent / f"{tmp_path.name}-snap.json"
    monkeypatch.chdir(root)
    monkeypatch.setenv("GITHUB_WORKSPACE", str(root))
    monkeypatch.setenv("RUNNER_TEMP", str(root.parent / "no-temp"))
    monkeypatch.setenv("HOME", str(root.parent / "no-home"))
    canary.main(["snapshot", "--out", str(snap)])
    assert canary.main(
        ["verify", "--snapshot", str(snap), "--execution-log", "", "--repo", "o/r", "--sha", SHA]
    ) == 1
    assert "execution log" in capsys.readouterr().err


def test_verify_fails_when_a_log_error_is_found(tmp_path, monkeypatch):
    assert _verify(tmp_path, monkeypatch, _log())[1] == 1


def test_verify_fails_a_rewritten_guarded_file_even_with_a_clean_log(tmp_path, monkeypatch):
    root = _tree(tmp_path)
    snap = tmp_path.parent / f"{tmp_path.name}-snap.json"
    exec_log = tmp_path.parent / f"{tmp_path.name}-exec.json"
    exec_log.write_text(json.dumps(_clean_log(root)), encoding="utf-8")
    monkeypatch.chdir(root)
    monkeypatch.setenv("GITHUB_WORKSPACE", str(root))
    monkeypatch.setenv("RUNNER_TEMP", str(root.parent / "no-temp"))
    monkeypatch.setenv("HOME", str(root.parent / "no-home"))
    canary.main(["snapshot", "--out", str(snap)])
    (root / "CLAUDE.md").write_text("forged\n")
    assert canary.main(
        ["verify", "--snapshot", str(snap), "--execution-log", str(exec_log),
         "--repo", "o/r", "--sha", SHA]
    ) == 1


def test_an_attack_that_exited_zero_is_an_error():
    runs = _attacks_blocked()
    runs[0] = (runs[0][0], EROFS, False)
    errors = _errors(_log(*runs, *_controls_passed()))
    assert any(runs[0][0] in e and "was not blocked" in e for e in errors)


def test_a_network_control_that_never_ran_is_an_error():
    errors = _errors(_log(*_attacks_blocked(), *_controls_passed()[:2]))
    assert any("network" in e for e in errors)


# --- the workflow carries the reviewer's boundary, unchanged -----------------
#
# A canary on a different pin or different settings would prove nothing about the
# reviewer. These walk the parsed YAML of both workflows.

WORKFLOWS = ROOT / ".github" / "workflows"
REVIEW = yaml.safe_load((WORKFLOWS / "code-review.yml").read_text(encoding="utf-8"))
CANARY = yaml.safe_load((WORKFLOWS / "review-sandbox-canary.yml").read_text(encoding="utf-8"))
HELD = CANARY["jobs"]["sandbox-holds"]
FAIL_CLOSED = CANARY["jobs"]["sandbox-required"]
TRUSTED = "$RUNNER_TEMP/trusted"
PINNED = "--settings ${{ runner.temp }}/trusted/review-sandbox.json\n"
PLACEHOLDERS = ("${{ github.workspace }}", "${{ runner.temp }}", "${{ env.CANARY_HOME }}")


def _step(steps, step_id):
    (found,) = [s for s in steps if s.get("id") == step_id]
    return found


def _position(steps, step_id):
    return steps.index(_step(steps, step_id))


def _reviewer():
    (found,) = [s for s in REVIEW["jobs"]["review"]["steps"] if s.get("id") == "review1"]
    return found


def _granted(claude_args):
    return set(re.search(r'--allowed-tools "([^"]+)"', claude_args).group(1).split(","))


def _denied(claude_args):
    return re.search(r"--disallowed-tools (.+)", claude_args).group(1)


def test_canary_runs_on_the_pr_head_for_every_file_of_the_boundary():
    trigger = CANARY[True]
    assert "pull_request_target" not in trigger
    assert "workflow_dispatch" in trigger
    assert set(trigger["pull_request"]["paths"]) >= {
        ".github/workflows/code-review.yml",
        ".github/workflows/review-sandbox-canary.yml",
        ".github/review-sandbox.json",
        ".github/scripts/code_gate_verdict.py",
        ".github/scripts/review_sandbox_canary.py",
    }
    (checkout,) = [s for s in HELD["steps"] if "actions/checkout" in s.get("uses", "")]
    assert "ref" not in checkout.get("with", {})


@pytest.mark.parametrize("job", [HELD, FAIL_CLOSED], ids=["held", "fail-closed"])
def test_canary_runs_the_reviewers_action_pin_and_settings(job):
    action = _step(job["steps"], "canary")
    assert action["uses"] == _reviewer()["uses"]
    assert PINNED in action["with"]["claude_args"]
    assert PINNED in _reviewer()["with"]["claude_args"]


def test_canary_grants_what_the_reviewer_grants_plus_only_rev_list():
    canary_args = _step(HELD["steps"], "canary")["with"]["claude_args"]
    review_args = _reviewer()["with"]["claude_args"]
    assert _granted(canary_args) - _granted(review_args) == {"Bash(git rev-list:*)"}
    assert _granted(review_args) - _granted(canary_args) == set()
    assert _denied(canary_args) == _denied(review_args)


def test_canary_prompt_makes_every_attack_and_both_controls():
    prompt = _step(HELD["steps"], "canary")["with"]["prompt"]
    for command, _ in canary.attack_commands(*PLACEHOLDERS):
        assert command in prompt
    assert canary.tmpdir_write_command() in prompt
    assert canary.tmpdir_read_command() in prompt
    assert (
        canary.network_command("${{ github.repository }}", "${{ github.event.pull_request.head.sha || github.sha }}")
        in prompt
    )


def test_held_job_snapshots_before_the_reviewer_and_judges_from_trusted_copies_after():
    steps = HELD["steps"]
    assert (
        _position(steps, "copy")
        < _position(steps, "pin")
        < _position(steps, "snapshot")
        < _position(steps, "canary")
        < _position(steps, "verify")
    )
    assert "continue-on-error" not in _step(steps, "pin")
    assert "cp .github/scripts/code_gate_verdict.py .github/scripts/review_sandbox_canary.py" in (
        _step(steps, "copy")["run"]
    )
    assert _step(steps, "canary")["continue-on-error"] is True
    for step_id in ("snapshot", "verify", "check-tree", "validate"):
        run = _step(steps, step_id)["run"]
        assert f'python -I "{TRUSTED}/' in run
        assert ".github/scripts/" not in run


@pytest.mark.parametrize("step_id", ["verify", "check-tree", "validate"])
def test_held_job_judges_even_when_the_reviewer_failed(step_id):
    step = _step(HELD["steps"], step_id)
    assert step["if"] == "always()"
    assert "continue-on-error" not in step


def test_held_job_keeps_the_env_scrub_and_read_only_token():
    assert HELD["env"]["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1"
    assert HELD["permissions"] == {"contents": "read", "pull-requests": "read"}


def test_fail_closed_job_has_no_bubblewrap_and_requires_the_reviewer_to_fail():
    steps = FAIL_CLOSED["steps"]
    assert not any("bubblewrap" in s.get("run", "") for s in steps)
    # With the scrub on, a missing bwrap crashes the reviewer for its own reason;
    # off, only failIfUnavailable can stop it.
    assert FAIL_CLOSED["env"]["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "0"
    action = _step(steps, "canary")
    assert action["continue-on-error"] is True
    verify = _step(steps, "verify")
    assert verify["if"] == "always()"
    assert verify["env"]["OUTCOME"] == "${{ steps.canary.outcome }}"
    assert '[ "$OUTCOME" = failure ]' in verify["run"]


def test_held_job_installs_bubblewrap_exactly_as_the_reviewer_does():
    (reviewer,) = [
        s
        for s in REVIEW["jobs"]["review"]["steps"]
        if s.get("name") == "Install subprocess isolation (bubblewrap)"
    ]
    assert _step(HELD["steps"], "install")["run"] == reviewer["run"]
    assert _position(HELD["steps"], "install") < _position(HELD["steps"], "canary")
