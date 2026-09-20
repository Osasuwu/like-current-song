"""Tests for `hosts/_common.py`'s `build_action_chains` (issue #57).

`build_pre_actions` and `build_post_actions` used to each independently call
`build_like_cooldown`, constructing two separate `_CooldownStore` instances
for the gate and the recorder. They happened to converge on the same JSON
file, but nothing enforced that a caller wired both halves onto the same
`Pipeline` — a future host could build one chain and forget the other.
`build_action_chains` replaces both with a single call that returns the gate
and recorder built from one shared store.
"""

from __future__ import annotations

import pytest

from like_spotify.core.types import CurrentTrack, LikeContext
from like_spotify.hosts import _common


def _ctx(track_id: str = "trk-a") -> LikeContext:
    return LikeContext(
        track=CurrentTrack(
            provider="spotify",
            provider_track_id=track_id,
            title="Song",
            artists=("Artist",),
        )
    )


@pytest.fixture
def cooldown_file(tmp_path, monkeypatch):
    path = tmp_path / "like_cooldown.json"
    monkeypatch.setattr(_common, "LIKE_COOLDOWN_FILE", path)
    return path


@pytest.mark.asyncio
async def test_cooldown_gate_and_recorder_share_state(cooldown_file) -> None:
    pre_actions, post_actions = _common.build_action_chains({}, storage=None)

    gates = [a for a in pre_actions if type(a).__name__ == "LikeCooldownGate"]
    recorders = [a for a in post_actions if type(a).__name__ == "LikeCooldownRecorder"]
    assert len(gates) == 1
    assert len(recorders) == 1

    ctx = _ctx()
    assert await gates[0].run(ctx) is True
    await recorders[0].run(ctx)

    # Same track, still inside the default 10-minute window — the gate
    # built alongside the recorder must see what the recorder just wrote.
    assert await gates[0].run(_ctx()) is False


@pytest.mark.asyncio
async def test_cooldown_disabled_omits_gate_and_recorder(cooldown_file) -> None:
    cfg = {"actions": {"like_cooldown": {"enabled": False}}}

    pre_actions, post_actions = _common.build_action_chains(cfg, storage=None)

    assert not any(type(a).__name__ == "LikeCooldownGate" for a in pre_actions)
    assert not any(type(a).__name__ == "LikeCooldownRecorder" for a in post_actions)


def test_cooldown_minutes_respected(cooldown_file) -> None:
    cfg = {"actions": {"like_cooldown": {"minutes": 30}}}

    pre_actions, _post_actions = _common.build_action_chains(cfg, storage=None)

    gate = next(a for a in pre_actions if type(a).__name__ == "LikeCooldownGate")
    assert gate._window_seconds == 30 * 60

# ── Back-compat: the "best-of" → "best" rename (v1.1.1) ────────────────


def _best_action(cfg: dict):
    _pre, post = _common.build_action_chains(cfg, storage=None)
    return next((a for a in post if type(a).__name__ == "PromoteToBestAction"), None)


def test_legacy_promote_to_best_of_block_still_builds_the_action(cooldown_file) -> None:
    """A config written by v1.1.0 or earlier keeps its best-playlist rule."""
    action = _best_action(
        {"actions": {"promote_to_best_of": {"playlist_name": "My Best", "threshold": 4}}}
    )

    assert action is not None
    assert action._playlist_name == "My Best"
    assert action._threshold == 4


def test_legacy_promote_to_best_of_block_honours_disabled(cooldown_file) -> None:
    assert (
        _best_action(
            {
                "actions": {
                    "promote_to_best_of": {"playlist_name": "My Best", "enabled": False}
                }
            }
        )
        is None
    )


def test_current_promote_to_best_block_wins_over_the_legacy_one(cooldown_file) -> None:
    """Once the settings window rewrites the block, the new name decides."""
    action = _best_action(
        {
            "actions": {
                "promote_to_best": {"playlist_name": "New", "threshold": 2},
                "promote_to_best_of": {"playlist_name": "Old", "threshold": 9},
            }
        }
    )

    assert action is not None
    assert action._playlist_name == "New"
    assert action._threshold == 2
