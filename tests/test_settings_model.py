"""Settings window model layer (#100): config round-trips, no tkinter.

The window is a thin view; everything that decides what lands in
`config.json` is here and exercised directly.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Iterator
from dataclasses import replace
from pathlib import Path

import pytest

from like_spotify.hosts import _common
from like_spotify.hosts.settings import model, services
from like_spotify.hosts.settings.model import ConfigDocument, Settings


@pytest.fixture
def tmp_paths(tmp_path, monkeypatch) -> Iterator[Path]:
    monkeypatch.setattr(_common, "CONFIG_FILE", tmp_path / "config.json")
    monkeypatch.setattr(_common, "SPOTIFY_TOKEN_FILE", tmp_path / "spotify_token.json")
    monkeypatch.setattr(_common, "GOOGLE_TOKEN_FILE", tmp_path / "google_token.json")
    monkeypatch.setattr(_common, "YOUTUBE_TOKEN_FILE", tmp_path / "youtube_token.json")
    yield tmp_path


def _write(path: Path, cfg: dict) -> None:
    path.write_text(json.dumps(cfg), encoding="utf-8")


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


# ── Fresh config ───────────────────────────────────────────────────────


def test_fresh_config_defaults() -> None:
    s = model.settings_from_config({})
    assert s == Settings()
    assert s.provider == "spotify"
    assert s.storage_backend == "none"
    assert s.hotkey == "ctrl+shift+alt+w"
    assert s.remove_hotkey == _common.DEFAULT_REMOVE_HOTKEY
    assert s.feedback_volume == _common.DEFAULT_FEEDBACK_VOLUME


def test_fresh_config_extra_actions_off_and_empty() -> None:
    s = model.settings_from_config({})
    assert not (s.archive_enabled or s.best_enabled or s.follow_enabled or s.cooldown_enabled)
    assert s.archive_playlist == "" and s.best_playlist == ""


def test_fresh_save_writes_actions_explicitly_off(tmp_paths) -> None:
    """The host treats a missing cooldown / follow block as ON, so a fresh
    save must write them down as off, and the host must agree."""
    doc = ConfigDocument()
    assert doc.fresh
    doc.save(replace(doc.initial_settings(), spotify_client_id="abc"))

    cfg = _read(_common.CONFIG_FILE)
    actions = cfg["actions"]
    for name in ("archive_remove", "promote_to_best", "follow_artist", "like_cooldown"):
        assert actions[name]["enabled"] is False
    assert "playlist_name" not in actions["archive_remove"]
    assert cfg["spotify"]["client_id"] == "abc"
    assert cfg["music"]["provider"] == "spotify"
    assert cfg["storage"]["backend"] == "none"

    pre, post = _common.build_action_chains(cfg, storage=None)
    assert pre == [] and post == []
    # And reading it back doesn't flip anything on.
    assert ConfigDocument().initial_settings().cooldown_enabled is False


# ── Round-trips on existing configs ────────────────────────────────────


_EXISTING = {
    "spotify": {"client_id": "cid", "note": "keep me"},
    "trigger": {"hotkey": "ctrl+alt+l", "feedback_volume": 0.5, "extra": 1},
    "actions": {
        "archive_remove": {"playlist_name": "Weekly", "custom": True},
        "like_cooldown": {"minutes": 7},
        "future_action": {"enabled": True},
    },
    "future_section": {"a": [1, 2, 3]},
}


def test_unchanged_save_is_identity() -> None:
    s = model.settings_from_config(_EXISTING)
    assert model.apply_settings(_EXISTING, s, baseline=s) == _EXISTING


def test_unknown_keys_survive_a_real_change() -> None:
    s = model.settings_from_config(_EXISTING)
    out = model.apply_settings(_EXISTING, replace(s, hotkey="ctrl+alt+k"), baseline=s)

    assert out["trigger"] == {"hotkey": "ctrl+alt+k", "feedback_volume": 0.5, "extra": 1}
    assert out["spotify"]["note"] == "keep me"
    assert out["future_section"] == {"a": [1, 2, 3]}
    assert out["actions"]["future_action"] == {"enabled": True}
    assert out["actions"]["archive_remove"]["custom"] is True
    # Input not mutated.
    assert _EXISTING["trigger"]["hotkey"] == "ctrl+alt+l"


def test_existing_config_reflects_runtime_defaults() -> None:
    s = model.settings_from_config(_EXISTING)
    assert s.archive_enabled and s.archive_playlist == "Weekly"
    assert s.cooldown_enabled and s.cooldown_minutes == 7  # missing enabled = on
    assert s.follow_enabled  # missing block = on at runtime
    assert not s.best_enabled  # no playlist name = off at runtime
    assert s.feedback_volume == 0.5


def test_legacy_archive_key_read_and_rewritten_nested() -> None:
    cfg = {"spotify": {"client_id": "x"}, "archive_playlist_name": "Old"}
    s = model.settings_from_config(cfg)
    assert s.archive_enabled and s.archive_playlist == "Old"

    out = model.apply_settings(cfg, replace(s, archive_playlist="New"), baseline=s)
    assert out["actions"]["archive_remove"] == {"enabled": True, "playlist_name": "New"}
    assert _common.resolve_archive_playlist_name(out) == "New"


def test_legacy_promote_to_best_of_block_read_and_rewritten_under_new_name() -> None:
    """A v1.1.0 config keeps its best-playlist rule across the rename."""
    cfg = {
        "spotify": {"client_id": "x"},
        "actions": {
            "promote_to_best_of": {"enabled": True, "playlist_name": "Old", "threshold": 4}
        },
    }
    s = model.settings_from_config(cfg)
    assert s.best_enabled and s.best_playlist == "Old" and s.best_threshold == 4

    out = model.apply_settings(cfg, replace(s, best_playlist="New"), baseline=s)
    assert out["actions"]["promote_to_best"] == {
        "enabled": True,
        "playlist_name": "New",
        "threshold": 4,
    }
    # The superseded block is dropped so the two cannot disagree.
    assert "promote_to_best_of" not in out["actions"]


def test_disabling_an_action_keeps_its_playlist_name() -> None:
    s = model.settings_from_config(_EXISTING)
    out = model.apply_settings(_EXISTING, replace(s, archive_enabled=False), baseline=s)
    assert out["actions"]["archive_remove"]["enabled"] is False
    assert out["actions"]["archive_remove"]["playlist_name"] == "Weekly"
    assert _common.resolve_archive_playlist_name(out) == ""


def test_provider_and_storage_round_trip() -> None:
    s = replace(
        Settings(),
        provider="ytmusic",
        storage_backend="sheets",
        sheets_spreadsheet_id="sid",
    )
    out = model.apply_settings({}, s)
    assert out["music"]["provider"] == "ytmusic"
    assert out["storage"]["backend"] == "sheets"
    assert out["sheets"] == {"spreadsheet_id": "sid"}
    assert "spotify" not in out  # nothing to write
    assert model.settings_from_config(out) == replace(
        s,
        archive_enabled=False,
        best_enabled=False,
        follow_enabled=False,
        cooldown_enabled=False,
    )


def test_retired_backend_reads_back_as_none() -> None:
    """A config still on the removed Supabase backend opens the window on
    "none" - matching what the host does with it - rather than showing a
    backend the window can no longer configure."""
    cfg = {"storage": {"backend": "supabase"}, "supabase": {"url": "https://x"}}
    assert model.settings_from_config(cfg).storage_backend == "none"


def test_legacy_supabase_block_is_no_longer_inferred() -> None:
    cfg = {"supabase": {"url": "https://x", "anon_key": "k"}}
    assert model.settings_from_config(cfg).storage_backend == "none"


@pytest.mark.parametrize("keep_counter_off", [True, False])
def test_one_save_normalises_a_retired_backend(keep_counter_off: bool) -> None:
    """After any save from the window, `storage.backend` is a backend we
    still ship.

    The counter-off case is the one that used to slip through: a retired
    backend reads back as "none", so leaving the counter alone was not a
    *change*, nothing was written, and `build_storage` kept printing its
    retirement notice on every startup.
    """
    cfg = {"storage": {"backend": "supabase"}, "supabase": {"url": "https://x"}}
    baseline = model.settings_from_config(cfg)
    s = (
        baseline
        if keep_counter_off
        else replace(baseline, storage_backend="sheets", sheets_spreadsheet_id="sid")
    )

    out = model.apply_settings(cfg, s, baseline=baseline)

    assert out["storage"]["backend"] in model.STORAGE_BACKENDS
    assert out["storage"]["backend"] == ("none" if keep_counter_off else "sheets")
    # The dead credentials block is left alone on purpose - see apply_settings.
    assert out["supabase"] == {"url": "https://x"}


def test_save_does_not_invent_a_backend_key() -> None:
    """Normalising a retired name must not turn into "always write the
    backend": a config that never set one keeps not having one."""
    s = model.settings_from_config(_EXISTING)
    out = model.apply_settings(_EXISTING, s, baseline=s)
    assert "backend" not in out.get("storage", {})


