# Like Current Song — save the Spotify song you're hearing without touching your phone

[![CI](https://github.com/Osasuwu/like-current-song/actions/workflows/ci.yml/badge.svg)](https://github.com/Osasuwu/like-current-song/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Osasuwu/like-current-song)](https://github.com/Osasuwu/like-current-song/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/python-3.11%2B-blue)](pyproject.toml)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](CONTRIBUTING.md)

Heard a song you love while your phone is in your pocket with the screen off? **Pause and resume it with your headphone button** (e.g. pause → play), and the track is saved to your Spotify **Liked Songs**. You don't unlock the phone, look at the screen, or open the Spotify app.

At your computer, a **global keyboard shortcut** does the same thing: press `Ctrl+Shift+Alt+W` while your music plays in the background, and the current song is liked without switching away from the app you're working in.

- **Android**: works with the screen off and the phone locked. It reacts to the pause/play state of whatever is playing, so anything that pauses and resumes playback can trigger it: wired or Bluetooth headphones, earbud taps, a smartwatch, or a car stereo. The pattern is configurable, and a short sound confirms the like.
- **Windows**: a tray app with a global hotkey to like the current track, plus a second hotkey to remove it from a playlist. Spotify, or YouTube Music in beta.
- **macOS / Linux**: a `like-current-song like-once` command you can bind to any shortcut.
- **Two music services**: Spotify, and YouTube Music (beta on Windows, and on Android with no Google sign-in needed). On Android you can also let it pick whichever one is actually playing.
- **Beyond "like"** (optional rules): remove the track from a Discover Weekly archive playlist, promote it to a "best" playlist after you like it N times across devices, and auto-follow an artist after N liked tracks. The counts live in a Google Sheet you own, so your phone and computer see the same numbers.

Open source (MIT). It talks to your music service through that service's official API, using a developer app you create yourself. There's no UI scraping, and your tokens stay on your devices.

For developers: the desktop side is a **pluggable framework** with five extension points (`Trigger`, `MusicProvider`, `Storage`, `PreLikeAction`, `PostLikeAction`). Nine extensions ship across those five seams, plus one skeleton, each a folder under `like_spotify/extensions/` with a `manifest.json` describing it. Adding one is a builder function and a registry entry, not a new branch in a dispatcher. See [CONTRIBUTING.md](CONTRIBUTING.md).

## FAQ

### Can I like a Spotify song without unlocking my phone?
Yes, that's the main use case. Install the Android app, connect Spotify, and turn on the listener service. With the screen off, do the trigger pattern with your headphone button (default: pause, then play within a short window), and the current track goes to Liked Songs.

### Does it work with Bluetooth headphones, earbuds, or a smartwatch?
Yes. The app watches Spotify's playback state rather than one specific button, so any device that pauses and resumes Spotify works.

### Is there a global keyboard shortcut to like the current Spotify song on Windows?
Yes. The Windows tray host binds `Ctrl+Shift+Alt+W` (configurable) to "save current track to Liked Songs", and it works while Spotify is minimized or in the background. On macOS and Linux, bind `like-current-song like-once` to a shortcut in your OS settings, Raycast, skhd, or similar.

### Can it add the song to a playlist too, not only Liked Songs?
Yes, through the rule engine: it can promote a track to a "best" playlist after N likes and remove it from an archive playlist. New actions are small Python plugins.

### Does it work with YouTube Music?
Yes, on both halves. On Android it is built in and needs **no Google sign-in**: the trigger gives the playing song a thumbs-up through YT Music's own media session. On Windows it is in beta — pick `ytmusic` during `--setup` and connect your own free Google OAuth client. If you use both services, Android can send each like to whichever one is currently playing.

### Do I have to use Spotify?
No. Spotify and YouTube Music are equal citizens: the desktop side reaches each one through a `MusicProvider` extension, and adding a third is a plugin, not a fork.

### Does it work on iPhone?
No. iOS doesn't let third-party apps observe another app's playback in the background. Android and desktop only.

## По-русски

**Like Current Song** лайкает играющий трек — в Spotify или YouTube Music — не доставая телефон: нажмите пауза → плей на наушниках, и песня попадёт в «Любимые треки», даже с выключенным экраном и заблокированным телефоном. Работает с любыми наушниками (проводными и Bluetooth), часами и магнитолой. На компьютере (Windows) то же самое делает глобальная горячая клавиша `Ctrl+Shift+Alt+W`, пока Spotify играет в фоне. Открытый исходный код, лицензия MIT.

## How it works

1. **Trigger** — pause-play your headset (Android) or press a hotkey (desktop)
2. **Like** — the current track is saved: Liked Songs on Spotify, a thumbs-up
   on YouTube Music
3. **Archive cleanup** — if the track is in your archive playlist, it gets removed
4. **Best promotion** — like a track 3 times across devices and it's added to your best playlist
5. **Artist follow** — like 5+ tracks from an artist and they get auto-followed

Steps 3–5 are optional and off until you set them up. On Android they live
under **Trigger configuration → Extra actions**. Steps 4 and 5 count likes, so
they also need the counter from
[Cross-device counters](#4-cross-device-counters-optional); step 3 works
without one.

## How it compares

Several desktop hotkey tools can like the current Spotify song. We haven't found another open-source project that does it **from a phone with the screen off**, or one that covers phone and desktop with shared rules. If you only need a Windows hotkey, the smaller tools below may fit you better.

| Project | One-press like | Headset trigger (phone) | Hotkey trigger (desktop) | Rule engine (archive/best/follow) | Cross-device counters | Pluggable | Use **theirs** when |
|---|---|---|---|---|---|---|---|
| **Like Current Song** (this) | ✓ | ✓ Android | ✓ Windows tray + mac/linux CLI | ✓ | ✓ a Google Sheet you own | ✓ 5 typed seams, 9 extensions | n/a |
| [Pano Scrobbler](https://github.com/kawaiiDango/pano-scrobbler) | partial (love via UI) | — (notification scrape) | — | — (scrobble target only) | — | provider seam only (write target) | you want **scrobbling history** to last.fm/listenbrainz/librefm/pleroma. Pano is the right answer for "where did my listens go" — we don't try to replace it. |
| [BeatBind](https://github.com/justinknguyen/BeatBind) | ✓ (save / remove) | — | ✓ Windows tray (.NET) | — | — | — | you want a polished **Windows-only** global-hotkey app for full playback control (play/pause, skip, volume, seek) as well as saving tracks. |
| [Spotikey](https://github.com/dannj90/Spotikey) | ✓ | — | ✓ Windows (`Ctrl+Alt+L`) | — | — | — | you want **only** a like hotkey, as a single small executable. |
| [SpotiLike-GUI](https://github.com/senuka-b/SpotiLike-GUI) | ✓ (to a playlist) | — | ✓ desktop (PyQt) | — | — | — | you want one hotkey per **target playlist** and a GUI to manage them. |
| [SpotifyHotKeys.ahk](https://github.com/rjmccallumbigl/SpotifyHotKeys.ahk) | ✓ (like / unlike) | — | ✓ Windows only (AutoHotKey) | — | — | — | you already live in AutoHotKey and want a small single-file script you can paste & edit. We're heavier (Python install) but cross-platform and rule-capable. |
| [Music Assistant](https://www.music-assistant.io/) | partial (per-provider) | — | via Home Assistant | extensive (queue / library / sync) | — (per-instance) | ✓ ~60 providers | you want **Home Assistant-grade music orchestration** — multi-provider library merging, multi-room sync, queue scripting. We don't try to be your music server; we sit next to your existing Spotify client. |
| [n8n](https://n8n.io/) / Zapier / IFTTT | only via polling | — | — | yes (general workflows) | yes (workflow vars) | ✓ generic | you want **a generic workflow engine** with a UI and 400+ integrations. We're the inverse — narrow to "like + post-like rules", but one button press and ~30 ms latency vs minutes of polling. |

## Quick start

### 1. Spotify Developer App

*Only if you use Spotify.* For YouTube Music, skip this step — on Android it
needs no sign-in at all ([details](#youtube-music-android)), and on Windows it
uses a Google OAuth client instead ([details](#youtube-music-beta-windows)).

You run this against your own Spotify app, which stays in Spotify's
**development mode**. Since the February 2026 changes (in force for existing
integrations from 9 March 2026), that mode has three limits worth knowing
before you start — see
[quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes):

- **The owner needs Spotify Premium.** "The app owner must have a Spotify
  Premium account for apps in development mode to function." On a free
  account your own app does not work at all.
- **Five users, allowlisted by hand.** "Up to 5 authenticated Spotify users
  can use an app that is in development mode" (it was 25). Everyone counts,
  you included, and each one is added manually in the dashboard.
- **One development-mode app per developer.** "Developers will be limited to
  one Development Mode Client ID", so a single client ID has to serve your
  phone and your computer — which is how this project uses it anyway.

Extended quota mode is not an escape hatch for a project like this one: since
15 May 2025 Spotify only accepts applications from organizations, not
individuals, and expects at least 250k monthly active users.

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
2. Create an app
3. Add redirect URIs:
   - `likespotify://auth-callback` (Android)
   - `http://127.0.0.1:8793/callback` (Desktop)
4. Open the app's **Settings → User Management** and add every Spotify
   account that will use it — your own included — by display name and the
   email on the account
5. Copy your Client ID

**If likes fail with 403 right after a successful login**, that is the
allowlist, not a bug here. An account that is not under *User Management* can
still complete the whole OAuth flow and look connected; the limit is enforced
on the API calls afterwards. Add the account, then reconnect in the app.

### 2. Android

Download `app-release.apk` from the
[latest release](https://github.com/Osasuwu/like-current-song/releases/latest)
and install it. Android will warn you about an app from outside the Play Store;
that is expected for a sideloaded APK.

Then open *Connected services* and paste the Client ID from step 1 into
**Spotify credentials** → *Save client ID*. The redirect URI to add in the
dashboard is shown right there, with a copy button. **Connect Spotify** turns on
once the ID is saved.

**Then grant notification access — the trigger does not work without it.**
Open *Permissions* → *Open notification access (required)* and switch the app
on. Android gives the headset button to the music app, not to us, so the only
way a pause-play reaches the app is by reading the player's own playback state,
and that is what notification access is for. Without it the service starts,
says so, and nothing ever happens. Finally, switch the service on from the main
screen.

The client ID lives in the app's encrypted storage, so it survives updates and
a disconnect — you type it once, not once per build. The published APK carries
no credentials of anyone else's.

**Building it yourself instead.**

```bash
git clone https://github.com/Osasuwu/like-current-song.git
cd like-current-song
flutter pub get
flutter build apk --release
```

A build with no keystore of your own is signed with your machine's debug key.
That is fine for your own phone, but it cannot be upgraded in place by the
released APK — you would have to uninstall first. See
[CONTRIBUTING.md](CONTRIBUTING.md#signing-an-android-release) for signing with a
real key.

**Building with your credentials baked in (optional).** If you flash the app
often, or hand builds to the four other people on your allowlist, you can seed
the credentials at build time instead:

```bash
cp .env.example .env
# Edit .env — fill in only the keys you use
flutter build apk --release --dart-define-from-file=.env
```

`.env.example` documents all six, and every one of them is optional:

| Key | What it seeds |
|---|---|
| `SPOTIFY_CLIENT_ID` | Spotify sign-in |
| `YTMUSIC_CLIENT_ID`, `YTMUSIC_CLIENT_SECRET` | the optional YouTube Music sign-in |
| `COUNTER_SPREADSHEET_ID` | which sheet the [shared counter](#4-cross-device-counters-optional) writes to |
| `COUNTER_GOOGLE_CLIENT_ID`, `COUNTER_GOOGLE_CLIENT_SECRET` | the counter's own Google sign-in |

Those values only ever fill a field the app has never been told about. Anything
saved in *Connected services* wins from then on, and clearing a field keeps it
clear — a rebuild will not put the old value back.

#### YouTube Music (Android)

**YouTube Music (beta).** Pick YouTube Music under *Connected services*. The
trigger then gives the playing song a thumbs-up through the YT Music app's own
media session, so it works with the screen off and needs **no Google sign-in
at all** — only the notification access the listener already uses.

**Automatic (optional).** If you use both services, *Connected services* also
offers **Automatic**, which sends the like to whichever connected service is
currently playing instead of to one service you picked. It resolves, in order:
the one connected service with a playing media session; otherwise the last one
that was playing; otherwise the service still shown in the picker. Automatic is
off until you choose it — upgrading never changes where your likes go — and it
is only offered while notification access is granted **and** at least two
services are connected, since that is what it takes to tell them apart. When it
isn't offered, the picker says which of the two is missing. Every automatic like
logs which service it went to and why, on the *Logs* screen.

**Signing in is optional, and the rest of this section is only about that.**
It buys two things: a YouTube Data API fallback for when the session rating
doesn't take, and likes that count in the shared counter (the same one the
desktop app uses, keyed by your Google account, and only once the
[shared like counter](#4-cross-device-counters-optional) is set up). It costs
setting up a Google Cloud project, and — if you leave that project in
*Testing* — a re-sign-in about once a week; see step 3, which is also where
that weekly reconnect is avoided. If the trade isn't worth it to you, stop
here; the thumbs-up keeps working.

Counting looks a song up through the Data API the first time it is liked.
Since 1 June 2026 that lookup has its own budget: Google grants a project
**100 `search.list` calls a day**, separate from the **10,000 units a day**
shared by every other endpoint
([quota details](https://developers.google.com/youtube/v3/getting-started)).
So counting stops after about 100 *new* songs in a day while the 10,000-unit
pool is still almost untouched — the two run out independently. Repeats of a
song already looked up cost nothing. Past the limit, likes still work, they
just stop counting until the buckets reset at midnight Pacific time.

To sign in, you use your own Google OAuth client. Nothing goes in
`.env`: you enter the client in the app. It takes about 5 minutes, once.

1. Open [console.cloud.google.com](https://console.cloud.google.com/) and
   create a project. You can reuse the desktop one.
2. Go to **APIs & Services → Library**, find **YouTube Data API v3** and
   click **Enable**.
3. Go to **APIs & Services → OAuth consent screen** and choose **External**.
   Fill in the app name and your email. You now pick one of two states, and
   the choice is worth a minute because one of them makes you reconnect every
   week.

   **Testing** — the quick way to try it. Add your own Google account under
   *Test users* and carry on. The cost: Google expires the refresh token after
   **7 days**, so you repeat the sign-in (steps 6–7) roughly once a week.
   There is no way around that for the `youtube` scope — the 7-day limit is
   waived only for the name/email/profile scopes. An account that is *not* on
   the *Test users* list gets "Access blocked: … has not completed the Google
   verification process" instead of a consent screen, so add it there first.

   **In production** — click **Publish app**, and the 7-day expiry goes away.
   Publishing is not the same as being verified by Google, and it does not
   require a review. What it does require is a **Branding** page with a home
   page, a privacy policy and a terms-of-service link, each on a domain you
   have verified in Search Console: "These links are required for all external
   production apps"
   ([source](https://support.google.com/cloud/answer/10311615)). Without them
   Publish only answers *"To publish your app, you must complete your
   configuration on the Branding page"*. This repo ships those pages — they
   are the GitHub Pages site under [`docs/`](docs/), served from
   `osasuwu.github.io`, which is a domain you can verify if you fork. What
   publishing does **not** remove: the "Google hasn't verified this app"
   interstitial on every sign-in (step 7), because `youtube` is a sensitive
   scope, and the **100-user** lifetime cap. Both need full verification, which
   is a demo video and a review.

   The project this repo is developed against runs in production, unverified.
4. Go to **APIs & Services → Credentials → Create credentials → OAuth client
   ID**, and pick application type **TVs and Limited Input devices**. Other
   types (Android, Desktop app, Web) are rejected by the sign-in the app uses.
   **Copy the client secret straight away** — it is shown only once, when the
   client is created, and cannot be downloaded again. If you lose it, open
   **Google Auth Platform → Clients →** your client **→ Add Secret** and use
   the new secret instead.
5. In the app, open **Connected services**, pick **YouTube Music**, paste the
   client ID and secret, and tap **Save credentials**.
6. Tap **Connect YouTube Music**. The app shows a code and a link
   (`google.com/device`). Open the link on the phone or any other device, enter
   the code, and pick your Google account.
7. Google warns that the app isn't verified, because it is your own
   unreviewed project. Click **Advanced → Go to *app name* (unsafe)** and
   allow access. The app notices on its own and shows the account as
   connected.

Requested scopes: `youtube` (to rate videos) and `openid` (the account id shown
in the app). Tokens stay on the phone in encrypted storage, apart from
Spotify's, so switching services keeps both signed in. **Disconnect** signs out
of YouTube Music only and keeps the client ID and secret.

The opt-in **Extra actions** work under YouTube Music too: archive clean-up,
promote-to-best and follow-artist act on your ordinary YouTube playlists and
channel subscriptions. Each one spends about 50 units of the 10,000-unit daily
pool — the pool the song lookup above does *not* draw on — so a like with all
three enabled costs a couple of hundred units out of 10,000, and you would need
hundreds of likes in a day to exhaust it. A plain like costs none. The
`youtube` scope above already covers them, so there is nothing more to
authorise.

### 3. Desktop

The desktop side ships as a pluggable Python package (`like_spotify/`) —
a tray host + global hotkey on Windows, a CLI fallback (`like-once`) on
macOS / Linux, providers for **Spotify** and **YouTube Music** (beta), and
an optional like counter kept in a Google Sheet you own.

**One-liner installs.** Run from a fresh clone:

```powershell
# Windows (PowerShell)
git clone https://github.com/Osasuwu/like-current-song.git
cd like-current-song
.\install.ps1
```

```bash
# macOS / Linux
git clone https://github.com/Osasuwu/like-current-song.git
cd like-current-song
./install.sh
```

The installer checks for Python 3.11+, installs `pipx` if missing,
installs the `like-current-song` package, then walks you through the
interactive setup wizard. It opens by asking which **music service** you
want — `spotify` or `ytmusic` — and that answer decides what step 1 asks
for. Then four numbered steps:

1. **Sign in to the service you picked.**
   - *Spotify*: paste a Client ID from
     [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
     (redirect URI: `http://127.0.0.1:8793/callback`); a browser opens
     for PKCE OAuth.
   - *YouTube Music*: paste your own Google OAuth client — see
     [YouTube Music (beta, Windows)](#youtube-music-beta-windows) below.
2. **Storage** — `sheets` counts your likes into a Google Sheet you own;
   `none` skips counting. Likes work either way; without a counter you
   lose cross-device aggregation and the two rules that read it
   (promote-to-best, follow-artist). The default is `none`, so nothing is
   set up behind your back.
3. **Playlist clean-up** (optional) — the archive playlist that a like
   should remove the track from, plus the best playlist. Leave blank to
   skip.
4. **Autostart** — Windows: toggle the `HKCU\…\Run` entry. macOS /
   Linux: instructions for a Launch Agent / `.desktop` file are
   printed (no auto-config — too platform-fragmented).

The wizard is re-runnable; existing tokens are kept unless you pass
`--reauth` (or `-Reauth` on PowerShell).

**After install:**

```bash
like-current-song             # Windows: tray host with the hotkey (default Ctrl+Shift+Alt+W)
like-current-song like-once   # any OS: like the currently-playing track and exit
like-current-song discard-once # any OS: dislike the current track and/or un-archive it (no like)
like-current-song --config    # print config + token paths
like-current-song --settings  # open the settings window
```

**Upgrading from `like-spotify`.** The package and commands used to be
called `like-spotify` / `like-spotify-gui`. Re-run the installer: it
removes the old pipx package and installs `like-current-song`. Your config
and tokens in `~/.like_spotify/` stay where they are. The old command names
still work for now (the console one prints a short note), but they will be
removed in a future release, so update any scripts or hotkey tools. On
Windows, an autostart entry from the old version is moved to the new
launcher the next time the tray starts, or when `--setup` asks about
autostart.

**Settings window.** Everything the wizard asks, in one window instead of a
terminal: the music service and the account sign-in (the same browser flow
as `--setup`), the hotkeys, the sound volume (with a Test button), the like
counter storage, and autostart. The optional **Extra actions** (archive
clean-up, best, follow artist, like cooldown) sit in a collapsed
section, each with a one-line explanation. On a fresh install they all
start switched off. On Windows, open it from the tray menu (**Settings…**).
Saved changes apply right away, hotkeys included. If the new settings can't
run yet (for example, you switched service but haven't signed in), the tray
keeps the old ones and tells you why. If a change can't be applied live, it
offers to restart. From a terminal, run `like-current-song --settings` (or
`like-current-song-gui --settings`). It needs Tk: on Linux, install your
distro's `python3-tk` package. The window only edits the keys it knows, so
anything else you added to `config.json` by hand is kept as is.

`like-current-song` is a console-subsystem executable, so any of the above
briefly shows a terminal window. On Windows, a windowed twin is also
installed — `like-current-song-gui` — that runs the exact same commands with no
console at all. Autostart uses it automatically; if you trigger `like-once`
/ `discard-once` from an external hotkey tool (AutoHotkey, a macro app, a
Stream Deck, etc.), point it at `like-current-song-gui like-once` instead of
`like-current-song like-once` to avoid the flash. (`--setup` / `--config` still
need `like-current-song`, since they read from the terminal.)

On Windows the tray host also binds a **second** global hotkey (default
`Ctrl+Shift+Alt+Q`) — the *discard* key, for tracks you want gone rather
than liked. One press does two independent things, **without liking**:

- **Un-archive** — removes the track from your Discover-Weekly archive
  playlist, if you set an archive playlist name.
- **Dislike** — tells the music service itself “not this one”. What that
  means differs per service, and the app does not pretend otherwise. On
  **YouTube Music** it is a real thumbs-down, which also clears any like you
  had on the track. On **Spotify** there is no dislike to send — the Web API
  has no such endpoint, and the “Hide this song” control in the official
  clients is not available to third-party apps — so the press removes the
  track from your Liked Songs instead.

Either half is enough to earn the hotkey: with no archive playlist set you
still get the dislike. Neither half can cost you the other — if one fails,
the other still goes through, and the notification says what actually
happened. If the combo collides with the like hotkey it's skipped. Audio
feedback is audible through the default sound device and distinct per action
(like / discard / error).

#### YouTube Music (beta, Windows)

Choose `ytmusic` at the "Music service" prompt in `--setup` — it is the first
thing the wizard asks, before any sign-in. The hotkey then likes the song
playing in the YT Music browser tab or desktop app, and it lands in YT Music's
*Liked music*.

You need your own free Google OAuth client with the YouTube Data API enabled;
the steps are in
[`extensions/ytmusic/README.md`](like_spotify/extensions/ytmusic/README.md).
Unlike the Android side, the desktop one has no session to drive, so the
sign-in is required rather than optional.

The playlist actions (archive-remove, best, follow-artist) work here too.
Follow-artist subscribes to the artist's channel, and each playlist write costs
YouTube API quota (see that README).

To switch back, re-run `--setup` and pick `spotify`, or change the music
service in the settings window. Both services keep their own tokens, so
switching does not sign you out of the other one.

**Single-file `.exe`** (for users without Python): build via
`tools\build.bat` → `dist\LikeSpotify.exe`.

### 4. Cross-device counters (optional)

Everything above works without this. Turning it on buys you two things: the
same like counts on your phone and your computer, and the two rules that read
them — **promote-to-best** (add a track to a "best" playlist once you have
liked it N times) and **follow-artist** (follow an artist after N liked
tracks). Without a counter those two stay inactive and every other feature is
unaffected.

The counter is a **Google Sheet you own**. There is no service to sign up for,
no database to run, and no backend operated by this project — the numbers are
rows in a spreadsheet you can open, edit, chart or delete yourself.

You do not have to build that sheet yourself — either half will make one for
you, tabs and header rows and all, in the Drive of the Google account you sign
in with. Pasting the ID of a sheet you already have keeps working, and is how
a second device joins an existing count.

1. Enable the **Google Sheets API** on
   [its page in the API library](https://console.cloud.google.com/apis/library/sheets.googleapis.com),
   then create an OAuth client at
   [console.cloud.google.com/apis/credentials](https://console.cloud.google.com/apis/credentials).
   They are two different pages: the credentials one makes clients and cannot
   switch an API on, and a project with the API off refuses every call with a
   403. Which kind of client depends on the half, because the two sign in
   differently:

   | Half | Client type | Why |
   |---|---|---|
   | Desktop | **Desktop app** | it opens a browser and catches the reply on `127.0.0.1` |
   | Android | **TVs and Limited Input devices** | it shows a code you type at `google.com/device` |

   One Cloud project covers both. If you already made a *TVs and Limited Input
   devices* client for YouTube Music, the phone can reuse that same client for
   the counter once the Sheets API is on — the two grants are still separate
   sign-ins with separate scopes.
2. Run `like-current-song --setup`, pick `sheets` at the storage step, and
   enter the client ID and secret. A browser opens for the Google consent
   screen; the token is refreshed automatically afterwards and lives in
   `~/.like_spotify/google_token.json`. The wizard then asks about the
   spreadsheet itself and takes one of three answers:

   | Answer | What happens |
   |---|---|
   | `create` (default) | makes the sheet in your Drive and prints its ID |
   | `paste` | counts into a sheet you name by ID — how a second device joins |
   | `skip` | leaves the counter off; likes still work, nothing is counted |

   The Windows settings window has the same **Create spreadsheet** button next
   to the Spreadsheet ID box.
3. Point the Android app at the **same sheet** to share counts between
   devices: *Connected services* → **Shared like counter (optional)**. Enter
   the client ID and secret, sign in, then either press **Create spreadsheet**
   or paste the ID of the sheet the other device already uses. This is the
   counter's **own** Google sign-in, separate from the music service and
   asking for one scope, `spreadsheets` — so a Spotify user gets a shared
   counter without granting any YouTube permission, and disconnecting the
   counter leaves the music service signed in. Creating a sheet needs no extra
   permission: `spreadsheets` already covers it.

   Whichever half creates the sheet, the other one joins it by ID. Neither
   will make a second sheet once one is configured — it says so instead, so a
   stray tap cannot split your counts across two files.
4. *Only if you would rather build the sheet by hand:* create a Google Sheet
   with a tab named `Likes` carrying this header row:

   ```
   user_id | track_id | count | backfilled | updated_at
   ```

   For the follow-artist rule, add a second tab named `ArtistTracks` with the
   header row `user_id | artist_id | track_id`. Then paste its ID at step 2
   or 3 instead of creating one.

Both halves address a row by your own account id — your Spotify user id, or
the Google account id when the like came from YouTube Music — so two people
using one sheet do not collide.

**Storage is a seam, not a hard-coded choice.** `Storage` is one of the five
extension points, and `tests/test_storage_contract.py` holds the seven
invariants any implementation has to satisfy. If a spreadsheet is the wrong
shape for you, a different backend is a plugin — see
[CONTRIBUTING.md](CONTRIBUTING.md). Google Sheets is simply the one that
ships.

> **Upgrading from the Supabase backend?** Both halves had one; both dropped
> it in the release after v1.1.0. Nothing breaks: likes keep working, they
> just stop being counted until you point the half at a sheet.
>
> On the desktop, a config still saying `backend: "supabase"` says so once at
> startup — re-run `--setup` (or open the settings window) and pick `sheets`.
> On the phone, the old Supabase fields are gone from *Connected services*;
> fill in **Shared like counter** instead. Counts do not carry over, on either
> half. Your Supabase project is untouched and yours to keep or delete.

## Architecture

Neither half is written against one music service or one place to keep counts.
Both go through the same two seams: a **provider** that knows how to like a
track somewhere, and a **counter** that knows how to add one to a number.

```
Android (Flutter + Kotlin)            Desktop (Python framework)
┌────────────────────────────┐       ┌────────────────────────────┐
│ Trigger                    │       │ Trigger                    │
│  · headset / media buttons │       │  · tray + global hotkey    │
│    (pause-play patterns)   │       │  · one-shot CLI            │
│            ↓               │       │            ↓               │
│ Music service              │       │ MusicProvider              │
│  · Spotify   · YT Music    │       │  · Spotify   · YT Music    │
│  · Automatic (whichever    │       │            ↓               │
│    one is playing)         │       │ PreLikeAction              │
│            ↓               │       │  · like cooldown           │
│ Extra actions              │       │            ↓               │
│  · archive remove          │       │ PostLikeAction             │
│  · promote to best         │       │  · archive remove          │
│  · follow artist           │       │  · promote to best         │
└──────┬─────────────────────┘       │  · follow artist           │
       │                             └──────┬─────────────────────┘
       │                                    │
       └──────────────┬─────────────────────┘
                      ↓
        Your music service's own API   (what "like" means)
        Storage  ·  Google Sheets      (shared counts, optional)
```

The desktop side names those seams as five ABCs in `like_spotify/core/`:
`Trigger`, `MusicProvider`, `Storage`, `PreLikeAction` and `PostLikeAction`.
Nine extensions ship against them, plus one skeleton:

| Seam | Ships today |
|---|---|
| `Trigger` | `tray_hotkey_trigger`, `one_shot_cli_trigger` |
| `MusicProvider` | `spotify`, `ytmusic` (beta) |
| `Storage` | `google_sheets_storage` |
| `PreLikeAction` | `like_cooldown` |
| `PostLikeAction` | `archive_remove`, `promote_to_best`, `follow_artist` |

`volume_button_trigger` is in the tree as well, but it is a skeleton: the
pattern matching is written, the HID read loop is a TODO, and its manifest
stage says `experimental`. Finishing it is
[#74](https://github.com/Osasuwu/like-current-song/issues/74), and it is a
good way to see the `Trigger` seam end to end.

Each lives in its own folder under `like_spotify/extensions/` with a
`manifest.json` describing it, and is wired in by one builder function plus one
registry entry in `like_spotify/hosts/_common.py`. Nothing in `core/` or the
pipeline knows the names above.

- `lib/` — Flutter app (Dart): UI, state management (Riverpod), OAuth
- `android/.../kotlin/` — native Android: foreground service, MediaSession,
  background worker
- `like_spotify/` — Python desktop package: `core/` (the five ABCs and the
  pipeline), `hosts/` (tray runtime, setup wizard, settings window),
  `extensions/` (the ten above), `samples/` (alt-flavor examples)

## Configuration

Every desktop setting below except the token files can be changed in the
settings window (`like-current-song --settings`, or **Settings…** in the tray menu).

| Setting | Android | Desktop |
|---------|---------|---------|
| Trigger pattern / hotkey | In-app UI | `~/.like_spotify/config.json` → `trigger.hotkey` (default `Ctrl+Shift+Alt+W`) |
| Discard hotkey (dislike + un-archive) | n/a (one trigger on headphones) | `~/.like_spotify/config.json` → `trigger.remove_hotkey` (default `Ctrl+Shift+Alt+Q`) |
| Archive playlist name | In-app UI | `~/.like_spotify/config.json` → `actions.archive_remove.playlist_name` (blank = the discard hotkey only dislikes) |
| Music service | In-app UI (Spotify / YouTube Music / Automatic) | `~/.like_spotify/config.json` → `music.provider` (`spotify` / `ytmusic`, default `spotify`) |
| YouTube Music client ID / secret | In-app UI (*Connected services*), stored in `FlutterSecureStorage`; `.env` (`YTMUSIC_CLIENT_ID`, `YTMUSIC_CLIENT_SECRET`) seeds a build | `like-current-song --setup` → `~/.like_spotify/config.json` |
| YouTube Music tokens | `FlutterSecureStorage` (refreshed automatically) | `~/.like_spotify/youtube_token.json` (refreshed automatically) |
| Spotify client_id | In-app UI (*Connected services*), stored in `FlutterSecureStorage`; `.env` (`SPOTIFY_CLIENT_ID`) seeds a build | `like-current-song --setup` → `~/.like_spotify/config.json` |
| Spotify tokens | `FlutterSecureStorage` | `~/.like_spotify/spotify_token.json` |
| Counter spreadsheet ID | In-app UI (*Connected services* → *Shared like counter*), stored in `FlutterSecureStorage`; `.env` (`COUNTER_SPREADSHEET_ID`) seeds a build | `like-current-song --setup` → `~/.like_spotify/config.json` → `sheets.spreadsheet_id` |
| Counter Google client ID / secret | In-app UI (*Shared like counter*); `.env` (`COUNTER_GOOGLE_CLIENT_ID`, `COUNTER_GOOGLE_CLIENT_SECRET`) seeds a build | `like-current-song --setup`, kept beside the tokens in `~/.like_spotify/google_token.json` |
| Storage backend | Blank spreadsheet ID = counts stay on the device | `~/.like_spotify/config.json` → `storage.backend` (`sheets` / `none`) |
| Counter Google tokens | `FlutterSecureStorage` (refreshed automatically) | `~/.like_spotify/google_token.json` (refreshed automatically) |
| Best / follow | In-app UI | `~/.like_spotify/config.json` → `actions.{promote_to_best,follow_artist}` |

## Contributing

Contributions are welcome — the desktop side is a plugin framework precisely so
that other people's triggers, providers, storages, and actions can live in it.

- [**CONTRIBUTING.md**](CONTRIBUTING.md) — repo layout, the five extension
  points with code, the add-an-extension checklist, and how to run the tests.
  It also lists what's known to be easy to land.
- [**Good first issues**](https://github.com/Osasuwu/like-current-song/labels/good%20first%20issue)
  · [**Help wanted**](https://github.com/Osasuwu/like-current-song/labels/help%20wanted)
- [**CODE_OF_CONDUCT.md**](CODE_OF_CONDUCT.md)
- [**SECURITY.md**](SECURITY.md) — please report vulnerabilities privately, not
  as a public issue.
- [**CHANGELOG.md**](CHANGELOG.md)

## License

[MIT](LICENSE)
