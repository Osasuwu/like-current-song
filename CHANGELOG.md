# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases from v1.1.0 on carry a signed Android APK. It ships with no
credentials of its own: you paste your Spotify Client ID into the app after
installing (see [README](README.md)). Building it yourself still works and is
still the only option for the desktop half.

## [Unreleased]

### Added

- **Android: the Logs screen now shows what happened while the app was
  closed.** Background events — a like triggered with the app swiped out of
  recents, and every failure behind it — were broadcast to a receiver that
  only exists while the app is open, so they were thrown away unseen. That is
  precisely the case the background service exists for, which made it the one
  case you could not diagnose. Those events are now kept on the device and
  appear on the Logs screen the next time you open the app, with the time they
  actually happened rather than the time you opened it. Only events that found
  no open app are kept, so nothing is listed twice; the last 200 are held, and
  anything that looks like a credential is redacted before it is written.
- **Android: every log entry now says when it happened.** The Logs screen
  never showed a time, which was survivable while everything on it had just
  happened in front of you. Now that a line can be days old, each one carries
  its own clock time — plus the date once it is not from today.
- **Desktop: choose where a like goes.** A like used to mean exactly one
  thing — the music service's own like. It now has three settings: *Like on
  the music service* (the default, unchanged), *Add to a playlist* of your
  own, or *Both*. This matters most on YouTube Music, where the native like
  drops the song into the same bucket as every liked video, so a playlist is
  the only song-only list you can keep; on Spotify it is a way to collect
  likes somewhere other than Liked Songs. Pick it in `like-current-song
  --setup` (the new step 2) or in the settings window, under *Where a like
  goes*; in `config.json` it is `like.destination` (`native` / `playlist` /
  `both`) plus `like.playlist_name`. The playlist is created on first use if
  it doesn't exist. **An existing config keeps behaving exactly as it did** —
  no `like` block means the service's own like, as before. With *Both*, a
  like that lands in only one of the two places still counts and tells you
  which half failed, rather than reporting a failure you'd have to guess at.
  A playlist destination on a service that has no playlist API is refused when
  the config is read, with a message naming the service, instead of failing on
  every press.
- **Android: choose where a like goes.** A like always meant one thing — Liked
  Songs on Spotify, a thumbs-up on YouTube Music. *Trigger configuration* now
  opens with **Where likes go**, and it has three settings: *Liked songs* (the
  default, exactly what the app did before), *A playlist*, or *Both*. It matters most on YouTube Music, where a thumbs-up drops the song
  into the same bucket as every video you have ever liked, so a playlist is the
  only song-only list you can keep; on Spotify it is a way to collect likes
  somewhere other than Liked Songs. The playlist is matched **by name on
  whichever service played the song** — one name, so a phone that switches
  between Spotify and YouTube Music keeps filling the list it is on — and it is
  created on first use if it isn't there yet. The setting reaches the headphone
  trigger as well as the in-app button, so a like fired with the screen off
  lands in the same place. With *Both*, a like that only made it to one of the
  two still counts, and the Logs screen names the half that failed instead of
  reporting a failure you would have to guess at. On YouTube Music a playlist
  destination spends about 50 of the 10,000 daily API units per like, which the
  setting says on screen. **An existing install keeps behaving exactly as it
  did**: saved settings with no destination in them read back as the service's
  own likes.
- **The shared like counter can make its own spreadsheet.** Setting the counter
  up used to start with homework: open Google Sheets, make a file, name a tab
  `Likes`, type five column headers exactly right, add an `ArtistTracks` tab,
  then find the id in the URL — and getting a header wrong failed later, in a
  background job, as a like that quietly did not count. Now every entry point
  offers to do it for you. On Android it is a **Create spreadsheet** button in
  *Connected services* → *Shared like counter*, which shows the new sheet's id
  and a link to open it. On the desktop it is the `create` answer in
  `like-current-song --setup` (now the default, and asked *after* the Google
  sign-in rather than before it) and a **Create spreadsheet** button in the
  settings window. Both tabs and both header rows come out right by
  construction. **Pasting an id still works everywhere** — it is how a second
  device joins a count that already exists, and the setup wizard's third
  answer, `skip`, leaves the counter off entirely. No new Google permission is
  involved: the `spreadsheets` scope the counter already asks for is what
  allows it, and the app still cannot see any other file in your Drive.
  Whichever half you are on, once a spreadsheet is configured, asking again
  tells you so instead of quietly making a second one and splitting your counts
  across two files.

