# Security Policy

## Supported versions

Only the latest tagged release is supported. Fixes land on `main` and ship in
the next tag; there are no backport branches.

| Version | Supported |
|---------|-----------|
| latest release (see [Releases](https://github.com/Osasuwu/like-current-song/releases)) | ✅ |
| anything older | ❌ |

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/Osasuwu/like-current-song/security/advisories/new).

Please include:

- which half is affected — Android (`lib/`, `android/`) or desktop (`like_spotify/`)
- version / commit
- reproduction steps, and the impact you believe it has

Expect a first response within 7 days. This is a hobby project maintained by
one person, so please size your expectations accordingly — there is no paid
support and no bug bounty.

## What is in scope

- Leakage or mishandling of Spotify OAuth tokens (`FlutterSecureStorage` on
  Android, `~/.like_spotify/spotify_token.json` on desktop)
- Leakage or mishandling of Google OAuth tokens (`~/.like_spotify/google_token.json`)
- Anything that lets a third party act on a user's Spotify account
- Privilege escalation or arbitrary code execution through an extension the
  host loads from `like_spotify/extensions/`
- Android: the foreground service, the notification listener, and the exported
  broadcast receivers

## What is out of scope

- **Extensions you install yourself.** An extension is Python that lives under
  `like_spotify/extensions/` and is wired in by hand in
  `like_spotify/hosts/_common.py`. This is by design — it is a plugin
  framework. Installing an untrusted extension is equivalent to running
  untrusted code; that is not a vulnerability in this project.
- **Your own credentials in your own config.** `~/.like_spotify/config.json`
  and `.env` hold the client ID of whichever music service you connected, and
  the Google client ID and secret if you turned the like counter on. They are
  stored in plaintext on your machine by design, protected by your OS file
  permissions.
- **Your Google Sheet.** The counter lives in a spreadsheet you own, reached
  with your own OAuth credentials. Who else can read or write it is decided by
  that sheet's sharing settings, which are yours to set.
- Vulnerabilities in the music services' own APIs and clients (Spotify,
  YouTube Music) or in Google Sheets.
- Denial of service against your own machine.

## Credential hygiene

This project never transmits your credentials anywhere except to the music
service and Google Sheets — the services you configured. There is no
telemetry, no analytics, and no maintainer-operated backend. If you find
otherwise, that is a report worth filing.
