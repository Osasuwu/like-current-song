"""Extension discovery: read each extension's `manifest.json` at startup (#144).

Every subfolder of `like_spotify/extensions/` with a `manifest.json` is an
extension. `installed()` returns them; the hosts' builders in `_common`
look an extension up by its extension point and config key, so a new folder
with a valid manifest is picked up without an edit to `_common`.

A folder whose manifest is missing, unreadable or invalid is skipped with
one line on stderr — never a crash, since one bad extension must not take
the like flow down with it.
"""

from __future__ import annotations

import importlib
import inspect
import json
import sys
from dataclasses import dataclass
from importlib import metadata
from pathlib import Path

from packaging.requirements import InvalidRequirement, Requirement
from packaging.version import InvalidVersion, Version

import like_spotify.extensions as _extensions_pkg

# The real extensions folder. Tests point these at a throwaway package.
_ROOT = Path(_extensions_pkg.__file__).parent
_PACKAGE = _extensions_pkg.__name__

# Extension point → the factory name its `__init__.py` exports.
EXTENSION_POINTS: dict[str, str] = {
    "trigger": "TRIGGER",
    "music_provider": "MUSIC_PROVIDER",
    "storage": "STORAGE",
    "pre_like_action": "PRE_LIKE_ACTION",
    "post_like_action": "POST_LIKE_ACTION",
}

STAGES = ("stable", "beta", "experimental", "deprecated")

# Top-level config.json blocks the hosts own. A provider or storage reads
# `cfg[<config_key>]`, so it may not take one of these names.
RESERVED_CONFIG_KEYS = frozenset({"music", "storage", "actions", "trigger", "like"})


def _config_path(extension_point: str, key: str) -> str:
    """Where an extension's settings live in config.json.

    Both action points share `actions.<key>` (a pre/post pair such as
    like-cooldown reads one block), so they share one key space.
    """
    if extension_point in ("pre_like_action", "post_like_action"):
        return f"actions.{key}"
    if extension_point == "trigger":
        return f"trigger.{key}"
    return key


class ManifestError(ValueError):
    """The manifest cannot describe a loadable extension."""


@dataclass(frozen=True)
class Extension:
    folder: str
    package: str
    domain: str
    extension_point: str
    name: str
    stage: str
    description: str = ""
    requirements: tuple[str, ...] = ()
    # The name config.json selects it by: `music.provider`, `storage.backend`,
    # or the `actions.<key>` block. Defaults to `domain`.
    config_key: str = ""

    @property
    def factory_name(self) -> str:
        return EXTENSION_POINTS[self.extension_point]

    @property
    def config_path(self) -> str:
        return _config_path(self.extension_point, self.config_key)


