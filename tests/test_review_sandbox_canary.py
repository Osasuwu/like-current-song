"""The sandbox canary's judgement (#228): what counts as the sandbox holding.

The canary's CI run is the only evidence bubblewrap held. These tests pin the
script that reads that run, so a canary that attacked nothing, or a sandbox that
blocked nothing, cannot read as green.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import stat
from pathlib import Path

import pytest
import yaml

ROOT = next(p for p in Path(__file__).resolve().parents if (p / ".github" / "workflows").is_dir())

_spec = importlib.util.spec_from_file_location(
    "review_sandbox_canary", ROOT / ".github" / "scripts" / "review_sandbox_canary.py"
)
canary = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(canary)

_gate_spec = importlib.util.spec_from_file_location(
    "code_gate_verdict", ROOT / ".github" / "scripts" / "code_gate_verdict.py"
)
gate = importlib.util.module_from_spec(_gate_spec)
_gate_spec.loader.exec_module(gate)

WS = "/work/repo"
TMP = "/work/_temp"
HOME = "/home/runner"
SHA = "a" * 40
EROFS = "fatal: could not create file: Read-only file system"
BWRAP_DIED = "Exit code 1\nbwrap: Can't create file at /work/repo/scripts: Read-only file system"


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
        (canary.write_control_command(), "", False),
        (canary.network_command("o/r"), '[{"number":296}]\n', False),
    ]


def _errors(log):
    return canary.run_errors(log, WS, TMP, HOME, "o/r")


def _harness_refused(log, position):
    """The harness refused the Bash call at `position`, as the real log says so."""
    log.append(
        {
            "type": "system",
            "subtype": "permission_denied",
            "tool_use_id": f"toolu_{position}",
            "message": "A variable in this command can't be checked before it runs",
        }
    )
    return log


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


# What a later step or attempt 2 would load if the reviewer could write it.
LATER_STEP_TARGETS = {
    "trusted-copy": f"{TMP}/trusted/review-sandbox-canary",
    "actions": f"{HOME}/work/_actions/review-sandbox-canary",
    "user-settings": f"{HOME}/.claude/settings.json",
}


@pytest.mark.parametrize("target", LATER_STEP_TARGETS.values(), ids=LATER_STEP_TARGETS)
def test_an_attack_on_what_a_later_step_loads_must_be_refused(target):
    assert target in [t for _, t in _targets()]
    runs = [(c, "" if target in c else EROFS, target not in c) for c, _ in _targets()]
    errors = _errors(_log(*runs, *_controls_passed()))
    assert errors == [f"attack was not blocked by the filesystem: git log -1 --o''utput={target}"]


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


def test_an_event_whose_message_is_text_is_not_a_tool_call():
    log = _harness_refused(_log(*_attacks_blocked(), *_controls_passed()), 0)
    assert [r["denied"] for r in canary.bash_runs(log)] == [True] + [False] * (len(_targets()) + 1)


def test_a_sandbox_that_never_started_is_not_a_block():
    # bubblewrap's own failure says "Read-only file system" too: it must not read
    # as the filesystem refusing the attack, when no attack ran at all.
    runs = [(command, BWRAP_DIED, True) for command, _ in _targets()]
    errors = _errors(_log(*runs, *_controls_passed()))
    assert any("sandbox never started" in e and "/work/repo/scripts" in e for e in errors)
    assert sum("was not blocked" in e for e in errors) == len(runs)


def test_the_gate_and_the_canary_agree_on_a_dead_sandbox():
    """Two readers of one log: the scripts run as `python -I` and cannot share code."""
    dead = _log(("git log -1", BWRAP_DIED, True))
    assert "sandbox never started" in " ".join(_errors(dead))
    assert "sandbox never started" in " ".join(gate.sandbox_run_errors(dead))
    live = _log(("git log -1", "abc123 a commit\n", False))
    assert "sandbox never started" not in " ".join(_errors(live))
    assert gate.sandbox_run_errors(live) == []


def test_one_startup_failure_is_named_once():
    runs = [(command, BWRAP_DIED, True) for command, _ in _targets()]
    errors = _errors(_log(*runs, *_controls_passed()))
    assert sum("sandbox never started" in e for e in errors) == 1


def test_a_write_control_the_sandbox_refused_is_an_error():
    controls = _controls_passed()
    controls[0] = (controls[0][0], EROFS, True)
    errors = _errors(_log(*_attacks_blocked(), *controls))
    assert any("write control failed" in e for e in errors)


def test_a_write_control_the_harness_refused_says_it_proves_nothing():
    log = _harness_refused(_log(*_attacks_blocked(), *_controls_passed()), len(_attacks_blocked()))
    errors = _errors(log)
    assert any("write control" in e and "harness" in e for e in errors)


def test_a_write_control_that_never_ran_is_an_error():
    errors = _errors(_log(*_attacks_blocked(), *_controls_passed()[1:]))
    assert any("write control never ran" in e for e in errors)


def test_a_reworded_write_control_does_not_count():
    controls = _controls_passed()
    controls[0] = ("git log -1 > /dev/null", "", False)
    errors = _errors(_log(*_attacks_blocked(), *controls))
    assert any("write control never ran" in e for e in errors)


def test_a_network_control_refused_on_the_way_out_is_an_error():
    controls = _controls_passed()
    controls[1] = (controls[1][0], "connection refused", True)
    errors = _errors(_log(*_attacks_blocked(), *controls))
    assert any("network control failed" in e for e in errors)


def test_a_network_control_that_printed_no_pr_is_an_error():
    controls = _controls_passed()
    controls[1] = (controls[1][0], "[]\n", False)
    errors = _errors(_log(*_attacks_blocked(), *controls))
    assert any("network control failed" in e for e in errors)


def test_a_network_control_the_harness_refused_says_it_proves_nothing():
    log = _harness_refused(_log(*_attacks_blocked(), *_controls_passed()), len(_attacks_blocked()) + 1)
    errors = _errors(log)
    assert any("network control" in e and "harness" in e for e in errors)


def test_the_control_commands_avoid_what_the_harness_refused():
    # A variable in the path, and `gh api` under its prefix grant, were both refused
    # before Bash ran in run 41034402640. Those controls proved nothing.
    assert "$" not in canary.write_control_command()
    assert canary.network_command("o/r").startswith("gh pr list ")


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


@pytest.mark.parametrize("path", [".ripgreprc", ".mcp.json", "CLAUDE.local.md"])
def test_an_empty_guarded_file_created_during_the_run_differs(tmp_path, path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    (root / path).write_text("")
    assert canary.changed(before, canary.snapshot(root, index="index")) == [path]


def test_the_exclude_filter_applies_to_no_other_guarded_file(tmp_path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    with (root / "CLAUDE.md").open("a", encoding="utf-8", newline="\n") as rules:
        rules.write("/.npmrc\n")
    assert canary.changed(before, canary.snapshot(root, index="index")) == ["CLAUDE.md"]


def test_the_clis_exclude_block_does_not_differ(tmp_path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    with (root / ".git" / "info" / "exclude").open("a", encoding="utf-8", newline="\n") as exclude:
        exclude.write("\n# claude-code scrub-mode stubs\n/.npmrc\n/.env\n/.claude-pr/\n")
    assert canary.changed(before, canary.snapshot(root, index="index")) == []


@pytest.mark.parametrize("line", ["/scripts", "!/.npmrc", "*", "# claude-code scrub-mode stubs x"])
def test_any_other_line_in_exclude_differs(tmp_path, line):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    with (root / ".git" / "info" / "exclude").open("a", encoding="utf-8", newline="\n") as exclude:
        exclude.write(f"\n# claude-code scrub-mode stubs\n/.npmrc\n{line}\n")
    assert canary.changed(before, canary.snapshot(root, index="index")) == [".git/info/exclude"]


def test_the_exclude_block_tolerates_every_stub_the_gate_exempts():
    stubs = {name for name in gate.CLI_PLACEHOLDERS if "/" not in name}
    assert set(canary.CLI_STUBS) == stubs


def test_the_clis_empty_gitmodules_placeholder_does_not_differ(tmp_path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    (root / ".gitmodules").write_text("", encoding="utf-8")
    assert canary.changed(before, canary.snapshot(root, index="index")) == []


def test_a_symlink_at_gitmodules_differs(tmp_path):
    root = _tree(tmp_path)
    before = canary.snapshot(root, index="index")
    (root / "empty").write_text("", encoding="utf-8")
    try:
        os.symlink(root / "empty", root / ".gitmodules")
    except OSError:
        pytest.skip("this platform cannot make a symlink")
    assert canary.changed(before, canary.snapshot(root, index="index")) == [".gitmodules"]


def test_only_a_regular_file_counts_as_the_empty_placeholder(tmp_path, monkeypatch):
    # The real symlink above skips on Windows; this one runs everywhere.
    path = tmp_path / ".gitmodules"
    path.write_text("", encoding="utf-8")
    assert canary.is_empty_file(path)
    link = os.stat_result((stat.S_IFLNK | 0o777, 0, 0, 1, 0, 0, 0, 0, 0, 0))
    with monkeypatch.context() as patched:
        patched.setattr(canary.os, "lstat", lambda *a, **k: link)
        verdict = canary.is_empty_file(path)
    assert verdict is False


def test_an_empty_file_placeholder_that_is_absent_is_not_empty(tmp_path):
    assert not canary.is_empty_file(tmp_path / "nothing")


def test_write_control_passes_a_file_the_command_wrote(tmp_path):
    path = tmp_path / "control"
    path.write_text(f"canary-ok-{SHA}\n", encoding="utf-8")
    assert canary.write_control_errors(path) == []


def test_write_control_fails_a_file_it_did_not_write(tmp_path):
    path = tmp_path / "control"
    path.write_text("something else\n", encoding="utf-8")
    assert any("write control" in e for e in canary.write_control_errors(path))


def test_write_control_fails_with_no_file(tmp_path):
    assert any("write control" in e for e in canary.write_control_errors(tmp_path / "control"))


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
    assert canary.outside_errors(targets, str(tmp_path / "ws"), str(tmp_path / "home")) == [
        f"{tmp_path / 'review-sandbox-canary'} exists"
    ]


def test_workspace_targets_are_left_to_the_snapshot():
    targets = [("cmd", f"{WS}/CLAUDE.md")]
    assert canary.outside_errors(targets, WS, HOME) == []


def _user_settings(home, content="{}\n"):
    path = Path(home) / ".claude" / "settings.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    if content is not None:
        path.write_text(content, encoding="utf-8")
    return str(path)


def test_the_settings_file_the_action_writes_is_not_a_landed_attack(tmp_path):
    target = _user_settings(tmp_path, '{"enableAllProjectMcpServers": true}\n')
    assert canary.outside_errors([("cmd", target)], WS, str(tmp_path)) == []


@pytest.mark.parametrize(
    "content",
    [f"commit {SHA}\nAuthor: canary\n", "", "[]\n"],
    ids=["git-output", "emptied", "not-an-object"],
)
def test_a_rewritten_settings_file_is_an_error(tmp_path, content):
    # `git --output` truncates and writes commits: the file's existence says nothing.
    target = _user_settings(tmp_path, content)
    errors = canary.outside_errors([("cmd", target)], WS, str(tmp_path))
    assert errors == [f"{target} is not the action's settings"]


def test_a_settings_file_that_is_gone_is_an_error(tmp_path):
    target = _user_settings(tmp_path, content=None)
    assert canary.outside_errors([("cmd", target)], WS, str(tmp_path)) == [
        f"{target} is not the action's settings"
    ]


# --- the verify command ------------------------------------------------------


def _control_file(tmp_path, monkeypatch, content=f"canary-ok-{SHA}\n"):
    path = tmp_path.parent / f"{tmp_path.name}-control"
    if content is not None:
        path.write_text(content, encoding="utf-8")
    monkeypatch.setattr(canary, "WRITE_CONTROL", str(path))


def _home(root):
    """Per test: a run's home holds the settings file the action writes."""
    return root.parent / f"{root.name}-home"


