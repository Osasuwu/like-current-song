import logging
from collections.abc import Sequence
from dataclasses import dataclass
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
            # the same rule DiscardPipeline follows.
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


@dataclass
class _PlaylistLeg:
    """One playlist a discard press takes the playing track out of.

    Each leg keeps its *own* resolved id, so a playlist that was deleted
    invalidates only its own cache — the other legs keep the ids they
    already resolved.
    """

    name: str
    playlist_id: str | None = None


class DiscardPipeline:
    """"I don't want this one" — no like. Independent legs, one press.

    Powers the second desktop hotkey (`trigger.remove_hotkey`, default
    Ctrl+Shift+Alt+Q). The like flow's `ArchiveRemoveAction` only fires
    *after* a like, so it can't help with a track the user is rejecting;
    this is the opposite intent, and it says so in every way a service
    understands:

        1. **Dislike leg** — tell the service itself (#172). Needs
           `DislikeCapableProvider`, whose docstring covers how far that
           reaches per service: a real thumbs-down on YouTube Music, a
           library removal on Spotify, whose Web API has no dislike.
        2. **Archive leg** — take the track out of the archive playlist
           (`playlist_name`), for the "keep my Discover Weekly archive
           clean" job this class shipped with in #43. Needs
           `PlaylistCapableProvider`.
        3. **Destination leg** — take it out of the playlist a *like*
           would have put it in (`destination_playlist_name`, i.e.
           `like.playlist_name` when `like.destination` is `playlist` or
           `both`, #177). Without it, a discard could not undo the like it
           exists to undo: on Spotify the like never touched the library,
           so a dislike had nothing to remove and the press was a no-op
           for the track the user had just liked.

    Every available leg runs on every press, and **none can cost the user
    another**: each soft-fails on its own and the feedback reports what
    actually happened, so a deleted archive playlist doesn't silently
    swallow the dislike. A leg whose capability the provider lacks is not
    attempted at all rather than counted as a failure — that is how a
    dislike-only user (no playlists configured) and a playlist-only
    provider both get a useful press. When *no* leg applies there is
    nothing honest to do, and the press says so instead of raising,
    keeping `core` free of any extension import.

    Both playlist names may be blank: that is the dislike-only wiring, not
    an error. Nothing stops a user pointing the archive and the like
    destination at the *same* playlist either, so the two names are
    de-duplicated case-insensitively (`find_playlist_by_name` matches that
    way) — one press then removes once and reports once, instead of
    claiming a second, phantom removal. Hosts decide whether a press is
    worth offering at all — see `build_discard_pipeline` in
    `hosts/_common.py`.

    Each playlist's resolved id is cached after its first successful
    lookup. A miss (playlist not found, or a lookup error) is *not*
    cached, and a cached id is dropped again if the remove call later
    fails (the playlist may have been deleted/renamed) — so a later press
    re-resolves. Useful in a long-lived tray when the user creates the
    playlist after launch.

    Slices: #43 (remove-without-like hotkey), #172 (dislike leg),
    #177 (like-destination leg).
    """

    def __init__(
        self,
        provider: MusicProvider,
        feedback: FeedbackFn,
        playlist_name: str = "",
        destination_playlist_name: str = "",
    ) -> None:
        self._provider = provider
        self._feedback = feedback
        self._playlist_name = (playlist_name or "").strip()
        self._destination_playlist_name = (destination_playlist_name or "").strip()
        self._legs = tuple(
            _PlaylistLeg(name)
            for name in _unique_names(
                self._playlist_name, self._destination_playlist_name
            )
        )

    @property
    def label(self) -> str:
        """Imperative one-liner for what a press will attempt.

        Lives here rather than in the tray so the menu item, the CLI help
        and the feedback all describe the same press from one place.
        """
        parts: list[str] = []
        if self._can_dislike():
            parts.append("dislike")
        if self._can_remove():
            parts.extend(f"remove from {leg.name}" for leg in self._legs)
        if not parts:
            # No leg is available. The host still wires the press when
            # *something* was asked for (an archive playlist, say) but the
            # provider cannot honour it, so stay generic rather than
            # promise a leg that would only report "unsupported" on press.
            return "Discard current track"
        if parts == ["dislike"]:
            # Alone, the verb needs an object to be a sentence.
            return "Dislike current track"
        return _capitalize(_and(parts))

    def _can_remove(self) -> bool:
        return bool(self._legs) and isinstance(
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
            for leg in self._legs:
                reason = await self._remove(track, leg)
                if reason is None:
                    done.append(f"removed from {leg.name}")
                else:
                    failed.append(f"not removed from {leg.name}")
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

    async def _remove(self, track: CurrentTrack, leg: _PlaylistLeg) -> str | None:
        """Run one playlist leg. None on success, else the reason to show.

        Every failure path is contained in the leg that hit it — the
        caller keeps going through the remaining legs either way.
        """
        if leg.playlist_id is None:
            try:
                leg.playlist_id = await self._provider.find_playlist_by_name(leg.name)
            except Exception as e:
                # Not cached — next press retries.
                logger.warning("playlist lookup failed", exc_info=True)
                return f"Playlist lookup failed: {e}"
            if not leg.playlist_id:
                return f"Playlist not found: {leg.name}"

        try:
            await self._provider.remove_track_from_playlist(
                track.provider_track_id, leg.playlist_id
            )
        except Exception as e:
            # The cached id may be stale (playlist deleted/renamed since the
            # last resolve) — drop it so the next press re-resolves instead
            # of failing forever against a dead id.
            leg.playlist_id = None
            logger.warning("playlist remove failed", exc_info=True)
            return f"Remove failed: {e}"
        return None


def _unique_names(*names: str) -> list[str]:
    """Drop blanks and repeats, keeping the first spelling of each name.

    Nothing stops a user pointing `actions.archive_remove.playlist_name`
    and `like.playlist_name` at the same playlist (#177). Matching is
    case-insensitive because `find_playlist_by_name` is: two spellings
    that resolve to one playlist must not become two legs, or a press
    would remove twice and report a removal that never happened.
    """
    seen: set[str] = set()
    unique: list[str] = []
    for name in names:
        key = name.casefold()
        if not name or key in seen:
            continue
        seen.add(key)
        unique.append(name)
    return unique


def _and(parts: list[str]) -> str:
    """Join leg phrases into the one clause a press is reported as.

    Two legs read best as "a and b" — the #43/#172 wording, kept
    verbatim. A third (#177) would stack conjunctions
    ("disliked and removed from A and removed from B", which parses as
    though the second removal were part of the first), so from three on
    the list takes commas and keeps "and" for the final pair:
    "disliked, removed from A and removed from B". No serial comma,
    matching the prose style of the rest of the UI strings.
    """
    if len(parts) <= 2:
        return " and ".join(parts)
    return f"{', '.join(parts[:-1])} and {parts[-1]}"


def _capitalize(text: str) -> str:
    return text[:1].upper() + text[1:]


def _display(track: CurrentTrack) -> str:
    artists = ", ".join(track.artists) if track.artists else ""
    return f"{track.title} — {artists}" if artists else track.title
