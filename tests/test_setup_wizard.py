"""Setup wizard + storage dispatch tests.

Slice: #28 (one-liner install + interactive --setup + autostart).

Covers the wizard branches (re-runnable, --reauth, storage backend
choice, autostart) and the multi-backend `build_storage` dispatch.
The real OAuth flows (Spotify PKCE, Google installed-app) are not
exercised — they hit a real browser + network; the wizard mocks the
provider/storage factories at their boundaries.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest

from like_spotify.extensions.google_sheets_storage.create import CreatedSpreadsheet
from like_spotify.extensions.google_sheets_storage.errors import (
    SheetsApiDisabledError,
)
from like_spotify.hosts import _common, _setup


# ── Fixtures ───────────────────────────────────────────────────────────


@pytest.fixture
def tmp_paths(tmp_path, monkeypatch) -> Iterator[Path]:
    """Redirect all host I/O at a writable tmp dir."""
    cfg = tmp_path / "config.json"
    spotify = tmp_path / "spotify_token.json"
    google = tmp_path / "google_token.json"
    monkeypatch.setattr(_common, "CONFIG_FILE", cfg)
    monkeypatch.setattr(_common, "SPOTIFY_TOKEN_FILE", spotify)
    monkeypatch.setattr(_common, "GOOGLE_TOKEN_FILE", google)
    monkeypatch.setattr(_common, "YOUTUBE_TOKEN_FILE", tmp_path / "youtube_token.json")
    yield tmp_path


class _FakeProvider:
    """Stand-in for SpotifyMusicProvider used during setup."""

    def __init__(self, has_tokens: bool = False) -> None:
        self._has = has_tokens
        self.authorize_calls = 0

    @property
    def has_tokens(self) -> bool:
        return self._has

    def authorize(self) -> None:
        self.authorize_calls += 1
        self._has = True


@pytest.fixture
def fake_provider(monkeypatch) -> _FakeProvider:
    fp = _FakeProvider()
    monkeypatch.setattr(_common, "make_provider", lambda _client_id: fp)
    return fp


def _scripted_input(answers: list[str]):
    """Returns a callable substitute for `input` that pops answers in order.

    If the wizard prompts more than scripted, fail fast — that's a real
    drift in the wizard, not a test bug.
    """
    answers = list(answers)

    def _input(prompt: str = "") -> str:
        if not answers:
            raise AssertionError(f"wizard asked for more input than scripted: {prompt!r}")
        return answers.pop(0)

    return _input


# ── do_setup happy path: Spotify + no counter + no autostart ───────────


def test_setup_writes_config_and_runs_oauth(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    answers = [
        "",                    # music service — default spotify
        "abc123client",        # Spotify Client ID
        "none",                # Storage backend
        "",                    # [3/4] archive playlist name — blank = skip
        # autostart prompt only fires on win32 — we patch sys.platform off
    ]
    monkeypatch.setattr("builtins.input", _scripted_input(answers))
    monkeypatch.setattr(_common.sys, "platform", "darwin")

    rc = _setup.do_setup(reauth=False)
    assert rc == 0

    cfg = _common.load_config()
    assert cfg["spotify"]["client_id"] == "abc123client"
    assert cfg["storage"]["backend"] == "none"
    assert fake_provider.authorize_calls == 1


def test_setup_skips_spotify_oauth_when_tokens_present(
    tmp_paths, monkeypatch
) -> None:
    fp = _FakeProvider(has_tokens=True)
    monkeypatch.setattr(_common, "make_provider", lambda _cid: fp)
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "none",
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 0
    assert fp.authorize_calls == 0  # tokens already there


def test_setup_reauth_forces_oauth_even_with_tokens(
    tmp_paths, monkeypatch
) -> None:
    fp = _FakeProvider(has_tokens=True)
    monkeypatch.setattr(_common, "make_provider", lambda _cid: fp)
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "none",
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=True)
    assert rc == 0
    assert fp.authorize_calls == 1


def test_setup_aborts_when_client_id_missing(
    tmp_paths, fake_provider, monkeypatch, capsys
) -> None:
    monkeypatch.setattr("builtins.input", _scripted_input(["", ""]))  # service default, blank client id
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 2
    err = capsys.readouterr().err
    assert "Client ID is required" in err


def test_setup_storage_none_writes_backend_marker(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "none",
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 0
    cfg = _common.load_config()
    assert cfg["storage"]["backend"] == "none"
    # No sheets block created.
    assert "sheets" not in cfg or not cfg.get("sheets")


def test_setup_archive_writes_playlist_and_remove_hotkey(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    """[3/4]: a playlist name + remove hotkey land in config so the
    archive PostLikeAction AND the remove-without-like trigger both wire."""
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "none",
        "Discover Weekly Archive",  # [3/4] archive playlist name
        "ctrl+shift+alt+e",         # [3/4] remove hotkey (override default)
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 0
    cfg = _common.load_config()
    assert cfg["actions"]["archive_remove"]["playlist_name"] == "Discover Weekly Archive"
    assert cfg["actions"]["archive_remove"]["enabled"] is True
    assert cfg["trigger"]["remove_hotkey"] == "ctrl+shift+alt+e"
    # The same name drives the like-flow archive action.
    assert _common.resolve_archive_playlist_name(cfg) == "Discover Weekly Archive"


def test_setup_archive_blank_disables_previously_set_name(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    """Re-running and clearing the name must turn the feature off, not
    leave a stale playlist silently configured."""
    _common.save_config({
        "actions": {"archive_remove": {"playlist_name": "Old", "enabled": True}},
    })
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "none",
        "-",  # [3/4] archive — '-' turns it off (blank would KEEP it)
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 0
    cfg = _common.load_config()
    assert cfg["actions"]["archive_remove"]["enabled"] is False
    assert _common.resolve_archive_playlist_name(cfg) == ""


def test_setup_archive_overwrites_existing_name(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    """Typing a *different* name replaces the old one (the rename path) and
    keeps the feature enabled — guards the one-line overwrite from refactors."""
    _common.save_config({
        "actions": {"archive_remove": {"playlist_name": "Old", "enabled": True}},
    })
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "none",
        "New Archive",        # [3/4] archive — rename
        "ctrl+shift+alt+q",   # [3/4] remove hotkey
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 0
    cfg = _common.load_config()
    assert cfg["actions"]["archive_remove"]["playlist_name"] == "New Archive"
    assert cfg["actions"]["archive_remove"]["enabled"] is True
    assert _common.resolve_archive_playlist_name(cfg) == "New Archive"


def test_setup_archive_dash_when_nothing_configured_disables_cleanly(
    tmp_paths, fake_provider, monkeypatch, capsys
) -> None:
    """'-' with no prior name is idempotent: feature stays off and the
    message acknowledges the explicit off-switch rather than 'Skipped'."""
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "none",
        "-",  # [3/4] archive — explicit off with nothing set
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 0
    cfg = _common.load_config()
    assert cfg["actions"]["archive_remove"]["enabled"] is False
    assert "playlist_name" not in cfg["actions"]["archive_remove"]
    assert _common.resolve_archive_playlist_name(cfg) == ""
    assert "Already disabled" in capsys.readouterr().out


def _signed_in_google() -> None:
    """Pretend Google is already authorised, so the wizard skips its OAuth."""
    _common.GOOGLE_TOKEN_FILE.write_text(
        '{"refresh_token": "rt", "access_token": "at",'
        ' "expires_at": 9999999999, "client_id": "cid", "client_secret": "sec"}'
    )


def _fake_create(
    monkeypatch, *, spreadsheet_id: str = "made-1", url: str | None = None, error=None
) -> dict:
    """Stand in for the real create call — no spreadsheet is ever made."""
    calls: dict = {"n": 0}

    def _create(token_provider, **_kw):
        calls["n"] += 1
        calls["token_provider"] = token_provider
        if error is not None:
            raise error
        return CreatedSpreadsheet(spreadsheet_id=spreadsheet_id, url=url)

    monkeypatch.setattr(_setup, "create_counter_spreadsheet", _create)
    return calls


def test_setup_aborts_when_paste_chosen_without_an_id(
    tmp_paths, fake_provider, monkeypatch, capsys
) -> None:
    """Blank is no longer a dead end for the whole wizard — but if you asked
    to paste and pasted nothing, there is nothing to count into."""
    _signed_in_google()
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        "paste",
        "",  # empty spreadsheet id
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 2
    assert "spreadsheet" in capsys.readouterr().err.lower()


def test_setup_creates_the_spreadsheet_and_stores_its_id(
    tmp_paths, fake_provider, monkeypatch, capsys
) -> None:
    _signed_in_google()
    calls = _fake_create(
        monkeypatch, spreadsheet_id="made-1", url="https://example.invalid/made-1"
    )
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        "",  # spreadsheet — bare Enter takes 'create'
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 0
    assert calls["n"] == 1
    cfg = _common.load_config()
    assert cfg["storage"]["backend"] == "sheets"
    assert cfg["sheets"]["spreadsheet_id"] == "made-1"
    out = capsys.readouterr().out
    assert "made-1" in out
    assert "https://example.invalid/made-1" in out


def test_setup_keeps_the_configured_spreadsheet_rather_than_making_a_second(
    tmp_paths, fake_provider, monkeypatch, capsys
) -> None:
    """Acceptance criterion: never quietly end up with two counters."""
    _signed_in_google()
    _common.save_config({"sheets": {"spreadsheet_id": "household-1"}})
    calls = _fake_create(monkeypatch)
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        "",  # spreadsheet — bare Enter keeps what is configured
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 0
    assert calls["n"] == 0
    assert _common.load_config()["sheets"]["spreadsheet_id"] == "household-1"
    assert "already configured" in capsys.readouterr().out


def test_setup_second_spreadsheet_needs_a_confirmation(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    _signed_in_google()
    _common.save_config({"sheets": {"spreadsheet_id": "household-1"}})
    calls = _fake_create(monkeypatch)
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        "create",  # asked for a second one…
        "n",       # …then said no
        "",        # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 0
    assert calls["n"] == 0
    assert _common.load_config()["sheets"]["spreadsheet_id"] == "household-1"


def test_setup_skip_turns_the_counter_off_without_aborting(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    _signed_in_google()
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        "skip",
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 0
    assert _common.load_config()["storage"]["backend"] == "none"


def test_setup_reports_why_creating_failed(
    tmp_paths, fake_provider, monkeypatch, capsys
) -> None:
    _signed_in_google()
    _fake_create(monkeypatch, error=RuntimeError("sheets create 429: slow down"))
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        "create",
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 2
    assert "sheets create 429: slow down" in capsys.readouterr().err


def test_setup_says_to_switch_the_sheets_api_on(
    tmp_paths, fake_provider, monkeypatch, capsys
) -> None:
    """A project with the API off is the one failure the user can act on, so
    it is printed as its own sentence — no "could not create the
    spreadsheet:" in front of it burying the instruction (#165)."""
    _signed_in_google()
    _fake_create(
        monkeypatch,
        error=SheetsApiDisabledError(
            "The Google Sheets API is not enabled on your Google Cloud "
            "project 12345. Enable it at https://example.test/enable, give "
            "Google a minute to catch up, then try again.",
            activation_url="https://example.test/enable",
            project="12345",
        ),
    )
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        "create",
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 2
    printed = capsys.readouterr().err
    assert "Google Sheets API is not enabled" in printed
    assert "https://example.test/enable" in printed
    assert "Could not create the spreadsheet" not in printed


