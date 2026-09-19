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
- Privilege escalation or arbitrary code execution via the extension-discovery
  mechanism (`manifest.json` loading in `like_spotify/extensions/`)
- Android: the foreground service, the notification listener, and the exported
  broadcast receivers

## What is out of scope

- **Extensions you install yourself.** Extension discovery loads and executes
  Python from any folder placed under `like_spotify/extensions/`. This is by
  design — it is a plugin framework. Installing an untrusted extension is
  equivalent to running untrusted code; that is not a vulnerability in this
  project.
- **Your own credentials in your own config.** `~/.like_spotify/config.json`
  and `.env` hold your Spotify client ID and (optionally) a Supabase anon key.
  They are stored in plaintext on your machine by design, protected by your OS
  file permissions.
- **The Supabase anon key.** It is a public-by-design key; the security boundary
  is your Row Level Security policy. The permissive `anon_full_access` policy in
  the README's quick start is a single-user convenience — tighten it if you
  expose your project to anyone else.
- Vulnerabilities in Spotify's own API, the Spotify client, or Supabase.
- Denial of service against your own machine.

## Credential hygiene

This project never transmits your credentials anywhere except to Spotify,
Supabase, or Google Sheets — the services you configured. There is no
telemetry, no analytics, and no maintainer-operated backend. If you find
otherwise, that is a report worth filing.