- **Desktop: the second hotkey now also tells the service “not this one”.**
  `Ctrl+Shift+Alt+Q` used to do exactly one thing — take the playing track back
  out of your archive playlist. It still does that, and in the same press it
  now sends the strongest negative signal your music service actually
  supports. On YouTube Music that is a real thumbs-down (`videos.rate` with
  `rating=dislike`), which also clears a like you had on the track. On Spotify
  there is nothing to send: **the Web API has no dislike endpoint at all**, and
  the “Hide this song” control in the official clients is not exposed to
  third-party apps — so there the press removes the track from your Liked
  Songs, which is the strongest honest negative available, and the feedback
  says which of the two happened. The two halves are independent: if the
  playlist removal fails the dislike still goes out, and the message names what
  actually happened (“Disliked and removed from Archive”, “Disliked — could
  not remove from Archive”, “Nothing changed”). Because a dislike needs no
  playlist, the hotkey now registers for a dislike-capable service even with
  **no archive playlist configured**; before, that combination left you with no
  second hotkey at all. **No new key combination was added.** The tray menu
  item, the startup balloon and the CLI all describe what one press will do on
  your setup; the CLI command is now `like-current-song discard-once`, and the
  old `remove-once` keeps working as an alias so existing AutoHotkey / Stream
  Deck bindings are unaffected.

- **Desktop: the discard hotkey now also empties your like destination.** If
  your likes go to a playlist of your own (`like.destination` = `playlist` or
  `both`, new above), changing your mind used to be half a job:
  `Ctrl+Shift+Alt+Q` disliked the track and took it out of your archive
  playlist, but left it sitting in the very playlist the like had just put it
  in, and the only way to take it out was to open your music service and do it
  by hand. The same press now removes it from that playlist too, as a third
  independent leg: any one of the three failing never costs the other two, and
  the notification names each one — *“Disliked, removed from Archive and
  removed from My Songs”*, or *“Disliked and removed from Archive — not
  removed from My Songs”* when only the last one failed. If your archive
  playlist and your like destination are **the same playlist**, the track is
  removed once and reported once, rather than twice. A `native` destination —
  the default, and what every config without a `like` block resolves to —
  changes nothing whatsoever, and because a destination playlist is by itself
  a reason for the hotkey to exist, it is now wired even on a service with no
  dislike and no archive playlist configured. **No new key combination, no new
  setting**: it follows the like destination you already chose.

### Fixed

- **Android: the shared counter sheet no longer grows a second row for a track
  instead of counting on the first.** The row *is* the counter, so once a
  track had two of them its count was split for good — every later like went
  to one row or the other, and the total you saw stayed permanently below the
  number of likes, with nothing saying so. Two ways in: two likes of the same
  track close enough together both found "no row yet" and both added one; and
  the app's in-memory picture of the sheet, once loaded, never learned about
  rows the background half had added since, so it added a row of its own on
  top. Likes are now counted one at a time, and a track the app believes is
  new is looked up on the sheet again before any row is added. Sheets that
  already carry a duplicate keep counting on the topmost of the two rows —
  the same one the background half picks, so the two stop drifting further
  apart — and the Logs screen now names the rows to merge, once per track.
  The spare row is never deleted for you; adding the two counts up and
  removing one row by hand restores the real total.

