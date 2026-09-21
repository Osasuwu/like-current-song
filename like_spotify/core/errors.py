class AuthError(Exception):
    """Token expired or revoked. Host should trigger re-auth."""


class RateLimited(Exception):
    """Provider returned 429. Host should back off."""


class TransientError(Exception):
    """Network blip / 5xx. Host may retry with jitter."""


class UserActionRequired(Exception):
    """A failure that will keep happening until the user goes and fixes it.

    Mixed into an extension's own exception type — `SheetsApiDisabledError`
    is the first — to say two things: retrying changes nothing, and the
    message already names the fix. A soft-failing step (the like path's
    counter, #168) uses it to decide whether the user hears about the
    failure or only the log does. It lives in `core` so that decision costs
    no import of any concrete extension.
    """
