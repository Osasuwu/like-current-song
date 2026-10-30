"""Shape of the two code-gate workflows (#226, ported from jarvis#1964).

code-gate-verdict.yml is the trusted half: it runs from the default branch and
decides `verify-verdict`. Its safety is structural — it must never run PR code, never
hold more than read permissions, and never let a PR-controlled string reach a
shell. code-review.yml produces the evidence; its retry and upload settings are
what make a missing or stale review fail closed. Each test walks the parsed YAML,
not the file text.
"""

from __future__ import annotations

import importlib.util
import re
import shlex
from pathlib import Path

import pytest
import yaml

WORKFLOWS = next(
    p for p in Path(__file__).resolve().parents if (p / ".github" / "workflows").is_dir()
) / ".github" / "workflows"
REVIEW = yaml.safe_load((WORKFLOWS / "code-review.yml").read_text(encoding="utf-8"))
VERDICT = yaml.safe_load((WORKFLOWS / "code-gate-verdict.yml").read_text(encoding="utf-8"))

# PyYAML parses the bare key `on` as the boolean True.
ON = True


def _steps(spec: dict) -> list[dict]:
    return [step for job in spec["jobs"].values() for step in job["steps"]]


def _run_bodies(spec: dict) -> list[str]:
    return [step["run"] for step in _steps(spec) if "run" in step]


# --- verdict workflow -----------------------------------------------------


def test_verdict_permissions_are_exactly_three_reads():
    assert VERDICT["permissions"] == {
        "contents": "read",
        "actions": "read",
        "pull-requests": "read",
    }
    for name, job in VERDICT["jobs"].items():
        assert "permissions" not in job, f"job {name} must not widen the workflow permissions"


# A schedule event carries no repository payload, so it checks out its own ref,
# which for a schedule is always the default branch; every other event names the
# default branch explicitly (for pull_request_target, `github.ref` is the PR's base).
BASE_REF = (
    "${{ github.event_name == 'schedule' && github.ref"
    " || github.event.repository.default_branch }}"
)


def test_verdict_never_checks_out_the_pr_head():
    checkouts = [
        s for s in _steps(VERDICT) if str(s.get("uses", "")).startswith("actions/checkout@")
    ]
    assert len(checkouts) == 2  # resolve + verdict, both base-pinned
    for step in checkouts:
        assert step["with"]["ref"] == BASE_REF
        assert step["with"]["sparse-checkout"] == ".github/scripts"
        assert step["with"]["persist-credentials"] is False


def test_verdict_triggers_pull_request_target_review_workflow_run_and_a_daily_sweep():
    triggers = VERDICT[ON]
    assert set(triggers) == {"pull_request_target", "workflow_run", "schedule"}
    assert triggers["workflow_run"] == {"workflows": ["Code Review"], "types": ["completed"]}
    assert triggers["pull_request_target"]["types"] == [
        "opened",
        "synchronize",
        "reopened",
        "ready_for_review",
        "edited",
    ]
    # #231: evidence expires with no event; once a day every open PR is re-decided.
    ((cron,),) = [list(entry.values()) for entry in triggers["schedule"]]
    minute, hour, dom, month, dow = cron.split()
    assert (dom, month, dow) == ("*", "*", "*")
    assert minute.isdigit() and hour.isdigit()


def test_verdict_runs_once_per_resolved_target():
    job = VERDICT["jobs"]["verdict"]
    assert job["if"] == "needs.resolve.outputs.targets != '[]'"
    assert job["strategy"] == {
        "fail-fast": False,
        "matrix": {"target": "${{ fromJSON(needs.resolve.outputs.targets) }}"},
    }
    assert VERDICT["jobs"]["resolve"]["outputs"] == {
        "targets": "${{ steps.resolve.outputs.targets }}"
    }
    (step,) = [s for s in job["steps"] if s.get("name") == "Decide and post verify-verdict"]
    assert step["env"]["PR_NUMBER"] == "${{ matrix.target.pr_number }}"
    assert step["env"]["HEAD_SHA"] == "${{ matrix.target.head_sha }}"


def test_verdict_concurrency_is_per_pr_and_sha_without_cancel():
    """Per target, so a sweep's verdict and an event's verdict for one SHA never
    interleave their ledger read and write."""
    assert VERDICT["jobs"]["verdict"]["concurrency"] == {
        "group": "code-gate-${{ matrix.target.pr_number }}-${{ matrix.target.head_sha }}",
        "cancel-in-progress": False,
    }


def test_edited_proceeds_only_on_a_base_change_in_both_workflows():
    guard = "github.event.action != 'edited' || github.event.changes.base"
    assert guard in VERDICT["jobs"]["resolve"]["if"]
    assert guard in REVIEW["jobs"]["review"]["if"]


