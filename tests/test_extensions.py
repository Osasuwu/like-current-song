"""Manifest-driven extension discovery (#144).

Each test builds a throwaway extensions package under `tmp_path` and points
`like_spotify.hosts._extensions` at it, so nothing here depends on (or
writes to) the shipped extensions or `~/.like_spotify`. The one exception is
`test_every_shipped_manifest_loads`, a data lint over the real folder.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from like_spotify.hosts import _extensions

_NOTE = re.compile(r"^Like Current Song: skipping extension '(?P<folder>[^']+)': (?P<reason>.+)$")


def _manifest(**overrides) -> dict:
    base = {
        "domain": "fake",
        "extension_point": "post_like_action",
        "name": "Fake",
        "description": "test extension",
        "codeowners": ["@nobody"],
        "requirements": [],
        "documentation": "https://example.invalid",
        "stage": "stable",
    }
    base.update(overrides)
    return base


class FakeRoot:
    """A real importable package on sys.path, standing in for `like_spotify.extensions`."""

    def __init__(self, base: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        self.package = "lcs_fake_ext_" + re.sub(r"\W", "_", base.name)
        pkgs = base / "pkgs"
        self.root = pkgs / self.package
        self.root.mkdir(parents=True)
        (self.root / "__init__.py").write_text("", encoding="utf-8")
        monkeypatch.syspath_prepend(str(pkgs))
        monkeypatch.setattr(_extensions, "_ROOT", self.root)
        monkeypatch.setattr(_extensions, "_PACKAGE", self.package)

    def add(self, folder: str, manifest: dict | str | None, source: str = "") -> Path:
        d = self.root / folder
        d.mkdir()
        (d / "__init__.py").write_text(source, encoding="utf-8")
        if isinstance(manifest, dict):
            (d / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        elif isinstance(manifest, str):
            (d / "manifest.json").write_text(manifest, encoding="utf-8")
        return d


@pytest.fixture
def fake_root(tmp_path, monkeypatch) -> FakeRoot:
    monkeypatch.setattr(_extensions, "_NOTED", set())
    return FakeRoot(tmp_path, monkeypatch)


def _notes(err: str) -> list[re.Match]:
    lines = [line for line in err.splitlines() if line.strip()]
    matches = [_NOTE.match(line) for line in lines]
    assert all(matches), f"unexpected stderr lines: {lines}"
    return matches


# ── Slice 1: discovery, and a bad manifest is a note, not a crash ──────


def test_scan_returns_each_valid_manifest_in_folder_order(fake_root, capsys) -> None:
    fake_root.add("zeta_action", _manifest(domain="zeta", name="Zeta", stage="beta"))
    fake_root.add(
        "alpha_store",
        _manifest(
            domain="alpha_db",
            extension_point="storage",
            name="Alpha",
            config_key="alpha",
            requirements=["requests>=2"],
        ),
    )

    found = _extensions.scan(fake_root.root, fake_root.package)

    assert [
        (e.folder, e.package, e.domain, e.extension_point, e.name, e.stage, e.config_key, e.requirements)
        for e in found
    ] == [
        ("alpha_store", f"{fake_root.package}.alpha_store", "alpha_db", "storage", "Alpha", "stable", "alpha", ("requests>=2",)),
        ("zeta_action", f"{fake_root.package}.zeta_action", "zeta", "post_like_action", "Zeta", "beta", "zeta", ()),
    ]
    assert capsys.readouterr().err == ""


def test_scan_ignores_private_and_cache_folders(fake_root, capsys) -> None:
    (fake_root.root / "__pycache__").mkdir()
    (fake_root.root / "_helpers").mkdir()
    fake_root.add("real", _manifest(domain="real"))

    assert [e.folder for e in _extensions.scan(fake_root.root, fake_root.package)] == ["real"]
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize(
    ("manifest", "reason"),
    [
        (None, "no manifest.json"),
        ("{not json", "manifest.json is not valid JSON"),
        ("[1, 2]", "manifest.json must be a JSON object"),
        (_manifest(stage=None), "'stage' must be one of"),
        (_manifest(stage="alpha"), "'stage' must be one of"),
        (_manifest(extension_point="widget"), "'extension_point' must be one of"),
        (_manifest(domain="has space"), "'domain' must be a Python identifier"),
        (_manifest(name=""), "'name' must be a non-empty string"),
        (_manifest(requirements="requests"), "'requirements' must be a list of strings"),
        (_manifest(requirements=["requests >>> 2"]), "invalid requirement 'requests >>> 2'"),
        (_manifest(config_key="a-b"), "'config_key' must be a Python identifier"),
    ],
)
def test_bad_manifest_is_skipped_with_one_line_note(fake_root, capsys, manifest, reason) -> None:
    fake_root.add("bad", manifest)
    fake_root.add("good", _manifest(domain="good"))

    found = _extensions.scan(fake_root.root, fake_root.package)

    assert [e.folder for e in found] == ["good"]
    (note,) = _notes(capsys.readouterr().err)
    assert note["folder"] == "bad"
    assert note["reason"].startswith(reason), note["reason"]


def test_unreadable_manifest_is_skipped_with_a_note(fake_root, capsys) -> None:
    fake_root.add("bad", None)
    (fake_root.root / "bad" / "manifest.json").mkdir()  # exists, cannot be read as a file
    fake_root.add("good", _manifest(domain="good"))

    assert [e.folder for e in _extensions.scan(fake_root.root, fake_root.package)] == ["good"]
    (note,) = _notes(capsys.readouterr().err)
    assert note["folder"] == "bad"
    assert note["reason"].startswith("cannot read manifest.json")


def test_missing_extensions_folder_is_no_extensions_and_one_note(tmp_path, monkeypatch, capsys) -> None:
    """A broken install (or a bundle without the manifests) must not crash the host."""
    monkeypatch.setattr(_extensions, "_NOTED", set())
    missing = tmp_path / "gone"

    assert _extensions.scan(missing, "gone") == []
    assert _extensions.scan(missing, "gone") == []
    err = [line for line in capsys.readouterr().err.splitlines() if line.strip()]
    assert len(err) == 1, err
    assert err[0].startswith("Like Current Song: cannot list extensions in "), err[0]


def test_second_extension_with_a_taken_domain_or_key_is_skipped(fake_root, capsys) -> None:
    fake_root.add("a_first", _manifest(domain="dup"))
    fake_root.add("b_same_domain", _manifest(domain="dup", extension_point="storage"))
    fake_root.add("c_same_key", _manifest(domain="other", extension_point="pre_like_action", config_key="dup"))
    fake_root.add("d_key_free_elsewhere", _manifest(domain="d", extension_point="storage", config_key="dup2"))

    found = _extensions.scan(fake_root.root, fake_root.package)

    assert [e.folder for e in found] == ["a_first", "d_key_free_elsewhere"]
    notes = _notes(capsys.readouterr().err)
    assert [(n["folder"], n["reason"]) for n in notes] == [
        ("b_same_domain", "domain 'dup' is already used by 'a_first'"),
        ("c_same_key", "config key 'actions.dup' is already used by 'a_first'"),
    ]


def test_every_shipped_manifest_loads(monkeypatch, capsys) -> None:
    """Data lint: each shipped extension folder is discovered, cleanly."""
    monkeypatch.setattr(_extensions, "_NOTED", set())
    root = Path(_extensions.__file__).resolve().parents[1] / "extensions"
    on_disk = sorted(
        p.name for p in root.iterdir() if p.is_dir() and (p / "__init__.py").exists()
    )

    found = _extensions.installed()

    assert capsys.readouterr().err == ""
    assert [e.folder for e in found] == on_disk
    # The sheets backend is selected as `storage.backend = "sheets"`, not by
    # its domain; the manifest has to say so for discovery to line up.
    assert {e.folder: e.config_key for e in found}["google_sheets_storage"] == "sheets"


def test_the_wheel_ships_every_manifest_and_the_parser_it_needs() -> None:
    """Data lint: the manifests are read at runtime now, so a pip install
    without one would silently drop that extension; and `packaging` parses
    their requirements, so it is a runtime dependency, not a test one."""
    import tomllib

    repo = Path(_extensions.__file__).resolve().parents[2]
    project = tomllib.loads((repo / "pyproject.toml").read_text(encoding="utf-8"))
    root = repo / "like_spotify" / "extensions"
    on_disk = {p.name for p in root.iterdir() if (p / "manifest.json").is_file()}
    data = project["tool"]["setuptools"]["package-data"]

    assert {
        pkg.rsplit(".", 1)[-1]
        for pkg, files in data.items()
        if pkg.startswith("like_spotify.extensions.") and "manifest.json" in files
    } == on_disk
    assert any(d.startswith("packaging") for d in project["project"]["dependencies"])


# ── Slice 2: the hosts build a new extension from its manifest alone ───

_PROVIDER_SRC = r'''
from pathlib import Path

from like_spotify.core.music_provider import MusicProvider
from like_spotify.core.types import CurrentTrack


class FakeProvider(MusicProvider):
    has_tokens = True

    def __init__(self, user, liked_log):
        self.user = user
        self.liked_log = liked_log

    async def get_currently_playing(self):
        return CurrentTrack(provider="fakeprov", provider_track_id="t-1", title="Song", artists=("A",))

    async def like(self, track):
        with open(self.liked_log, "a", encoding="utf-8") as fh:
            fh.write(f"like {track.provider_track_id}\n")

    async def is_liked(self, track):
        return False

    async def user_id(self):
        return self.user


def MUSIC_PROVIDER(user, config_dir):
    return FakeProvider(user, Path(config_dir) / "events.log")
'''

_POST_SRC = r'''
from pathlib import Path

from like_spotify.core.actions import PostLikeAction


class Record(PostLikeAction):
    def __init__(self, tag, path, storage):
        self.tag = tag
        self.path = path
        self.storage = storage

    async def run(self, ctx):
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(f"post {self.tag} {ctx.track.provider_track_id}\n")


def POST_LIKE_ACTION(config_dir, storage, tag="default"):
    return Record(tag, Path(config_dir) / "events.log", storage)
'''

_PRE_SRC = '''
from like_spotify.core.actions import PreLikeAction


class Gate(PreLikeAction):
    async def run(self, ctx):
        return True


def PRE_LIKE_ACTION():
    return Gate()
'''

_STORAGE_SRC = '''
from like_spotify.core.storage import Storage


def STORAGE(path):
    # Not a real Storage: the test only checks it is built with its config,
    # so a bare object would do -- but the host rejects non-Storage results.
    class S(Storage):
        pass
    S.__abstractmethods__ = frozenset()
    s = S()
    s.path = path
    return s
'''


@pytest.fixture
def cfg_dir(tmp_path, monkeypatch) -> Path:
    from like_spotify.hosts import _common

    d = tmp_path / "home"
    d.mkdir()
    # Every path the hosts read or write, so no test touches ~/.like_spotify.
    for attr, name in (
        ("CONFIG_FILE", "config.json"),
        ("SPOTIFY_TOKEN_FILE", "spotify_token.json"),
        ("GOOGLE_TOKEN_FILE", "google_token.json"),
        ("YOUTUBE_TOKEN_FILE", "youtube_token.json"),
        ("LIKE_COOLDOWN_FILE", "like_cooldown.json"),
        ("FOLLOWED_ARTISTS_FILE", "followed_artists.json"),
        ("PROMOTED_TRACKS_FILE", "promoted_tracks.json"),
    ):
        monkeypatch.setattr(_common, attr, d / name)
    return d


def test_build_provider_constructs_a_discovered_provider_from_its_config(fake_root, cfg_dir) -> None:
    from like_spotify.hosts import _common

    fake_root.add("fakeprov", _manifest(domain="fakeprov", extension_point="music_provider"), _PROVIDER_SRC)

    provider = _common.build_provider({"music": {"provider": "fakeprov"}, "fakeprov": {"user": "u-7"}})

    assert type(provider).__name__ == "FakeProvider"
    assert provider.user == "u-7"
    assert provider.liked_log == cfg_dir / "events.log"


def test_build_provider_without_the_providers_required_config_is_none(fake_root, cfg_dir, capsys) -> None:
    from like_spotify.hosts import _common

    fake_root.add("fakeprov", _manifest(domain="fakeprov", extension_point="music_provider"), _PROVIDER_SRC)

    assert _common.build_provider({"music": {"provider": "fakeprov"}}) is None
    err = capsys.readouterr().err
    assert "extension 'fakeprov' could not be built" in err
    assert "user" in err  # the missing argument is named


def test_build_storage_constructs_a_discovered_backend_by_its_config_key(fake_root, cfg_dir) -> None:
    from like_spotify.hosts import _common

    fake_root.add(
        "fake_store",
        _manifest(domain="fake_store", extension_point="storage", config_key="fakedb"),
        _STORAGE_SRC,
    )

    storage = _common.build_storage({"storage": {"backend": "fakedb"}, "fakedb": {"path": "x.db"}})

    assert storage is not None
    assert storage.path == "x.db"


def test_build_action_chains_appends_discovered_actions_after_the_shipped_ones(fake_root, cfg_dir) -> None:
    from like_spotify.hosts import _common

    fake_root.add("record", _manifest(domain="record", extension_point="post_like_action"), _POST_SRC)
    fake_root.add("gate", _manifest(domain="gate", extension_point="pre_like_action"), _PRE_SRC)
    sentinel_storage = object()
    cfg = {"actions": {"record": {"tag": "t9"}}}

    shipped_pre, shipped_post = _common.build_action_chains(
        {**cfg, "actions": {**cfg["actions"], "record": {"enabled": False}, "gate": {"enabled": False}}},
        sentinel_storage,
    )
    pre, post = _common.build_action_chains(cfg, sentinel_storage)

    assert [type(a).__name__ for a in pre] == [type(a).__name__ for a in shipped_pre] + ["Gate"]
    assert [type(a).__name__ for a in post] == [type(a).__name__ for a in shipped_post] + ["Record"]
    record = post[-1]
    assert (record.tag, record.path, record.storage) == ("t9", cfg_dir / "events.log", sentinel_storage)


def test_disabled_discovered_action_is_not_built(fake_root, cfg_dir) -> None:
    from like_spotify.hosts import _common

    fake_root.add("record", _manifest(domain="record", extension_point="post_like_action"), _POST_SRC)

    _pre, post = _common.build_action_chains({"actions": {"record": {"enabled": False}}}, None)

    assert "Record" not in [type(a).__name__ for a in post]


def test_shipped_action_extensions_are_built_once_by_their_own_builders(cfg_dir, monkeypatch, capsys) -> None:
    # The real extensions folder: every shipped action has a manifest too,
    # and must not be built a second time from it.
    from like_spotify.hosts import _common

    monkeypatch.setattr(_extensions, "_NOTED", set())
    cfg = {
        "actions": {
            "archive_remove": {"playlist_name": "Archive"},
            "promote_to_best": {"playlist_name": "Best"},
            "follow_artist": {},
        }
    }

    pre, post = _common.build_action_chains(cfg, object())

    assert [type(a).__name__ for a in pre] == ["LikeCooldownGate"]
    assert [type(a).__name__ for a in post] == [
        "LikeCooldownRecorder",
        "ArchiveRemoveAction",
        "PromoteToBestAction",
        "FollowArtistAction",
    ]
    assert "could not be built" not in capsys.readouterr().err


def test_explicitly_enabled_discovered_action_is_built_without_the_toggle(fake_root, cfg_dir) -> None:
    # `enabled` is the host's switch, not a factory argument: the Record
    # factory takes no `enabled`, so passing it through would break the build.
    from like_spotify.hosts import _common

    fake_root.add("record", _manifest(domain="record", extension_point="post_like_action"), _POST_SRC)

    _pre, post = _common.build_action_chains({"actions": {"record": {"enabled": True, "tag": "on"}}}, None)

    assert [a.tag for a in post if type(a).__name__ == "Record"] == ["on"]


def test_factory_returning_the_wrong_kind_of_object_is_skipped_with_a_note(fake_root, cfg_dir, capsys) -> None:
    from like_spotify.hosts import _common

    fake_root.add(
        "wrong",
        _manifest(domain="wrong", extension_point="post_like_action"),
        "def POST_LIKE_ACTION():\n    return 'not an action'\n",
    )

    _pre, post = _common.build_action_chains({}, None)

    assert "not an action" not in post
    assert "extension 'wrong' could not be built: POST_LIKE_ACTION returned str, not PostLikeAction" in capsys.readouterr().err


def test_extension_without_its_factory_is_skipped_with_a_note(fake_root, cfg_dir, capsys) -> None:
    from like_spotify.hosts import _common

    fake_root.add("nofactory", _manifest(domain="nofactory", extension_point="post_like_action"), "X = 1\n")

    _pre, post = _common.build_action_chains({}, None)

    assert len(post) == len(_common.build_action_chains({"actions": {"nofactory": {"enabled": False}}}, None)[1])
    assert "extension 'nofactory' could not be built: no POST_LIKE_ACTION in" in capsys.readouterr().err


def test_stub_like_once_runs_a_dropped_in_provider_and_action_end_to_end(fake_root, cfg_dir) -> None:
    from like_spotify.hosts import _common, _stub

    fake_root.add("fakeprov", _manifest(domain="fakeprov", extension_point="music_provider"), _PROVIDER_SRC)
    fake_root.add("record", _manifest(domain="record", extension_point="post_like_action"), _POST_SRC)
    _common.save_config(
        {
            "music": {"provider": "fakeprov"},
            "fakeprov": {"user": "u-1"},
            "actions": {"record": {"tag": "e2e"}, "like_cooldown": {"enabled": False}},
        }
    )

    assert _stub.main(["like-once"]) == 0
    assert (cfg_dir / "events.log").read_text(encoding="utf-8").splitlines() == [
        "like t-1",
        "post e2e t-1",
    ]


# ── Slice 3: requirements are checked against what is installed ────────

# A distribution name nothing on PyPI uses, so it is never installed.
_ABSENT = "lcs-no-such-dist-144"


def _ext(*requirements: str) -> _extensions.Extension:
    return _extensions.parse_manifest(
        _manifest(requirements=list(requirements)), "fake", "pkg"
    )


def test_requirement_problems_names_a_distribution_that_is_not_installed() -> None:
    assert _extensions.requirement_problems(_ext(f"{_ABSENT}>=1")) == [
        f"{_ABSENT}>=1 (not installed)"
    ]


def test_requirement_problems_names_an_installed_version_outside_the_range() -> None:
    assert _extensions.requirement_problems(_ext("pytest>=999")) == [
        f"pytest>=999 (found {pytest.__version__})"
    ]


def test_met_requirements_and_ones_for_another_platform_are_not_problems() -> None:
    ext = _ext("pytest>=1", f"{_ABSENT}>=1; sys_platform == 'no-such-os'")

    assert _extensions.requirement_problems(ext) == []


def test_requirements_are_not_checked_in_a_frozen_build(monkeypatch) -> None:
    # PyInstaller bundles no dist-info, so every requirement would read as
    # missing; the bundle was built with them, so there is nothing to check.
    monkeypatch.setattr(_extensions.sys, "frozen", True, raising=False)

    assert _extensions.requirement_problems(_ext(f"{_ABSENT}>=1")) is None


def test_unmet_requirement_is_noted_once_and_the_extension_still_built(fake_root, cfg_dir, capsys) -> None:
    from like_spotify.hosts import _common

    fake_root.add(
        "record",
        _manifest(domain="record", extension_point="post_like_action", requirements=[f"{_ABSENT}>=1"]),
        _POST_SRC,
    )

    for _ in range(2):  # the resident host rebuilds the chains on every reload
        _pre, post = _common.build_action_chains({}, None)
        assert "Record" in [type(a).__name__ for a in post]

    assert capsys.readouterr().err.splitlines() == [
        f"Like Current Song: extension 'record' needs {_ABSENT}>=1 (not installed)"
    ]


# ── Slice 4: `--config` lists every installed extension with its stage ──


def _listing(out: str) -> list[str]:
    lines = out.splitlines()
    assert "Extensions:" in lines
    return lines[lines.index("Extensions:") + 1 :]


def test_config_listing_shows_each_extension_with_its_point_and_stage(fake_root, cfg_dir, capsys) -> None:
    from like_spotify.hosts import _common

    fake_root.add("b_gate", _manifest(domain="gate", name="Gate", extension_point="pre_like_action", stage="beta"), _PRE_SRC)
    fake_root.add("a_record", _manifest(domain="record", name="Record", stage="experimental"), _POST_SRC)

    assert _common.print_config_paths() == 0

    assert _listing(capsys.readouterr().out) == [
        "  Record (record, post_like_action, experimental)",
        "  Gate (gate, pre_like_action, beta)",
    ]


def test_config_listing_names_unmet_requirements(fake_root, cfg_dir, capsys) -> None:
    from like_spotify.hosts import _common

    fake_root.add("record", _manifest(domain="record", name="Record", requirements=[f"{_ABSENT}>=1", "pytest>=1"]), _POST_SRC)

    _common.print_config_paths()

    assert _listing(capsys.readouterr().out) == [
        f"  Record (record, post_like_action, stable); needs {_ABSENT}>=1 (not installed)",
    ]
