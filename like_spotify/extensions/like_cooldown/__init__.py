"""LikeCooldownGate / LikeCooldownRecorder — default flavor cooldown dedup.

Guards against accidentally counting the same track as liked twice (e.g.
two hotkey presses seconds apart) by skipping the like when the track was
already liked within a configurable cooldown window (default 10 minutes).
Mirrors the mobile app's `SharedPrefsLikeCountRepository` cooldown design
(`getLastLikedAt` / `recordLikedAt`): local-only, no Storage/network
round-trip — cross-device dedup was deliberately descoped as
overengineering, so this reads/writes a small JSON file under the config
dir instead.

Two cooperating actions sharing one `_CooldownStore`, split the same way
the mobile repository splits the check from the record:
    - `LikeCooldownGate` (PreLikeAction) — runs before the real like; a
      track liked within the window returns `False`, aborting the like
      with "Skipped by LikeCooldownGate" feedback (see
      `Pipeline.run_once`).
    - `LikeCooldownRecorder` (PostLikeAction) — runs after
      `MusicProvider.like` succeeds, stamping the current time. Recording
      only on confirmed success (not from the gate) means a failed like
      never starts the cooldown, so a genuine retry isn't blocked.
      Its `undo` (#270) puts back the stamp the press replaced, so an
      undone like does not hold the track in its cooldown.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

from like_spotify.core.actions import PostLikeAction, PreLikeAction
from like_spotify.core.types import LikeContext

DOMAIN = "like_cooldown"
DEFAULT_MINUTES = 10

# Per-press undo state in `ctx.extras`: (track_id, stamp it replaced or None).
_PREVIOUS = "like_cooldown.previous"

logger = logging.getLogger(__name__)


class _CooldownStore:
    """Local JSON map of `track_id -> last_liked_at (unix seconds)`."""

    def __init__(self, path: Path) -> None:
        self._path = path

    def last_liked_at(self, track_id: str) -> float | None:
        return self._load().get(track_id)

    def record(self, track_id: str, at: float) -> None:
        state = self._load()
        state[track_id] = at
        self._save(state)

    def restore(self, track_id: str, at: float | None) -> None:
        """Set the track's stamp back to `at`; `None` drops it."""
        state = self._load()
        if at is None:
            state.pop(track_id, None)
        else:
            state[track_id] = at
        self._save(state)

    def _load(self) -> dict[str, float]:
        try:
            return json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    def _save(self, state: dict[str, float]) -> None:
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            self._path.write_text(json.dumps(state), encoding="utf-8")
        except OSError:
            logger.warning("like-cooldown: failed to persist state to %s", self._path)


class LikeCooldownGate(PreLikeAction):
    def __init__(self, store: _CooldownStore, minutes: int = DEFAULT_MINUTES) -> None:
        if minutes < 1:
            raise ValueError("minutes must be >= 1")
        self._store = store
        self._window_seconds = minutes * 60

    async def run(self, ctx: LikeContext) -> bool:
        last = self._store.last_liked_at(ctx.track.provider_track_id)
        if last is not None and (time.time() - last) < self._window_seconds:
            return False
        return True


class LikeCooldownRecorder(PostLikeAction):
    def __init__(self, store: _CooldownStore) -> None:
        self._store = store

    async def run(self, ctx: LikeContext) -> None:
        track_id = ctx.track.provider_track_id
        ctx.extras[_PREVIOUS] = (track_id, self._store.last_liked_at(track_id))
        self._store.record(track_id, time.time())

    async def undo(self, ctx: LikeContext) -> None:
        previous = ctx.extras.get(_PREVIOUS)
        if previous is not None:
            self._store.restore(*previous)


def build_like_cooldown(
    state_path: Path, minutes: int = DEFAULT_MINUTES
) -> tuple[LikeCooldownGate, LikeCooldownRecorder]:
    """Factory called by the host. Returns the (pre, post) action pair —
    both must be wired into the same `Pipeline` to share cooldown state."""
    store = _CooldownStore(state_path)
    return LikeCooldownGate(store, minutes=minutes), LikeCooldownRecorder(store)
