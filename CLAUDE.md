# CLAUDE.md — Like Spotify Mobile App

## What this is

Two halves that share Spotify state and a cross-device like counter:

- **Android** (Flutter + Kotlin, `lib/` + `android/`) — listens for media button
  patterns (e.g. pause-play) and triggers Spotify actions: like current track,
  manage playlists, follow artists.
- **Desktop** (Python, `like_spotify/`) — a *pluggable framework* with five
  extension points (`Trigger`, `MusicProvider`, `Storage`, `PreLikeAction`,
  `PostLikeAction`) discovered at startup via a `manifest.json` filesystem
  convention. Default flavor: Windows tray host + global hotkey; `_stub.py` CLI
  fallback on macOS/Linux.

Repo: `Osasuwu/like-current-song` — **public**. Public repo = production
quality: no local hacks, no "works for me".

**Status**: feature-complete through v1.1.0, maintenance mode — lower priority
than redrobot and jarvis. No advanced protocols (PM dispatch, parallel work)
needed. Standard Claude Code practices apply.

## Tech stack

### Android
- **Framework**: Flutter (Dart) — Android-only, other platforms are stubs
- **State management**: Riverpod (`StateNotifier<AppState>`)
- **Architecture**: Clean Architecture — domain / data / presentation layers
- **Native**: Kotlin — foreground service, MediaSession, broadcast receivers
- **Auth**: Spotify OAuth 2.0 (PKCE flow)
- **Storage**: SharedPreferences + FlutterSecureStorage (tokens)

### Desktop
- **Language**: Python 3.11+, packaged via `pyproject.toml` (`like-current-song`)
- **Architecture**: ABCs in `core/`, implementations in `extensions/`, OS-bound
  side effects confined to `hosts/<platform>/`
- **Counters**: Supabase (Postgres RPC) or Google Sheets, selected by
  `storage.backend` in `~/.like_spotify/config.json`
- **Config/tokens**: `~/.like_spotify/` (`config.json`, `spotify_token.json`,
  `google_token.json`)

## Architecture

```
lib/
├── core/              # Constants, shared utilities
├── domain/            # Business logic (pure, no deps)
│   ├── entities/      # TriggerConfig, SpotifyAuthState, AppLog
│   ├── services/      # SignalPatternMatcher
│   └── repositories/  # Interface contracts
├── data/              # Implementations
│   ├── spotify/       # SpotifyClient, token store, music service repo
│   ├── settings/      # SharedPrefs settings repo
│   └── platform/      # Android MethodChannel bridge
└── presentation/
    ├── state/         # AppController (StateNotifier), providers
    ├── screens/       # 7 screens (main, trigger config, logs, etc.)
    └── widgets/       # Reusable UI components

like_spotify/
├── core/                 # Pure interfaces — no I/O, no platform code
├── extensions/           # Pluggable impls (spotify, tray_hotkey_trigger,
│                         #   supabase_storage, google_sheets_storage,
│                         #   archive_remove, promote_to_best_of,
│                         #   follow_artist, like_cooldown)
├── hosts/
│   ├── windows/          # Resident tray + global hotkey + autostart
│   ├── _stub.py          # macOS / Linux CLI fallback (like-once only)
│   ├── _common.py        # Config I/O + storage/action builder registries
│   └── _setup.py         # Interactive `--setup` wizard
└── samples/              # Alt-flavor examples

android/app/src/main/kotlin/.../
├── MediaButtonForegroundService.kt  # Background service
├── MediaEventPatternDetector.kt     # Pattern matching (Kotlin mirror)
├── SpotifyLikeWorker.kt             # WorkManager job
├── PlaybackNotificationListenerService.kt
├── MediaButtonReceiver.kt
├── BootCompletedReceiver.kt
├── MainActivity.kt
└── AppConstants.kt
```

## Commands

```bash
flutter pub get           # Install dependencies
flutter analyze           # Lint check
flutter test              # Run all tests
flutter test --coverage   # Run tests with coverage
flutter build apk --release                                         # Build APK (credentials typed in-app)
flutter build apk --release --dart-define-from-file=.env            # …or seed credentials from .env

pip install -e .[dev]     # Desktop: install with dev extras
pytest                    # Desktop: run Python tests
like-current-song --setup # Desktop: interactive config wizard
```

## Key files

| What | Where |
|------|-------|
| Entry point | `lib/main.dart` |
| State machine | `lib/presentation/state/app_controller.dart` |
| Core algorithm | `lib/domain/services/signal_pattern_matcher.dart` |
| Spotify OAuth | `lib/data/spotify/spotify_client.dart` |
| Repository interfaces | `lib/domain/repositories/` |
| Android service | `android/.../MediaButtonForegroundService.kt` |
| Constants | `lib/core/app_constants.dart` |
| Desktop interfaces | `like_spotify/core/` |
| Desktop pipeline | `like_spotify/core/pipeline.py` |
| Desktop builder registries | `like_spotify/hosts/_common.py` |
| Setup wizard | `like_spotify/hosts/_setup.py` |

## Testing

- Framework: `flutter_test` + `mocktail`
- Tests mirror source structure: `test/domain/`, `test/data/`, `test/presentation/`
- Domain layer tests are pure (no mocks needed)
- Data/state layer tests mock repository interfaces with `mocktail`
- Run: `flutter test`

Desktop:

- Framework: `pytest` + `pytest-asyncio`, tests under `tests/`
- `Storage` impls join the parametrised contract suite in
  `tests/test_storage_contract.py` — seven shared invariants for free
- Run: `pytest`

CI (`.github/workflows/ci.yml`) runs both: a `test` job (Flutter, ubuntu) and a
`pytest` job (Windows).

## Spotify setup

Requires a Spotify Developer App:
1. Create app at https://developer.spotify.com/dashboard
2. Set redirect URI: `likespotify://auth-callback` (fixed — it is the Android
   intent filter, exposed as `AppConstants.spotifyRedirectUri`)
3. Paste the Client ID into the app, under *Connected services* → Spotify
   credentials. It is kept in `FlutterSecureStorage` under `spotify_client_id`
   and read lazily, so a prebuilt APK works.
4. Optional shortcut for your own builds: copy `.env.example` to `.env` and
   build with `--dart-define-from-file=.env`. Those values only *seed* a store
   that has never been written; whatever the UI saved wins afterwards
   (`_seedCompileTimeCredentials` in `lib/main.dart`).

## OSS conventions

Public repo — outside contributors are a real audience:

- `CONTRIBUTING.md` is the plugin-author guide; keep it true when seams change.
- `CHANGELOG.md` (Keep a Changelog) gets an `Unreleased` entry per user-facing
  change; release notes are derived from it.
- Security problems go through GitHub private advisories, never a public issue
  (`SECURITY.md`).
- PRs need a linked issue in the body (`Closes #N`) or the `[no-issue]` marker —
  enforced by `.github/workflows/pr-body-check.yml`.
- Issue labels use the `domain:android` / `domain:desktop` / `domain:backend`
  axis plus `area:docs` / `area:quality`.
