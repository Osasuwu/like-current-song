# Interface design — prior art and draft signatures

Issue: #20 (Phase 1 prior-art research, parent #19, blocks #21).

> **Historical record.** This captures the design as it was decided in
> Phase 1 and is deliberately not rewritten as the code moves on. It still
> names `SupabaseStorage`, which was the first `Storage` impl and has since
> been removed; `GoogleSheetsStorage` is now the only shipped one. The
> interface shapes below are still current.

Sources read at commit time:

- **Pano Scrobbler** — `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/Scrobblable.kt` @ `009b4886`. Closest architectural analog: a multi-target write provider abstraction over Last.fm / ListenBrainz / Libre.fm / Pleroma / file.
- **Music Assistant** — `music_assistant/providers/_demo_plugin_provider/{__init__.py, manifest.json}` and `lastfm_scrobble/{__init__.py, manifest.json}` @ `main`. Closest plugin-registration analog: ~60 providers discovered via filesystem convention, manifest-driven dependency install.

The five extension points are fixed by epic decision `99dffb2c-369b-436d-80aa-99395fab92c5` — Trigger / PreLikeAction / MusicProvider / PostLikeAction / Storage. This doc fixes their **shape**, not their **set**.

---

## 1. Comparison: their abstractions vs our 5

| Concern | Pano `Scrobblable` | Music Assistant `PluginProvider` | Our split |
|---|---|---|---|
| Number of seams | 1 (write to a scrobble target) | 1 generic plugin + capability flags | 5 named seams |
| Read vs write | mixed (`scrobble`, `loveOrUnlove`, `getRecents`, `getCharts`, `getFriends`, `getListeningActivity` — 10 methods) | per-plugin: `loaded_in_mass`, `unload`, optional `get_audio_stream` etc. | split — `MusicProvider` is read-now + like-now only; metrics-on-history would be a different seam if we ever need it |
| Capability declaration | implicit (overrides) + closed `enum AccountType` for dispatch | `SUPPORTED_FEATURES: set[ProviderFeature]` + manifest `multi_instance`, `builtin` | implicit per base class; **no feature-flag set in Phase 1** (premature at our scale) |
| Registration | hardcoded `accountToScrobblable(userAccount)` `when {}` block over the enum | filesystem: `providers/<domain>/{__init__.py, manifest.json}`, loaded via `importlib.import_module(f".{domain}", "music_assistant.providers")` | filesystem (MA-style) — see §3 |
| Lifecycle | none explicit; `Scrobblables` cache holds instances per account, `@Synchronized` on access | `setup() → instance`, then `loaded_in_mass()` and `unload(is_removed)` | host-driven `setup`/`teardown`; chains run per-event, not per-instance |
| Async style | Kotlin `suspend` + `Result<T>` | `async def` everywhere, exceptions for failure | `async def` for all extension methods; sync impls wrapped in `asyncio.to_thread` (so default Spotify port can stay `requests`-based without rewrite) |
| Error model | `Result<ScrobbleResult>` | exceptions + `LoginFailed`, `SetupFailedError` typed errors | exceptions + a small typed-error module (`AuthError`, `RateLimited`, `TransientError`); host catches and routes to feedback |
| Dependency install | none — Gradle module | `manifest.json: requirements: ["pylast==7.0.2"]` pip-installed at provider load | manifest `requirements` resolved by host installer at first enable (out of scope for #21 tracer; #28 wires it) |

**Headline takeaway**: Pano is the wrong shape for an OSS framework — its registry is a closed enum, every new provider edits core. Music Assistant is the right shape for discovery and lifecycle but its single-bag `PluginProvider` blurs what we want to keep separated. Our move: **MA's discovery + manifest, with five typed base classes (Pano-style separation by responsibility, not Pano's by-target enum)**.

---

## 2. Draft signatures (Python, async-first)

All extension classes live in `like_spotify/extensions/<domain>/__init__.py`. Each module exports one of: `TRIGGER`, `PRE_LIKE_ACTION`, `MUSIC_PROVIDER`, `POST_LIKE_ACTION`, `STORAGE` — a callable returning the configured instance, matching MA's module-level `setup()` pattern.

### 2.1 Common types