def _run_env(root, monkeypatch):
    monkeypatch.chdir(root)
    monkeypatch.setenv("GITHUB_WORKSPACE", str(root))
    monkeypatch.setenv("RUNNER_TEMP", str(root.parent / "no-temp"))
    monkeypatch.setenv("HOME", str(_home(root)))


def _verify(tmp_path, monkeypatch, log):
    root = _tree(tmp_path)
    snap = tmp_path.parent / f"{tmp_path.name}-snap.json"
    exec_log = tmp_path.parent / f"{tmp_path.name}-exec.json"
    exec_log.write_text(json.dumps(log), encoding="utf-8")
    _run_env(root, monkeypatch)
    if not (_home(root) / ".claude" / "settings.json").exists():
        _user_settings(_home(root))
    assert canary.main(["snapshot", "--out", str(snap)]) == 0
    return root, canary.main(
        ["verify", "--snapshot", str(snap), "--execution-log", str(exec_log), "--repo", "o/r"]
    )


def _clean_log(root):
    workspace, temp, home = str(root), str(root.parent / "no-temp"), str(_home(root))
    attacks = [(c, EROFS, True) for c, _ in canary.attack_commands(workspace, temp, home)]
    return _log(*attacks, *_controls_passed())


def test_verify_passes_a_run_where_the_sandbox_held(tmp_path, monkeypatch):
    _control_file(tmp_path, monkeypatch)
    assert _verify(tmp_path, monkeypatch, _clean_log(tmp_path))[1] == 0


