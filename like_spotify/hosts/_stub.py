"""Stub host — macOS / Linux CLI fallback.

Phase 1 ships Windows as the only first-class host. On every other
platform we still want `pip install like-current-song` to be useful, so this
stub host wires up:

    - `--setup` / `--config` (identical to Windows)
    - `like-current-song like-once`    → single like via OneShotCliTrigger
    - `like-current-song discard-once` → dislike and/or un-archive, no like

The long-lived `run` command prints a friendly message and exits with a
non-zero code — full tray + global-hotkey support on mac/linux is left
as a good-first-PR (see CONTRIBUTING.md), since `keyboard` needs root on
Linux and `pystray` is awkward outside Win32.

Slice: #27.
"""

from __future__ import annotations

import sys

from like_spotify.core.pipeline import Pipeline

from . import _common, _setup

_PLATFORM_HINT = {
    "darwin": (
        "Resident tray host is not implemented for macOS yet. Use:\n"
        "    like-current-song like-once\n"
        "to like the currently-playing track. See CONTRIBUTING.md "
        "(`hosts/macos.py`) if you'd like to ship the tray flavor."
    ),
    "linux": (
        "Resident tray host is not implemented for Linux yet. Use:\n"
        "    like-current-song like-once\n"
        "to like the currently-playing track. See CONTRIBUTING.md "
        "(`hosts/linux.py`) if you'd like to ship the tray flavor."
    ),
}


def _no_tray_message() -> str:
    return _PLATFORM_HINT.get(sys.platform, _PLATFORM_HINT["linux"])


class CliFeedback:
    """Plain-stdout feedback for the CLI host.

    Accepts the optional `kind` keyword (e.g. "remove") so the
    remove-without-like pipeline can call it; the CLI has no audio, so
    `kind` only affects nothing here — it's stored for tests / parity.
    """

    def __init__(self) -> None:
        self.calls: list[tuple[bool, str, str]] = []
        self.kinds: list[str] = []

    def __call__(
        self, success: bool, title: str, message: str, *, kind: str = "like"
    ) -> None:
        self.calls.append((success, title, message))
        self.kinds.append(kind)
        stream = sys.stdout if success else sys.stderr
        prefix = "[ok]" if success else "[err]"
        line = f"{prefix} {title}"
        if message:
            line += f" — {message}"
        print(line, file=stream)


def _resolved_provider_or_hint():
    """(provider, None, cfg) when ready, else (None, exit_code, cfg)."""
    cfg = _common.load_config()
    provider = _common.build_provider(cfg)
    if provider is None:
        _common.msgbox(
            "Not configured. Run:\n\n    like-current-song --setup\n",
            title="Like Current Song — setup required",
        )
        return None, 2, cfg

    if not provider.has_tokens:
        _common.msgbox(
            "Not authenticated. Run:\n\n    like-current-song --setup\n",
            title="Like Current Song — auth required",
        )
        return None, 2, cfg
    return provider, None, cfg


def _run_like_once() -> int:
    provider, err, cfg = _resolved_provider_or_hint()
    if provider is None:
        return err

    feedback = CliFeedback()
    storage = _common.build_storage(cfg)
    pre_actions, post_actions = _common.build_action_chains(cfg, storage)
    pipeline = Pipeline(
        provider=provider,
        feedback=feedback,
        storage=storage,
        pre_like_actions=pre_actions,
        post_like_actions=post_actions,
    )
    return _common.run_one_shot(pipeline, feedback)


def _run_discard_once() -> int:
    provider, err, cfg = _resolved_provider_or_hint()
    if provider is None:
        return err

    feedback = CliFeedback()
    pipeline = _common.build_discard_pipeline(cfg, provider, feedback)
    if pipeline is None:
        # Both legs are out: no archive playlist to remove from, and a
        # music service that can't be told "not this one" either.
        _common.msgbox(
            "Nothing to discard with: this music service has no dislike, and "
            "no archive playlist is configured. Run:\n\n"
            "    like-current-song --setup\n",
            title="Like Current Song — setup required",
        )
        return 2
    return _common.run_one_shot(pipeline, feedback)


def main(argv: list[str] | None = None) -> int:
    args = _common.parse_args(argv if argv is not None else sys.argv[1:])

    if args.config:
        return _common.print_config_paths()
    if args.setup:
        return _setup.do_setup(reauth=args.reauth)
    if args.settings:
        from .settings import run as run_settings  # lazy: tkinter may be absent

        return run_settings(from_tray=args.from_tray)

    if args.command == "like-once":
        return _run_like_once()
    if args.command == "discard-once":
        return _run_discard_once()

    # Default `run` on a non-tray platform: tell the user what works.
    print(_no_tray_message(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
