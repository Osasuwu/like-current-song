"""Interactive `--setup` wizard — music service + OAuth, like destination,
storage, archive, autostart.

Split out of `hosts/_common.py` in #58: the wizard (prompts, `do_setup`,
the `_setup_*` steps) was one of five unrelated concerns living in that
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
from like_spotify.core.pipeline import BOTH, LIKE_DESTINATIONS, NATIVE
from like_spotify.extensions.google_sheets_storage.create import (
    create_counter_spreadsheet,
)
from like_spotify.extensions.google_sheets_storage.errors import (
    SHEETS_API_LIBRARY_URL,
    SheetsApiDisabledError,
)
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
    """Interactive wizard: music service → its OAuth (Spotify or YouTube)
    → like destination → storage choice → archive playlist → autostart.

    Re-runnable. Existing OAuth tokens (Spotify, YouTube, Google) are kept unless
    `reauth=True` is passed — turning the counter off and back on does NOT
    invalidate the Google tokens, so a user can flip sheets ↔ none without
    redoing OAuth.
    """
    print("Like Current Song — interactive setup")
    print("--------------------------------")
    cfg = _common.load_config()
    try:
        if _choose_provider(cfg) == "ytmusic":
            _setup_ytmusic(cfg, reauth=reauth)
        else:
            _setup_spotify(cfg, reauth=reauth)
        _setup_like_destination(cfg)
        _setup_storage(cfg, reauth=reauth)
        # Both providers speak the playlist capability, so the archive
        # step is offered whichever music service was picked.
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
    print("Done. Launch with: like-current-song")
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
    print("\n[1/5] YouTube Music")
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
    print("\n[1/5] Spotify")
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


STORAGE_CHOICES = ["sheets", "none"]


def _setup_storage(cfg: dict, *, reauth: bool) -> None:
    print("\n[3/5] Storage (counts likes across devices)")
    print(
        "  Optional. 'none' keeps every like working and just doesn't count\n"
        "  them; 'sheets' counts them into a Google Sheet you own, which is\n"
        "  what best and follow-artist read."
    )
    current_backend = (cfg.get("storage", {}) or {}).get("backend", "")
    # A retired backend must not become the default — `_prompt_choice`
    # would reject it on every blank Enter and loop forever.
    default = current_backend if current_backend in STORAGE_CHOICES else "none"
    backend = _prompt_choice("  Backend", choices=STORAGE_CHOICES, default=default)
    cfg.setdefault("storage", {})["backend"] = backend

    if backend != "sheets":
        print("  ✓ Counter disabled — likes still work, no count tracking.")
        return

    # Google first, spreadsheet second: creating one needs the tokens, and
    # asking for an id the user may not have yet — then aborting on a blank
    # — used to end the whole wizard before it ever reached this auth.
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
                "https://console.cloud.google.com/apis/credentials, and "
                f"switch the Sheets API on at {SHEETS_API_LIBRARY_URL})"
            )
        print("  Opening browser for Google authorization…")
        google_auth.authorize(
            client_id=client_id,
            client_secret=client_secret,
            token_path=_common.GOOGLE_TOKEN_FILE,
        )
        print(f"  ✓ Google tokens saved: {_common.GOOGLE_TOKEN_FILE}")

    _setup_spreadsheet(cfg)


SPREADSHEET_CHOICES = ["create", "paste", "skip"]


def _setup_spreadsheet(cfg: dict) -> None:
    """Pick the counter's spreadsheet: make one, paste one, or do without.

    Pasting stays first-class — a household sheet the phone or another PC
    already counts in is the whole point of a *shared* counter, and there
    is no way to reach it but by its id.
    """
    sheets = cfg.setdefault("sheets", {})
    current = (sheets.get("spreadsheet_id") or "").strip()

    if current:
        # Acceptance criterion: never quietly make a second one. A stray
        # Enter here would otherwise orphan the sheet the counts are in.
        print(f"  A spreadsheet is already configured: {current}")
        choice = _prompt_choice(
            "  Spreadsheet",
            choices=["keep", *SPREADSHEET_CHOICES],
            default="keep",
        )
        if choice == "keep":
            print("  ✓ Keeping the configured spreadsheet.")
            return
        if choice == "create" and not _prompt_yes_no(
            "  Really make a second spreadsheet? The counts in the old one "
            "stay there and stop growing.",
            default=False,
        ):
            print("  ✓ Keeping the configured spreadsheet.")
            return
    else:
        print(
            "  'create' makes one in your Google Drive, tabs and headers and\n"
            "  all; 'paste' reuses a sheet another device already counts in;\n"
            "  'skip' turns the counter off."
        )
        choice = _prompt_choice(
            "  Spreadsheet", choices=SPREADSHEET_CHOICES, default="create"
        )

    if choice == "skip":
        cfg.setdefault("storage", {})["backend"] = "none"
        sheets["spreadsheet_id"] = ""
        print("  ✓ Counter disabled — likes still work, no count tracking.")
        return

    if choice == "paste":
        entered = _prompt_secret(
            "  Spreadsheet ID (from the sheet URL)", current=current
        ).strip()
        if not entered:
            raise _SetupAbort(
                "no spreadsheet ID entered — re-run --setup and pick "
                "'create' or 'skip' if you don't have one"
            )
        sheets["spreadsheet_id"] = entered
        print("  ✓ Counting into the spreadsheet you named.")
        return

    print("  Creating a spreadsheet in your Google Drive…")
    try:
        created = create_counter_spreadsheet(
            google_auth.make_token_provider(_common.GOOGLE_TOKEN_FILE)
        )
    except SheetsApiDisabledError as exc:
        # No prefix: this message is already a complete sentence about the
        # one thing to go and do, and "could not create the spreadsheet"
        # in front of it only buries the instruction (#165).
        raise _SetupAbort(str(exc)) from exc
    except Exception as exc:  # the wizard's own error channel says why
        raise _SetupAbort(f"could not create the spreadsheet: {exc}") from exc
    sheets["spreadsheet_id"] = created.spreadsheet_id
    print(f"  ✓ Created: {created.spreadsheet_id}")
    if created.url:
        print(f"    {created.url}")
    print("    Paste that ID into your phone to share the count.")


def _setup_like_destination(cfg: dict) -> None:
    """Where a like lands: the service's own like, a playlist, or both (#173).

    Asked before the counter because it decides what a press *does*;
    everything after it only decorates that. The current value is read
    through `_common.resolve_like_destination` (no provider — nothing is
    built yet), so a config that already names a destination re-offers it
    as the default, and an unreadable one is reported there.

    Picking `native` leaves any playlist name in place instead of blanking
    it: switching back and forth shouldn't make the user retype it.
    """
    print("\n[2/5] Where a like goes")
    print(
        "  'native' likes the track on the music service — that's what feeds\n"
        "  its recommendations. 'playlist' adds it to a playlist of your own\n"
        "  instead; on YouTube Music the native like shares one bucket with\n"
        "  liked videos, so a playlist is the only song-only list you can\n"
        "  keep. 'both' does the two."
    )
    current = _common.resolve_like_destination(cfg)
    destination = _prompt_choice(
        "  Like destination",
        choices=list(LIKE_DESTINATIONS),
        default=current.mode,
    )
    like_cfg = cfg.setdefault("like", {})
    like_cfg["destination"] = destination

    if destination == NATIVE:
        print("  ✓ Likes go to the music service.")
        return

    playlist_name = _prompt(
        "  Playlist name",
        default=current.playlist_name,
        required=True,
    )
    like_cfg["playlist_name"] = playlist_name
    if destination == BOTH:
        print(f"  ✓ Likes go to the music service and to: {playlist_name}")
    else:
        print(f"  ✓ Likes go to: {playlist_name}")


def _setup_archive(cfg: dict) -> None:
    """Playlist clean-up (e.g. a Discover Weekly archive): archive playlist + remove-without-like hotkey.

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
    print("\n[4/5] Playlist clean-up (optional)")
    print(
        "  Name one of your playlists to curate (e.g. an archived copy of\n"
        "  Spotify's Discover Weekly, or a YouTube Music playlist).\n"
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
    print("\n[5/5] Autostart")
    if sys.platform != "win32":
        # Print instructions only — issue AC: no auto-config on mac/linux.
        if sys.platform == "darwin":
            print(
                "  macOS: add a Launch Agent to start at login. Example "
                "(write to ~/Library/LaunchAgents/com.osasuwu.like-current-song.plist):"
            )
            print(
                '    <plist version="1.0"><dict>'
                '<key>Label</key><string>com.osasuwu.like-current-song</string>'
                '<key>ProgramArguments</key><array>'
                '<string>like-current-song</string><string>like-once</string>'
                '</array>'
                '<key>RunAtLoad</key><true/></dict></plist>'
            )
            print("    then: launchctl load ~/Library/LaunchAgents/com.osasuwu.like-current-song.plist")
        else:
            print(
                "  Linux: drop a .desktop entry into ~/.config/autostart/, e.g.\n"
                "    [Desktop Entry]\n"
                "    Type=Application\n"
                "    Exec=like-current-song like-once\n"
                "    Hidden=false\n"
                "    NoDisplay=false\n"
                "    Name=Like Current Song"
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
        else "  Start Like Current Song when you log in to Windows?"
    )
    if _prompt_yes_no(label, default=True):
        _win._autostart_set(True)
        print("  ✓ Autostart enabled (HKCU\\…\\Run)")
    else:
        _win._autostart_set(False)
        print("  ✓ Autostart disabled")