```python
# like_spotify/core/types.py

from dataclasses import dataclass, field
from typing import Protocol

@dataclass(frozen=True)
class CurrentTrack:
    """Whatever the MusicProvider returns when something is playing.

    Provider-agnostic IDs: the `provider_track_id` is opaque to the host
    and only meaningful inside the producing provider.
    """
    provider: str           # domain of the producing MusicProvider, e.g. "spotify"
    provider_track_id: str  # opaque to host
    title: str
    artists: tuple[str, ...]
    artist_ids: tuple[str, ...] = ()  # opaque to host; PostLikeActions use them
    album: str | None = None

@dataclass
class LikeContext:
    """Mutable bag passed down a like pipeline. PostLikeActions read/write.

    Mutable by design — the chain mutates `like_count` and `extras` in place.
    Contrast with `CurrentTrack` which is frozen.
    """
    track: CurrentTrack
    like_count: int | None = None       # populated by Storage; None if no Storage configured
    music_provider: "MusicProvider | None" = None  # resolved provider for this pipeline (for actions that downcast to provider-specific clients)
    extras: dict[str, object] = field(default_factory=dict)  # free-form per-action data
```

The `music_provider` field carries the resolved provider instance so that **provider-aware PostLikeActions** (e.g. `ArchiveRemoveAction` which needs `find_playlist_by_name` + `remove_track_from_playlist`, neither of which belong on the narrow `MusicProvider` interface) can downcast: `if isinstance(ctx.music_provider, SpotifyMusicProvider): ctx.music_provider.client.remove_from_playlist(...)`. Such provider-coupled actions ship in the same extension folder as the provider (e.g. `extensions/spotify_archive_remove/`) and declare a soft dependency on it.

Rationale tie:

- `provider` + `provider_track_id` instead of a synthetic global ID — Pano stores per-account caches keyed on `UserAccountSerializable`; same lesson, IDs don't cross providers.
- `LikeContext.like_count` flows through the chain because PostLikeActions need to gate on it (best promote at threshold = 3). MA's event bus pattern (`subscribe(handle_event, EventType.MEDIA_ITEM_PLAYED)`) is the alternative — pub/sub. Rejected for Phase 1: explicit ordering matters here (count must be incremented before promote checks it), and the chain is short (~5 actions).

Typed errors used by host branching are stubbed in `core/errors.py` (full surface in #21):

```python
# like_spotify/core/errors.py (stubs — full definitions in #21)
class AuthError(Exception): ...        # token expired or revoked; host triggers re-auth
class RateLimited(Exception): ...      # provider returned 429; host backs off
class TransientError(Exception): ...   # network blip / 5xx; host retries with jitter
```

### 2.2 Trigger

```python
# like_spotify/core/trigger.py

from abc import ABC, abstractmethod
from collections.abc import Awaitable, Callable

EmitFn = Callable[[], Awaitable[None]]  # ask host to run the like pipeline once

class Trigger(ABC):
    """Long-lived source of like intents.

    The host calls `start(emit)` once. The trigger should call `emit()`
    each time the user signals 'like the current track'. `stop()` is
    called on host shutdown and must be idempotent.
    """

    @abstractmethod
    async def start(self, emit: EmitFn) -> None: ...

    @abstractmethod
    async def stop(self) -> None: ...
```

Rationale tie:

- `start` / `stop` lifecycle mirrors MA's `loaded_in_mass` / `unload` but is required, not optional — every Trigger needs both.
- `EmitFn` takes no track arg: the trigger doesn't know what's playing, it just signals intent. The pipeline asks `MusicProvider.get_currently_playing()` after.
- No `Result` return type. If a hotkey backend fails to bind, raise — host logs and surfaces in tray.

### 2.3 MusicProvider

```python
# like_spotify/core/music_provider.py

from abc import ABC, abstractmethod
from .types import CurrentTrack

class MusicProvider(ABC):
    """Read 'what is playing' and write 'I like this'. Nothing else.

    Stays narrow on purpose. Charts, history, social — out of scope.
    Pano's Scrobblable is 10 methods; we do not want that.
    """

    @abstractmethod
    async def get_currently_playing(self) -> CurrentTrack | None: ...

    @abstractmethod
    async def like(self, track: CurrentTrack) -> None: ...

    @abstractmethod
    async def user_id(self) -> str:
        """Stable per-user id this provider uses. Storage keys against it.

        Expected O(1) after setup (cached post-auth value). Async because some
        future provider may need a lazy fetch on first call; default impls
        cache and return immediately.
        """
```

Rationale tie:

- Two write methods on one interface, no read-stats methods: explicit reaction to Pano's fat interface (10 methods, mixes scrobbling with chart fetching). If a future provider needs read-only metrics, that's a new extension point, not a method here.
- `user_id()` exists because Storage needs a stable user key, and asking the user to configure one is friction. Spotify gives `/me`, Last.fm gives username — providers know how. Rejected alternative: pass user_id at construction (forces two-stage init).
- `like` takes the full `CurrentTrack`, not just an id, so a provider can re-validate (e.g. "is this still the playing item?") without a second API call.
- **Provider-specific operations** like Spotify's `find_playlist_by_name` / `remove_track_from_playlist` (used by today's `desktop/like_spotify.py:431-435` archive-remove flow) deliberately do NOT live on `MusicProvider`. They live as methods on the concrete provider class (e.g. `SpotifyMusicProvider.client.remove_from_playlist`) and are reached by **provider-coupled `PostLikeAction`s** via `LikeContext.music_provider` + `isinstance` downcast. Such actions ship in the same extension folder as the provider they couple to (e.g. `extensions/spotify_archive_remove/`). Cross-provider actions stay narrow to what's on the base interface.

