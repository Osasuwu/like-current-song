# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

No prebuilt APK is attached to any release — build your own with your own
Spotify/Supabase credentials (see [README](README.md)).

## [Unreleased]

### Added

- **Desktop: settings window** ([#100](https://github.com/Osasuwu/like-current-song/issues/100)).
  `like-spotify --settings`, or **Settings…** in the Windows tray menu, opens
  a window that covers everything `--setup` does. That includes the music
  service and account sign-in, hotkeys, sound volume, counter storage and
  autostart. A collapsed **Extra actions** section holds archive clean-up,
  best-of, follow artist and like cooldown, each with a one-line hint and
  off on a fresh install. Saves from the tray apply live, with no restart.
  If the new config isn't ready yet, the old settings stay active; if a
  change can't be applied live, the tray offers a restart. Unknown keys in
  `config.json` are preserved. A first launch with no config now offers to
  open the window instead of only pointing at `--setup`. Built on the
  standard-library tkinter, so there's no new dependency.
- **Desktop: YouTube Music support (beta, Windows).** Pick "Music service" →
  `ytmusic` in `like-spotify --setup`. The hotkey likes whatever is playing in
  the YT Music tab or app: now-playing comes from the Windows media session, the
  song is matched through the YouTube Data API, and the like lands in YT Music's
  Liked music. You bring your own Google OAuth client; see
  [the extension README](like_spotify/extensions/ytmusic/README.md). The
  Windows installer now includes the `ytmusic` extra. Playlist actions
  (archive-remove, best-of, follow-artist) stay Spotify-only.

### Changed

- **README leads with the problem it solves**: liking a Spotify song with the
  phone screen off (headphone pause-play) or with a global hotkey on Windows.
  Adds an FAQ, a short Russian summary, and BeatBind / Spotikey / SpotiLike-GUI
  to the comparison table.
- **Repository renamed to `like-current-song`** (was `like_spotify_mobile_app`),
  so the name covers more than one music service once YouTube Music support
  lands. Old URLs redirect. The `like-spotify` package and CLI names are
  unchanged for now.
- **Android: feedback sound volume defaults to 100%** (was 25%, about −37 dB
  below media volume and inaudible over music). Existing installs keep their
  saved value.

### Fixed

- **Android: the listener survives swiping the app out of recents.** Some OEM
  shells (MIUI / HyperOS) tear the foreground service down together with the
  task. The service now re-asserts itself and queues a restart when the task is
  removed. A system-initiated kill also no longer clears the "enabled" flag, so
  the service still comes back after a reboot.
- **Android: like feedback tone and vibration are back on HyperOS 3 / Android 16.**
  The tone was released immediately after starting, which the newer audio stack
  cuts to its first ~20 ms buffer; it now plays in full. The vibration is tagged
  as media feedback, so it is no longer dropped when system touch haptics are
  off.

## [1.0.3] - 2026-09-01

### Fixed

- **Desktop: no more console flashes.** The packaged entry point is now a
  windowed `gui-scripts` entry, so the tray host no longer spawns a visible
  console window on launch or on each hotkey press ([#68](https://github.com/Osasuwu/like-current-song/issues/68)).

### Changed

- Repo baseline synced — CI workflows, PR body check, and owner-queue guard
  brought in line with the shared template ([#65](https://github.com/Osasuwu/like-current-song/pull/65)).

### Documentation

- Added `CODE_OF_CONDUCT.md`, `SECURITY.md`, this changelog, a feature-request
  issue template, and README status badges; corrected a stale CI claim in
  `CONTRIBUTING.md` ([#70](https://github.com/Osasuwu/like-current-song/issues/70)).

## [1.0.2] - 2026-08-13

Desktop crash fix plus the close-out of a five-finding architecture review pass.
No user-facing behavior changes beyond the crash fix.

### Fixed

- **Tray beep crash.** `winsound` rejects `SND_MEMORY | SND_ASYNC` outright, so
  every like/error beep on desktop crashed with
  `RuntimeError: Cannot play asynchronously from memory`. Dropped the redundant
  `SND_ASYNC` flag — `_beep` already runs on its own daemon thread.
- Like-cooldown gate and recorder now share one store, removing a fragile
  pre/post-action coupling that risked silent desync between the dedup check and
  the record write ([#57](https://github.com/Osasuwu/like-current-song/issues/57)).

### Changed

- `hosts/windows.py` split into a package — tray feedback, tone synthesis,
  autostart, and resident wiring each got their own module instead of one
  687-line grab-bag ([#55](https://github.com/Osasuwu/like-current-song/issues/55)).
- `hosts/_common.py` decomposed into a builder registry; the interactive
  `--setup` wizard extracted to its own module. Adding an extension is now one
  function plus one registry entry, not a new `if`/`elif` branch
  ([#58](https://github.com/Osasuwu/like-current-song/issues/58)).
- `PlaylistCapableProvider` protocol replaces three independent duck-typing
  checks with one structural-typing `Protocol`, applied consistently across the
  remove-from-playlist pipeline, archive-remove action, and follow-artist action
  ([#59](https://github.com/Osasuwu/like-current-song/issues/59)).

### Added

- Regression tests for `TrayFeedback._beep` / `_synth_tone`, covering the crash
  above ([#56](https://github.com/Osasuwu/like-current-song/issues/56)).

## [1.0.1] - 2026-08-06

### Added

- **Like cooldown / dedup.** A 10-minute (configurable) cooldown against
  accidental repeat-likes on the same track — two presses seconds apart during
  one listen now count as one like instead of two.
  - *Android*: `RuleConfig.likeCooldownEnabled` / `likeCooldownMinutes`
    (default 10). Checked before liking, recorded only after the real Spotify
    like call succeeds — mirrored in the native Kotlin WorkManager background
    path.
  - *Desktop*: `like_spotify/extensions/like_cooldown`, a pre/post action pair
    backed by a local JSON store under `~/.like_spotify/`. No Storage or network
    round-trip; same 10-minute default.

## [1.0.0] - 2026-08-05

First tagged release.

### Added

- Android and Windows media-button triggers for Spotify like/unlike, playlist
  archiving, best-of promotion, and artist auto-follow.
- Desktop tray feedback tone — synthesized, distinctive, volume-configurable
  via `trigger.feedback_volume` in `~/.like_spotify/config.json`.
- Matching Android feedback-volume setting in the Trigger configuration screen.

[Unreleased]: https://github.com/Osasuwu/like-current-song/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/Osasuwu/like-current-song/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/Osasuwu/like-current-song/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Osasuwu/like-current-song/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Osasuwu/like-current-song/releases/tag/v1.0.0
