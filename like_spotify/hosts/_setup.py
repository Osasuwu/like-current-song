"""Interactive `--setup` wizard — Spotify OAuth, storage, archive, autostart.

Split out of `hosts/_common.py` in #58: the wizard (prompts, `do_setup`,
the four `_setup_*` steps) was one of five unrelated concerns living in that
module alongside config I/O and the storage/action-chain builders. Every
host (`_stub.py`, `windows/resident.py`) calls `do_setup(reauth=...)` here
directly instead of going through `_common`.

References everything it needs from `_common` via `_common.<name>` (not
`from ._common import <name>`) so tests that monkeypatch `_common`
attributes (e.g. `_common.make_provider`, `_common.google_auth`) keep
working unchanged — this module just looks them up at call time.
"""

from __future__ import annotations

import sys

from like_spotify.auth import google as google_auth
from like_spotify.extensions.tray_hotkey_trigger import DEFAULT_HOTKEY

from . import _common


def _prompt(label: str, *, default: str = "", required: bool = False) -> str:
    hint = f" [{default}]" if default else (" [required]" if required else "")
    entered = input(f"{label}{hint}: ").strip()
    value = entered or default
    if required and not value:
        raise _SetupAbort(f"{label} is required")
    return value


def _prompt_secret(label: str, *, current: str = "") -> str:
    """Prompt with a masked preview of the current value (if any).

    `getpass`-style hiding isn't worth it here — `--setup` runs in a
    terminal the user controls, and the value is then written to a
    plaintext config file anyway. The mask is just to keep shoulder-
    surfing-friendly diffs out of `--config` output.
    """
    preview = (current[:4] + "…") if current else "required"
    entered = input(f"{label} [{preview}]: ").strip()
    return entered or current


def _prompt_choice(
    label: str, choices: list[str], default: str
) -> str:
    options = "/".join(c if c != default else f"{c}*" for c in choices)
    while True:
        entered = input(f"{label} [{options}]: ").strip().lower()
        value = entered or default
        if value in choices:
            return value
        print(f"  pick one of {', '.join(choices)}", file=sys.stderr)


def _prompt_yes_no(label: str, *, default: bool) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    entered = input(f"{label} {suffix}: ").strip().lower()
    if not entered:
        return default
    return entered.startswith("y")


class _SetupAbort(Exception):
    """User-facing setup failure — caught by `do_setup`."""


def do_setup(reauth: bool = False) -> int:
    """Interactive wizard: Spotify OAuth → storage choice → autostart.

    Re-runnable. Existing OAuth tokens (Spotify, Google) are kept unless
    `reauth=True` is passed — switching storage backend does NOT
    invalidate the other backend's tokens, so a user can flip
    supabase ↔ sheets without redoing OAuth.
    """
    print("Like Spotify — interactive setup")
    print("--------------------------------")
    cfg = _common.load_config()
    try:
        if _choose_provider(cfg) == "ytmusic":
            _setup_ytmusic(cfg, reauth=reauth)
        else:
            _setup_spotify(cfg, reauth=reauth)
        _setup_storage(cfg, reauth=reauth)
        if _common.resolve_provider_name(cfg) == "spotify":
            # Playlist clean-up needs Spotify playlists; YT Music has none here.
            _setup_archive(cfg)
        _setup_autostart()
    except _SetupAbort as e:
        print(f"Aborted: {e}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\nAborted by user.", file=sys.stderr)
        return 130

    _common.save_config(cfg)
    print(f"\nConfig saved: {_common.CONFIG_FILE}")
    print("Done. Launch with: like-spotify")
    return 0


# ── Wizard steps ───────────────────────────────────────────────────────


def _choose_provider(cfg: dict) -> str:
    current = _common.resolve_provider_name(cfg)
    provider = _prompt_choice(
        "Music service", choices=list(_common.PROVIDER_BUILDERS), default=current
    )
    cfg.setdefault("music", {})["provider"] = provider
    return provider


