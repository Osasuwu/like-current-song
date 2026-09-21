"""Resident tray live reload + settings launcher (#100).

A settings save rebuilds the tray's wiring in place. These tests drive
`_HostRuntime.reload` with fake triggers/providers on a real event loop
(no keyboard hooks, no pystray) and `_SettingsLauncher` with a fake spawn.
"""

from __future__ import annotations

import asyncio
import threading
from collections.abc import Iterator

import pytest

from like_spotify.hosts import _common
from like_spotify.hosts.windows import resident


class _FakeProvider:
    """Neither playlist- nor dislike-capable — the plain baseline."""

    def __init__(self, has_tokens: bool = True) -> None:
        self.has_tokens = has_tokens


class _DislikeProvider(_FakeProvider):
    """`DislikeCapableProvider` structurally — enough to earn the discard
    hotkey on its own, with no archive playlist configured (#172)."""

    async def dislike(self, track) -> None:  # pragma: no cover - never run
        pass


class _FakeTrigger:
    fail_hotkeys: set[str] = set()

    def __init__(self, hotkey: str, log: list) -> None:
        self.hotkey = hotkey
        self.log = log

    async def start(self, emit) -> None:
        if self.hotkey in self.fail_hotkeys:
            raise ValueError(f"cannot register {self.hotkey}")
        self.log.append(("start", self.hotkey))

    async def stop(self) -> None:
        self.log.append(("stop", self.hotkey))


@pytest.fixture
def env(tmp_path, monkeypatch) -> Iterator[dict]:
    monkeypatch.setattr(_common, "CONFIG_FILE", tmp_path / "config.json")
    monkeypatch.setattr(_common, "LIKE_COOLDOWN_FILE", tmp_path / "cooldown.json")
    provider = {"value": _FakeProvider()}
    monkeypatch.setattr(_common, "build_provider", lambda cfg: provider["value"])
    monkeypatch.setattr(_FakeTrigger, "fail_hotkeys", set())

    log: list = []

    def make_trigger(*, hotkey: str) -> _FakeTrigger:
        return _FakeTrigger(hotkey, log)

    loop = asyncio.new_event_loop()
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()
    yield {"log": log, "make_trigger": make_trigger, "loop": loop, "provider": provider}
    loop.call_soon_threadsafe(loop.stop)
    thread.join(timeout=2)
    loop.close()


class _Volume:
    def __init__(self) -> None:
        self.volumes: list[float] = []

    def __call__(self, *a, **kw) -> None:
        pass

    def set_volume(self, v: float) -> None:
        self.volumes.append(v)


def _cfg(hotkey: str, *, archive: str | None = None, remove: str = "ctrl+alt+r", volume=0.5):
    cfg = {
        "trigger": {"hotkey": hotkey, "remove_hotkey": remove, "feedback_volume": volume},
        "actions": {
            "follow_artist": {"enabled": False},
            "like_cooldown": {"enabled": False},
        },
    }
    if archive:
        cfg["actions"]["archive_remove"] = {"enabled": True, "playlist_name": archive}
    return cfg


def _runtime(env, cfg, feedback=None):
    feedback = feedback or _Volume()
    wiring = resident._build_wiring(cfg, feedback, make_trigger=env["make_trigger"])
    rt = resident._HostRuntime(env["loop"], feedback, wiring, make_trigger=env["make_trigger"])
    rt.start()
    return rt


def test_build_wiring_requires_a_signed_in_provider(env) -> None:
    env["provider"]["value"] = None
    with pytest.raises(resident._NotReady, match="isn't configured"):
        resident._build_wiring({}, _Volume(), make_trigger=env["make_trigger"])
    env["provider"]["value"] = _FakeProvider(has_tokens=False)
    with pytest.raises(resident._NotReady, match="not signed in"):
        resident._build_wiring({}, _Volume(), make_trigger=env["make_trigger"])


def test_discard_hotkey_needs_an_archive_or_a_dislike_and_a_distinct_combo(env) -> None:
    mk = env["make_trigger"]
    # Nothing to do: no archive playlist, and a provider with no dislike.
    assert not resident._build_wiring(_cfg("a+b"), _Volume(), make_trigger=mk).discard_enabled
    assert resident._build_wiring(_cfg("a+b", archive="W"), _Volume(), make_trigger=mk).discard_enabled
    # A colliding combo would fire both pipelines on one press.
    same = _cfg("a+b", archive="W", remove="a+b")
    assert not resident._build_wiring(same, _Volume(), make_trigger=mk).discard_enabled


def test_discard_hotkey_registers_for_a_dislike_capable_provider(env) -> None:
    """The relaxed gate (#172): no archive playlist at all, but the service
    can be told "not this one", so the hotkey must still register."""
    env["provider"]["value"] = _DislikeProvider()
    w = resident._build_wiring(_cfg("a+b"), _Volume(), make_trigger=env["make_trigger"])
    assert w.discard_enabled
    assert w.discard_pipeline is not None
    assert w.discard_pipeline.label == "Dislike current track"


