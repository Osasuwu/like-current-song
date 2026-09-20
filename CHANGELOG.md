# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases from v1.1.0 on carry a signed Android APK. It ships with no
credentials of its own: you paste your Spotify Client ID into the app after
installing (see [README](README.md)). Building it yourself still works and is
still the only option for the desktop half.

## [Unreleased]

### Fixed

- **Android: the trigger configuration screen no longer takes an empty
  pattern.** Clearing the *Pattern* field — or leaving only commas and spaces
  in it — saved a trigger with no events in it, and the background listener
  then matched nothing: pause-play quietly stopped liking anything, with
  nothing on screen to say why. Saving one is now refused with a message
  naming what is missing, and the in-app matcher, which read the same empty
  pattern as "match every play and pause", now agrees with the listener that
  it means "no trigger configured".

- **Liking a track works again for newly registered Spotify Client IDs.**
  Every write to Spotify's library — liking the current track and following an
  artist — failed with an API error (HTTP 400) unless your Client ID was old
  enough to still be served by the endpoints Spotify replaced in February 2026.
  The list of things to save was being sent in the request body when Spotify
  expects it in the query string, so the request never carried it. Affects the
  Android app and the desktop half alike. Failed library writes now also quote
  Spotify's own explanation in the log instead of only a status code.

### Changed

- **The "best-of" playlist rule is now just "best".** "Best of" reads like it
  wants a qualifier ("best of electronic"), but there is only ever one general
  best playlist, so the rule is called **best** everywhere: in the app and the
  desktop settings window, in `config.json` (`actions.promote_to_best`), in the
  docs, and in the code (`PromoteToBestAction`, `bestPlaylistName`,
  `rule_best_*`). **Existing settings migrate themselves** — an upgrade reads
  the old `bestOf*` / `rule_best_of_*` / `promote_to_best_of` spellings when the
  new ones are absent and writes only the new ones from then on, so nothing has
  to be re-entered. Playlist names you already have on Spotify are untouched.
  Log rows written from now on say `best_add`; older rows keep saying
  `best_of_add`.
- **Android: the shared like counter now counts in a Google Sheet.** It is the
  same sheet the desktop half writes — a `Likes` tab with the columns
  `user_id | track_id | count | backfilled | updated_at` — so a phone and a PC
  finally add up to one number. Set it up under *Connected services* → *Shared
  like counter*: paste a Google OAuth client, sign in on another device with
  the code the app shows, and give it the spreadsheet id from the sheet's URL.
  The counter signs in to Google separately from YouTube Music, with only the
  spreadsheets scope; the same OAuth client works for both once the Google
  Sheets API is enabled on its project. Leave the spreadsheet empty and likes
  are counted on this device only, exactly as before.
- **Android: builds can be seeded from `.env` again, for every service.**
  `flutter build apk --release --dart-define-from-file=.env` now understands
  `SPOTIFY_CLIENT_ID`, `YTMUSIC_CLIENT_ID`, `YTMUSIC_CLIENT_SECRET`,
  `COUNTER_SPREADSHEET_ID`, `COUNTER_GOOGLE_CLIENT_ID` and
  `COUNTER_GOOGLE_CLIENT_SECRET`. As before, a compile-time value only fills a
  field the app has never been told about: whatever you save in *Connected
  services* wins from then on, and a field you cleared on purpose stays clear
  across rebuilds.

### Removed

- **Android: the Supabase counter backend is gone**, along with the Supabase
  URL and anon key fields in *Connected services*. Google Sheets replaces it,
  matching the desktop half, which dropped Supabase in the same release.
  Like counts already stored on your phone are untouched and keep counting up;
  there is no automatic migration of numbers that lived in Supabase, so a sheet
  starts from what the phone knows. A track the service had already liked
  before its first press is seeded at 2 and flagged `backfilled`, the same rule
  the desktop half uses.

- **Desktop: the Supabase counter backend.** Google Sheets is now the only
  way to count likes across devices, and `like-current-song --setup` offers
  `sheets` or `none`. Supabase was a database to stand up and maintain for a
  counter that fits in a spreadsheet you already own.
  **If your `~/.like_spotify/config.json` still says `backend: "supabase"`**
  nothing breaks and nothing needs deleting: likes keep working exactly as
  before, but they are counted nowhere, and the desktop app says so once on
  startup. Run `like-current-song --setup` and pick `sheets` to get your
  counter back, or open **Settings…** — either one clears the startup notice,
  whether you switch to Sheets or leave the counter off. Note that counts do
  not carry over — the Sheet starts empty. Promote-to-best and follow-artist,
  which read those counts, stay off until a counter is configured. The
  Supabase schema file (`docs/supabase-setup.sql`) is gone too; existing
  Supabase projects are untouched and yours to keep or delete.