def test_no_run_body_interpolates_pr_controlled_context():
    # PR title, branch names, head repo and dispatch inputs are attacker-chosen;
    # they reach shell only through `env:`.
    pattern = re.compile(
        r"\$\{\{[^}]*(github\.event\.pull_request\.|github\.event\.workflow_run\.|inputs\.|github\.head_ref)"
    )
    for spec in (VERDICT, REVIEW):
        bodies = _run_bodies(spec)
        assert bodies, "expected run bodies to scan"
        for body in bodies:
            assert pattern.search(body) is None, body


def test_only_the_verdict_step_holds_the_app_token():
    holders = [
        s["name"]
        for s in _steps(VERDICT)
        if "GATE_TOKEN" in (s.get("env") or {})
        or "secrets.GATE_APP_PRIVATE_KEY" in str(s.get("with") or {})
    ]
    assert holders == ["Mint osasuwu-ci installation token", "Decide and post verify-verdict"]
    assert VERDICT["jobs"]["verdict"]["environment"] == "code-gate-verdict"


# --- review workflow ------------------------------------------------------


def test_review_concurrency_cancels_a_superseded_review():
    # Job-level: workflow-level concurrency is evaluated before the job `if`, so a
    # skipped `edited` run would cancel the real review and leave no evidence.
    assert "concurrency" not in REVIEW
    assert REVIEW["jobs"]["review"]["concurrency"] == {
        "group": "code-review-${{ github.event.pull_request.number || inputs.pr_number }}",
        "cancel-in-progress": True,
    }


def test_review_run_name_embeds_pr_and_head_sha_for_dispatch_provenance():
    run_name = REVIEW["run-name"]
    assert "format('Code review PR #{0} @ {1}', inputs.pr_number, inputs.head_sha)" in run_name


def test_dispatch_requires_pr_number_and_head_sha():
    inputs = REVIEW[ON]["workflow_dispatch"]["inputs"]
    assert set(inputs) == {"pr_number", "head_sha"}
    assert all(spec["required"] is True for spec in inputs.values())


def test_review_checks_out_base_only_with_bounded_history():
    """The base commit and its ancestors, so the reviewer's `git log`/`git blame`
    can back a `regression` finding (#229). Bounded, never `0`: depth 0 fetches
    every branch, same-repo PR heads included. A dispatch names the branch fully:
    checkout fetches an unqualified `main` as the glob `refs/heads/main*`."""
    (checkout,) = [
        s for s in _steps(REVIEW) if str(s.get("uses", "")).startswith("actions/checkout@")
    ]
    assert checkout["with"] == {
        "ref": "${{ github.event.pull_request.base.sha"
        " || format('refs/heads/{0}', github.event.repository.default_branch) }}",
        "fetch-depth": 1000,
    }


def _upload_steps() -> list[dict]:
    return [
        s for s in _steps(REVIEW) if str(s.get("uses", "")).startswith("actions/upload-artifact@")
    ]


EVIDENCE_UPLOAD_NAME = "review-evidence-${{ github.run_attempt }}"


def test_evidence_artifact_is_retained_90_days_one_per_attempt():
    """A re-run attempt uploads its own artifact and cannot overwrite an earlier
    attempt's, so blocking evidence survives a re-run."""
    (evidence,) = [s for s in _upload_steps() if s["with"]["name"] == EVIDENCE_UPLOAD_NAME]
    assert evidence["with"]["retention-days"] == 90
    assert evidence["with"]["overwrite"] is False
    assert evidence["with"]["if-no-files-found"] == "error"
    assert "if" not in evidence, "every run uploads evidence, including skipped ones"


@pytest.mark.parametrize("attempt", ["1", "2", "17"])
def test_uploaded_evidence_name_is_what_the_verdict_reads(attempt):
    """The verdict only reads artifacts whose name fullmatches its pattern; an
    upload name it does not match would read as "missing" for every run. The step
    is found by what it uploads, not by the name under test."""
    (evidence,) = [s for s in _upload_steps() if s["with"]["path"] == "review-evidence.json"]
    name = evidence["with"]["name"].replace("${{ github.run_attempt }}", attempt)
    assert _gate().EVIDENCE_ARTIFACT_NAME.fullmatch(name)


