# Contributing

Thanks for looking! This file collects what's known to be easy to land
(good-first-PR ideas), how the desktop framework is laid out, and how
tests / CI work.

## Repo at a glance

- **Android** (`lib/`, `android/app/src/main/kotlin/…`) — Flutter + Kotlin
  app that listens for headset pause-play patterns. Feature-complete for
  Phase 0.
- **Desktop** (`like_spotify/`) — pluggable Python framework. Default
  flavor is a Windows tray host + global hotkey. Pluggability is what
  the OSS-framework refactor ([#19](https://github.com/Osasuwu/like-current-song/issues/19))
  is about: every concern (`Trigger`, `MusicProvider`, `Storage`,
  `PreLikeAction`, `PostLikeAction`, host) is a small interface in
  `like_spotify/core/`, and concrete implementations live under
  `like_spotify/extensions/` and `like_spotify/hosts/`.

## Desktop layout

```
like_spotify/
├── core/                 # Pure interfaces — no I/O, no platform code.
├── extensions/           # Pluggable implementations.
│   ├── spotify/                  # Spotify Web API provider (default).
│   ├── ytmusic/                  # YouTube Music provider (beta, Windows).
│   ├── tray_hotkey_trigger/      # Global-hotkey trigger (Windows).
│   ├── one_shot_cli_trigger/     # Per-invocation trigger (every OS).
│   ├── volume_button_trigger/    # Volume-key trigger (skeleton, #74).
│   ├── google_sheets_storage/    # Counter kept in a sheet you own.
│   ├── like_cooldown/            # PreLikeAction.
│   ├── archive_remove/           # PostLikeAction.
│   ├── promote_to_best/          # PostLikeAction.
│   └── follow_artist/            # PostLikeAction (needs Storage).
└── hosts/
    ├── windows/          # Resident tray + global hotkey + autostart.
    ├── settings/         # `--settings` window: model.py (pure config
    │                     #   round-trip + validation), services.py (OAuth,
    │                     #   autostart), window.py (thin tkinter view).
    ├── _stub.py          # macOS / Linux CLI fallback (like-once only).
    ├── _common.py        # Config I/O + storage/action-chain builder registries.
    └── _setup.py         # Interactive `--setup` wizard.
```

A new config key needs three touches: the runtime reader in
`hosts/_common.py`, the `--setup` prompt in `hosts/_setup.py`, and a field
in `hosts/settings/model.py` (`Settings`, `settings_from_config`,
`apply_settings`) plus its widget in `window.py`. Keep all logic in the
model so `tests/test_settings_model.py` covers it without a display.

`hosts/__init__.py` picks the right host at startup via `sys.platform`.
Anything Windows-specific (`winreg`, `winsound`, `ctypes.windll`,
`pystray`) lives in `hosts/windows.py` and the `tray_hotkey_trigger`
extension — never in `core/`.

## Good-first-PR ideas

### `hosts/macos.py` — native tray host for macOS

Today macOS gets the `_stub` host: `like-current-song --setup` and
`like-current-song like-once` work; the resident tray does not. A native
macOS host would:

- Render a menu-bar icon (`rumps` is the easy path, `pyobjc` if you want
  no extra deps).
- Register a global hotkey (`pynput` works; check the accessibility
  permission flow).
- Install a Launch Agent for autostart, or print clean instructions for
  the user to copy a plist into `~/Library/LaunchAgents/` — explicit is
  fine, we don't ship a Launch Agent automatically.
- Reuse everything in `hosts/_common.py` (pipeline wiring, config paths,
  builder registries) and `hosts/_setup.py` (the setup wizard).

Mirror `hosts/windows/` for shape; aim for ~200 LOC. Hook it up by
extending the dispatch in `hosts/__init__.py::select_host`.

### `hosts/linux.py` — Linux tray host

Same shape as macOS:

- Tray icon via `pystray` (works on common DEs with an
  `AppIndicator3`/`StatusNotifierItem` daemon — Gnome needs the
  AppIndicator extension; KDE works out of the box).
- Global hotkey — the existing `keyboard` library needs root on Linux,
  so prefer `pynput` (X11/Wayland) or document the limitation.
- Autostart via a generated `.desktop` file in
  `~/.config/autostart/`.
- Same `_common` / `_setup` wiring as the other hosts.

### Smaller wins

- **`Storage` impls** — anything tabular works. One ships today (Google
  Sheets), which is exactly why this is the most useful seam to fill:
  SQLite for a purely local counter, or whatever service you already
  keep data in. The contract suite means you inherit the tests.
- **`Trigger` impls** — global hotkey is one signal source; an MQTT
  trigger or a "shake your phone" → webhook flow would be a fun second
  resident trigger.
- **`PostLikeAction` impls** — anything that wants to react to a like.
  Mood tagging, last.fm scrobble fix-up, "send to a friend's queue", etc.

## Plugin-author guide

The desktop framework has five extension points. Each one is a small
ABC under `like_spotify/core/`; concrete impls live in
`like_spotify/extensions/<your_domain>/`. Every extension has the same
shape — a manifest plus a module-level factory — modelled on Music
Assistant's provider layout, with a typed-base per seam instead of a
single generic `Plugin` (see
[docs/design/interfaces.md](docs/design/interfaces.md) §1 for the
prior-art comparison and why we chose this shape over Pano's closed
enum or MA's single-bag plugin).

### Anatomy of an extension

Every extension folder has the same shape:

```
like_spotify/extensions/<your_domain>/
├── __init__.py     # the class + a module-level factory
└── manifest.json   # static metadata for the host
```

The factory name is fixed per extension point — `TRIGGER`,
`MUSIC_PROVIDER`, `STORAGE`, `PRE_LIKE_ACTION`, or `POST_LIKE_ACTION`
— and it's a plain callable that returns one configured instance.

**There is no automatic discovery yet.** A host picks your extension up
because someone imported it and registered its factory in
`like_spotify/hosts/_common.py` — one builder function and one entry in
the matching registry (`_STORAGE_BUILDERS`, `PROVIDER_BUILDERS`,
`_ACTION_EXTENSION_BUILDERS`). That is the whole wiring cost, and the
checklist below walks it. Scanning `extensions/` for manifests and
loading them without that edit is [#144](https://github.com/Osasuwu/like-current-song/issues/144);
the manifest shape here is what that work will read, which is why it is
worth filling in properly now.

Example manifest:

```json
{
  "domain": "volume_button_trigger",
  "extension_point": "trigger",
  "name": "Volume Buttons",
  "description": "Listen for vol-up-up on a connected MIDI / HID device and emit a like intent.",
  "codeowners": ["@you"],
  "requirements": ["hid>=1.0"],
  "documentation": "https://github.com/Osasuwu/like-current-song/blob/main/like_spotify/extensions/volume_button_trigger/README.md",
  "stage": "experimental"
}
```

`stage` is one of `experimental | beta | stable | deprecated`, and it
is documentation, not something enforced at runtime — nothing reads the
manifest yet (see above). `requirements` is pip-compatible; resolving it
at first enable is part of [#144](https://github.com/Osasuwu/like-current-song/issues/144),
so for now declare a dependency there **and** say so in your extension's
README.

### 1. `Trigger` — emit a like intent

```python
# like_spotify/core/trigger.py (already shipped)
class Trigger(ABC):
    @abstractmethod
    async def start(self, emit: EmitFn) -> None: ...
    @abstractmethod
    async def stop(self) -> None: ...
```

`start(emit)` is called once. Long-lived triggers register a listener
(global hotkey, system-tray menu item, MQTT subscription, MIDI HID
read loop) and call `emit()` each time the user signals "like the
playing track". One-shot triggers (`OneShotCliTrigger`) `await emit()`
inside `start` and return. `stop()` must be idempotent.

Existing impls:

- `tray_hotkey_trigger` — global keyboard hotkey (Windows).
- `one_shot_cli_trigger` — per-invocation, any OS.

**Skeleton for a third trigger (good-first-PR — `VolumeButtonTrigger`):**

```python
# like_spotify/extensions/volume_button_trigger/__init__.py
"""VolumeButtonTrigger — emit a like intent on a vol-up-up double-tap.

Watches an HID device for media-volume-up events. Two presses inside
DOUBLE_TAP_WINDOW_MS count as a like signal — single presses still
adjust system volume normally because we don't suppress them.

Status: skeleton only — the HID device discovery + event-loop are
TODOs. Pick this up by:

  1. Decide your HID library (hidapi via `pip install hid`, or evdev on
     Linux). Document it in `manifest.json::requirements`.
  2. Implement `_listen` as an asyncio task that reads HID events and
     calls `self._on_volume_up` on each press.
  3. Match the "two presses in N ms" pattern (mirror the Android
     `MediaEventPatternDetector.kt` logic — same domain shape, just
     translated to Python).
  4. Tests: feed synthetic timestamps to `_on_volume_up` and assert
     `emit` is called exactly once per matched double-tap, never on
     a single press, never on three presses spaced > window.

Acceptance: vol-up-up likes the playing track; single vol-up still
changes system volume. No state shared with TrayHotkeyTrigger.
"""

from __future__ import annotations

import asyncio
import time

from like_spotify.core.trigger import EmitFn, Trigger

DOUBLE_TAP_WINDOW_MS = 400


class VolumeButtonTrigger(Trigger):
    def __init__(self, double_tap_window_ms: int = DOUBLE_TAP_WINDOW_MS) -> None:
        self._window_ms = double_tap_window_ms
        self._last_press_ms: float | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._emit: EmitFn | None = None
        self._task: asyncio.Task | None = None

    async def start(self, emit: EmitFn) -> None:
        self._loop = asyncio.get_running_loop()
        self._emit = emit
        # TODO: open the HID device here and spawn a listener task that
        # calls `self._on_volume_up()` on each press event.
        self._task = self._loop.create_task(self._listen())

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            self._task = None
        # TODO: close the HID device here.

    async def _listen(self) -> None:
        # TODO: replace with a real `await device.read()` loop.
        raise NotImplementedError("VolumeButtonTrigger HID listener — see TODOs")

    def _on_volume_up(self, now_ms: float | None = None) -> None:
        now_ms = now_ms if now_ms is not None else time.monotonic() * 1000
        if (
            self._last_press_ms is not None
            and (now_ms - self._last_press_ms) <= self._window_ms
        ):
            # Double-tap matched — emit and reset so a third press doesn't
            # also fire.
            self._last_press_ms = None
            if self._loop is not None and self._emit is not None:
                asyncio.run_coroutine_threadsafe(self._emit(), self._loop)
            return
        self._last_press_ms = now_ms


def TRIGGER(**_cfg) -> VolumeButtonTrigger:
    return VolumeButtonTrigger()
```

### 2. `MusicProvider` — read playback + write a like

```python
# like_spotify/core/music_provider.py
class MusicProvider(ABC):
    @abstractmethod
    async def get_currently_playing(self) -> CurrentTrack | None: ...
    @abstractmethod
    async def like(self, track: CurrentTrack) -> None: ...
    @abstractmethod
    async def is_liked(self, track: CurrentTrack) -> bool: ...
    @abstractmethod
    async def user_id(self) -> str: ...
```

`extensions/ytmusic/` is the second implementation: it reads now-playing
from the OS media session instead of the service's API, which is the
pattern to copy for services without a "currently playing" endpoint.
A provider is selected by `music.provider` in `config.json`; register a
builder in `PROVIDER_BUILDERS` (`hosts/_common.py`) to make yours
selectable in `--setup`. Tidal or local Mopidy would fit the same seam.
To make the playlist actions work with your provider too, implement the
optional `PlaylistCapableProvider` protocol (see *Provider-aware actions*
below).

OAuth flows belong inside the extension. See `extensions/spotify/`
for a PKCE example (~70 LOC) and `like_spotify/auth/google.py` for an
installed-app OAuth pattern with refresh.

### 3. `Storage` — count likes across devices

```python
# like_spotify/core/storage.py
class Storage(ABC):
    @abstractmethod
    async def increment(
        self, user_id: str, track: CurrentTrack, was_already_liked: bool = False
    ) -> int: ...
    @abstractmethod
    async def get_count(self, user_id: str, track: CurrentTrack) -> int: ...
    @abstractmethod
    async def record_artist_track(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int: ...
```

`increment` is the hot path; it must be safe to call concurrently from
multiple devices and return the new count. `was_already_liked` is the
backfill flag — on first encounter with `True`, seed `count=2` and a
`backfilled=TRUE` marker, otherwise `count=1`. See
[#24](https://github.com/Osasuwu/like-current-song/issues/24)
for why this exists.

**Existing impls**: `google_sheets_storage` — REST PUT/APPEND on a sheet
you own. A Supabase backend shipped alongside it until the release after
v1.1.0 and was removed: a hosted Postgres project was a lot of setup to
ask of someone who wanted a like counter, and the Sheets impl covered the
same job. What it left behind is the useful part — `core/storage.py` is
written against neither, and the Android half arrives at the same counts
through a separately-shaped Dart interface of its own
(`lib/domain/repositories/like_count_repository.dart`) — same sheet, same
rows, no shared code.

**Wanted next** (good-first-PR): `sqlite_storage`, for a counter that
never leaves the machine. The shared contract test in
`tests/test_storage_contract.py` is already parametrised over the
`Storage` implementations rather than hard-coded to one — add a fixture
and you get all seven invariants for free. A second implementation is
what keeps that contract honest: until one exists, nothing stops the
interface from quietly growing a Google-Sheets-shaped assumption.

### 4. `PreLikeAction` — veto a like before it happens

```python
# like_spotify/core/actions.py
class PreLikeAction(ABC):
    @abstractmethod
    async def run(self, ctx: LikeContext) -> bool: ...
```

Returning `False` aborts the like (feedback shows "Skipped by
`<ActionName>`"). Pre-actions are independent: a raising pre-action is
logged and skipped, later pre-actions still run, the like still
proceeds. **Independence is the contract** — if you need a hard veto
that survives a raise, raise from inside `run` and the host will catch
it; but plan around that as the rare case.

**Existing impl**: `like_cooldown` — ignores a repeat like on the same
track within a configurable window (10 minutes by default), local-only,
no `Storage` round-trip. It is the one this seam ships, so it is also
the shortest thing to read before writing your own.

**Wanted next** (good-first-PR): a rule keyed on position rather than
history — "skip likes on tracks shorter than 30s", or "skip in the first
10s of a track, probably a misclick on the previous one". Either is
about fifty lines.

### 5. `PostLikeAction` — react to a successful like

```python
class PostLikeAction(ABC):
    @abstractmethod
    async def run(self, ctx: LikeContext) -> None: ...
```

Each action runs independently; a raise is logged and the chain
continues (mirrors the Pre-action rule). The `ctx.like_count` field
is populated by Storage *before* the post-chain runs — that's how
`PromoteToBestAction` gates on "liked 3+ times".

Existing impls: `archive_remove`, `promote_to_best`, `follow_artist`.

`archive_remove` reads its target playlist from
`actions.archive_remove.playlist_name` in `config.json`; a blank name
disables it (and `build_action_chains` drops the action). The same name
feeds the standalone **remove-without-like** flow: `RemoveFromPlaylistPipeline`
(in `core/pipeline.py`) removes the currently-playing track from that
playlist *without* a like. The Windows tray host binds it to a second
global hotkey, `trigger.remove_hotkey` (default `Ctrl+Shift+Alt+Q`), and
every host exposes it as `like-current-song remove-once`. The hotkey is
skipped if it equals `trigger.hotkey` or no archive name is configured.
`resolve_archive_playlist_name` in `hosts/_common.py` is the single
source of truth both flows read.

**Provider-aware actions** check a capability, not a class. Playlist and
follow operations live on the `PlaylistCapableProvider` protocol
(`core/music_provider.py`), not on `MusicProvider`:

| Method | Contract |
|--------|----------|
| `find_playlist_by_name(name)` | Id or `None`; case-insensitive, trimmed |
| `find_or_create_playlist(name)` | Id; creates a private playlist if missing |
| `get_playlist_track_ids(playlist_id)` | Set of `provider_track_id`s |
| `add_track_to_playlist(track_id, playlist_id)` | Append |
| `remove_track_from_playlist(track_id, playlist_id)` | Every occurrence; absent is not an error |
| `follow_artist(artist_id)` | An id from `CurrentTrack.artist_ids`; already-followed is not an error |

Your action checks `isinstance(ctx.music_provider, PlaylistCapableProvider)`
and stays silent when the provider doesn't qualify. The protocol is
structural, so a provider opts in by implementing all six methods, with no
inheritance. Both `spotify` and `ytmusic` do, so archive-remove,
promote-to-best and follow-artist run on either unchanged. A provider
that can't name a track's artist leaves `artist_ids` empty, and
follow-artist skips that track. For an API that only one provider has,
downcast to the concrete class and ship the action in a folder named
after that provider, so the dependency is visible.

## Adding an extension — checklist

1. Create `like_spotify/extensions/<your_domain>/__init__.py` with the
   concrete class and the matching top-level factory name (`TRIGGER`,
   `MUSIC_PROVIDER`, `STORAGE`, `PRE_LIKE_ACTION`, or
   `POST_LIKE_ACTION`).
2. Create `manifest.json` next to it. The required keys are
   `domain`, `extension_point`, `name`, `description`,
   `codeowners`, `requirements`, and `stage`.
3. Register the manifest in `pyproject.toml`'s
   `[tool.setuptools.package-data]` block so it ships in the wheel.
4. If the extension needs configuration, prompt for it in
   `like_spotify/hosts/_setup.py::do_setup` (the wizard) and read it
   from `cfg` in a `_build_*` helper registered in `_common.py`'s
   `_STORAGE_BUILDERS` (storage backends) or `_ACTION_EXTENSION_BUILDERS`
   (pre/post-like actions) — adding an extension is one function + one
   registry entry, not a new `if`/`elif` branch.
5. Tests under `tests/`. For `Storage`, drop your fixture into the
   parametrised contract suite (`tests/test_storage_contract.py`). For
   everything else, small async unit tests against the interface +
   one slice in `tests/test_pipeline.py` if the host wiring is novel.

## Running tests

```bash
pip install -e .[dev]
pytest                  # all tests
pytest tests/test_pipeline.py -k storage   # one slice
flutter test            # Android tests
```

CI (`.github/workflows/ci.yml`) runs on push/PR to `main`: a `test` job
(Flutter analyze + `flutter test`, ubuntu) and a `pytest` job (windows, since
the default host is Windows-bound). A PR must also carry a linked issue in its
body (`Closes #123`) or the `[no-issue]` marker for trivial drive-bys — see
`.github/workflows/pr-body-check.yml`.

## Signing an Android release

Day to day you need none of this: with no `android/key.properties` present,
`flutter build apk --release` signs with the per-machine debug key and says so.
That is fine for testing on your own phone and it is what CI does.

It is *not* fine for anything you hand to someone else. A debug key is
generated per machine, so an APK signed with yours can never be upgraded in
place by a build signed anywhere else — including the next official release.

To produce a publishable APK, generate a keystore once:

```bash
keytool -genkey -v -keystore ../like-current-song.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias like-current-song
```

Then copy `android/key.properties.example` to `android/key.properties` and fill
in `storeFile`, `storePassword`, `keyAlias`, `keyPassword`. Both the keystore
and that file are gitignored, and nothing reads them but Gradle.

**Keep the keystore.** Losing it means every existing install is stranded on
the version it has: the only way forward is a new application ID, which reads
as a different app. Back it up somewhere that is not this repository and not
the machine you build on.

Gradle warns which key it used whenever a release is assembled, but
`flutter build` hides Gradle's output, so before publishing anything check the
artifact itself:

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

A debug-signed APK names `CN=Android Debug, O=Android, C=US`. Anything you
publish must not.

## Conventions

- **One Spotify development-mode app per developer.** Spotify limits each
  developer to a single Development Mode Client ID, allows at most 5
  allowlisted users on it, and requires the app owner to hold Spotify Premium
  for the app to function at all. So don't plan on a throwaway Spotify app per
  branch or per test account: reuse your one client ID for phone and desktop,
  and add any account you test with under **Settings → User Management** in
  the dashboard — a missing account gets 403s *after* a successful login. See
  [README](README.md#1-spotify-developer-app).
- Cross-platform helpers in `hosts/_common.py` (config I/O, builder
  registries) and `hosts/_setup.py` (the wizard); OS-bound side effects
  in `hosts/<platform>.py`. **No `winreg` / `winsound` / `ctypes.windll`
  outside `hosts/windows/`.**
- Each `PostLikeAction` is independent — a failure must not abort the
  chain (see `like_spotify/core/pipeline.py`).
- "Abstractions need two real implementations" — when you add an
  interface, also ship the second concrete impl (or wait until you
  have a second use case in hand).
- Issues drive scope; the design lives in issue bodies. Decisions live
  in commit messages and the design docs under `docs/design/`.
