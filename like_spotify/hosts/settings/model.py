"""Settings window — toolkit-free model layer.

`config.json` → `Settings` (a flat, editable snapshot) → `validate` →
`apply_settings` back into the *existing* schema. No tkinter here: the
window (`window.py`) is a thin view over these functions, and pytest drives
the round-trips directly.

Rules that keep a save from surprising anyone:

- **Unknown keys survive.** `apply_settings` deep-copies the loaded dict and
  only touches the keys this module owns.
- **Unchanged fields are not rewritten.** A save writes a field only when it
  differs from what was loaded, so opening the window and pressing Save on
  an existing config leaves `config.json` semantically unchanged, including
  env-var fallbacks and legacy keys the window doesn't show.
- **A fresh config gets its extra actions written as explicitly off.** The
  host treats a missing `actions.like_cooldown` / `actions.follow_artist`
  block as *on* (back-compat for configs written before those extensions
  existed), so "off by default" in the window has to be written down.
"""

from __future__ import annotations

import copy
import json
import os
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from like_spotify.extensions.follow_artist import (
    DEFAULT_THRESHOLD as DEFAULT_FOLLOW_THRESHOLD,
)
from like_spotify.extensions.like_cooldown import DEFAULT_MINUTES as DEFAULT_COOLDOWN_MINUTES
from like_spotify.extensions.promote_to_best_of import (
    DEFAULT_THRESHOLD as DEFAULT_BEST_OF_THRESHOLD,
)
from like_spotify.extensions.tray_hotkey_trigger import DEFAULT_HOTKEY

from .. import _common

PROVIDER_LABELS: dict[str, str] = {
    "spotify": "Spotify",
    "ytmusic": "YouTube Music (beta, Windows)",
}
STORAGE_BACKENDS: tuple[str, ...] = ("none", "supabase", "sheets")

# One-line hints shown under each extra action in the window. Kept here so
# the copy lives next to the defaults it describes.
ACTION_HINTS: dict[str, str] = {
    "archive_remove": (
        "Liking a track removes it from this playlist (e.g. a saved copy of "
        "Discover Weekly). Also turns on the remove-without-like hotkey."
    ),
    "promote_to_best_of": (
        "Adds a track to this playlist once you've liked it N times "
        "(needs counter storage)."
    ),
    "follow_artist": (
        "Follows an artist once you've liked N different tracks by them "
        "(needs counter storage)."
    ),
    "like_cooldown": (
        "Ignores a repeat like of the same track within N minutes, so a "
        "double press doesn't count twice."
    ),
}


@dataclass(frozen=True)
class Settings:
    """Everything the window edits, flattened. Field names mirror config keys."""

    provider: str = _common.DEFAULT_PROVIDER
    spotify_client_id: str = ""

    storage_backend: str = "none"
    supabase_url: str = ""
    supabase_anon_key: str = ""
    sheets_spreadsheet_id: str = ""

    hotkey: str = DEFAULT_HOTKEY
    remove_hotkey: str = _common.DEFAULT_REMOVE_HOTKEY
    feedback_volume: float = _common.DEFAULT_FEEDBACK_VOLUME

    archive_enabled: bool = False
    archive_playlist: str = ""
    best_of_enabled: bool = False
    best_of_playlist: str = ""
    best_of_threshold: int = DEFAULT_BEST_OF_THRESHOLD
    follow_enabled: bool = False
    follow_threshold: int = DEFAULT_FOLLOW_THRESHOLD
    cooldown_enabled: bool = False
    cooldown_minutes: int = DEFAULT_COOLDOWN_MINUTES


# Field groups that are written together (a change to one rewrites the group).
_ACTION_GROUPS: dict[str, tuple[str, ...]] = {
    "archive_remove": ("archive_enabled", "archive_playlist"),
    "promote_to_best_of": ("best_of_enabled", "best_of_playlist", "best_of_threshold"),
    "follow_artist": ("follow_enabled", "follow_threshold"),
    "like_cooldown": ("cooldown_enabled", "cooldown_minutes"),
}


# ── Reading ────────────────────────────────────────────────────────────


def _section(cfg: dict, key: str) -> dict:
    value = cfg.get(key)
    return value if isinstance(value, dict) else {}


