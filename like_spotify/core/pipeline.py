import logging
from collections.abc import Sequence
from typing import Protocol

from .actions import PostLikeAction, PreLikeAction
from .errors import UserActionRequired
from .music_provider import MusicProvider, PlaylistCapableProvider
from .storage import Storage
from .types import CurrentTrack, LikeContext


class FeedbackFn(Protocol):
    """(success, title, message) plus an optional keyword `kind` that hosts
    use to pick a distinct confirmation sound — "like" (default), "remove",
    or whatever a future flow needs. Callers that don't care omit `kind`;
    feedback impls default it to "like", so the 3-arg call stays valid
    everywhere. A Protocol (not `Callable[..., None]`) so mypy/pyright still
    catch mismatched argument types at the call site."""

    def __call__(
        self, success: bool, title: str, message: str, *, kind: str = "like"
    ) -> None: ...

logger = logging.getLogger(__name__)


class Pipeline:
    """Composes a MusicProvider + optional Storage + action chains.

    Order of operations in `run_once`:
        1. get_currently_playing
        2. PreLikeAction chain — any action returning False aborts the like
        3. is_liked probe (only when Storage is wired — feeds the backfill flag)
        4. MusicProvider.like
        5. Storage.increment (soft-fail, always logged; new count shown in
           the feedback title, and a `UserActionRequired` failure says so)
        6. PostLikeAction chain — each action runs independently, failures
           are logged and the chain continues

    Slice history:
        #21 — tracer-bullet (1, 4, feedback)
        #22 — Storage wiring (5)
        #23 — Pre/PostLikeAction chains (2, 6)
        #24 — backfill probe (3): first encounter of an already-liked track
              counts as 2; the flag is gated on Storage presence so we don't
              spend an extra Spotify call when no counter is configured.
    """

    def __init__(
        self,
        provider: MusicProvider,
        feedback: FeedbackFn,
        storage: Storage | None = None,
        pre_like_actions: Sequence[PreLikeAction] = (),
        post_like_actions: Sequence[PostLikeAction] = (),
    ) -> None:
        self._provider = provider
        self._feedback = feedback
        self._storage = storage
        self._pre_actions = tuple(pre_like_actions)
        self._post_actions = tuple(post_like_actions)

    async def run_once(self) -> None:
        try:
            track = await self._provider.get_currently_playing()
        except Exception as e:
            self._feedback(False, "Error", f"Could not read playback: {e}")
            return

        if track is None:
            self._feedback(False, "Nothing playing", "")
            return

        ctx = LikeContext(track=track, music_provider=self._provider)

        # ── Pre-like chain ────────────────────────────────────────────────
        for action in self._pre_actions:
            try:
                proceed = await action.run(ctx)
            except Exception:
                # An action's internal failure does NOT abort the like —
                # the contract is "actions are independent". Log + continue.
                logger.warning(
                    "PreLikeAction %s raised", type(action).__name__, exc_info=True
                )
                continue
            if not proceed:
                self._feedback(
                    False,
                    f"Skipped by {type(action).__name__}",
                    _display(ctx.track),
                )
                return

        # ── Backfill probe (#24): only when Storage is wired. ─────────────
        # Soft fail to False — better to miss a +1 backfill than double-count.
        was_already_liked = False
        if self._storage is not None:
            try:
                was_already_liked = await self._provider.is_liked(ctx.track)
            except Exception:
                was_already_liked = False

        # ── Like ──────────────────────────────────────────────────────────
        try:
            await self._provider.like(ctx.track)
        except Exception as e:
            self._feedback(False, "Like failed", str(e))
            return

        # ── Storage (#22, soft fail) ──────────────────────────────────────
        # The like has already happened, so the count degrades to None
        # whatever went wrong — a counter must never cost the user a like.
        # What the failure is worth differs, though (#168): a timeout or a
        # 5xx clears itself and only earns a log line, while a
        # `UserActionRequired` will repeat on every press until the user
        # does the thing its message names, so it also goes to the feedback.
        storage_problem: str | None = None
        if self._storage is not None:
            try:
                user_id = await self._provider.user_id()
                ctx.like_count = await self._storage.increment(
                    user_id, ctx.track, was_already_liked
                )
            except Exception as e:
                ctx.like_count = None
                logger.warning(
                    "Storage %s could not count the like",
                    type(self._storage).__name__,
                    exc_info=True,
                )
                if isinstance(e, UserActionRequired):
                    storage_problem = str(e)

        # ── Post-like chain (independent, log + continue on failure) ──────
        for action in self._post_actions:
            try:
                await action.run(ctx)
            except Exception:
                logger.warning(
                    "PostLikeAction %s raised", type(action).__name__, exc_info=True
                )

        title = "Liked" if ctx.like_count is None else f"Liked × {ctx.like_count}"
        message = _display(ctx.track)
        if storage_problem is not None:
            title = "Liked — counter not updated"
            # The reason travels in the message as well as the title because
            # the tray balloon renders the message and drops the title.
            message = f"{message}\n{storage_problem}"
        self._feedback(True, title, message)