def test_setup_does_not_default_to_a_retired_backend(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    """A config left on the removed Supabase backend must not become the
    prompt's default - a blank Enter would be rejected forever. Bare Enter
    falls through to "none", which the user can then change to sheets."""
    _common.save_config({"storage": {"backend": "supabase"}})
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "",  # storage backend — bare Enter takes the default
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    rc = _setup.do_setup(reauth=False)
    assert rc == 0
    assert _common.load_config()["storage"]["backend"] == "none"


def test_setup_sheets_branch_runs_google_oauth(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        # Google auth comes first now — making a spreadsheet needs its tokens.
        "google-client.apps.googleusercontent.com",
        "google-secret",
        "paste",
        "spreadsheet-id-xyz",
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    calls: dict = {}

    def fake_google_authorize(*, client_id, client_secret, token_path):
        calls["client_id"] = client_id
        calls["client_secret"] = client_secret
        calls["token_path"] = token_path
        # Pretend the OAuth flow wrote a refresh token to disk.
        token_path.write_text('{"refresh_token": "rt", "access_token": "at"}')
        return {"refresh_token": "rt", "access_token": "at"}

    monkeypatch.setattr(_common.google_auth, "authorize", fake_google_authorize)

    rc = _setup.do_setup(reauth=False)
    assert rc == 0

    cfg = _common.load_config()
    assert cfg["storage"]["backend"] == "sheets"
    assert cfg["sheets"]["spreadsheet_id"] == "spreadsheet-id-xyz"
    assert calls["client_id"] == "google-client.apps.googleusercontent.com"
    assert calls["client_secret"] == "google-secret"
    assert calls["token_path"] == _common.GOOGLE_TOKEN_FILE


def test_setup_sheets_skips_google_oauth_when_refresh_token_present(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    """If google_token.json already has a refresh_token, the wizard should
    not re-prompt for client_id/secret and not call `authorize`."""
    _common.GOOGLE_TOKEN_FILE.write_text(
        '{"refresh_token": "rt", "access_token": "at",'
        ' "client_id": "old", "client_secret": "old"}'
    )

    monkeypatch.setattr("builtins.input", _scripted_input([
        "",  # music service — default spotify
        "abc123client",
        "sheets",
        # NO client_id/secret prompts because refresh_token is present.
        "paste",
        "spreadsheet-id-xyz",
        "",  # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    called = {"n": 0}

    def fake_google_authorize(**_kw):
        called["n"] += 1

    monkeypatch.setattr(_common.google_auth, "authorize", fake_google_authorize)

    rc = _setup.do_setup(reauth=False)
    assert rc == 0
    assert called["n"] == 0


# ── build_storage dispatch ─────────────────────────────────────────────


def test_build_storage_retired_supabase_backend_returns_none(
    tmp_paths, capsys
) -> None:
    """THE upgrade path: an existing `~/.like_spotify/config.json` still
    says `backend: "supabase"`. It must resolve to None - likes keep
    working and count nowhere - never raise, and say so once on stderr."""
    storage = _common.build_storage({
        "storage": {"backend": "supabase"},
        "supabase": {"url": "https://x.supabase.co", "anon_key": "k"},
    })
    assert storage is None
    err = capsys.readouterr().err
    assert "--setup" in err
    assert "sheets" in err.lower()


def test_build_storage_legacy_supabase_block_returns_none(tmp_paths) -> None:
    """A pre-#28 config with only a `supabase` block and no backend marker
    no longer infers anything - it is just an unconfigured counter."""
    assert _common.build_storage({
        "supabase": {"url": "https://x.supabase.co", "anon_key": "k"},
    }) is None


def test_build_storage_ignores_supabase_env_vars(tmp_paths, monkeypatch) -> None:
    """Pre-#28 env-var-only deploys no longer wire a backend either."""
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_ANON_KEY", "k")
    assert _common.build_storage({}) is None


def test_build_storage_sheets_backend(tmp_paths) -> None:
    _common.GOOGLE_TOKEN_FILE.write_text(
        '{"refresh_token": "rt", "access_token": "at",'
        ' "expires_at": 9999999999,'
        ' "client_id": "cid", "client_secret": "sec"}'
    )
    storage = _common.build_storage({
        "storage": {"backend": "sheets"},
        "sheets": {"spreadsheet_id": "sid"},
    })
    assert storage is not None
    assert type(storage).__name__ == "GoogleSheetsStorage"


def test_build_storage_none_backend_returns_none(tmp_paths) -> None:
    assert _common.build_storage({"storage": {"backend": "none"}}) is None


def test_build_storage_unknown_backend_returns_none(tmp_paths) -> None:
    """Acceptance criterion #22: like still succeeds when storage is
    unconfigured. A backend name the host does not know is not a crash."""
    assert _common.build_storage({"storage": {"backend": "redis"}}) is None


def test_build_storage_missing_spreadsheet_id_returns_none(tmp_paths) -> None:
    assert _common.build_storage({"storage": {"backend": "sheets"}}) is None


# ── archive name resolution + remove-pipeline builder (#43) ────────────


def test_resolve_archive_name_reads_nested_key() -> None:
    cfg = {"actions": {"archive_remove": {"playlist_name": "Arch"}}}
    assert _common.resolve_archive_playlist_name(cfg) == "Arch"


def test_resolve_archive_name_legacy_flat_key() -> None:
    assert _common.resolve_archive_playlist_name({"archive_playlist_name": "Old"}) == "Old"


def test_resolve_archive_name_honors_disabled_flag() -> None:
    cfg = {"actions": {"archive_remove": {"playlist_name": "Arch", "enabled": False}}}
    assert _common.resolve_archive_playlist_name(cfg) == ""


def test_resolve_archive_name_empty_when_unset() -> None:
    assert _common.resolve_archive_playlist_name({}) == ""


def test_build_remove_pipeline_none_when_no_archive() -> None:
    assert _common.build_remove_pipeline({}, object(), lambda *a, **k: None) is None


def test_build_remove_pipeline_built_when_configured() -> None:
    cfg = {"actions": {"archive_remove": {"playlist_name": "Arch"}}}
    pipe = _common.build_remove_pipeline(cfg, object(), lambda *a, **k: None)
    assert pipe is not None
    assert pipe._playlist_name == "Arch"


def test_resolve_remove_hotkey_default_and_override() -> None:
    assert _common.resolve_remove_hotkey({}) == _common.DEFAULT_REMOVE_HOTKEY
    assert (
        _common.resolve_remove_hotkey({"trigger": {"remove_hotkey": "ctrl+x"}})
        == "ctrl+x"
    )


# ── print_config_paths surfaces all three paths ────────────────────────


def test_print_config_paths_includes_google_token(tmp_paths, capsys) -> None:
    rc = _common.print_config_paths()
    assert rc == 0
    out = capsys.readouterr().out
    assert "Config:" in out
    assert "Spotify token:" in out
    assert "Google token:" in out


# ── YouTube Music provider branch ──────────────────────────────────────


class _FakeYtProvider:
    def __init__(self, has_tokens: bool = False) -> None:
        self._has = has_tokens
        self.authorized_with: tuple[str, str] | None = None

    @property
    def has_tokens(self) -> bool:
        return self._has

    def authorize(self, client_id: str, client_secret: str) -> None:
        self.authorized_with = (client_id, client_secret)
        self._has = True


def test_setup_ytmusic_runs_google_oauth(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    yt = _FakeYtProvider()
    monkeypatch.setattr(_common, "make_ytmusic", lambda: yt)
    monkeypatch.setattr("builtins.input", _scripted_input([
        "ytmusic",      # music service
        "g-client",     # Google OAuth client id
        "g-secret",     # Google OAuth client secret
        "none",         # storage
        "",             # [3/4] archive — skip
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 0
    assert yt.authorized_with == ("g-client", "g-secret")
    assert fake_provider.authorize_calls == 0  # Spotify untouched
    cfg = _common.load_config()
    assert cfg["music"]["provider"] == "ytmusic"
    assert "spotify" not in cfg
    assert _common.resolve_archive_playlist_name(cfg) == ""


def test_setup_ytmusic_offers_archive_step(
    tmp_paths, fake_provider, monkeypatch
) -> None:
    """#99: YT Music speaks the playlist capability, so the archive step
    (and its remove-without-like hotkey) is offered for it too."""
    monkeypatch.setattr(_common, "make_ytmusic", lambda: _FakeYtProvider(has_tokens=True))
    monkeypatch.setattr("builtins.input", _scripted_input([
        "ytmusic",          # music service (tokens present → no OAuth prompts)
        "none",             # storage
        "YT Archive",       # [3/4] archive playlist name
        "",                 # remove hotkey — default
    ]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 0
    cfg = _common.load_config()
    assert cfg["music"]["provider"] == "ytmusic"
    assert _common.resolve_archive_playlist_name(cfg) == "YT Archive"
    assert cfg["trigger"]["remove_hotkey"] == _common.DEFAULT_REMOVE_HOTKEY


def test_setup_ytmusic_aborts_without_google_client(
    tmp_paths, monkeypatch, capsys
) -> None:
    monkeypatch.setattr(_common, "make_ytmusic", lambda: _FakeYtProvider())
    monkeypatch.setattr("builtins.input", _scripted_input(["ytmusic", "", ""]))
    monkeypatch.setattr(_common.sys, "platform", "linux")

    assert _setup.do_setup(reauth=False) == 2
    assert "client id + secret" in capsys.readouterr().err


# ── build_provider dispatch ────────────────────────────────────────────


def test_build_provider_defaults_to_spotify(monkeypatch) -> None:
    monkeypatch.delenv("SPOTIFY_CLIENT_ID", raising=False)
    monkeypatch.setattr(_common, "make_provider", lambda cid: ("spotify", cid))
    assert _common.build_provider({"spotify": {"client_id": "abc"}}) == ("spotify", "abc")
    assert _common.build_provider({}) is None  # no client id → not configured


def test_build_provider_selects_ytmusic(monkeypatch) -> None:
    sentinel = object()
    monkeypatch.setattr(_common, "make_ytmusic", lambda: sentinel)
    assert _common.build_provider({"music": {"provider": "ytmusic"}}) is sentinel


def test_build_provider_unknown_name_is_not_configured() -> None:
    assert _common.build_provider({"music": {"provider": "napster"}}) is None