def _as_int(raw, default: int) -> int:
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def _infer_storage_backend(cfg: dict) -> str:
    """The backend the window shows. Mirrors `_common.build_storage` minus
    the env-var fallback (the window only edits what's in the file)."""
    backend = _section(cfg, "storage").get("backend", "")
    if backend in STORAGE_BACKENDS:
        return backend
    sb = _section(cfg, "supabase")
    if not backend and sb.get("url") and sb.get("anon_key"):
        return "supabase"
    return "none"


def is_fresh(cfg: dict) -> bool:
    """A config nobody has written yet (missing, empty, or unreadable file)."""
    return not cfg


def settings_from_config(cfg: dict) -> Settings:
    """What the host would *effectively* do with `cfg`, as editable fields.

    For an existing config the extra actions reflect runtime behavior (a
    missing `like_cooldown` block means the cooldown is on). For a fresh
    config they are all off — see the module docstring.
    """
    trigger = _section(cfg, "trigger")
    actions = _section(cfg, "actions")
    archive = _section(actions, "archive_remove")
    best_of = _section(actions, "promote_to_best_of")
    follow = _section(actions, "follow_artist")
    cooldown = _section(actions, "like_cooldown")

    archive_name = (
        archive.get("playlist_name")
        or actions.get("archive_playlist_name")
        or cfg.get("archive_playlist_name")
        or ""
    )
    best_of_name = (
        best_of.get("playlist_name")
        or actions.get("best_of_playlist_name")
        or cfg.get("best_of_playlist_name")
        or ""
    )
    fresh = is_fresh(cfg)

    return Settings(
        provider=_common.resolve_provider_name(cfg),
        spotify_client_id=_section(cfg, "spotify").get("client_id", "") or "",
        storage_backend=_infer_storage_backend(cfg),
        supabase_url=_section(cfg, "supabase").get("url", "") or "",
        supabase_anon_key=_section(cfg, "supabase").get("anon_key", "") or "",
        sheets_spreadsheet_id=_section(cfg, "sheets").get("spreadsheet_id", "") or "",
        hotkey=trigger.get("hotkey") or DEFAULT_HOTKEY,
        remove_hotkey=trigger.get("remove_hotkey") or _common.DEFAULT_REMOVE_HOTKEY,
        feedback_volume=_common.resolve_feedback_volume({"trigger": trigger}),
        archive_enabled=(
            not fresh and bool(archive_name) and bool(archive.get("enabled", True))
        ),
        archive_playlist=archive_name,
        best_of_enabled=(
            not fresh and bool(best_of_name) and bool(best_of.get("enabled", True))
        ),
        best_of_playlist=best_of_name,
        best_of_threshold=_as_int(best_of.get("threshold"), DEFAULT_BEST_OF_THRESHOLD),
        follow_enabled=not fresh and bool(follow.get("enabled", True)),
        follow_threshold=_as_int(follow.get("threshold"), DEFAULT_FOLLOW_THRESHOLD),
        cooldown_enabled=not fresh and bool(cooldown.get("enabled", True)),
        cooldown_minutes=_as_int(cooldown.get("minutes"), DEFAULT_COOLDOWN_MINUTES),
    )


# ── Validation ─────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Issue:
    field: str
    message: str


@dataclass(frozen=True)
class Validation:
    errors: tuple[Issue, ...] = ()
    warnings: tuple[Issue, ...] = ()

    @property
    def ok(self) -> bool:
        return not self.errors


def hotkey_problem(combo: str) -> str | None:
    """Syntactic check for a `keyboard`-style combo like `ctrl+shift+alt+w`.

    Deliberately shallow (the `keyboard` library is the real parser, and the
    window runs it too when available); this catches the typos that would
    otherwise only surface as a failed hotkey registration in the tray.
    """
    text = combo.strip()
    if not text:
        return "is empty"
    if any(not part.strip() for part in text.split("+")):
        return f"'{text}' has an empty key between '+' signs"
    return None