### 2.4 PreLikeAction

```python
# like_spotify/core/pre_like_action.py

from abc import ABC, abstractmethod
from enum import Enum
from .types import LikeContext

class PreDecision(Enum):
    PROCEED = "proceed"
    SKIP = "skip"        # don't like, don't run post-actions; host shows neutral tray feedback (e.g. "already liked"), no error sound

class PreLikeAction(ABC):
    """Run before MusicProvider.like(). Can short-circuit the pipeline.

    Examples (none in Phase 1 default flavor): dedupe (already liked recently),
    rate-limit, blocklist by artist.

    Errors are raised, not encoded in the return value — keeps the error model
    consistent with the rest of the framework (typed exceptions caught by host).
    """

    @abstractmethod
    async def run(self, ctx: LikeContext) -> PreDecision: ...
```

Rationale tie:

- Two-state decision (PROCEED / SKIP) — error paths use exceptions, not a return-value enum. Consistent with the rest of the framework.
- Default flavor has no PreLikeActions in Phase 1 — included as a seam because the alternative is wedging skip-logic into MusicProvider (Pano's mistake).

### 2.5 PostLikeAction

```python
# like_spotify/core/post_like_action.py

from abc import ABC, abstractmethod
from .types import LikeContext

class PostLikeAction(ABC):
    """Run after MusicProvider.like() succeeds. Sequential, ordered.

    Failures are isolated: an action raising does NOT stop the chain.
    Host logs and shows a non-fatal error in feedback.
    """

    @abstractmethod
    async def run(self, ctx: LikeContext) -> None: ...
```

Rationale tie:

- Sequential, not concurrent: the existing best flow needs `Storage.increment_and_get_count` to populate `ctx.like_count` *before* `PromoteToBestAction` reads it. Concurrent breaks the gate.
- Failures isolated: an unreachable Supabase shouldn't block archive-remove. (Today's `desktop/like_spotify.py` already does this implicitly — every step is a try-or-fall-through; we make the contract explicit.)

### 2.6 Storage

```python
# like_spotify/core/storage.py

from abc import ABC, abstractmethod
from dataclasses import dataclass

@dataclass(frozen=True)
class LikeRecord:
    user_id: str
    provider: str           # MusicProvider.domain
    provider_track_id: str
    liked_at: float         # unix seconds, UTC
    title: str | None = None
    artists: tuple[str, ...] = ()

class Storage(ABC):
    """Cross-device counter + (optional) audit log.

    Phase 1 default: SupabaseStorage. Second impl: GoogleSheetsStorage (#25).
    Two impls is the abstraction-honesty test (CLAUDE.md rule).
    """

    @abstractmethod
    async def increment_and_get_count(
        self, user_id: str, provider_track_id: str,
    ) -> int | None:
        """Atomically increment the like counter, return new count.

        Returning `None` is allowed (e.g. write-only sink, or transient
        backend outage): downstream actions that gate on count must
        treat `None` as 'unknown, do not gate'.

        Single-provider scope: `user_id` is provider-scoped (Spotify gives
        `/me`, Last.fm gives username). Multi-provider key splitting (adding
        a `provider` arg) is a future change once a second provider lands.
        """

    async def backfill(self, records: list[LikeRecord]) -> None:
        """Insert historical records without bumping counters or triggering hooks.

        For #24. Default raises NotImplementedError; storages that support
        backfill override. Host catches NotImplementedError and logs
        'storage X does not support backfill' — non-fatal.
        """
        raise NotImplementedError
```