def test_verify_fails_when_the_write_control_left_no_file(tmp_path, monkeypatch, capsys):
    _control_file(tmp_path, monkeypatch, content=None)
    assert _verify(tmp_path, monkeypatch, _clean_log(tmp_path))[1] == 1
    assert "write control" in capsys.readouterr().err


def test_verify_reads_a_real_shape_log_without_crashing(tmp_path, monkeypatch, capsys):
    _control_file(tmp_path, monkeypatch)
    log = _harness_refused(_clean_log(tmp_path), 0)
    assert _verify(tmp_path, monkeypatch, log)[1] == 1
    assert "was not blocked" in capsys.readouterr().err


def test_verify_fails_a_rewritten_user_settings_file_even_with_a_clean_log(
    tmp_path, monkeypatch, capsys
):
    _control_file(tmp_path, monkeypatch)
    _user_settings(_home(tmp_path), f"commit {SHA}\n")
    assert _verify(tmp_path, monkeypatch, _clean_log(tmp_path))[1] == 1
    assert "is not the action's settings" in capsys.readouterr().err


def test_verify_fails_a_missing_execution_log(tmp_path, monkeypatch, capsys):
    root = _tree(tmp_path)
    snap = tmp_path.parent / f"{tmp_path.name}-snap.json"
    _run_env(root, monkeypatch)
    canary.main(["snapshot", "--out", str(snap)])
    assert canary.main(
        ["verify", "--snapshot", str(snap), "--execution-log", "", "--repo", "o/r"]
    ) == 1
    assert "execution log" in capsys.readouterr().err