## [1.1.0] - 2026-09-20

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
- **Android: Automatic music service routing**
  ([#125](https://github.com/Osasuwu/like-current-song/issues/125)). Connected
  services has a new **Automatic** option that sends the like to whichever
  connected service is playing, instead of to one service you picked up front.
  It resolves in order: the one connected service with a playing media session;
  otherwise the last service that was playing; otherwise the service still shown
  in the picker. The same rule runs in the background listener, so it holds with
  the screen off and the app closed. Automatic is opt-in — upgrading leaves your
  current pick exactly as it was — and is only offered while notification access
  is granted and at least two services are connected; when it isn't, the picker
  is the only option and says which of the two is missing. If a service signs out
  or notification access is revoked, the app falls back to the picker on its own.
  Each automatic like logs the service it went to and why, on the Logs screen.
  Spotify-only setups are unaffected and still need no notification access.
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
- **Android: Spotify credentials are typed into the app, not baked into the
  build** ([#131](https://github.com/Osasuwu/like-current-song/issues/131)).
  *Connected services* now has a **Spotify credentials** section: a link to the
  dashboard, one Client ID field (the PKCE flow needs no secret), and the
  redirect URI to paste into the dashboard, selectable and with a copy button.
  **Connect Spotify** stays off until a client ID is saved, and says so. The ID
  lives in `FlutterSecureStorage` and survives a disconnect, so reconnecting
  does not mean retyping it. This is what makes an APK you did not build
  yourself usable.
- **Android: the shared like counter is configurable in the app.** A secondary
  **Shared like counter (optional)** section takes a Supabase project URL and
  anon key. Leaving both blank keeps counts on the device; saving pushes the
  new config to the native listener straight away, with no restart.

### Changed

- **The app is called Like Current Song everywhere it is visible.** The project
  was renamed, and since it started liking on YouTube Music too the old name
  was also wrong on the facts, but the Android launcher icon, the notification,
  the Windows tray and settings window, the installers and the docs still said
  *Like Spotify*. They now all say *Like Current Song*, and the Spotify
  provider writes the same `Managed by Like Current Song` playlist description
  the YouTube Music one already did. Nothing that a machine reads changed: the
  `com.osasuwu.like_spotify` application ID, the `likespotify://auth-callback`
  redirect URI registered in everyone's Spotify dashboard, the notification
  channel ID, the `LikeSpotify` autostart entry and `~/.like_spotify` are all
  untouched, so this is a relabel and not an upgrade barrier.
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
- **Android: `.env` is now a convenience, not a requirement.** `flutter build
  apk --release` with no `--dart-define` produces a working APK.
  `SPOTIFY_CLIENT_ID`, `SUPABASE_URL` and `SUPABASE_ANON_KEY` still work: on
  first launch they *seed* a store that has never been written, so existing
  builds stay configured across the upgrade. From then on whatever
  *Connected services* saved wins, and a field you cleared stays cleared
  through a rebuild.
- **Release builds can be signed with a real keystore**
  ([#132](https://github.com/Osasuwu/like-current-song/issues/132)). Gradle now
  reads `android/key.properties` when it is there, and the build prints which
  key it used. Without that file nothing changes — the build still succeeds,
  debug-signed, which is all a local test needs — but a debug-signed APK can
  never be upgraded in place by a build from another machine, so it must not be
  published. Groundwork for attaching a prebuilt APK to a release.

### Removed

- **Android: the `SPOTIFY_REDIRECT_URI` build variable.** It was never really
  configurable — the value has to match the `likespotify://auth-callback`
  intent filter in the manifest — so it is now a constant the credentials
  screen shows you. Drop it from your `.env`; it is ignored.

### Fixed

- **Android: the bottom of a screen no longer hides under the navigation bar**
  ([#139](https://github.com/Osasuwu/like-current-song/issues/139)). Flutter
  draws edge-to-edge on Android 15+, so a screen ran all the way under the
  gesture pill and whatever sat at the bottom of it was half covered — most
  visibly the **Shared like counter** section, the last row of *Connected
  services*, which could not be scrolled clear. Scrolling screens now add the
  bar's height to their own padding, so the content scrolls past it; fixed
  screens keep clear of it.
- **Android: the MIUI battery instructions dropped the Recents lock.** Step 3
  told you to lock the app in Recent apps, which has not been necessary since
  the listener learned to restart itself after a swipe-away. Auto-start and
  "No restrictions" are still the two that matter.
- **Likes and artist follows keep working on newly registered Spotify apps**
  ([#121](https://github.com/Osasuwu/like-current-song/issues/121)). Spotify's
  February 2026 migration replaced the per-type library endpoints (`PUT
  /me/tracks`, `PUT /me/following`, `GET /me/tracks/contains`) with one generic
  `/me/library` that takes Spotify URIs, and client IDs created since then only
  get the new form. Android (both the app and the background like worker) and
  the desktop app now call the generic endpoint, and fall back to the old one
  when Spotify says this client ID does not have it — so the client IDs that
  were grandfathered onto the old endpoints keep working too. The fallback is
  remembered for the rest of the session, so at most one like per run pays for
  the extra request, and rate limits and expired tokens still surface exactly
  as before.
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
- **Android: the YouTube Music sign-in can be set up from the phone**
  ([#118](https://github.com/Osasuwu/like-current-song/issues/118)). The block
  used to point at the README with no way to reach it, so a user holding only
  the phone was stuck at two empty fields. It now links straight to the Google
  Cloud credentials page and to the README's setup steps, says the client must
  be of type "TVs and Limited Input devices" with YouTube Data API v3 enabled,
  explains that **Connect YouTube Music** stays off until the client ID and
  secret are saved, and says the sign-in code `google.com/device` asks for
  appears only after Connect.

### Documentation

- **Project home page, privacy policy and terms published**
  ([#126](https://github.com/Osasuwu/like-current-song/issues/126)). Three
  static pages under `docs/`, served by GitHub Pages at
  <https://osasuwu.github.io/like-current-song/>. Google requires all three,
  on a verified domain, before an OAuth app can leave Testing mode — which is
  what limits YouTube Music sign-in to a 7-day refresh token today. The
  privacy policy is written from the code rather than from a template: it
  names every Spotify scope the app asks for, says plainly that the scope set
  is fixed and requested in full at sign-in (the in-app toggles gate what the
  app *does*, not what it is allowed to do), names both Google scopes
  (`youtube` and `openid`) and what each is for, and describes the optional
  shared counter as the only request that ever leaves the device.

- **Setup docs corrected for the 2026 platform limits**
  ([#120](https://github.com/Osasuwu/like-current-song/issues/120),
  [#122](https://github.com/Osasuwu/like-current-song/issues/122),
  [#123](https://github.com/Osasuwu/like-current-song/issues/123)). The
  YouTube Music steps told users to **Publish app**, which no individual can
  do — Google requires a home page, privacy policy and terms on a
  Search-Console-verified domain for every external production app. Both
  READMEs now describe the Testing + *Test users* path instead, say plainly
  that the refresh token then expires after 7 days, lead with the fact that
  YT Music sign-in is optional (the thumbs-up needs no Google account), and
  warn that the client secret is shown only at creation and otherwise has to
  be rotated under **Google Auth Platform → Clients → Add Secret**. The
  Spotify section now lists the development-mode limits in force since
  February 2026: Premium required for the app owner, 5 allowlisted users, one
  Development Mode Client ID per developer, extended quota mode unavailable to
  individuals — plus the 403-after-a-successful-login symptom that follows
  from the allowlist. `CONTRIBUTING.md` repeats the one-client-ID limit for
  contributors. Finally, the YouTube quota figures were stale: since
  2026-06-01 `search.list` has its own 100-calls-a-day bucket, separate from
  the 10,000 units a day shared by the other endpoints, so the counted-like
  cost and the Extra actions note (in the README and in the app) are
  rewritten around the two buckets.

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

[Unreleased]: https://github.com/Osasuwu/like-current-song/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Osasuwu/like-current-song/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/Osasuwu/like-current-song/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/Osasuwu/like-current-song/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Osasuwu/like-current-song/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Osasuwu/like-current-song/releases/tag/v1.0.0