def test_reload_swaps_hotkeys_and_volume(env) -> None:
    fb = _Volume()
    rt = _runtime(env, _cfg("ctrl+alt+l"), fb)
    assert rt.state() == ("ctrl+alt+l", False, "ctrl+alt+r", "")

    rt.reload(_cfg("ctrl+alt+k", archive="Weekly", volume=0.9))

    assert env["log"] == [
        ("start", "ctrl+alt+l"),
        ("stop", "ctrl+alt+l"),
        ("start", "ctrl+alt+k"),
        ("start", "ctrl+alt+r"),
    ]
    # The fake provider is neither playlist- nor dislike-capable, so the
    # label stays generic even though an archive playlist is configured.
    assert rt.state() == (
        "ctrl+alt+k", True, "ctrl+alt+r", "Discard current track"
    )
    assert fb.volumes == [0.9]


def test_reload_not_ready_changes_nothing(env) -> None:
    rt = _runtime(env, _cfg("ctrl+alt+l"))
    old = rt.wiring
    env["provider"]["value"] = _FakeProvider(has_tokens=False)

    with pytest.raises(resident._NotReady):
        rt.reload(_cfg("ctrl+alt+k"))
    assert rt.wiring is old
    assert env["log"] == [("start", "ctrl+alt+l")]


def test_reload_rolls_back_when_new_hotkey_fails(env) -> None:
    fb = _Volume()
    rt = _runtime(env, _cfg("ctrl+alt+l"), fb)
    old = rt.wiring
    _FakeTrigger.fail_hotkeys = {"ctrl+alt+r"}  # like key registers, remove key doesn't

    with pytest.raises(ValueError):
        rt.reload(_cfg("ctrl+alt+k", archive="Weekly"))

    assert rt.wiring is old
    assert env["log"] == [
        ("start", "ctrl+alt+l"),
        ("stop", "ctrl+alt+l"),
        ("start", "ctrl+alt+k"),
        ("stop", "ctrl+alt+k"),  # partially started new wiring is undone
        ("start", "ctrl+alt+l"),  # and the old hotkey comes back
    ]
    assert fb.volumes == []


# ── Settings launcher ──────────────────────────────────────────────────


class _FakeProc:
    def __init__(self, on_wait=None) -> None:
        self.done = threading.Event()
        self._on_wait = on_wait

    def poll(self):
        return 0 if self.done.is_set() else None

    def wait(self):
        self.done.wait(timeout=5)
        if self._on_wait:
            self._on_wait()
        return 0


def _launcher(on_wait=None):
    saved = threading.Event()
    spawned: list = []
    procs: list[_FakeProc] = []

    def spawn(argv):
        spawned.append(argv)
        proc = _FakeProc(on_wait)
        procs.append(proc)
        return proc

    return resident._SettingsLauncher(saved.set, spawn=spawn), saved, spawned, procs


def test_launcher_spawns_settings_child_once(env) -> None:
    launcher, _, spawned, procs = _launcher()
    assert launcher.open() is True
    assert spawned[0][-2:] == ["--settings", "--from-tray"]
    assert launcher.open() is False  # still open
    procs[0].done.set()
    assert launcher.open() is True  # closed → a new one is allowed
    procs[1].done.set()


def test_launcher_reports_save_only_when_config_changed(env) -> None:
    _common.CONFIG_FILE.write_text("{}", encoding="utf-8")

    launcher, saved, _, procs = _launcher()
    launcher.open()
    procs[0].done.set()
    assert not saved.wait(timeout=0.3)

    def write():
        _common.CONFIG_FILE.write_text('{"x": 1}', encoding="utf-8")

    launcher, saved, _, procs = _launcher(on_wait=write)
    launcher.open()
    procs[0].done.set()
    assert saved.wait(timeout=2)


def test_self_command_frozen_and_module(monkeypatch) -> None:
    monkeypatch.setattr(resident.sys, "frozen", True, raising=False)
    assert resident._self_command("--settings")[1:] == ["--settings"]
    monkeypatch.setattr(resident.sys, "frozen", False)
    assert resident._self_command("--settings")[1:] == ["-m", "like_spotify", "--settings"]


def test_main_settings_flag_opens_window(monkeypatch) -> None:
    import like_spotify.hosts.settings as settings_pkg

    calls = []
    monkeypatch.setattr(settings_pkg, "run", lambda **kw: calls.append(kw) or 0)
    assert resident.main(["--settings", "--from-tray"]) == 0
    assert calls == [{"from_tray": True}]


def test_stub_settings_flag_opens_window(monkeypatch) -> None:
    import like_spotify.hosts.settings as settings_pkg
    from like_spotify.hosts import _stub

    calls = []
    monkeypatch.setattr(settings_pkg, "run", lambda **kw: calls.append(kw) or 0)
    assert _stub.main(["--settings"]) == 0
    assert calls == [{"from_tray": False}]