def _setup_ytmusic(cfg: dict, *, reauth: bool) -> None:
    print("\n[1/4] YouTube Music")
    cfg.setdefault("trigger", {}).setdefault("hotkey", DEFAULT_HOTKEY)
    # Persist now so a later step's failure doesn't lose the provider choice.
    _common.save_config(cfg)

    provider = _common.make_ytmusic()
    if provider.has_tokens and not reauth:
        print("  ✓ YouTube tokens already saved — skipping browser auth")
        print("    (use --reauth to force a re-login)")
        return
    tokens = google_auth.load_tokens(_common.YOUTUBE_TOKEN_FILE)
    print(
        "  Needs your own Google OAuth client (Desktop app) with the\n"
        "  YouTube Data API v3 enabled. Steps:\n"
        "  https://github.com/Osasuwu/like-current-song/blob/main/like_spotify/extensions/ytmusic/README.md\n"
        "  Publish the consent screen ('In production'), or Google\n"
        "  expires the login after 7 days."
    )
    client_id = _prompt_secret(
        "  Google OAuth Client ID", current=tokens.get("client_id", "")
    )
    client_secret = _prompt_secret(
        "  Google OAuth Client Secret", current=tokens.get("client_secret", "")
    )
    if not client_id or not client_secret:
        raise _SetupAbort(
            "google client id + secret are both required "
            "(create a Desktop OAuth client at "
            "https://console.cloud.google.com/apis/credentials)"
        )
    print("  Opening browser for Google (YouTube) authorization…")
    provider.authorize(client_id=client_id, client_secret=client_secret)
    print(f"  ✓ Tokens saved: {_common.YOUTUBE_TOKEN_FILE}")


def _setup_spotify(cfg: dict, *, reauth: bool) -> None:
    print("\n[1/4] Spotify")
    current_id = cfg.get("spotify", {}).get("client_id", "")
    client_id = _prompt_secret("  Client ID", current=current_id)
    if not client_id:
        raise _SetupAbort(
            "Spotify Client ID is required. Get one at "
            "https://developer.spotify.com/dashboard "
            "(redirect URI: http://127.0.0.1:8793/callback)."
        )
    cfg.setdefault("spotify", {})["client_id"] = client_id
    cfg.setdefault("trigger", {}).setdefault("hotkey", DEFAULT_HOTKEY)
    # Persist now so a later step's failure doesn't lose the client id.
    _common.save_config(cfg)

    provider = _common.make_provider(client_id)
    if provider.has_tokens and not reauth:
        print("  ✓ Spotify tokens already saved — skipping browser auth")
        print("    (use --reauth to force a re-login)")
        return
    print("  Opening browser for Spotify authorization (PKCE)…")
    provider.authorize()
    print(f"  ✓ Tokens saved: {_common.SPOTIFY_TOKEN_FILE}")


def _setup_storage(cfg: dict, *, reauth: bool) -> None:
    print("\n[2/4] Storage (counts likes across devices)")
    current_backend = (cfg.get("storage", {}) or {}).get("backend", "")
    default = current_backend or "none"
    backend = _prompt_choice(
        "  Backend", choices=["supabase", "sheets", "none"], default=default
    )
    cfg.setdefault("storage", {})["backend"] = backend

    if backend == "supabase":
        sb = cfg.setdefault("supabase", {})
        print("    (project URL, e.g. https://<ref>.supabase.co — not the /rest/v1 endpoint)")
        sb["url"] = _prompt_secret("  Supabase URL", current=sb.get("url", ""))
        sb["anon_key"] = _prompt_secret(
            "  Supabase anon key", current=sb.get("anon_key", "")
        )
        if not sb["url"] or not sb["anon_key"]:
            raise _SetupAbort("supabase URL + anon key are both required")
        print("  ✓ Supabase configured")
    elif backend == "sheets":
        sheets = cfg.setdefault("sheets", {})
        sheets["spreadsheet_id"] = _prompt_secret(
            "  Spreadsheet ID (from the sheet URL)",
            current=sheets.get("spreadsheet_id", ""),
        )
        if not sheets["spreadsheet_id"]:
            raise _SetupAbort("spreadsheet ID is required for sheets backend")

        tokens = google_auth.load_tokens(_common.GOOGLE_TOKEN_FILE)
        if tokens.get("refresh_token") and not reauth:
            print("  ✓ Google tokens already saved — skipping browser auth")
            print("    (use --reauth to force a re-login)")
        else:
            client_id = _prompt_secret(
                "  Google OAuth Client ID (Desktop app)",
                current=tokens.get("client_id", ""),
            )
            client_secret = _prompt_secret(
                "  Google OAuth Client Secret",
                current=tokens.get("client_secret", ""),
            )
            if not client_id or not client_secret:
                raise _SetupAbort(
                    "google client id + secret are both required "
                    "(create a Desktop OAuth client at "
                    "https://console.cloud.google.com/apis/credentials)"
                )
            print("  Opening browser for Google authorization…")
            google_auth.authorize(
                client_id=client_id,
                client_secret=client_secret,
                token_path=_common.GOOGLE_TOKEN_FILE,
            )
            print(f"  ✓ Google tokens saved: {_common.GOOGLE_TOKEN_FILE}")
    else:
        print("  ✓ Counter disabled — likes still work, no count tracking.")


