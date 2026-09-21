import logging
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol

from .actions import PostLikeAction, PreLikeAction
from .errors import UserActionRequired
from .music_provider import MusicProvider, PlaylistCapableProvider
from .storage import Storage
from .types import CurrentTrack, LikeContext

NATIVE = "native"
PLAYLIST = "playlist"
BOTH = "both"
LIKE_DESTINATIONS: tuple[str, ...] = (NATIVE, PLAYLIST, BOTH)


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


@dataclass(frozen=True)
class LikeDestination:
    """Where a like lands (#173).

    `native` is the service's own like — what every install did before
    this setting existed, and what feeds the service's recommendations.
    `playlist` puts the track in a playlist you own instead: on YouTube
    Music the native like drops the song into one bucket shared with
    liked *videos*, so a playlist is the only way to keep a song-only
    list. `both` does the two, because those are not alternatives — one
    trains the service, the other is the clean list you actually browse.

    Anything but `native` needs a playlist name, and a provider that
    speaks `PlaylistCapableProvider`. Both are checked here and again by
    the hosts, which refuse at config-resolution time with a message
    naming the configured service (`resolve_like_destination` in
    `hosts/_common.py`) rather than letting a press fail.
    """

    mode: str = NATIVE
    playlist_name: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "playlist_name", (self.playlist_name or "").strip())
        if self.mode not in LIKE_DESTINATIONS:
            raise ValueError(
                f"unknown like destination {self.mode!r} "
                f"(expected one of {', '.join(LIKE_DESTINATIONS)})"
            )
        if self.mode != NATIVE and not self.playlist_name:
            raise ValueError(f"like destination {self.mode!r} needs a playlist_name")

    @property
    def wants_native(self) -> bool:
        return self.mode in (NATIVE, BOTH)

    @property
    def wants_playlist(self) -> bool:
        return self.mode in (PLAYLIST, BOTH)


@dataclass(frozen=True)
class _LegFailure:
    """One failed half of a like: what to blame in the title, and why."""

    title_suffix: str
    detail: str
    reason: str  # the bare provider error, for the single-leg message


class Pipeline:
    """Composes a MusicProvider + optional Storage + action chains.

    Order of operations in `run_once`:
        1. get_currently_playing
        2. PreLikeAction chain — any action returning False aborts the like
        3. already-there probe (only when Storage is wired — feeds the
           backfill flag)
        4. the like itself, at the configured LikeDestination
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
        #173 — `like_destination`: the like can land in a playlist instead
              of (or as well as) the service's own like. Omit the argument
              and every step behaves exactly as it did before.
    """

    def __init__(
        self,
        provider: MusicProvider,
        feedback: FeedbackFn,
        storage: Storage | None = None,
        pre_like_actions: Sequence[PreLikeAction] = (),
        post_like_actions: Sequence[PostLikeAction] = (),
        like_destination: LikeDestination | None = None,
    ) -> None:
        destination = like_destination or LikeDestination()
        if destination.wants_playlist and not isinstance(
            provider, PlaylistCapableProvider
        ):
            # Fail at wiring time, not on the press: a destination the
            # provider cannot serve is a configuration mistake, and a
            # hotkey that silently does nothing is the worst way to learn
            # about it. Hosts catch this earlier with a friendlier message.
            raise ValueError(
                f"{type(provider).__name__} has no playlist API, so the like "
                f"destination {destination.mode!r} cannot be used"
            )
        self._provider = provider
        self._feedback = feedback
        self._storage = storage
        self._pre_actions = tuple(pre_like_actions)
        self._post_actions = tuple(post_like_actions)
        self._destination = destination
        self._playlist_id: str | None = None  # cached after the first resolve

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
                was_already_liked = await self._already_there(ctx.track)
            except Exception:
                was_already_liked = False

        # ── Like (#173: one leg per configured destination) ───────────────
        liked, failures = await self._run_like_legs(ctx.track)
        if not liked:
            # Every leg failed. With a single leg the message is the raw
            # provider error, exactly as it has always been; only a `both`
            # config has anything to disambiguate.
            message = (
                failures[0].reason
                if len(failures) == 1
                else "; ".join(f.detail for f in failures)
            )
            self._feedback(False, "Like failed", message)
            return
        # A partial failure still counts as a like — the user's press did
        # land somewhere — but the feedback has to name the half that didn't.
        like_problem = failures[0] if failures else None

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
        if like_problem is not None:
            title = f"{title} — {like_problem.title_suffix}"
            message = f"{message}\n{like_problem.detail}"
        self._feedback(True, title, message)

    async def _already_there(self, track: CurrentTrack) -> bool:
        """Has this track been liked before, in the sense the user configured?

        Under `playlist` the service's own like is not what a press does,
        so asking `is_liked` would answer about a bucket nothing writes
        to — "already liked" means "already in the destination playlist".
        `both` still writes the native like, so `is_liked` stays the
        cheaper and equally correct probe there.
        """
        if self._destination.mode == PLAYLIST:
            provider = self._playlist_provider()
            track_ids = await provider.get_playlist_track_ids(
                await self._destination_playlist_id()
            )
            return track.provider_track_id in track_ids
        return await self._provider.is_liked(track)

    async def _run_like_legs(
        self, track: CurrentTrack
    ) -> tuple[bool, list[_LegFailure]]:
        """Run every configured leg. Returns (did anything land, failures).

        The legs are independent on purpose: under `both`, a playlist that
        was deleted must not cost the user the native like, and an expired
        playlist scope must not cost them the playlist entry.
        """
        landed = False
        failures: list[_LegFailure] = []

        if self._destination.wants_native:
            try:
                await self._provider.like(track)
                landed = True
            except Exception as e:
                failures.append(
                    _LegFailure(
                        title_suffix="service like failed",
                        detail=f"Could not like on the music service: {e}",
                        reason=str(e),
                    )
                )

        if self._destination.wants_playlist:
            name = self._destination.playlist_name
            try:
                await self._add_to_destination_playlist(track)
                landed = True
            except Exception as e:
                failures.append(
                    _LegFailure(
                        title_suffix=f"not added to {name}",
                        detail=f"Could not add to {name}: {e}",
                        reason=str(e),
                    )
                )

        return landed, failures

    async def _add_to_destination_playlist(self, track: CurrentTrack) -> None:
        provider = self._playlist_provider()
        try:
            await provider.add_track_to_playlist(
                track.provider_track_id, await self._destination_playlist_id()
            )
        except Exception:
            # The cached id may be stale (playlist deleted or renamed since
            # the last resolve) — drop it so the next press re-resolves,
            # the same rule RemoveFromPlaylistPipeline follows.
            self._playlist_id = None
            raise

    async def _destination_playlist_id(self) -> str:
        if self._playlist_id is None:
            self._playlist_id = await self._playlist_provider().find_or_create_playlist(
                self._destination.playlist_name
            )
        return self._playlist_id

    def _playlist_provider(self) -> PlaylistCapableProvider:
        # Guaranteed by the constructor; the cast keeps type checkers happy
        # without another isinstance on every press.
        return self._provider  # type: ignore[return-value]


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