def test_verify_fails_when_a_log_error_is_found(tmp_path, monkeypatch):
    _control_file(tmp_path, monkeypatch)
    assert _verify(tmp_path, monkeypatch, _log())[1] == 1


def test_verify_fails_a_rewritten_guarded_file_even_with_a_clean_log(tmp_path, monkeypatch, capsys):
    _control_file(tmp_path, monkeypatch)
    root = _tree(tmp_path)
    snap = tmp_path.parent / f"{tmp_path.name}-snap.json"
    exec_log = tmp_path.parent / f"{tmp_path.name}-exec.json"
    exec_log.write_text(json.dumps(_clean_log(root)), encoding="utf-8")
    _run_env(root, monkeypatch)
    _user_settings(_home(root))
    canary.main(["snapshot", "--out", str(snap)])
    (root / "CLAUDE.md").write_text("forged\n")
    assert canary.main(
        ["verify", "--snapshot", str(snap), "--execution-log", str(exec_log), "--repo", "o/r"]
    ) == 1
    assert "guarded path changed: CLAUDE.md" in capsys.readouterr().err


def _read_only(path):
    path.write_text("x", encoding="utf-8")
    path.chmod(0o444)
    return path


def test_describe_says_a_writable_file_can_be_replaced(tmp_path):
    target = tmp_path / "tool"
    target.write_text("x", encoding="utf-8")
    assert " writable=True " in canary.describe(str(target))