class RemoveFromPlaylistPipeline:
    """Remove the currently-playing track from a named playlist — no like.

    Powers the "I don't want this in my Discover Weekly archive" hotkey.
    The like flow's `ArchiveRemoveAction` only fires *after* a like, so it
    can't help with tracks the user dislikes; this is the second intent —
    a separate Trigger wired here lets the user curate a playlist without
    liking the track.

    Provider-agnostic via `PlaylistCapableProvider`: it needs
    `get_currently_playing` (on the `MusicProvider` base) plus
    `find_playlist_by_name` / `remove_track_from_playlist` (the optional
    playlist capability). A provider lacking it gets a clean error
    feedback rather than an exception — keeping `core` free of any
    extension import.

    The resolved playlist id is cached after the first successful lookup.
    A miss (playlist not found, or a lookup error) is *not* cached, and a
    cached id is dropped again if the remove call later fails (the playlist
    may have been deleted/renamed) — so a later press re-resolves. Useful in
    a long-lived tray when the user creates the playlist after launch.

    Slice: #43 (remove-without-like hotkey).
    """

    def __init__(
        self,
        provider: MusicProvider,
        feedback: FeedbackFn,
        playlist_name: str,
    ) -> None:
        normalized = (playlist_name or "").strip()
        if not normalized:
            raise ValueError("remove playlist_name is required (non-empty)")
        self._provider = provider
        self._feedback = feedback
        self._playlist_name = normalized
        self._playlist_id: str | None = None

    async def run_once(self) -> None:
        try:
            track = await self._provider.get_currently_playing()
        except Exception as e:
            self._feedback(
                False, "Error", f"Could not read playback: {e}", kind="remove"
            )
            return

        if track is None:
            self._feedback(False, "Nothing playing", "", kind="remove")
            return

        if not isinstance(self._provider, PlaylistCapableProvider):
            self._feedback(
                False,
                "Remove unsupported",
                "provider has no playlist API",
                kind="remove",
            )
            return

        if self._playlist_id is None:
            try:
                self._playlist_id = await self._provider.find_playlist_by_name(
                    self._playlist_name
                )
            except Exception as e:
                # Not cached — next press retries.
                self._feedback(
                    False, "Playlist lookup failed", str(e), kind="remove"
                )
                return
            if not self._playlist_id:
                self._feedback(
                    False, "Playlist not found", self._playlist_name, kind="remove"
                )
                return

        try:
            await self._provider.remove_track_from_playlist(
                track.provider_track_id, self._playlist_id
            )
        except Exception as e:
            # The cached id may be stale (playlist deleted/renamed since the
            # last resolve) — drop it so the next press re-resolves instead
            # of failing forever against a dead id.
            self._playlist_id = None
            self._feedback(False, "Remove failed", str(e), kind="remove")
            return

        self._feedback(
            True,
            f"Removed from {self._playlist_name}",
            _display(track),
            kind="remove",
        )


def _display(track: CurrentTrack) -> str:
    artists = ", ".join(track.artists) if track.artists else ""
    return f"{track.title} — {artists}" if artists else track.title
