# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

No prebuilt APK is attached to any release — build your own with your own
Spotify/Supabase credentials (see [README](README.md)).

## [Unreleased]

### Added

- **Desktop: settings window** ([#100](https://github.com/Osasuwu/like-current-song/issues/100)).
  `like-current-song --settings`, or **Settings…** in the Windows tray menu, opens
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
  `ytmusic` in `like-current-song --setup`. The hotkey likes whatever is playing in
  the YT Music tab or app: now-playing comes from the Windows media session, the
  song is matched through the YouTube Data API, and the like lands in YT Music's
  Liked music. You bring your own Google OAuth client; see
  [the extension README](like_spotify/extensions/ytmusic/README.md). The
  Windows installer now includes the `ytmusic` extra.
- **Desktop: playlist actions work with YouTube Music.** Archive-remove (and
  the remove-without-like hotkey), promote-to-best-of and follow-artist now run
  under the `ytmusic` provider as well as Spotify. Playlists are your ordinary
  YouTube playlists. Follow-artist subscribes to the artist's channel, but only
  when the matched song came from the artist's own "Topic" channel or a channel
  named after them. `--setup` now offers the playlist clean-up step for
  YT Music too. Each write costs about 50 units of the daily YouTube API quota.
  The `youtube` scope already granted covers the writes, so no re-login is
  needed.
- **Android: Music service picker.** Connected services now lets you choose
  Spotify (the default) or YouTube Music; the ids match desktop's
  `music.provider`. The choice also decides which app's playback the listener
  follows and which app "installed" checks and launches. With YouTube Music
  selected nothing is ever sent to Spotify.
- **Android: YouTube Music sign-in.** Connected services takes the client ID
  and secret of your own Google "TVs and Limited Input devices" OAuth client.
  **Connect** then shows a code to enter at google.com/device, with copy and
  open-in-browser buttons. Declined, expired and cancelled sign-ins show a
  plain message. The account id is shown once you are connected. Tokens are
  kept apart from Spotify's, so switching services keeps both signed in. The
  access token refreshes silently and is handed to the background listener.
  Setup steps are in the [README](README.md#youtube-music-android).
- **Android: YouTube Music likes, screen off.** With YouTube Music selected, the
  trigger gives the playing song a thumbs-up through the YT Music app's media
  session — no sign-in needed, same feedback tone, vibration and like cooldown
  as Spotify. A song that is already liked counts as a success and is never
  toggled off. If the session rating doesn't take and you have signed in to
  YouTube Music, the like falls back to the YouTube Data API (same song match as
  desktop); a used-up daily quota is logged as rate-limited, and a revoked
  sign-in posts a "Sign in to YouTube Music again" notification. Offline likes
  are never queued for YouTube Music (a later replay would like whatever is
  playing then), and queued Spotify likes are only ever replayed on Spotify.
- **Android: YouTube Music likes count in the shared counter**
  ([#96](https://github.com/Osasuwu/like-current-song/issues/96)). A YouTube
  Music like now adds to the same cross-device counter Spotify likes use, so
  the log line shows the running total ("x3") and the phone and the desktop
  app add to one count per account. Counting needs you to be signed in to
  YouTube Music (the count is keyed by that account, never mixed with your
  Spotify one) and a Supabase counter configured; otherwise the like just
  isn't counted. Counting happens after the like, so a counter that is down
  never turns a successful like into a failure — it only shows up in the log.
  Each counted like costs one YouTube Data API search (100 quota units),
  reusing the match the like itself made for the same song.
- **Android: extra actions work with YouTube Music**
  ([#98](https://github.com/Osasuwu/like-current-song/issues/98)). Remove from
  archive playlist, promote to best-of playlist and auto-follow artist now run
  under YouTube Music as well as Spotify, from the same switches and with the
  same thresholds; all three stay off on a fresh install. Playlists are your
  ordinary YouTube playlists, matched by name and created (private) if the
  best-of one doesn't exist yet. Auto-follow subscribes to the artist's
  channel, but only when the matched song came from their own "Topic" channel
  or a channel named after them, and an already-followed channel is not an
  error. Best-of uses the shared like count the counter just returned rather
  than counting again. The actions reuse the match the like already made, and
  playlist ids are cached, so each one costs about 50 units of the 10,000-unit
  daily YouTube API quota — the settings section now says so. Nothing here
  touches the network unless you turned an action on, and a failed action is
  logged and never turns a successful like into a failure.

### Changed

- **Desktop: the package and commands are now `like-current-song`**
  ([#101](https://github.com/Osasuwu/like-current-song/issues/101)).
  The pip/pipx package is `like-current-song`, and the commands are
  `like-current-song` and `like-current-song-gui`. The old `like-spotify` and
  `like-spotify-gui` commands still work for at least one more release. The
  console one prints a one-line note first; the windowed one stays silent.
  Your config and tokens stay in `~/.like_spotify/`, and the Python import
  name is still `like_spotify`.
  **To upgrade**, re-run `install.ps1` or `install.sh`. It removes the old
  `like-spotify` pipx package, then installs the new one. By hand:
  `pipx uninstall like-spotify`, then `pipx install` the repo again. On
  Windows, an autostart entry from an older version is moved to
  `like-current-song-gui` the next time the tray starts, or when `--setup`
  asks about autostart. Update any scripts or hotkey tools that call the old
  names.

- **Desktop: `PlaylistCapableProvider` gained `find_or_create_playlist` and
  `add_track_to_playlist`.** Promote-to-best-of now checks the protocol
  instead of `SpotifyMusicProvider`, so any provider that implements all six
  methods gets every playlist action. A third-party provider that implemented
  only the old four methods no longer matches the protocol, and all three
  actions go quiet for it until it adds the two new methods.

- **README leads with the problem it solves**: liking a Spotify song with the
  phone screen off (headphone pause-play) or with a global hotkey on Windows.
  Adds an FAQ, a short Russian summary, and BeatBind / Spotikey / SpotiLike-GUI
  to the comparison table.
- **Repository renamed to `like-current-song`** (was `like_spotify_mobile_app`),
  so the name covers more than one music service once YouTube Music support
  lands. Old URLs redirect. The `like-spotify` package and CLI names are
  unchanged for now.
- **Android: extra actions are opt-in and live in a collapsed "Extra actions"
  section.** Archive-remove, best-of promotion and artist auto-follow moved out
  of the main trigger settings. Each has a one-line hint saying what it does
  and what to fill in. On a fresh install all three are **off** with empty
  playlist names (they used to be on, pointed at "Discover Weekly Archive" and
  "Botbotb(Best of the best of the best)"). Existing installs keep what they
  had, including the old all-on behaviour if the rules were never touched.
  An action that is off, or has no playlist name, is skipped by the background
  worker too.
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
- **Android: two screens no longer speak as if Spotify were the only service**
  ([#113](https://github.com/Osasuwu/like-current-song/issues/113)). Permissions
  now lists internet access for whichever service is selected, instead of always
  naming Spotify. The queued-likes line on the main screen promised a retry
  "when online" even under YouTube Music, which neither queues likes nor replays
  the queue; under YouTube Music it now says the queued Spotify likes retry once
  Spotify is selected again.

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