- **Android: a failed like now says which step failed.** Everything a
  background like does happens under one safety net, and that net filed every
  failure the same way: *Like failed*, under `like_track`, whatever had
  actually gone wrong. A Spotify token Spotify would not renew, a "what's
  playing" call that never came back, and a playlist the extra actions could
  not read were three different problems wearing one label, and the Logs
  screen — the only place you can see any of this — could not tell you which
  you had. Each step now names itself: the entry says *Like failed while
  refreshing the Spotify token*, or *while reading the current track*, and is
  filed under that step rather than under the like. Steps that run **after**
  the song is already liked say so too — *The track was liked, but running the
  extra actions failed* — instead of reporting a failed like you can see in
  Spotify was not one. For the same reason those steps now play the success
  tone rather than the failure buzz: the like did go through.

- **Android: the shared like counter now tells you why it could not count.**
  Every refusal from Google came out as "the counter is not signed in to
  Google. Sign in under Connected services", or on the Spotify path as nothing
  at all — the reason was written to a debug log that does not exist in a
  release build. The advice was wrong for most of the refusals, and following
  it could not help: if Google is rejecting your client ID or secret, signing
  in again uses the same rejected credentials. The counter now passes on what
  Google said. A sign-in you revoked still says to sign in again, because that
  is the one case where signing in again is the fix; a rejected client says so
  and points at the credentials fields; a refused scope, or a Google that
  could not be reached at all, each read as themselves. The like is counted on
  the device either way, as before.

- **Android: the shared like counter no longer hands out a dead Google token
  for ever.** A stored access token with no expiry recorded beside it was
  treated as one that never expires, so the background counter kept presenting
  a token that had died an hour after it was issued, and every like fell
  through to this device's own tally — with, until now, nothing said about it.
  A missing expiry now reads as *unknown, so renew it*, which is the reading
  that cannot silently rot. **This is a behaviour change, not only a wording
  one**: a counter sign-in in that state is renewed on its next like instead
  of being trusted indefinitely. Renewals now always record an expiry, falling
  back to Google's own hour when the reply leaves it out, so the new reading
  costs at most one renewal an hour rather than one per like.

- **Android: likes made in the app and likes made with the media button now
  count towards the same total.** The two halves of the app kept their own
  copies of every per-device counter, in two stores that never met, so anyone
  who used both input methods had each number split between them. The
  follow-artist rule was the worst off: it fires when an artist's count
  *equals* the threshold, and a count split across two stores could pass five
  without either half ever reaching it — the artist was then never followed at
  all, not merely followed late. The same split also meant the like cooldown
  did not apply between the two paths, so a track liked in the app could be
  liked again by a media button seconds later, and the promote-to-best
  fallback undercounted when no counter sheet was set up. There is now one
  store, shared by both halves; the counts you already had are added together
  on the first launch. Follow-artist also fires at or past its threshold
  rather than exactly on it, and remembers which artists it has followed so it
  still only fires once each. Counters kept in a Google Sheet were never
  affected and are unchanged.

- **Android: a like made with the media button now counts every artist on the
  track.** Only the first credited artist was counted, so a feature or a
  collaboration never moved the guest artist's total, while the same like made
  in the app moved both. The two paths now count alike, and match the desktop.

- **Android: turning on Automatic no longer looks like nothing happened below
  the switch.** Automatic is the absence of an explicit pick, but everything
  under it on *Connected services* — installed, connected, the account, the
  credentials fields, Connect and Disconnect — still belongs to the service you
  had picked before. With the pick no longer highlighted, those fields read as
  leftovers from the old selection, and it was easy to think the switch had not
  taken. That block is now headed with the service's own name, and under
  Automatic it says in one line why that service is the subject: it is the one
  a like falls back to when nothing is playing. The other service's
  credentials were also simply unreachable while Automatic was on, since
  reaching them meant picking it; there is now a *Set up …* button for each
  other service that does exactly that, and says up front that picking turns
  Automatic off.
