import logging
from collections.abc import Sequence
from typing import Protocol

from .actions import PostLikeAction, PreLikeAction
from .errors import UserActionRequired
from .music_provider import (
    DislikeCapableProvider,
    MusicProvider,
    PlaylistCapableProvider,
)
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


class DiscardPipeline:
    """"I don't want this one" — no like. Two independent legs, one press.

    Powers the second desktop hotkey (`trigger.remove_hotkey`, default
    Ctrl+Shift+Alt+Q). The like flow's `ArchiveRemoveAction` only fires
    *after* a like, so it can't help with a track the user is rejecting;
    this is the opposite intent, and it says so in the two ways a service
    understands:

        1. **Playlist leg** — take the track out of the archive playlist
           (`playlist_name`), for the "keep my Discover Weekly archive
           clean" job this class shipped with in #43. Needs
           `PlaylistCapableProvider`.
        2. **Dislike leg** — tell the service itself (#172). Needs
           `DislikeCapableProvider`, whose docstring covers how far that
           reaches per service: a real thumbs-down on YouTube Music, a
           library removal on Spotify, whose Web API has no dislike.

    Both legs run on every press, and **neither can cost the user the
    other**: each soft-fails on its own and the feedback reports what
    actually happened, so a deleted archive playlist doesn't silently
    swallow the dislike. A leg whose capability the provider lacks is not
    attempted at all rather than counted as a failure — that is how a
    dislike-only user (no archive configured) and a playlist-only provider
    both get a useful press. When *neither* leg applies there is nothing
    honest to do, and the press says so instead of raising, keeping `core`
    free of any extension import.

    `playlist_name` may be blank: that is the dislike-only wiring, not an
    error. Hosts decide whether a press is worth offering at all — see
    `build_discard_pipeline` in `hosts/_common.py`.

    The resolved playlist id is cached after the first successful lookup.
    A miss (playlist not found, or a lookup error) is *not* cached, and a
    cached id is dropped again if the remove call later fails (the playlist
    may have been deleted/renamed) — so a later press re-resolves. Useful in
    a long-lived tray when the user creates the playlist after launch.

    Slices: #43 (remove-without-like hotkey), #172 (dislike leg).
    """

    def __init__(
        self,
        provider: MusicProvider,
        feedback: FeedbackFn,
        playlist_name: str = "",
    ) -> None:
        self._provider = provider
        self._feedback = feedback
        self._playlist_name = (playlist_name or "").strip()
        self._playlist_id: str | None = None

    @property
    def label(self) -> str:
        """Imperative one-liner for what a press will attempt.

        Lives here rather than in the tray so the menu item, the CLI help
        and the feedback all describe the same press from one place.
        """
        if self._can_remove() and self._can_dislike():
            return f"Dislike and remove from {self._playlist_name}"
        if self._can_remove():
            return f"Remove from {self._playlist_name}"
        if self._can_dislike():
            return "Dislike current track"
        # Neither leg is available. The host still wires the press when
        # *something* was asked for (an archive playlist, say) but the
        # provider cannot honour it, so stay generic rather than promise
        # a leg that would only report "unsupported" on press.
        return "Discard current track"

    def _can_remove(self) -> bool:
        return bool(self._playlist_name) and isinstance(
            self._provider, PlaylistCapableProvider
        )

    def _can_dislike(self) -> bool:
        return isinstance(self._provider, DislikeCapableProvider)

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

        if not self._can_remove() and not self._can_dislike():
            self._feedback(
                False,
                "Discard unsupported",
                "this provider can neither remove from a playlist nor dislike",
                kind="remove",
            )
            return

        done: list[str] = []
        failed: list[str] = []
        reasons: list[str] = []

        # Dislike first: it is the leg the user pressed *for*, and the one
        # a stale playlist id must not be able to starve.
        if self._can_dislike():
            reason = await self._dislike(track)
            if reason is None:
                done.append("disliked")
            else:
                failed.append("not disliked")
                reasons.append(reason)

        if self._can_remove():
            reason = await self._remove(track)
            if reason is None:
                done.append(f"removed from {self._playlist_name}")
            else:
                failed.append(f"not removed from {self._playlist_name}")
                reasons.append(reason)

        if done and not failed:
            title = _capitalize(_and(done))
        elif done:
            title = f"{_capitalize(_and(done))} — {_and(failed)}"
        else:
            title = "Nothing changed"

        self._feedback(
            not failed, title, "\n".join([_display(track), *reasons]), kind="remove"
        )

    async def _dislike(self, track: CurrentTrack) -> str | None:
        """Run the dislike leg. None on success, else the reason to show."""
        try:
            await self._provider.dislike(track)
        except Exception as e:
            logger.warning("dislike failed", exc_info=True)
            return f"Dislike failed: {e}"
        return None

    async def _remove(self, track: CurrentTrack) -> str | None:
        """Run the playlist leg. None on success, else the reason to show."""
        if self._playlist_id is None:
            try:
                self._playlist_id = await self._provider.find_playlist_by_name(
                    self._playlist_name
                )
            except Exception as e:
                # Not cached — next press retries.
                logger.warning("playlist lookup failed", exc_info=True)
                return f"Playlist lookup failed: {e}"
            if not self._playlist_id:
                return f"Playlist not found: {self._playlist_name}"

        try:
            await self._provider.remove_track_from_playlist(
                track.provider_track_id, self._playlist_id
            )
        except Exception as e:
            # The cached id may be stale (playlist deleted/renamed since the
            # last resolve) — drop it so the next press re-resolves instead
            # of failing forever against a dead id.
            self._playlist_id = None
            logger.warning("playlist remove failed", exc_info=True)
            return f"Remove failed: {e}"
        return None


def _and(parts: list[str]) -> str:
    return " and ".join(parts)


def _capitalize(text: str) -> str:
    return text[:1].upper() + text[1:]


def _display(track: CurrentTrack) -> str:
    artists = ", ".join(track.artists) if track.artists else ""
    return f"{track.title} — {artists}" if artists else track.title