def _setup_archive(cfg: dict) -> None:
    """Discover Weekly clean-up: archive playlist + remove-without-like hotkey.

    Two coupled settings, one playlist:
      - `actions.archive_remove.playlist_name` — when you like a track, it's
        auto-removed from this "save-for-later" playlist (the like flow's
        PostLikeAction).
      - `trigger.remove_hotkey` — a second hotkey that removes the current
        track from the *same* playlist WITHOUT liking it, for tracks you
        want gone but not saved. Only meaningful when a playlist is set.

    Empty input keeps the current value (the wizard's keep-on-blank idiom),
    so re-running setup for an unrelated step won't clobber the archive.
    Type `-` to turn the feature off; blank with nothing set = skip.
    """
    print("\n[3/4] Discover Weekly clean-up (optional)")
    print(
        "  Name a playlist (e.g. an archived copy of Discover Weekly) to "
        "curate.\n"
        "  Liking a track removes it from this playlist; a second hotkey "
        "removes\n"
        "  the current track WITHOUT liking it. Blank = skip, '-' = turn off."
    )
    current_name = _common.resolve_archive_playlist_name(cfg)
    if current_name:
        print(f"  (currently: {current_name})")
    playlist_name = _prompt("  Archive playlist name", default=current_name)
    archive_cfg = cfg.setdefault("actions", {}).setdefault("archive_remove", {})

    if playlist_name == "-":
        # Explicit off switch — idempotent: works whether or not a name was
        # set. The message reflects which it was so '-' never looks like a
        # no-op when the user clearly asked to turn it off.
        archive_cfg["enabled"] = False
        print("  ✓ Clean-up disabled." if current_name else "  ✓ Already disabled.")
        return
    if not playlist_name:
        # Bare Enter is only empty when nothing was configured (keep-on-blank
        # would otherwise have returned current_name) — so this is a skip.
        print("  ✓ Skipped.")
        return

    archive_cfg["playlist_name"] = playlist_name
    archive_cfg["enabled"] = True

    current_hotkey = _common.resolve_remove_hotkey(cfg)
    remove_hotkey = _prompt(
        "  Remove-without-like hotkey",
        default=current_hotkey or _common.DEFAULT_REMOVE_HOTKEY,
    )
    cfg.setdefault("trigger", {})["remove_hotkey"] = remove_hotkey
    print(f"  ✓ Archive playlist: {playlist_name}")
    print(f"  ✓ Remove hotkey: {remove_hotkey.upper()}")


def _setup_autostart() -> None:
    print("\n[4/4] Autostart")
    if sys.platform != "win32":
        # Print instructions only — issue AC: no auto-config on mac/linux.
        if sys.platform == "darwin":
            print(
                "  macOS: add a Launch Agent to start at login. Example "
                "(write to ~/Library/LaunchAgents/com.osasuwu.like-spotify.plist):"
            )
            print(
                '    <plist version="1.0"><dict>'
                '<key>Label</key><string>com.osasuwu.like-spotify</string>'
                '<key>ProgramArguments</key><array>'
                '<string>like-spotify</string><string>like-once</string>'
                '</array>'
                '<key>RunAtLoad</key><true/></dict></plist>'
            )
            print("    then: launchctl load ~/Library/LaunchAgents/com.osasuwu.like-spotify.plist")
        else:
            print(
                "  Linux: drop a .desktop entry into ~/.config/autostart/, e.g.\n"
                "    [Desktop Entry]\n"
                "    Type=Application\n"
                "    Exec=like-spotify like-once\n"
                "    Hidden=false\n"
                "    NoDisplay=false\n"
                "    Name=Like Spotify"
            )
        print("  (See CONTRIBUTING.md for the full hosts/macos.py / linux.py story.)")
        return

    # Windows: prompt to toggle the registry Run key.
    try:
        from like_spotify.hosts import windows as _win

        already = _win._autostart_enabled()
    except Exception:
        print("  (could not query autostart — skip)", file=sys.stderr)
        return

    label = (
        "  Autostart is currently ENABLED — keep it on?"
        if already
        else "  Start Like Spotify when you log in to Windows?"
    )
    if _prompt_yes_no(label, default=True):
        _win._autostart_set(True)
        print("  ✓ Autostart enabled (HKCU\\…\\Run)")
    else:
        _win._autostart_set(False)
        print("  ✓ Autostart disabled")
