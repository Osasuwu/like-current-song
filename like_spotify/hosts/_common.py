"""Cross-platform host helpers shared by every host implementation.

Hosts (windows / _stub / future macos+linux) compose the same pipeline:
config + provider + storage + post-action chain. The differences are the
runtime shell (tray vs CLI vs systemd) and the OS-bound side effects
(autostart, single-instance, native beep). Everything else lives here so
the host modules stay thin and platform-pure.

Slice history:
    #21 — extracted from the original tray launcher.
    #27 — split out of `hosts/tray.py` so `_stub.py` (mac/linux CLI)
          can share the same setup / config code without dragging in
          winreg / winsound / pystray.
    #58 — storage backends and action-chain extensions moved from
          hand-written if/elif chains to registries (`_STORAGE_BUILDERS`,
          `_ACTION_EXTENSION_BUILDERS`); the interactive setup wizard
          moved out to `hosts/_setup.py`.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Callable

from like_spotify.auth import google as google_auth
from like_spotify.core.actions import PostLikeAction, PreLikeAction
from like_spotify.core.pipeline import FeedbackFn, RemoveFromPlaylistPipeline
from like_spotify.core.storage import Storage
from like_spotify.extensions.one_shot_cli_trigger import (
    TRIGGER as make_one_shot_cli_trigger,
)
from like_spotify.extensions.archive_remove import (
    POST_LIKE_ACTION as make_archive_remove_action,
)
from like_spotify.extensions.follow_artist import (
    POST_LIKE_ACTION as make_follow_artist_action,
)
from like_spotify.extensions.google_sheets_storage import (
    STORAGE as make_google_sheets_storage,
)
from like_spotify.extensions.like_cooldown import (
    DEFAULT_MINUTES as DEFAULT_LIKE_COOLDOWN_MINUTES,
    build_like_cooldown,
)
from like_spotify.extensions.promote_to_best_of import (
    POST_LIKE_ACTION as make_promote_to_best_of_action,
)
from like_spotify.extensions.spotify import MUSIC_PROVIDER as make_spotify_provider
from like_spotify.extensions.supabase_storage import STORAGE as make_supabase_storage
from like_spotify.extensions.ytmusic import MUSIC_PROVIDER as make_ytmusic_provider

# Second hotkey: remove the current track from the archive playlist WITHOUT
# liking it. Distinct from DEFAULT_HOTKEY (the like trigger). The desktop can
# bind arbitrarily many triggers; headphones are limited to one media-button
# pattern, so this is desktop-only by design.
DEFAULT_REMOVE_HOTKEY = "ctrl+shift+alt+q"

# Beep loudness (0.0-1.0) for the synthesized tray tone (#53). Tuned down
# from the tone's initial full-scale level, which was audible but jarring
# for a hotkey confirmation played over whatever's already in the speakers.
DEFAULT_FEEDBACK_VOLUME = 0.25

# ── Paths ──────────────────────────────────────────────────────────────


def _config_dir() -> Path:
    return Path.home() / ".like_spotify"


CONFIG_FILE = _config_dir() / "config.json"
SPOTIFY_TOKEN_FILE = _config_dir() / "spotify_token.json"
GOOGLE_TOKEN_FILE = _config_dir() / "google_token.json"
YOUTUBE_TOKEN_FILE = _config_dir() / "youtube_token.json"
LIKE_COOLDOWN_FILE = _config_dir() / "like_cooldown.json"


def load_config() -> dict:
    if not CONFIG_FILE.exists():
        return {}
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_config(cfg: dict) -> None:
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")


# ── Storage / provider builders ────────────────────────────────────────


def _build_supabase_storage(cfg: dict) -> Storage | None:
    sb = cfg.get("supabase", {}) if isinstance(cfg.get("supabase"), dict) else {}
    url = sb.get("url") or os.environ.get("SUPABASE_URL", "")
    key = sb.get("anon_key") or os.environ.get("SUPABASE_ANON_KEY", "")
    if not url or not key:
        return None
    try:
        return make_supabase_storage(url=url, anon_key=key)
    except Exception:
        return None


def _build_sheets_storage(cfg: dict) -> Storage | None:
    sheets = cfg.get("sheets", {}) if isinstance(cfg.get("sheets"), dict) else {}
    sid = sheets.get("spreadsheet_id") or os.environ.get(
        "GOOGLE_SHEETS_SPREADSHEET_ID", ""
    )
    if not sid:
        return None
    try:
        token_provider = google_auth.make_token_provider(GOOGLE_TOKEN_FILE)
        return make_google_sheets_storage(
            spreadsheet_id=sid,
            token_provider=token_provider,
        )
    except Exception:
        return None


# Backend name → builder. Adding a backend is one function + one entry here,
# not another `elif` in `build_storage`.
_STORAGE_BUILDERS: dict[str, Callable[[dict], Storage | None]] = {
    "supabase": _build_supabase_storage,
    "sheets": _build_sheets_storage,
}


def build_storage(cfg: dict) -> Storage | None:
    """Return the configured Storage impl, or None when none is wired.

    Selection (set in `cfg["storage"]["backend"]`) dispatches through
    `_STORAGE_BUILDERS`:
        - "supabase" → SupabaseStorage (default; back-compat: also picked
          when `cfg["supabase"]` is populated and no explicit backend).
        - "sheets"   → GoogleSheetsStorage, backed by tokens persisted
          in `GOOGLE_TOKEN_FILE` (refreshed automatically).
        - "none" / missing / unknown → None. Pipeline treats `None` as
          "counter silently unavailable" — AC #22 says like still succeeds.
    """
    backend = (cfg.get("storage", {}) or {}).get("backend", "")

    # Back-compat for configs written before #28:
    #   - a populated `supabase` block implies Supabase
    #   - OR SUPABASE_URL + SUPABASE_ANON_KEY env vars alone (the pre-#28
    #     Android / CI path) — keep this working so existing deployments
    #     don't regress when they upgrade.
    if not backend:
        sb = cfg.get("supabase", {}) if isinstance(cfg.get("supabase"), dict) else {}
        if sb.get("url") and sb.get("anon_key"):
            backend = "supabase"
        elif os.environ.get("SUPABASE_URL") and os.environ.get("SUPABASE_ANON_KEY"):
            backend = "supabase"

    builder = _STORAGE_BUILDERS.get(backend)
    return builder(cfg) if builder else None


def resolve_archive_playlist_name(cfg: dict) -> str:
    """The configured Discover Weekly archive playlist name, or "".

    Single source of truth for both the like-flow `ArchiveRemoveAction`
    and the remove-without-like `RemoveFromPlaylistPipeline` — they curate
    the *same* playlist, so they must read the same key. Honors the
    `actions.archive_remove.enabled = false` opt-out (returns "" when off).
    """
    nested = cfg.get("actions") if isinstance(cfg.get("actions"), dict) else {}
    archive_cfg = (
        nested.get("archive_remove")
        if isinstance(nested.get("archive_remove"), dict)
        else {}
    )
    if not archive_cfg.get("enabled", True):
        return ""
    return (
        archive_cfg.get("playlist_name")
        or nested.get("archive_playlist_name")
        or cfg.get("archive_playlist_name")  # legacy flat key
        or ""
    )


# An action-extension builder takes (cfg, storage) and returns whichever
# half(s) of the chain it contributes — either can be None.
_ActionChainBuilder = Callable[
    [dict, "Storage | None"], "tuple[PreLikeAction | None, PostLikeAction | None]"
]


def _build_like_cooldown_actions(
    cfg: dict, _storage: Storage | None
) -> tuple[PreLikeAction | None, PostLikeAction | None]:
    """Build the like-cooldown gate + recorder from one shared `_CooldownStore`.

    `actions.like_cooldown.minutes` (default 10), opt-out via
    `actions.like_cooldown.enabled = false`. Both halves come from a single
    `build_like_cooldown` call so the gate and recorder are structurally
    coupled to the same store, rather than each independently constructing
    (and silently diverging on) their own.
    """
    nested = cfg.get("actions") if isinstance(cfg.get("actions"), dict) else {}
    cooldown_cfg = (
        nested.get("like_cooldown") if isinstance(nested.get("like_cooldown"), dict) else {}
    )
    if not cooldown_cfg.get("enabled", True):
        return None, None
    try:
        return build_like_cooldown(
            LIKE_COOLDOWN_FILE,
            minutes=int(cooldown_cfg.get("minutes", DEFAULT_LIKE_COOLDOWN_MINUTES)),
        )
    except Exception:
        return None, None


def _build_archive_remove_actions(
    cfg: dict, _storage: Storage | None
) -> tuple[PreLikeAction | None, PostLikeAction | None]:
    archive_name = resolve_archive_playlist_name(cfg)
    if not archive_name:
        return None, None
    try:
        return None, make_archive_remove_action(playlist_name=archive_name)
    except Exception:
        return None, None


def _build_promote_to_best_of_actions(
    cfg: dict, _storage: Storage | None
) -> tuple[PreLikeAction | None, PostLikeAction | None]:
    nested = cfg.get("actions") if isinstance(cfg.get("actions"), dict) else {}
    best_of_cfg = (
        nested.get("promote_to_best_of")
        if isinstance(nested.get("promote_to_best_of"), dict)
        else {}
    )
    best_of_name = (
        best_of_cfg.get("playlist_name")
        or nested.get("best_of_playlist_name")
        or cfg.get("best_of_playlist_name")  # legacy flat
        or ""
    )
    if not best_of_name or not best_of_cfg.get("enabled", True):
        return None, None
    try:
        return None, make_promote_to_best_of_action(
            playlist_name=best_of_name,
            threshold=int(best_of_cfg.get("threshold", 3)),
        )
    except Exception:
        return None, None


def _build_follow_artist_actions(
    cfg: dict, storage: Storage | None
) -> tuple[PreLikeAction | None, PostLikeAction | None]:
    # FollowArtistAction requires Storage (uses record_artist_track).
    if storage is None:
        return None, None
    nested = cfg.get("actions") if isinstance(cfg.get("actions"), dict) else {}
    follow_cfg = (
        nested.get("follow_artist") if isinstance(nested.get("follow_artist"), dict) else {}
    )
    if not follow_cfg.get("enabled", True):
        return None, None
    try:
        return None, make_follow_artist_action(
            storage=storage,
            threshold=int(follow_cfg.get("threshold", 5)),
        )
    except Exception:
        return None, None


# Extension name → builder, in the order each contributes to the chains.
# Adding an extension is one function + one entry here, not a new branch in
# `build_action_chains` itself.
_ACTION_EXTENSION_BUILDERS: list[tuple[str, _ActionChainBuilder]] = [
    ("like_cooldown", _build_like_cooldown_actions),
    ("archive_remove", _build_archive_remove_actions),
    ("promote_to_best_of", _build_promote_to_best_of_actions),
    ("follow_artist", _build_follow_artist_actions),
]


def build_action_chains(
    cfg: dict, storage: Storage | None
) -> tuple[list[PreLikeAction], list[PostLikeAction]]:
    """Compose the default-flavor pre- and post-like chains together.

    Iterates `_ACTION_EXTENSION_BUILDERS` rather than hand-checking each
    extension in a growing if-chain — every extension is independently
    togglable via `actions.<name>.enabled = false` (or by leaving its
    config key blank), and each builder gets the full `(cfg, storage)`
    context so extensions like like-cooldown that need to construct
    shared state across the pre/post split (see `_build_like_cooldown_actions`)
    still can.
    """
    pre_actions: list[PreLikeAction] = []
    post_actions: list[PostLikeAction] = []

    for _name, builder in _ACTION_EXTENSION_BUILDERS:
        pre, post = builder(cfg, storage)
        if pre is not None:
            pre_actions.append(pre)
        if post is not None:
            post_actions.append(post)

    return pre_actions, post_actions


def resolve_client_id(cfg: dict) -> str:
    return cfg.get("spotify", {}).get("client_id", "") or os.environ.get(
        "SPOTIFY_CLIENT_ID", ""
    )


def make_provider(client_id: str):
    return make_spotify_provider(client_id=client_id, token_path=SPOTIFY_TOKEN_FILE)


def make_ytmusic():
    return make_ytmusic_provider(token_path=YOUTUBE_TOKEN_FILE)


DEFAULT_PROVIDER = "spotify"


def resolve_provider_name(cfg: dict) -> str:
    music = cfg.get("music", {}) if isinstance(cfg.get("music"), dict) else {}
    return music.get("provider") or DEFAULT_PROVIDER


def _build_spotify_provider(cfg: dict):
    client_id = resolve_client_id(cfg)
    return make_provider(client_id) if client_id else None


def _build_ytmusic_provider(_cfg: dict):
    # Everything it needs lives in the token file written by --setup;
    # `has_tokens` tells the host whether that happened.
    return make_ytmusic()


# Provider name → builder. None means "not configured yet" (host shows the
# setup hint); a provider without tokens means "configured, not authorized".
PROVIDER_BUILDERS: dict[str, Callable[[dict], object | None]] = {
    "spotify": _build_spotify_provider,
    "ytmusic": _build_ytmusic_provider,
}


def build_provider(cfg: dict):
    """Return the configured MusicProvider, or None when it isn't set up.

    Selected by `cfg["music"]["provider"]` (default "spotify", so configs
    written before YouTube Music support keep working unchanged).
    """
    builder = PROVIDER_BUILDERS.get(resolve_provider_name(cfg))
    return builder(cfg) if builder else None


def resolve_remove_hotkey(cfg: dict) -> str:
    return cfg.get("trigger", {}).get("remove_hotkey", DEFAULT_REMOVE_HOTKEY)


def resolve_feedback_volume(cfg: dict) -> float:
    """Clamp `trigger.feedback_volume` to [0.0, 1.0]; bad/missing → default."""
    raw = cfg.get("trigger", {}).get("feedback_volume", DEFAULT_FEEDBACK_VOLUME)
    try:
        volume = float(raw)
    except (TypeError, ValueError):
        return DEFAULT_FEEDBACK_VOLUME
    return max(0.0, min(1.0, volume))


def run_one_shot(pipeline, feedback) -> int:
    """Drive a single pipeline pass via OneShotCliTrigger; return an exit code.

    Shared by every host's `like-once` / `remove-once` subcommand: the
    only thing that varies between them is which pipeline is built and how
    config errors are surfaced (handled by the caller). Exit code follows
    the pipeline's last feedback outcome — 0 on success, 1 on failure or
    if nothing was emitted — so the command is scriptable.
    """
    trigger = make_one_shot_cli_trigger()

    async def emit() -> None:
        await pipeline.run_once()

    async def run() -> None:
        try:
            await trigger.start(emit)
        finally:
            await trigger.stop()

    asyncio.run(run())

    if not getattr(feedback, "calls", None):
        return 1
    return 0 if feedback.calls[-1][0] else 1


def build_remove_pipeline(
    cfg: dict, provider, feedback: FeedbackFn
) -> RemoveFromPlaylistPipeline | None:
    """Build the remove-without-like pipeline, or None when not configured.

    Wired only when an archive playlist name is set — without a target
    playlist there's nothing to remove from, so the second hotkey stays
    dark rather than failing on every press. Targets the same playlist as
    the like-flow archive action (see `resolve_archive_playlist_name`).
    """
    archive_name = resolve_archive_playlist_name(cfg)
    if not archive_name:
        return None
    try:
        return RemoveFromPlaylistPipeline(
            provider=provider, feedback=feedback, playlist_name=archive_name
        )
    except ValueError:
        return None


# ── CLI ────────────────────────────────────────────────────────────────


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse the shared CLI surface.

    Subcommands:
        (none)      — run the platform's default host (tray on Windows,
                      CLI-only stub elsewhere).
        like-once   — perform a single like and exit (uses OneShotCliTrigger,
                      works on every platform).
        remove-once — remove the currently-playing track from the archive
                      playlist WITHOUT liking it, then exit.

    Flags (back-compat with the original tray launcher):
        --setup    — interactive Client ID + browser OAuth.
        --config   — print config / token paths and exit.
        --settings — open the settings window (tkinter; see hosts/settings).
    """
    p = argparse.ArgumentParser(prog="like-current-song")
    p.add_argument(
        "command",
        nargs="?",
        default="run",
        choices=["run", "like-once", "remove-once"],
        help=(
            "run (default) — start the long-lived host (tray on Windows). "
            "like-once — perform a single like and exit. "
            "remove-once — remove the current track from the archive "
            "playlist without liking it."
        ),
    )
    p.add_argument("--setup", action="store_true", help="Interactive setup wizard.")
    p.add_argument(
        "--reauth",
        action="store_true",
        help=(
            "With --setup: re-run OAuth even if valid tokens are present "
            "(use after revoking access or switching accounts)."
        ),
    )
    p.add_argument("--config", action="store_true", help="Print config / token paths.")
    p.add_argument(
        "--settings",
        action="store_true",
        help="Open the settings window (a GUI over everything --setup configures).",
    )
    # Internal: set when the tray spawns the window, so the window knows the
    # running tray will pick up the save and doesn't tell the user to restart.
    p.add_argument("--from-tray", action="store_true", help=argparse.SUPPRESS)
    return p.parse_args(argv)


def print_config_paths() -> int:
    print(f"Config:        {CONFIG_FILE}")
    print(f"Spotify token: {SPOTIFY_TOKEN_FILE}")
    print(f"Google token:  {GOOGLE_TOKEN_FILE}")
    print(f"YouTube token: {YOUTUBE_TOKEN_FILE}")
    return 0


# ── Error reporting (cross-platform fallback) ──────────────────────────


def msgbox(text: str, title: str = "Like Current Song") -> None:
    """Surface a user-visible error.

    Windows host overrides with a real MessageBoxW; here we just print so
    the stub host (mac/linux CLI) and any test environment still get the
    message on stderr.
    """
    print(f"{title}: {text}", file=sys.stderr)