def test_volume_is_clamped_on_read_and_rounded_on_write() -> None:
    assert model.settings_from_config({"trigger": {"feedback_volume": 7}}).feedback_volume == 1.0
    out = model.apply_settings({}, replace(Settings(), feedback_volume=1 / 3))
    assert out["trigger"]["feedback_volume"] == 0.33


# ── Validation ─────────────────────────────────────────────────────────


def _fields(result: model.Validation) -> set[str]:
    return {i.field for i in result.errors}


def test_valid_minimal_spotify() -> None:
    assert model.validate(replace(Settings(), spotify_client_id="x")).ok


def test_spotify_needs_client_id_but_ytmusic_does_not() -> None:
    assert "spotify_client_id" in _fields(model.validate(Settings()))
    assert model.validate(replace(Settings(), provider="ytmusic")).ok


@pytest.mark.parametrize(
    "changes, field",
    [
        ({"provider": "tidal"}, "provider"),
        ({"storage_backend": "supabase"}, "storage_backend"),
        ({"hotkey": ""}, "hotkey"),
        ({"hotkey": "ctrl++w"}, "hotkey"),
        ({"feedback_volume": 1.5}, "feedback_volume"),
        ({"archive_enabled": True}, "archive_playlist"),
        (
            {"archive_enabled": True, "archive_playlist": "A", "remove_hotkey": "CTRL+shift+alt+W"},
            "remove_hotkey",
        ),
        ({"best_enabled": True, "best_playlist": "B", "best_threshold": 0}, "best_threshold"),
        ({"follow_enabled": True, "follow_threshold": 0}, "follow_threshold"),
        ({"cooldown_enabled": True, "cooldown_minutes": 0}, "cooldown_minutes"),
    ],
)
def test_validation_errors(changes, field) -> None:
    s = replace(Settings(), spotify_client_id="x", **changes)
    assert field in _fields(model.validate(s))