def _gate():
    spec = importlib.util.spec_from_file_location(
        "code_gate_verdict", WORKFLOWS.parent / "scripts" / "code_gate_verdict.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_second_reviewer_attempt_runs_only_when_the_first_findings_are_invalid():
    by_name = {s["name"]: s for s in _steps(REVIEW) if "name" in s}
    first = by_name["Run code review (attempt 1)"]
    second = by_name["Run code review (attempt 2)"]
    assert first["continue-on-error"] is True
    assert by_name["Validate findings (attempt 1)"]["continue-on-error"] is True
    assert second["if"] == "steps.v1.outcome == 'failure'"
    # The retry starts from the sentinel again, not from attempt 1's invalid file.
    names = [s.get("name") for s in _steps(REVIEW)]
    reseed = by_name["Reseed findings file for the retry"]
    assert reseed["if"] == "steps.v1.outcome == 'failure'"
    assert names.index(reseed["name"]) < names.index(second["name"])
    assert "unreviewed" in reseed["run"]


def test_both_reviewer_attempts_use_one_input_block():
    """#235: the prompt and tool lists are written once. The second attempt's
    `with:` is a YAML alias of the first's, so the composed document holds one
    node for both: a copy, even an identical one, is two nodes that can drift."""
    root = yaml.compose((WORKFLOWS / "code-review.yml").read_text(encoding="utf-8"))

    def mapping(node):
        return {key.value: value for key, value in node.value}

    steps = mapping(mapping(mapping(root)["jobs"])["review"])["steps"].value
    reviewers = [
        mapping(s)
        for s in steps
        if mapping(s).get("uses") is not None
        and mapping(s)["uses"].value.startswith("anthropics/claude-code-action@")
    ]
    assert len(reviewers) == 2
    assert reviewers[0]["with"] is reviewers[1]["with"]


def test_decision_rests_on_the_findings_file_not_on_reviewer_outcome():
    # A run with permission denials but valid findings must pass; a clean run with
    # no findings file must fail. So no step may read the reviewer's outcome or its
    # denial count after validation.
    steps = _steps(REVIEW)
    final_names = {"Check workspace is clean", "Validate findings", "Stamp review evidence"}
    final = [s for s in steps if s.get("name") in final_names]
    assert [s["name"] for s in final] == [
        "Check workspace is clean",
        "Validate findings",
        "Stamp review evidence",
    ]
    for step in final:
        assert "continue-on-error" not in step
        assert "steps.review1" not in step.get("if", "") and "steps.review2" not in step.get(
            "if", ""
        )
    assert "permission_denials" not in yaml.safe_dump(REVIEW)


def test_resolve_step_gets_the_default_branch():
    """resolve_run_target picks the listed PR into the default branch (#230); the
    step reads DEFAULT_BRANCH, so without it every workflow_run resolve fails."""
    (step,) = [s for s in VERDICT["jobs"]["resolve"]["steps"] if s.get("id") == "resolve"]
    assert step["env"]["DEFAULT_BRANCH"] == "${{ github.event.repository.default_branch }}"
    # The schedule sweep lists the open PRs itself, with the read-only job token.
    assert step["env"]["GH_TOKEN"] == "${{ secrets.GITHUB_TOKEN }}"


def test_prepare_step_gets_the_default_branch():
    """review_skip_reason skips a `pull_request` run into another base (#234); the
    step reads DEFAULT_BRANCH, so without it every review run fails in prepare."""
    (step,) = [s for s in _steps(REVIEW) if s.get("id") == "prepare"]
    assert step["env"]["DEFAULT_BRANCH"] == "${{ github.event.repository.default_branch }}"


SCRUB = "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"


def test_bubblewrap_is_installed_before_the_reviewer_with_the_scrub_on():
    """#240: the scrub needs bwrap, which the runner lacks. The install is a plain
    step before the first reviewer attempt — a failure is a named red step, never
    swallowed — and the scrub stays on rather than being switched off to pass."""
    steps = REVIEW["jobs"]["review"]["steps"]
    ids = [s.get("id") for s in steps]
    (bwrap,) = [s for s in steps if s.get("name") == "Install subprocess isolation (bubblewrap)"]
    at = steps.index(bwrap)
    assert ids.index("prepare") < at < ids.index("review1")
    assert bwrap["if"] == "steps.prepare.outputs.skip_reason == ''"
    assert "continue-on-error" not in bwrap
    lines = [line.strip() for line in bwrap["run"].splitlines()]
    assert lines[0] == "set -euo pipefail"
    (install,) = [line for line in lines if "apt-get install" in line]
    assert "bubblewrap" in install.split()
    assert "sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0" in lines
    assert lines[-1] == "bwrap --ro-bind / / --unshare-all true"
    assert REVIEW["jobs"]["review"]["env"][SCRUB] == "1"
    overrides = [s.get("name") for s in steps if SCRUB in (s.get("env") or {})]
    assert overrides == []


def test_the_runners_podman_directory_is_gone_before_the_reviewer_starts():
    """#228: the CLI cannot resolve its denyRead entry /run/podman/podman.sock, which
    drops its read-deny prediction, and then every absent denyWrite path in the
    read-only workspace dies in bwrap. Pre-creating them is no way out: a
    .git/config.lock stops the action removing the checkout's token, and the action
    deletes .ripgreprc. The canary's install step is held equal to this one, so a
    line lost here fails there too."""
    steps = REVIEW["jobs"]["review"]["steps"]
    (bwrap,) = [s for s in steps if s.get("name") == "Install subprocess isolation (bubblewrap)"]
    lines = [line.strip() for line in bwrap["run"].splitlines()]
    assert "sudo rm -rf /run/podman" in lines
    assert lines.index("sudo rm -rf /run/podman") < lines.index("bwrap --ro-bind / / --unshare-all true")


# --- what runs after the reviewer (#228) ----------------------------------

TRUSTED_DIR = "$RUNNER_TEMP/trusted"
TRUSTED_SCRIPT = f'"{TRUSTED_DIR}/code_gate_verdict.py"'


def _review_steps() -> list[dict]:
    return REVIEW["jobs"]["review"]["steps"]


def _index(name: str) -> int:
    (at,) = [i for i, s in enumerate(_review_steps()) if s.get("name") == name or s.get("id") == name]
    return at


def test_gate_script_runs_only_from_a_copy_made_before_the_reviewer():
    """#228: the reviewer could once write the workspace, and a later step ran
    `.github/scripts/code_gate_verdict.py` from it. Every call now runs a copy
    taken right after the base checkout, outside the workspace."""
    steps = _review_steps()
    copy_at = _index("Copy the trusted gate script")
    assert "actions/checkout@" in steps[copy_at - 1].get("uses", "")
    copy = steps[copy_at]
    assert "if" not in copy, "the skip path runs the script too"
    lines = [line.strip() for line in copy["run"].splitlines()]
    assert lines == [
        "set -euo pipefail",
        f'mkdir -p "{TRUSTED_DIR}"',
        f'cp .github/scripts/code_gate_verdict.py "{TRUSTED_DIR}/"',
    ]
    calls = []
    for i, step in enumerate(steps):
        if i == copy_at or "run" not in step:
            continue
        assert ".github/scripts/" not in step["run"], step.get("name")
        calls += [(i, m) for m in re.findall(r"python -I (\S+)", step["run"])]
    assert len(calls) >= 6  # prepare, skip, validate x2, check-tree, stamp at least
    assert {script for _, script in calls} == {TRUSTED_SCRIPT}
    assert copy_at < min(i for i, _ in calls)


def test_reviewer_sandbox_settings_are_checked_and_pinned_before_the_reviewer():
    """#228: the reviewer loads `--settings` from outside the workspace, written
    by `pin-sandbox` only after it has checked `denyWrite` names this run's
    workspace. A failed check is a red step, so the reviewer never starts."""
    pin_at = _index("Pin the reviewer sandbox settings")
    pin = _review_steps()[pin_at]
    assert _index("Copy the trusted gate script") < pin_at < _index("review1")
    assert pin["if"] == "steps.prepare.outputs.skip_reason == ''"
    assert "continue-on-error" not in pin
    assert shlex.split(pin["run"]) == [
        "python",
        "-I",
        f"{TRUSTED_DIR}/code_gate_verdict.py",
        "pin-sandbox",
        "--settings",
        ".github/review-sandbox.json",
        "--out",
        f"{TRUSTED_DIR}/review-sandbox.json",
    ]
    # The file the reviewer loads is the one this step wrote.
    for attempt in ("review1", "review2"):
        args = _review_steps()[_index(attempt)]["with"]["claude_args"]
        assert "--settings ${{ runner.temp }}/trusted/review-sandbox.json\n" in args


def test_retry_starts_only_from_the_tree_attempt_1_started_from():
    """#228 AC4: attempt 2 is a second reviewer on the same job. Before it starts,
    the trusted check-tree proves attempt 1 left nothing but the findings file,
    and a dirty tree fails the job rather than handing it to the retry."""
    check_at = _index("Check workspace is clean before the retry")
    check = _review_steps()[check_at]
    assert _index("v1") < check_at < _index("Reseed findings file for the retry")
    assert check_at < _index("review2")
    assert check["if"] == "steps.v1.outcome == 'failure'"
    assert "continue-on-error" not in check
    assert shlex.split(check["run"]) == [
        "python",
        "-I",
        f"{TRUSTED_DIR}/code_gate_verdict.py",
        "check-tree",
        "--findings",
        "$FINDINGS",
    ]