def test_describe_says_a_read_only_file_cannot_be_replaced(tmp_path):
    line = canary.describe(str(_read_only(tmp_path / "tool")))
    assert " writable=False " in line
    assert "parent_writable=True" in line


def test_describe_names_the_owner_and_mode(tmp_path, monkeypatch):
    target = _read_only(tmp_path / "tool")
    monkeypatch.setattr(canary, "_owner", lambda info: f"uid-{info.st_uid}")
    line = canary.describe(str(target))
    assert f"owner=uid-{target.stat().st_uid}" in line
    assert f"mode={stat.S_IMODE(target.stat().st_mode):o}" in line


def test_describe_judges_what_a_link_points_at(tmp_path, monkeypatch):
    # No real symlink: Windows cannot always make one, and this runs everywhere.
    target = tmp_path / "real"
    target.write_text("x", encoding="utf-8")
    monkeypatch.setattr(canary.os.path, "realpath", lambda path: str(target))
    line = canary.describe(str(tmp_path / "link"))
    assert f" -> {target} " in line
    assert " writable=True " in line


def test_describe_reports_a_path_that_is_not_there(tmp_path):
    missing = tmp_path / "nothing"
    assert canary.describe(str(missing)).startswith(f"{missing}: ")


def test_command_lines_resolves_through_the_path_it_is_given(tmp_path):
    tool = tmp_path / "tool.exe"
    tool.write_text("x", encoding="utf-8")
    tool.chmod(0o755)
    (line,) = canary.command_lines(["tool.exe"], str(tmp_path))
    assert line.startswith("tool.exe: ")
    assert " writable=True " in line


def test_command_lines_reports_a_command_that_is_not_there(tmp_path):
    assert canary.command_lines(["no-such-tool"], str(tmp_path)) == ["no-such-tool: not found"]


def test_path_lines_keeps_the_search_order_and_skips_empty_entries(tmp_path):
    first, second = tmp_path / "b", tmp_path / "a"
    first.mkdir()
    second.mkdir()
    lines = canary.path_lines(os.pathsep.join([str(first), "", str(second)]))
    assert [line.split(" -> ")[0] for line in lines] == [str(first), str(second)]


def test_writable_paths_lists_what_this_user_could_replace_and_nothing_else(tmp_path):
    (tmp_path / "writable").write_text("x", encoding="utf-8")
    _read_only(tmp_path / "read-only")
    assert canary.writable_paths(str(tmp_path)) == [str(tmp_path / "writable")]


def test_writable_paths_stops_at_its_depth(tmp_path):
    deep = tmp_path / "a" / "b"
    deep.mkdir(parents=True)
    (deep / "too-deep").write_text("x", encoding="utf-8")
    (tmp_path / "a" / "in-reach").write_text("x", encoding="utf-8")
    found = canary.writable_paths(str(tmp_path), depth=2)
    assert str(tmp_path / "a" / "in-reach") in found
    assert str(deep / "too-deep") not in found


def test_survey_prints_commands_path_and_the_writable_roots_and_fails_nothing(
    tmp_path, monkeypatch, capsys
):
    root = tmp_path / "root"
    root.mkdir()
    (root / "planted").write_text("x", encoding="utf-8")
    on_path = tmp_path / "on-path"
    on_path.mkdir()
    monkeypatch.setenv("PATH", str(on_path))
    monkeypatch.setattr(canary, "WRITABLE_ROOTS", (str(root),))
    assert canary.main(["survey"]) == 0
    out = capsys.readouterr().out
    assert "git: not found" in out
    assert f"{on_path} -> " in out
    assert f"{root / 'planted'} -> " in out


def test_survey_cuts_a_long_root_and_says_how_many_it_found(tmp_path, monkeypatch, capsys):
    for i in range(3):
        (tmp_path / f"file{i}").write_text("x", encoding="utf-8")
    monkeypatch.setenv("PATH", "")
    monkeypatch.setattr(canary, "WRITABLE_ROOTS", (str(tmp_path),))
    monkeypatch.setattr(canary, "SURVEY_LIMIT", 2)
    canary.main(["survey"])
    out = capsys.readouterr().out
    assert f"== {tmp_path}: 3 writable" in out
    assert sum(line.startswith(str(tmp_path / "file")) for line in out.splitlines()) == 2