def test_remove_hotkey_only_checked_when_archive_on() -> None:
    assert model.validate(replace(Settings(), spotify_client_id="x", remove_hotkey="")).ok


def test_sheets_without_a_spreadsheet_warns_rather_than_blocking_save() -> None:
    """The window can make the sheet now, so Save must not be held hostage."""
    s = replace(Settings(), spotify_client_id="x", storage_backend="sheets")
    result = model.validate(s)
    assert result.ok
    assert "sheets_spreadsheet_id" in {i.field for i in result.warnings}


def test_storage_dependent_actions_warn_without_storage() -> None:
    s = replace(
        Settings(), spotify_client_id="x", best_enabled=True, best_playlist="B", follow_enabled=True
    )
    result = model.validate(s)
    assert result.ok
    assert {i.field for i in result.warnings} == {"best_enabled", "follow_enabled"}


def test_every_action_has_a_hint() -> None:
    assert set(model.ACTION_HINTS) == {
        "archive_remove",
        "promote_to_best",
        "follow_artist",
        "like_cooldown",
    }
    assert all(h and "\n" not in h for h in model.ACTION_HINTS.values())


# ── ConfigDocument (file I/O) ──────────────────────────────────────────


def test_save_merges_with_edits_made_while_window_open(tmp_paths) -> None:
    _write(_common.CONFIG_FILE, _EXISTING)
    doc = ConfigDocument()
    s = doc.initial_settings()

    # Someone else edits a field the window didn't touch.
    on_disk = _read(_common.CONFIG_FILE)
    on_disk["spotify"]["client_id"] = "changed-elsewhere"
    _write(_common.CONFIG_FILE, on_disk)

    assert doc.save(replace(s, hotkey="ctrl+alt+k")) is None
    cfg = _read(_common.CONFIG_FILE)
    assert cfg["spotify"]["client_id"] == "changed-elsewhere"
    assert cfg["trigger"]["hotkey"] == "ctrl+alt+k"
    assert doc.initial_settings().hotkey == "ctrl+alt+k"  # reloaded after save