- **The shared counter no longer writes some like counts as text.** Whether a
  count landed in your sheet as a number or as text depended on something you
  had no reason to think about: whether the app happened to be open when the
  like fired. Both halves write the same column, and the background one sent
  the number as a string, which Google Sheets stores as typed — so a column of
  counts came out half numbers, half text. The app read either without
  complaint, which is exactly why this went unnoticed: it only showed up in
  your own sheet, where `SUM` and sorting skip text cells and quietly give you
  a total that is too low. Counts now go out as numbers from both halves, and
  a text cell already on a sheet turns into a number the next time that track
  is liked.
- **A like stopped reaching a playlist you had deleted and recreated.** The
  app remembers a playlist's id under its name so it doesn't re-list every
  playlist you own on every like. Delete that playlist and the remembered id
  outlives it: Spotify answers `404` and the like goes nowhere, with nothing
  recovering — re-listing doesn't help, because a deleted playlist never
  comes back in the listing to overwrite the entry. With the app closed this
  lasted a full day, since the background half keeps the id on disk; with the
  app open it lasted until the next restart. Now a `404` drops the remembered
  id, resolves the name again — creating the playlist if it is really gone —
  and retries exactly once. A second failure is reported, not retried. The
  same happens on the archive and best-of legs and when removing a track,
  minus the retry, so the next like starts from a clean cache. The background
  log says `(after clearing a stale playlist id)` when a like was saved this
  way.
- **Android: a failed like with the app closed now says what failed.** When
  the app is swiped out of recents there is no window to show a log in, so
  everything the background path reported was simply dropped — a like that
  buzzed the failure tone told you nothing more than that. Those reports now
  also go to `adb logcat` under the tag `LikeCurrentSong`, so a failure can
  be diagnosed instead of guessed at (`adb logcat -s LikeCurrentSong:*`).
  Anything long enough to be an access or refresh token is replaced with
  `<redacted>` before it is written; track and playlist ids are short enough
  to survive, which is the point. Three failures that used to look identical
  now name themselves: no playlist name configured, a playlist that could be
  neither found nor created, and an error thrown on the way. The one failure
  tone that played with nothing logged at all — no access token left after a
  refresh — is logged too. These lines still do not reach the in-app Logs
  screen while the app is closed; carrying them across a restart is next.
- **Android: a like with the app closed no longer fails in silence.** If a
  Spotify request fell over mid-flight — a dropped connection, a reply that
  wasn't the JSON we expected — the background job died on the spot. You got
  no buzz and no log line, which looks exactly like the headset pattern never
  registering, so the only clue was the song not being liked. The job now
  reports what went wrong, buzzes the failure tone and stops. It deliberately
  does **not** retry later: it likes whatever is playing when it runs, so a
  retry minutes on would like the wrong song. Press again. The token refresh
  also got the same ten-second timeout the other calls already had, so a
  stalled refresh can't leave the job hanging.

- **Android: the headset pattern works again after you swipe the app out of
  recents.** Closing the app from the recents screen left the listener running
  and the notification in place, but every press of the pattern did nothing —
  no like, no log line, no error. The app tracks whether its Flutter side is
  listening so the background service knows whether to hand the like over or
  do it itself; that flag was only ever cleared when Flutter unsubscribed
  cleanly, which is not what happens when the system tears the app down.
  The service went on handing every like to a half that no longer existed.
  The flag is now cleared when the app is destroyed as well, so the service
  takes the like over itself, exactly as it does when the app was never
  opened.
- **Android: the listener survives a reboot again on Android 15 and newer.**
  If you had the listener switched on and restarted your phone, it stayed off
  until you opened the app by hand — the headset pattern simply did nothing,
  while the app still showed the listener as enabled. Android 15 stopped apps
  from starting a `mediaPlayback` background service at boot, and that is the
  kind the listener was declared as. It is now declared `specialUse`, which is
  both allowed at boot and an honest description: this app never plays
  anything, it listens for headset buttons and asks Spotify or YouTube Music to
  do the rest. A start the system still refuses — an OEM battery policy, say —
  now leaves the listener off instead of crashing the app during boot, and
  opening the app brings it back.