def _identifier(data: dict, key: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.isidentifier():
        raise ManifestError(f"'{key}' must be a Python identifier, got {value!r}")
    return value


def parse_manifest(data: object, folder: str, package: str) -> Extension:
    if not isinstance(data, dict):
        raise ManifestError("manifest.json must be a JSON object")

    domain = _identifier(data, "domain")

    point = data.get("extension_point")
    if not isinstance(point, str) or point not in EXTENSION_POINTS:
        raise ManifestError(
            f"'extension_point' must be one of {', '.join(EXTENSION_POINTS)}, got {point!r}"
        )

    name = data.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ManifestError(f"'name' must be a non-empty string, got {name!r}")

    stage = data.get("stage")
    if stage not in STAGES:
        raise ManifestError(f"'stage' must be one of {', '.join(STAGES)}, got {stage!r}")

    requirements = data.get("requirements", [])
    if not isinstance(requirements, list) or not all(isinstance(r, str) for r in requirements):
        raise ManifestError(f"'requirements' must be a list of strings, got {requirements!r}")
    for req in requirements:
        try:
            Requirement(req)
        except InvalidRequirement as e:
            # packaging's message spans lines (it draws a caret); the note is one.
            reason = str(e).splitlines()[0] if str(e) else "unparseable"
            raise ManifestError(f"invalid requirement {req!r}: {reason}") from None

    config_key = _identifier(data, "config_key") if "config_key" in data else domain
    if point in ("music_provider", "storage") and config_key in RESERVED_CONFIG_KEYS:
        raise ManifestError(f"'config_key' '{config_key}' is reserved for the host's own settings")

    description = data.get("description", "")
    return Extension(
        folder=folder,
        package=f"{package}.{folder}",
        domain=domain,
        extension_point=point,
        name=name.strip(),
        stage=stage,
        description=description if isinstance(description, str) else "",
        requirements=tuple(requirements),
        config_key=config_key,
    )


def _note(message: str) -> None:
    print(f"Like Current Song: {message}", file=sys.stderr)


# Messages already printed this process, so a builder called on every
# like does not repeat itself.
_NOTED: set[str] = set()


def _note_once(message: str) -> None:
    if message not in _NOTED:
        _NOTED.add(message)
        _note(message)


def _skip(folder: str, reason: str) -> None:
    _note_once(f"skipping extension '{folder}': {reason}")


def _read(folder: Path) -> object:
    path = folder / "manifest.json"
    if not path.exists():
        raise ManifestError("no manifest.json")
    try:
        text = path.read_text(encoding="utf-8-sig")  # Notepad may add a BOM
    except (OSError, UnicodeDecodeError) as e:
        raise ManifestError(f"cannot read manifest.json: {e}") from None
    try:
        return json.loads(text)
    # ValueError covers JSONDecodeError and an integer past Python's digit
    # limit; RecursionError is deeply nested arrays or objects.
    except (ValueError, RecursionError) as e:
        raise ManifestError(f"manifest.json is not valid JSON: {e}") from None


def scan(root: Path, package: str) -> list[Extension]:
    """Every loadable extension under `root`, sorted by folder name.

    Folders starting with `_` or `.` (`__pycache__`, helpers) are not
    extensions. A later folder reusing a taken domain, or a taken config
    key in the same key space, is skipped: the first one keeps it.
    """
    try:
        folders = sorted(p for p in root.iterdir() if p.is_dir())
    except OSError as e:
        _note_once(f"cannot list extensions in {root}: {e}")
        return []
    found: list[Extension] = []
    domains: dict[str, str] = {}
    keys: dict[str, str] = {}
    for folder in folders:
        if folder.name.startswith(("_", ".")):
            continue
        if not folder.name.isidentifier():
            # It becomes part of the import path: `a.b` would import another module.
            _skip(folder.name, "folder name must be a Python identifier")
            continue
        try:
            ext = parse_manifest(_read(folder), folder.name, package)
        except ManifestError as e:
            _skip(folder.name, str(e))
            continue
        except Exception as e:  # one folder must never stop the rest loading
            _skip(folder.name, f"unexpected error: {type(e).__name__}: {e}")
            continue
        if ext.domain in domains:
            _skip(folder.name, f"domain '{ext.domain}' is already used by '{domains[ext.domain]}'")
            continue
        if ext.config_path in keys:
            _skip(
                folder.name,
                f"config key '{ext.config_path}' is already used by '{keys[ext.config_path]}'",
            )
            continue
        domains[ext.domain] = folder.name
        keys[ext.config_path] = folder.name
        found.append(ext)
    return found


def installed() -> list[Extension]:
    """The extensions shipped in (or dropped into) `like_spotify/extensions/`."""
    return scan(_ROOT, _PACKAGE)


def find(extension_points: tuple[str, ...], key: str) -> Extension | None:
    """The installed extension at one of `extension_points` selected by `key`."""
    if not key:
        return None
    for ext in installed():
        if ext.extension_point in extension_points and ext.config_key == key:
            return ext
    return None


def requirement_problems(ext: Extension) -> list[str] | None:
    """The manifest's requirements this environment does not meet.

    Each problem reads `<requirement> (not installed)` or `<requirement>
    (found <version>)`. A requirement whose environment marker does not
    match (`; sys_platform == 'win32'` on Linux) is not a problem. Returns
    None, meaning "not checked", in a frozen (PyInstaller) build: it ships
    no package metadata, so every requirement would read as missing.
    """
    if getattr(sys, "frozen", False):
        return None
    problems: list[str] = []
    for text in ext.requirements:
        req = Requirement(text)  # parse_manifest already proved it parses
        if req.marker is not None and not req.marker.evaluate():
            continue
        try:
            found = metadata.version(req.name)
        except metadata.PackageNotFoundError:
            problems.append(f"{text} (not installed)")
            continue
        try:
            Version(found)
        except InvalidVersion:
            # packaging 23.x raises from `contains` on such a version.
            problems.append(f"{text} (found {found}, not a valid version)")
            continue
        if not req.specifier.contains(found, prereleases=True):
            problems.append(f"{text} (found {found})")
    return problems


def report_requirements(ext: Extension) -> None:
    """One note per process for each extension with unmet requirements.

    A note, not a refusal: the extension is still built, and if it truly
    cannot work its import or factory fails with a note of its own.
    """
    problems = requirement_problems(ext)
    if problems:
        _note_once(f"extension '{ext.folder}' needs {', '.join(problems)}")


def describe(ext: Extension) -> str:
    """One line for the `--config` listing: name, domain, point, stage, and
    any unmet requirements."""
    line = f"{ext.name} ({ext.domain}, {ext.extension_point}, {ext.stage})"
    problems = requirement_problems(ext)
    if problems:
        line += f"; needs {', '.join(problems)}"
    return line


def _expected_type(extension_point: str) -> type | None:
    # Imported here, not at module top: `core` must not load before the
    # extensions package does for anything that only wants to list them.
    from like_spotify.core.actions import PostLikeAction, PreLikeAction
    from like_spotify.core.music_provider import MusicProvider
    from like_spotify.core.storage import Storage

    return {
        "music_provider": MusicProvider,
        "storage": Storage,
        "pre_like_action": PreLikeAction,
        "post_like_action": PostLikeAction,
    }.get(extension_point)


def build(
    ext: Extension,
    section: object,
    *,
    config_dir: Path,
    storage: object | None = None,
):
    """Construct `ext` from its config block, or None if it cannot be.

    The factory is called with the block's keys as keyword arguments
    (`enabled` is the host's toggle and is not passed). Two more are passed
    when the factory's signature names them: `config_dir`, the folder
    config.json lives in, for state files; and `storage`, the configured
    Storage or None. A factory returning None means "not configured". Any
    failure — import error, missing factory, bad arguments, an object of
    the wrong kind — is one note on stderr and None, never a crash.
    """
    kwargs = {k: v for k, v in section.items() if k != "enabled"} if isinstance(section, dict) else {}
    report_requirements(ext)
    try:
        module = importlib.import_module(ext.package)
        factory = getattr(module, ext.factory_name, None)
        if not callable(factory):
            raise ManifestError(f"no {ext.factory_name} in {ext.package}")
        params = inspect.signature(factory).parameters
        if "config_dir" in params:
            kwargs["config_dir"] = config_dir
        if "storage" in params:
            kwargs["storage"] = storage
        built = factory(**kwargs)
        expected = _expected_type(ext.extension_point)
        if built is not None and expected is not None and not isinstance(built, expected):
            raise ManifestError(
                f"{ext.factory_name} returned {type(built).__name__}, not {expected.__name__}"
            )
        return built
    except Exception as e:  # one bad extension must not stop the like flow
        _note_once(f"extension '{ext.folder}' could not be built: {e}")
        return None
