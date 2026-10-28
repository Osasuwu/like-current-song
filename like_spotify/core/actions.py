from abc import ABC, abstractmethod

from .types import LikeContext


class PreLikeAction(ABC):
    """Hook fired before `MusicProvider.like` is written.

    Returning `False` aborts both the chain and the like itself — the host
    surfaces "Skipped by <ClassName>" feedback and no provider call is made.
    Returning `True` (the default-by-convention) lets the chain proceed.

    Raised exceptions are logged by the pipeline and treated as a *skip
    for this action only* — the chain continues. This keeps a flaky pre-
    action from blocking the user's intent.

    No default impl ships in #23 — this is a contributor seam. Sketches
    (a future CONTRIBUTING.md, tracked in #29, will link these directly):

        class BlacklistFilter(PreLikeAction):
            async def run(self, ctx: LikeContext) -> bool:
                return ctx.track.provider_track_id not in self._denied

        class ConfirmPrompt(PreLikeAction):
            async def run(self, ctx: LikeContext) -> bool:
                return await ask_user(f"Like {ctx.track.title}?")
    """

    @abstractmethod
    async def run(self, ctx: LikeContext) -> bool: ...


class PostLikeAction(ABC):
    """Hook fired after `MusicProvider.like` succeeded.

    Each registered action runs sequentially. One action's failure (raised
    exception) is logged by the pipeline and does NOT abort the chain —
    later actions still run. Failures are independent: an action's
    contract is its own to keep.

    Default impls in this repo: `ArchiveRemoveAction`. Promote-to-best
    and Follow-artist land in #26.
    """

    @abstractmethod
    async def run(self, ctx: LikeContext) -> None: ...

    async def undo(self, ctx: LikeContext) -> None:
        """Reverse what `run` did for this `ctx` (#270).

        Called by `Pipeline.undo_last` with the same `ctx` object `run`
        received, within the undo window, at most once, and in reverse
        chain order. `run` should record what it actually changed in
        `ctx.extras` (under a key of its own) so `undo` reverses exactly
        that and nothing a press before it did. Called even when `run`
        raised, so record each effect as it happens.

        Raise to report a reverse that failed; the pipeline names the
        action in the undo feedback. Not abstract, so an action written
        before undo existed keeps working: the default raises
        `NotImplementedError`, which the pipeline logs as "not undoable"
        and does not count as a failure. Raise it yourself, with the
        reason as the message, for an effect that cannot be taken back.
        """
        raise NotImplementedError(f"{type(self).__name__} has no undo")