- **On Android, a like the counter could not record now says so on the Logs
  screen.** The phone failed the way the desktop used to, only more quietly:
  whatever stopped a like reaching your spreadsheet — a counter not signed in
  to Google, a music-service account it could not resolve, a Google project
  with the Sheets API switched off — the app showed a count that had quietly
  been kept on the device alone, and wrote nothing anywhere you could read it.
  (Its only trace went to logcat, which nobody has open on an installed
  build.) Every one of those now appears in **Logs** as a `like_count` line
  saying the like was counted on this device only and why, and the failures
  you can actually clear name the fix — the Sheets API one links the page that
  switches it on instead of quoting Google's JSON at you. The like itself is
  untouched: it still succeeds, and the local tally still stands in for the
  shared count. Having no counter set up at all stays silent, as before.

- **A like the counter could not record no longer passes for one that was.**
  With the shared like counter switched on, anything that stopped a like being
  counted looked exactly like having no counter at all: the desktop said
  "Liked", the count stayed where it was, and nothing was written anywhere.
  Every such failure now reaches the log, and the ones you can actually do
  something about say so on the like itself — "Liked — counter not updated",
  followed by what to fix. Today that is a Google project with the Sheets API
  switched off, which a counter set up by pasting a spreadsheet id runs into on
  its very first like and never got told about. A timeout or a server hiccup
  stays quiet, so a flaky connection does not nag you on every press. The like
  is untouched either way: it still succeeds, whatever the counter did.

- **A Google project with the Sheets API switched off now says so, and links
  the page that switches it on.** Setting the shared like counter up on a
  fresh Cloud project — or on the one you already made for YouTube Music,
  which the README suggests reusing — failed with a bare `403` and a wall of
  Google's JSON, on the Android *Create spreadsheet* button, in
  `like-current-song --setup`, and in the desktop settings window alike. The
  API has to be enabled once per project, and nothing said so. All four places
  now report it as "the Google Sheets API is not enabled on your Google Cloud
  project", name the project Google named, and give the console link that
  enables it — Google's own one-click URL when the refusal carried one, the
  API library page otherwise. Android turns that link into a button; the
  README's counter setup now starts with the same step, and no longer implies
  the credentials page can enable an API. A 403 for any other reason keeps the
  message it always had.

- **Likes reach the shared spreadsheet even with every playlist rule off.**
  Setting the counter up and liking a track left the sheet empty: the count in
  the app went up, but nothing was ever written, and nothing said why. The
  counter keys its rows by your Spotify user id, and that id was only ever
  looked up as a side effect of *creating a playlist* — so with the archive,
  best-of and follow-artist rules switched off, which is the default, there was
  never an id to key by and every like quietly stayed on the device. Both
  halves of the Android app now look the id up on the like itself. A failed
  lookup still counts locally rather than failing the like. Disconnecting
  Spotify, or signing in as someone else, now forgets the remembered id, so a
  second account's likes are no longer filed under the first account's row.

- **Android: the app no longer says it is listening when it cannot hear
  anything.** Notification access was presented as a *fallback*, so it was easy
  to leave off — and with it off a pause-play did nothing at all, while the
  service notification still read *Listening for headset pattern*. It is not a
  fallback: Android hands the headset button to the music app, so reading that
  player's pause/play state is the only way a press ever reaches us. The
  permissions screen now calls the grant **required** and says in one line why;
  the main screen says **NOT LISTENING** and offers a one-tap *Grant
  notification access* while it is missing; the ongoing notification says
  *Notification access is off — pause-play cannot reach the app*, with a
  *Grant access* action, and re-words itself the moment the grant changes
  rather than only at startup. The *Logs* screen gets a line about it too,
  instead of staying silent about why nothing happens.

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
  the code the app shows, and either create the sheet or give it the
  spreadsheet id from an existing sheet's URL.
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