def test_broken_json_is_reported_and_backed_up(tmp_paths) -> None:
    _common.CONFIG_FILE.write_text("{ not json", encoding="utf-8")
    doc = ConfigDocument()
    assert doc.load_error and "not valid JSON" in doc.load_error

    backup = doc.save(replace(doc.initial_settings(), spotify_client_id="x"))
    assert backup is not None and backup.read_text(encoding="utf-8") == "{ not json"
    assert _read(_common.CONFIG_FILE)["spotify"]["client_id"] == "x"
    assert doc.load_error is None


def test_non_object_json_is_a_load_error(tmp_paths) -> None:
    _common.CONFIG_FILE.write_text("[1, 2]", encoding="utf-8")
    assert "JSON object" in ConfigDocument().load_error


def test_save_leaves_no_temp_files(tmp_paths) -> None:
    ConfigDocument().save(replace(Settings(), spotify_client_id="x"))
    assert sorted(p.name for p in tmp_paths.iterdir()) == ["config.json"]


def test_saved_config_drives_the_host(tmp_paths) -> None:
    """What the window writes is what `_common` reads."""
    doc = ConfigDocument()
    doc.save(
        replace(
            Settings(),
            spotify_client_id="x",
            remove_hotkey="ctrl+alt+r",
            feedback_volume=0.8,
            archive_enabled=True,
            archive_playlist="Weekly",
        )
    )
    cfg = _common.load_config()
    assert _common.resolve_remove_hotkey(cfg) == "ctrl+alt+r"
    assert _common.resolve_feedback_volume(cfg) == 0.8
    assert _common.resolve_archive_playlist_name(cfg) == "Weekly"
    assert _common.resolve_provider_name(cfg) == "spotify"


# ── Services (the same auth primitives the wizard uses) ────────────────


class _FakeAuth:
    def __init__(self, has_tokens: bool = False) -> None:
        self.has_tokens = has_tokens
        self.calls: list = []

    def authorize(self, **kwargs) -> None:
        self.calls.append(kwargs)
        self.has_tokens = True


def test_connect_spotify_uses_provider_factory(tmp_paths, monkeypatch) -> None:
    fake = _FakeAuth()
    seen = []
    monkeypatch.setattr(_common, "make_provider", lambda cid: seen.append(cid) or fake)

    assert not services.spotify_connected("")
    services.connect_spotify("  cid  ")
    assert seen == ["cid"] and fake.calls == [{}]
    assert services.spotify_connected("cid")
    with pytest.raises(ValueError):
        services.connect_spotify(" ")


def test_connect_ytmusic_passes_google_client(tmp_paths, monkeypatch) -> None:
    fake = _FakeAuth()
    monkeypatch.setattr(_common, "make_ytmusic", lambda: fake)
    services.connect_ytmusic("id", "secret")
    assert fake.calls == [{"client_id": "id", "client_secret": "secret"}]
    with pytest.raises(ValueError):
        services.connect_ytmusic("id", "")


def test_connect_sheets_writes_google_token_file(tmp_paths, monkeypatch) -> None:
    calls = []
    monkeypatch.setattr(
        services.google_auth, "authorize", lambda **kw: calls.append(kw)
    )
    services.connect_sheets("id", "secret")
    assert calls == [
        {"client_id": "id", "client_secret": "secret", "token_path": _common.GOOGLE_TOKEN_FILE}
    ]


