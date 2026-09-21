"""Reading Google's refusals back into words the user can act on.

The one that matters is a Cloud project with an OAuth client but the Sheets
API switched off (#165). That is the likely first-run failure rather than an
edge case: the README suggests reusing the *TVs and Limited Input devices*
client made for YouTube Music, and such a project has never had Sheets on.
Google says so plainly — a ``SERVICE_DISABLED`` reason, the project, and a
one-click activation URL — and every caller here used to throw that body away
and report a bare 403.

Nothing in this module assumes the body is there: Google's refusals go through
proxies, and a 403 with an empty or truncated body still has to leave the
caller with a message that makes sense.
"""

from __future__ import annotations

import json
import re

#: Where the Sheets API is switched on, for when Google named no URL of its
#: own. Note that this is the API's page in the *library* — the credentials
#: page, which the README used to send people to, creates OAuth clients and
#: cannot enable anything.
SHEETS_API_LIBRARY_URL = (
    "https://console.cloud.google.com/apis/library/sheets.googleapis.com"
)

#: Both spellings of "you never turned this API on": the ``ErrorInfo`` reason
#: current APIs send, and the one the older error shape still uses.
_DISABLED_REASONS = frozenset({"SERVICE_DISABLED", "accessNotConfigured"})

#: The old shape carries no activation URL of its own; it puts one in the
#: prose of ``error.message``, so that is where we go looking for it.
_URL_IN_PROSE = re.compile(r"https?://[^\s\"'<>)\]]+")

#: Likewise the project: "…has not been used in project 123456 before…".
_PROJECT_IN_PROSE = re.compile(r"\bproject\s+([A-Za-z0-9][\w.:-]*)")


class SheetsApiDisabledError(RuntimeError):
    """The Cloud project behind these tokens has the Sheets API switched off.

    A plain ``RuntimeError`` and deliberately *not* an
    :class:`~like_spotify.core.errors.AuthError`: the tokens are fine and
    re-authorising fixes nothing, so no host should answer this by sending
    the user back through a sign-in they just completed.
    """

    def __init__(
        self,
        message: str,
        *,
        activation_url: str,
        project: str | None = None,
    ) -> None:
        super().__init__(message)
        self.activation_url = activation_url
        self.project = project


def sheets_api_disabled(status_code: int, body: str | None) -> SheetsApiDisabledError | None:
    """The error to raise for this reply, or None when it is something else.

    Only a 403 is ever read this way — that is the status Google uses for a
    disabled service — and only when the body actually names the reason. A
    403 for a revoked token, or one with nothing parseable in it, is left to
    the caller to report as it always did, because guessing "the API is off"
    at someone whose API is on is worse than a status code.
    """
    if status_code != 403:
        return None
    parsed = _parse_error(body)
    if parsed is None:
        return None
    activation_url, project = parsed
    where = f" ({project})" if project else ""
    return SheetsApiDisabledError(
        f"The Google Sheets API is not enabled on your Google Cloud "
        f"project{where}. Enable it at {activation_url}, give Google a "
        f"minute to catch up, then try again.",
        activation_url=activation_url,
        project=project,
    )


def _parse_error(body: str | None) -> tuple[str, str | None] | None:
    """``(activation_url, project)`` when *body* is the disabled refusal."""
    try:
        payload = json.loads(body or "")
    except (TypeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    error = payload.get("error")
    if not isinstance(error, dict):
        return None

    disabled = False
    activation_url: str | None = None
    project: str | None = None

    # Current shape: a `google.rpc.ErrorInfo` among `error.details`, which
    # carries the activation URL and the project as `projects/123456`.
    details = error.get("details")
    for detail in details if isinstance(details, list) else []:
        if not isinstance(detail, dict) or detail.get("reason") not in _DISABLED_REASONS:
            continue
        disabled = True
        metadata = detail.get("metadata")
        if isinstance(metadata, dict):
            activation_url = activation_url or _text(metadata.get("activationUrl"))
            consumer = _text(metadata.get("consumer"))
            if consumer:
                project = project or consumer.rsplit("/", 1)[-1] or None

    # Older shape: `error.errors[0].reason == "accessNotConfigured"`, with
    # nothing beside it — whatever it can tell us is in the message.
    if not disabled:
        errors = error.get("errors")
        for old in errors if isinstance(errors, list) else []:
            if isinstance(old, dict) and old.get("reason") in _DISABLED_REASONS:
                disabled = True
                break

    if not disabled:
        return None

    message = _text(error.get("message")) or ""
    if not activation_url:
        found = _URL_IN_PROSE.search(message)
        activation_url = found.group(0).rstrip(".,;") if found else None
    if not project:
        named = _PROJECT_IN_PROSE.search(message)
        project = named.group(1) if named else None
    return activation_url or SHEETS_API_LIBRARY_URL, project


def _text(value: object) -> str | None:
    return value.strip() or None if isinstance(value, str) else None