def validate(s: Settings) -> Validation:
    errors: list[Issue] = []
    warnings: list[Issue] = []

    def err(field: str, msg: str) -> None:
        errors.append(Issue(field, msg))

    if s.provider not in _common.PROVIDER_BUILDERS:
        err("provider", f"Unknown music service '{s.provider}'.")
    if s.provider == "spotify" and not s.spotify_client_id.strip():
        err(
            "spotify_client_id",
            "Spotify needs a Client ID from developer.spotify.com/dashboard.",
        )

    if s.storage_backend not in STORAGE_BACKENDS:
        err("storage_backend", f"Unknown storage backend '{s.storage_backend}'.")
    elif s.storage_backend == "supabase":
        url = s.supabase_url.strip()
        if not url or not s.supabase_anon_key.strip():
            err("supabase_url", "Supabase needs both the project URL and the anon key.")
        elif not url.startswith(("https://", "http://")):
            err("supabase_url", "Supabase URL should look like https://<ref>.supabase.co.")
    elif s.storage_backend == "sheets" and not s.sheets_spreadsheet_id.strip():
        err("sheets_spreadsheet_id", "Google Sheets needs the spreadsheet ID.")

    problem = hotkey_problem(s.hotkey)
    if problem:
        err("hotkey", f"Like hotkey {problem}.")
    if s.archive_enabled:
        problem = hotkey_problem(s.remove_hotkey)
        if problem:
            err("remove_hotkey", f"Remove hotkey {problem}.")
        elif _norm_hotkey(s.remove_hotkey) == _norm_hotkey(s.hotkey):
            err("remove_hotkey", "The remove hotkey must differ from the like hotkey.")

    if not 0.0 <= s.feedback_volume <= 1.0:
        err("feedback_volume", "Feedback volume must be between 0 and 100%.")

    if s.archive_enabled and not s.archive_playlist.strip():
        err("archive_playlist", "Archive clean-up needs a playlist name.")
    if s.best_of_enabled:
        if not s.best_of_playlist.strip():
            err("best_of_playlist", "Best-of needs a playlist name.")
        if s.best_of_threshold < 1:
            err("best_of_threshold", "Best-of threshold must be at least 1.")
    if s.follow_enabled and s.follow_threshold < 1:
        err("follow_threshold", "Follow-artist threshold must be at least 1.")
    if s.cooldown_enabled and s.cooldown_minutes < 1:
        err("cooldown_minutes", "Cooldown must be at least 1 minute.")

    if s.storage_backend == "none":
        if s.best_of_enabled:
            warnings.append(
                Issue("best_of_enabled", "Best-of stays inactive until counter storage is set.")
            )
        if s.follow_enabled:
            warnings.append(
                Issue(
                    "follow_enabled",
                    "Follow artist stays inactive until counter storage is set.",
                )
            )

    return Validation(tuple(errors), tuple(warnings))


def _norm_hotkey(combo: str) -> str:
    return "+".join(part.strip().lower() for part in combo.split("+"))


# ── Writing ────────────────────────────────────────────────────────────


def _ensure(cfg: dict, key: str) -> dict:
    value = cfg.get(key)
    if not isinstance(value, dict):
        value = {}
        cfg[key] = value
    return value


def _changed(s: Settings, baseline: Settings | None, *names: str) -> bool:
    if baseline is None:
        return True
    return any(getattr(s, n) != getattr(baseline, n) for n in names)


def apply_settings(cfg: dict, s: Settings, baseline: Settings | None = None) -> dict:
    """Return a copy of `cfg` with `s` written into the existing schema.

    `baseline` is what `settings_from_config(cfg)` returned when the window
    opened; only fields that differ from it are written. `None` (or a fresh
    config) writes every field.
    """
    out = copy.deepcopy(cfg)
    if is_fresh(cfg):
        baseline = None

    if _changed(s, baseline, "provider"):
        _ensure(out, "music")["provider"] = s.provider
    if _changed(s, baseline, "spotify_client_id") and (
        s.spotify_client_id or "client_id" in _section(out, "spotify")
    ):
        _ensure(out, "spotify")["client_id"] = s.spotify_client_id.strip()

    if _changed(s, baseline, "storage_backend"):
        _ensure(out, "storage")["backend"] = s.storage_backend
    if _changed(s, baseline, "supabase_url", "supabase_anon_key") and (
        s.supabase_url or s.supabase_anon_key or "supabase" in out
    ):
        sb = _ensure(out, "supabase")
        sb["url"] = s.supabase_url.strip()
        sb["anon_key"] = s.supabase_anon_key.strip()
    if _changed(s, baseline, "sheets_spreadsheet_id") and (
        s.sheets_spreadsheet_id or "sheets" in out
    ):
        _ensure(out, "sheets")["spreadsheet_id"] = s.sheets_spreadsheet_id.strip()

    if _changed(s, baseline, "hotkey"):
        _ensure(out, "trigger")["hotkey"] = s.hotkey.strip()
    if _changed(s, baseline, "remove_hotkey"):
        _ensure(out, "trigger")["remove_hotkey"] = s.remove_hotkey.strip()
    if _changed(s, baseline, "feedback_volume"):
        _ensure(out, "trigger")["feedback_volume"] = round(s.feedback_volume, 2)

    for name, group in _ACTION_GROUPS.items():
        if not _changed(s, baseline, *group):
            continue
        block = _ensure(_ensure(out, "actions"), name)
        _write_action(name, block, s)

    return out