def test_saved_google_client_prefills_from_token_files(tmp_paths) -> None:
    _write(_common.YOUTUBE_TOKEN_FILE, {"client_id": "yt", "client_secret": "s1"})
    assert services.saved_google_client("ytmusic") == ("yt", "s1")
    assert services.saved_google_client("sheets") == ("", "")
    assert not services.sheets_connected()


def test_create_counter_sheet_refuses_before_google_is_connected(
    tmp_paths, monkeypatch
) -> None:
    """No tokens, no call — and a reason the window can print as-is."""
    called = {"n": 0}
    monkeypatch.setattr(
        services, "create_counter_spreadsheet", lambda *_a, **_k: called.update(n=1)
    )
    with pytest.raises(ValueError, match="connect Google first"):
        services.create_counter_sheet()
    assert called["n"] == 0


def test_create_counter_sheet_passes_a_token_provider(tmp_paths, monkeypatch) -> None:
    _write(
        _common.GOOGLE_TOKEN_FILE,
        {"refresh_token": "rt", "access_token": "at", "expires_at": 9999999999},
    )
    seen: list = []

    def _fake_create(token_provider, **_kw):
        seen.append(token_provider)
        return services.CreatedSpreadsheet(spreadsheet_id="made-1", url="u")

    monkeypatch.setattr(services, "create_counter_spreadsheet", _fake_create)

    created = services.create_counter_sheet()
    assert created.spreadsheet_id == "made-1"
    assert callable(seen[0])


def test_a_disabled_sheets_api_is_shown_as_its_own_sentence() -> None:
    """The window used to print every failure behind "Could not create the
    spreadsheet:", which in front of this one hides the only thing the user
    can go and do about it (#165)."""
    disabled = services.SheetsApiDisabledError(
        "The Google Sheets API is not enabled on your Google Cloud project "
        "12345. Enable it at https://example.test/enable, give Google a "
        "minute to catch up, then try again.",
        activation_url="https://example.test/enable",
        project="12345",
    )

    said = services.describe_create_failure(disabled)

    assert said.startswith("The Google Sheets API is not enabled")
    assert "https://example.test/enable" in said


def test_any_other_failure_keeps_the_prefix() -> None:
    said = services.describe_create_failure(RuntimeError("sheets create 429"))
    assert said == "Could not create the spreadsheet: sheets create 429"


def test_the_window_links_the_api_library_not_the_credentials_page() -> None:
    # Two different pages: the credentials one makes OAuth clients and cannot
    # switch an API on.
    assert services.GOOGLE_SHEETS_API_URL != services.GOOGLE_CREDENTIALS_URL
    assert services.GOOGLE_SHEETS_API_URL.endswith("sheets.googleapis.com")


def test_autostart_unsupported_off_windows(monkeypatch) -> None:
    monkeypatch.setattr(services.sys, "platform", "linux")
    assert services.autostart_supported() is False
    assert services.autostart_enabled() is None


# ── Lazy tkinter ───────────────────────────────────────────────────────


def test_importing_settings_does_not_import_tkinter() -> None:
    import importlib

    import like_spotify.hosts.settings as pkg

    importlib.reload(pkg)
    assert "like_spotify.hosts.settings.window" not in sys.modules or "tkinter" in sys.modules
    # The package, model and services themselves never import tkinter.
    for mod in (pkg, model, services):
        assert "tkinter" not in vars(mod)


def test_run_without_tkinter_prints_hint(monkeypatch, capsys) -> None:
    import builtins

    import like_spotify.hosts.settings as pkg

    real_import = builtins.__import__

    def fake_import(name, globals=None, locals=None, fromlist=(), level=0):
        if level == 1 and name == "" and "window" in (fromlist or ()):
            raise ImportError("No module named '_tkinter'")
        return real_import(name, globals, locals, fromlist, level)

    monkeypatch.delitem(sys.modules, "like_spotify.hosts.settings.window", raising=False)
    monkeypatch.setattr(builtins, "__import__", fake_import)
    assert pkg.run() == 2
    assert "--setup" in capsys.readouterr().err


def test_settings_flag_parses() -> None:
    args = _common.parse_args(["--settings", "--from-tray"])
    assert args.settings and args.from_tray
    assert not _common.parse_args([]).settings