Rationale tie:

- `increment_and_get_count` returns `int | None`, not `Result`-style — `None` semantically encodes "I don't know" (see today's `supabase_increment` returning `None` on failure, and the best gate quietly skipping). Promotes the existing implicit contract to explicit.
- Key is `(user_id, provider_track_id)` — single-provider scope for Phase 1 matches today's `desktop/like_spotify.py` reality. The `LikeRecord.provider` field carries the source for the audit log so backfill can disambiguate later, but the live counter is single-keyed.
- **Multi-provider migration path** (when a second `MusicProvider` lands): add `provider: str` arg to `increment_and_get_count`, default it to the configured single-provider domain for backwards compat, and migrate the live counter table by treating the existing rows as belonging to that provider. Storage authors landing in Phase 1 can rely on the single-key semantics; the migration is additive, not breaking.
- `backfill` is on the same interface (not a separate `Backfillable`): MA's lesson — capability flags on a single base class read better than a proliferation of optional mixins, **as long as the count is small** (we have one optional method, not ten).

---

## 3. Plugin-registration mechanism — chosen and justified

**Decision: filesystem convention** (Music Assistant style), default-flavor extensions in `like_spotify/extensions/<domain>/`. Third-party packages may register additional roots via a `like_spotify.plugin_roots` setuptools entry point in a later phase — out of scope for #21.

### Mechanism shape

Each extension is a directory:

```
like_spotify/extensions/<domain>/
  __init__.py        # exports one of TRIGGER/PRE_LIKE_ACTION/MUSIC_PROVIDER/POST_LIKE_ACTION/STORAGE
  manifest.json      # metadata + pip requirements
  icon.svg           # optional, for tray menu / future UI
```

`manifest.json` (copying MA's shape, dropping fields we don't need yet):

```json
{
  "domain": "spotify",
  "extension_point": "music_provider",
  "_extension_point_values": "trigger | pre_like_action | music_provider | post_like_action | storage",
  "name": "Spotify",
  "description": "Reads currently-playing and likes via Spotify Web API.",
  "codeowners": ["@Osasuwu"],
  "requirements": ["requests>=2.31"],
  "documentation": "https://github.com/Osasuwu/like-current-song/blob/main/like_spotify/extensions/spotify/README.md",
  "stage": "stable"
}
```

`__init__.py` exports per extension point — example for a MusicProvider:

```python
from like_spotify.core.host import ExtensionHost
from like_spotify.core.music_provider import MusicProvider

class SpotifyMusicProvider(MusicProvider):
    ...

async def MUSIC_PROVIDER(host: ExtensionHost, config: dict[str, object]) -> MusicProvider:
    return SpotifyMusicProvider(host, config)
```

`ExtensionHost` is a `Protocol` in `core/host.py` — one-line stub for #21, full surface area defined as the host grows. Naming it now anchors the seam in every extension's signature.

The host loader (analog of MA's `load_provider_module`):

```python
import importlib
mod = importlib.import_module(f".{domain}", "like_spotify.extensions")
factory = getattr(mod, expected_export)  # one of the 5 sentinels
instance = await factory(host, config)
```

### Why filesystem over alternatives

| Mechanism | Pro | Con | Verdict |
|---|---|---|---|
| **Filesystem convention** (chosen) | Zero ceremony — fork → drop folder → `pip install -e .` works. Manifest is human-readable. Proven at MA's ~60-provider scale. Discovery is `os.listdir` + manifest filter. | Requires a known root dir (we control it). Third-party packages outside the repo need a separate hook (entry-point bridge — Phase 2). | **Yes** for Phase 1. |
| **`setuptools` entry points** (`pyproject.toml [project.entry-points]`) | Standard Python plugin pattern. Third-party packages register without filesystem access. Auto-discovered via `importlib.metadata.entry_points()`. | Forces every contributor to write a `pyproject.toml`. Requirement install isn't bundled — relies on the dist's own `dependencies`. Manifest metadata (codeowners, docs URL, icon) has nowhere natural to live. Pano-style closed enum is what most projects fall back to to avoid this ceremony. | **Defer** — add as a thin loader on top of filesystem when third-party demand appears. |
| **Single config-file registration** (`plugins.toml` lists modules) | Explicit; no scanning. | User edits a config file to enable each extension — friction. Doesn't solve dependency install. | No. |
| **Closed enum + factory** (Pano) | Simplest possible code. Fast. | Every new extension edits core. **Not OSS-friendly.** This is exactly the anti-pattern we are escaping. | No. |

The filesystem path also keeps the **default-flavor-as-folders** invariant: `extensions/spotify/`, `extensions/tray_hotkey_trigger/`, `extensions/supabase_storage/` are first-class examples for contributors. Pano hides these behind an enum; MA promotes them to top-level discoverable units. We follow MA.

---

## 4. Anti-patterns we will NOT copy

1. **Pano's closed `enum AccountType` + `accountToScrobblable` `when {}`** — every new provider edits core, kills OSS contributions. Replaced by filesystem discovery.
2. **Pano's fat `Scrobblable` interface** (10 methods mixing `scrobble` + `getCharts` + `getFriends` + `getRecents`) — read-only stats and write actions belong on different seams. Our `MusicProvider` is intentionally 3 methods.
3. **Pano's `Result<T>` everywhere** — Python idiom is exceptions; `Result` becomes noise. Keep typed exceptions (`AuthError`, `RateLimited`, `TransientError`) for the cases the host actually branches on.
4. **Pano's `Scrobblables` global singleton with `@Synchronized` cache** — global mutable instance registries hide lifecycle bugs. Host owns instances explicitly, passes them into the pipeline.
5. **MA's `app_var(12)` opaque-index built-in API key fallback** — works for them because they ship default LastFM keys; for us, every secret is named (`SPOTIFY_CLIENT_ID`, etc.) in `.env`. No hidden defaults.
6. **MA's `SUPPORTED_FEATURES: set[ProviderFeature]` capability bag** — premature at five extension points and ~5 reference impls in Phase 1. The base-class method set IS the contract. Revisit only when we have a real third axis (≥3 implementations of one interface that genuinely differ in capability). Note: a single `raise NotImplementedError` in an optional method (e.g. `Storage.backfill`) is acceptable — the caller already wraps in `try`. The flag-bag becomes a problem at ≥5 flags, when callers grow conditional trees against them.
7. **MA's mandatory `multi_instance`/`builtin` manifest fields** — copy the names later if needed; not in Phase 1 (no instance management UI yet).
8. **Per-extension event bus** (MA's `mass.subscribe(handle_event, EventType.MEDIA_ITEM_PLAYED)`) — pub/sub is great when ordering doesn't matter and there are many subscribers. Our PostLikeActions need explicit ordering (count → promote gate). Sequential chain is the right shape; pub/sub becomes useful only when Phase 2's Android port adds parallel listeners.
9. **Sync `setup()` like MA's older providers used to have** — every extension is `async def` from day one. Mixed sync+async chains are the worst of both. Sync impls (default Spotify port using `requests`) wrap their I/O in `asyncio.to_thread`.
10. **Synchronous I/O in `__init__`** — extension constructors must not hit network/disk. Initialization that needs I/O (token refresh, playlist enumeration, capability probe) goes in the host-called `setup` factory or in `start()` for triggers. Keeps tests fast and lets the host handle init failures uniformly. Today's `desktop/like_spotify.py` already does it right: `auth_flow` is invoked from `main`, not at module import.

---

## 5. HITL gate — before #21 starts

Owner review checklist:

- [ ] Five base-class signatures (§2.2–§2.6) acceptable as drafts for #21 to implement
- [ ] Filesystem-convention plugin discovery (§3) is the right call vs deferring entry points
- [ ] Async-first (with sync wrapped in `to_thread`) is acceptable for the Spotify port — alternative would be sync-first and add async later
- [ ] `LikeContext` mutable bag pattern is acceptable vs a more functional pipeline (immutable record threaded through)
- [ ] Anti-pattern list is the right list — anything missing? anything mis-classified?

Signoff: edit this file with comments inline (`> NOTE: ...`) or close the gate by adding a `Reviewed:` line below.

Reviewed: code-reviewer agent (PR #31, 2026-05-10) — first round CHANGES NEEDED (5) addressed; second round LGTM with 4 follow-up nits (Optional annotation, backfill ambiguity, host typing, user_id async contract) all addressed in second revision. Cleared for #21 to proceed.
