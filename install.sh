#!/usr/bin/env bash
#
# One-liner installer for Like Spotify on macOS / Linux.
#
# Checks for Python 3.11+, installs pipx if missing, installs the
# like-current-song package from this repo, then runs the interactive setup
# wizard. Re-runnable; existing tokens are kept unless --reauth is
# passed.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Osasuwu/like-current-song/main/install.sh | bash
#
#   # Re-run OAuth (after revoking access or switching accounts):
#   ./install.sh --reauth
#
#   # From a local checkout, point at the source dir:
#   ./install.sh --source /path/to/checkout

set -euo pipefail

REAUTH=0
SKIP_SETUP=0
SOURCE="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reauth) REAUTH=1 ;;
        --skip-setup) SKIP_SETUP=1 ;;
        --source) SOURCE="$2"; shift ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m   ok: %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m   warn: %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m   err: %s\033[0m\n' "$*" >&2; }

# ── Python ─────────────────────────────────────────────────────────────

step "Checking for Python >= 3.11"
PY=""
for candidate in python3.13 python3.12 python3.11 python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
            PY="$candidate"
            ok "found $($candidate --version 2>&1) via '$candidate'"
            break
        fi
    fi
done

if [[ -z "$PY" ]]; then
    err "Python 3.11+ not found."
    case "$(uname -s)" in
        Darwin) echo "      Install via: brew install python@3.12" ;;
        Linux)  echo "      Install via your distro (e.g. apt install python3.12 python3.12-venv)" ;;
    esac
    exit 2
fi

# ── pipx ───────────────────────────────────────────────────────────────

step "Ensuring pipx is available"
if command -v pipx >/dev/null 2>&1; then
    ok "pipx already present"
else
    step "Installing pipx (user-local)"
    "$PY" -m pip install --user --upgrade pipx
    "$PY" -m pipx ensurepath
    # Try to make it available in the current shell session.
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v pipx >/dev/null 2>&1; then
        warn "pipx not on PATH yet — open a new shell and re-run install.sh, or add ~/.local/bin to PATH."
        exit 2
    fi
    ok "pipx installed"
fi

# ── like-current-song ──────────────────────────────────────────────────

# Before #101 the package was called `like-spotify`. Both ship the
# `like-spotify` command (the new one keeps it as a deprecated alias), so
# pipx can't hold both. Remove the old package first; ~/.like_spotify/ is kept.
if pipx list --short 2>/dev/null | grep -q '^like-spotify '; then
    step "Removing the old 'like-spotify' pipx package (now called like-current-song)"
    pipx uninstall like-spotify
    ok "old package removed; config in ~/.like_spotify/ is kept"
fi

step "Installing like-current-song from '$SOURCE'"
pipx install --force "$SOURCE"
ok "like-current-song on PATH"

# ── setup ──────────────────────────────────────────────────────────────

if [[ "$SKIP_SETUP" == "1" ]]; then
    step "Skipping --setup (per --skip-setup)"
    echo "Next: run 'like-current-song --setup' manually."
    exit 0
fi

step "Launching interactive setup"
setup_args=(--setup)
[[ "$REAUTH" == "1" ]] && setup_args+=(--reauth)
# Don't use `if ! cmd`: in bash that captures the exit code of `!`, not
# the command, masking real failures behind a 0 exit. Capture rc directly.
rc=0
like-current-song "${setup_args[@]}" || rc=$?
if [[ "$rc" -ne 0 ]]; then
    warn "setup exited with code $rc. Re-run 'like-current-song --setup' once you have the credentials."
    exit "$rc"
fi

echo
step "Done."
case "$(uname -s)" in
    Darwin)
        echo "       macOS: no resident tray host yet. Use 'like-current-song like-once' to like the current track,"
        echo "              or bind it to a hotkey via Shortcuts / Karabiner."
        ;;
    Linux)
        echo "       Linux: no resident tray host yet. Use 'like-current-song like-once' to like the current track,"
        echo "              or bind it to a hotkey via your DE's shortcut settings."
        ;;
esac
echo "       See CONTRIBUTING.md for the hosts/macos.py / linux.py good-first-PR."