def test_an_attack_that_exited_zero_is_an_error():
    runs = _attacks_blocked()
    runs[0] = (runs[0][0], EROFS, False)
    errors = _errors(_log(*runs, *_controls_passed()))
    assert any(runs[0][0] in e and "was not blocked" in e for e in errors)


def test_a_network_control_that_never_ran_is_an_error():
    errors = _errors(_log(*_attacks_blocked(), *_controls_passed()[:1]))
    assert any("network control never ran" in e for e in errors)


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
    assert canary.write_control_command() in prompt
    assert canary.network_command("${{ github.repository }}") in prompt


def test_canary_prompt_numbers_every_command_and_expects_only_the_attacks_to_fail():
    prompt = _step(HELD["steps"], "canary")["with"]["prompt"]
    attacks = len(canary.attack_commands(*PLACEHOLDERS))
    assert len(re.findall(r"^\d+\. ", prompt, re.M)) == attacks + 2
    flat = " ".join(prompt.split())
    assert f"Run commands 1 to {attacks + 2} exactly" in flat
    assert f"Commands 1 to {attacks} are expected to fail" in flat


def test_canary_sandbox_lines_reach_the_log_and_the_debug_file_does_not_leave_the_runner():
    steps = HELD["steps"]
    args = _step(steps, "canary")["with"]["claude_args"]
    assert "--debug-file ${{ runner.temp }}/claude-debug.log\n" in args
    assert "--debug-file" not in _reviewer()["with"]["claude_args"]
    # The sandbox runtime logs only under SRT_DEBUG, to the CLI's stderr, and the
    # SDK keeps that stderr only under DEBUG_CLAUDE_AGENT_SDK, in ~/.claude/debug.
    env = _step(steps, "canary")["env"]
    assert env["SRT_DEBUG"] == "1" and env["DEBUG_CLAUDE_AGENT_SDK"] == "1"
    assert not {"SRT_DEBUG", "DEBUG_CLAUDE_AGENT_SDK"} & set(_reviewer().get("env", {}))
    mounts = _step(steps, "mounts")
    assert mounts["if"] == "always()"
    assert "[Sandbox" in mounts["run"]
    assert "$HOME/.claude/debug" in mounts["run"]
    assert "cat " not in mounts["run"]
    assert _position(steps, "canary") < _position(steps, "mounts")
    uploads = [s for s in steps if "upload-artifact" in s.get("uses", "")]
    assert uploads and all("claude-debug" not in s["with"]["path"] for s in uploads)


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
    for step_id in ("snapshot", "survey", "verify", "check-sandbox", "check-tree", "validate"):
        run = _step(steps, step_id)["run"]
        assert f'python -I "{TRUSTED}/' in run
        assert ".github/scripts/" not in run


def test_held_job_surveys_after_the_reviewer_because_the_action_changes_path():
    steps = HELD["steps"]
    assert _position(steps, "canary") < _position(steps, "survey")
    assert "review_sandbox_canary.py\" survey" in _step(steps, "survey")["run"]


@pytest.mark.parametrize("step_id", ["survey", "verify", "check-sandbox", "check-tree", "validate"])
def test_held_job_judges_even_when_the_reviewer_failed(step_id):
    step = _step(HELD["steps"], step_id)
    assert step["if"] == "always()"
    assert "continue-on-error" not in step


def test_held_job_runs_the_reviewers_sandbox_check_on_its_own_log():
    """code-review.yml runs the base copy and skips gate-machinery PRs, so this is
    where a change to `check-sandbox` meets a real execution log."""
    step = _step(HELD["steps"], "check-sandbox")
    assert _position(HELD["steps"], "canary") < _position(HELD["steps"], "check-sandbox")
    assert step["env"]["EXECUTION_LOG"] == "${{ steps.canary.outputs.execution_file }}"
    assert 'code_gate_verdict.py" check-sandbox --execution-log "$EXECUTION_LOG"' in step["run"]


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