def _write_action(name: str, block: dict, s: Settings) -> None:
    if name == "archive_remove":
        block["enabled"] = s.archive_enabled
        if s.archive_playlist.strip():
            block["playlist_name"] = s.archive_playlist.strip()
    elif name == "promote_to_best_of":
        block["enabled"] = s.best_of_enabled
        if s.best_of_playlist.strip():
            block["playlist_name"] = s.best_of_playlist.strip()
        block["threshold"] = s.best_of_threshold
    elif name == "follow_artist":
        block["enabled"] = s.follow_enabled
        block["threshold"] = s.follow_threshold
    elif name == "like_cooldown":
        block["enabled"] = s.cooldown_enabled
        block["minutes"] = s.cooldown_minutes


# ── File I/O ───────────────────────────────────────────────────────────


class ConfigDocument:
    """One editing session over `config.json`: load, remember, save.

    Unlike `_common.load_config`, an unreadable file is *reported*
    (`load_error`) instead of silently treated as empty, and `save` backs
    it up before replacing it — the window must never quietly destroy a
    hand-edited config with a typo in it.
    """

    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path is not None else _common.CONFIG_FILE
        self.load_error: str | None = None
        self.cfg: dict = {}
        self._raw: str | None = None
        self.reload()

    def reload(self) -> None:
        self.load_error = None
        self._raw = None
        self.cfg = {}
        try:
            self._raw = self.path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return
        except OSError as e:
            self.load_error = f"could not read {self.path}: {e}"
            return
        try:
            data = json.loads(self._raw) if self._raw.strip() else {}
        except json.JSONDecodeError as e:
            self.load_error = f"{self.path.name} is not valid JSON ({e})"
            return
        if not isinstance(data, dict):
            self.load_error = f"{self.path.name} does not contain a JSON object"
            return
        self.cfg = data

    @property
    def fresh(self) -> bool:
        return is_fresh(self.cfg)

    def initial_settings(self) -> Settings:
        return settings_from_config(self.cfg)

    def save(self, s: Settings) -> Path | None:
        """Write `s` to disk atomically. Returns the backup path, if one was made.

        Re-reads the file first and applies only the fields the user changed
        (relative to what was loaded when the window opened), so an edit made
        elsewhere while the window was open, to a key the user didn't touch
        here, is kept rather than overwritten with a stale copy.
        """
        baseline = None if self.fresh else settings_from_config(self.cfg)
        target = self.cfg
        backup: Path | None = None
        if self.load_error:
            if self._raw is not None:
                backup = self.path.with_name(
                    f"{self.path.name}.broken-{time.strftime('%Y%m%d-%H%M%S')}"
                )
                backup.write_text(self._raw, encoding="utf-8")
        else:
            on_disk = _read_json_object(self.path)
            if on_disk is not None:
                target = on_disk
        _atomic_write_json(self.path, apply_settings(target, s, baseline))
        self.reload()
        return backup


def _read_json_object(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


__all__ = [
    "ACTION_HINTS",
    "ConfigDocument",
    "Issue",
    "PROVIDER_LABELS",
    "STORAGE_BACKENDS",
    "Settings",
    "Validation",
    "apply_settings",
    "hotkey_problem",
    "is_fresh",
    "settings_from_config",
    "validate",
]
