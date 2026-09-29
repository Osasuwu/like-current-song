"""The standalone exe's bundle check (#214): no credentials ship, nothing lazy
is missing. Exercised on synthetic bundle contents — CI runs it against the
real exe after building."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_PATH = Path(__file__).resolve().parent.parent / "tools" / "check_bundle.py"
_spec = importlib.util.spec_from_file_location("check_bundle", _PATH)
check_bundle = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_bundle)

REQUIRED = ["like_spotify.extensions.spotify", "winrt.windows.media.control"]
MODULES = {m: b"\xe3compiled" for m in REQUIRED}


def test_clean_bundle_has_no_problems() -> None:
    files = [
        ("certifi/cacert.pem", b"-----BEGIN CERTIFICATE-----"),
        ("like_spotify/extensions/spotify/manifest.json", b'{"name": "spotify"}'),
        # The Settings form's empty field is not a secret.
        ("defaults.json", b'{"client_secret": ""}'),
    ]

    assert check_bundle.find_problems(files, MODULES, REQUIRED) == []


@pytest.mark.parametrize(
    "name",
    [
        ".env",
        ".env.local",
        "spotify_token.json",
        "like_spotify/google_token.json",
        "client_secret_1234.apps.googleusercontent.com.json",
        "credentials.json",
        "config.json",
        "android\\key.properties",
        "upload-keystore.jks",
        "release.keystore",
    ],
)
def test_credential_file_names_are_denied(name) -> None:
    problems = check_bundle.find_problems([(name, b"")], MODULES, REQUIRED)

    assert problems == [f"credential-like file bundled: {name}"]


@pytest.mark.parametrize(
    "data, label",
    [
        (b"secret = 'GOCSPX-abcdefghijklmnop'", "Google client secret"),
        (b'{"client_secret": "shh"}', "filled-in client_secret"),
        (b'{"refresh_token" : "AQD-xyz"}', "filled-in refresh_token"),
        (b"1//0gAbCdEfGhIjKlMnOpQrStUvWx", "Google refresh token"),
        (b"ya29.a0AfH6SMBabcdefghijklmnopq", "Google access token"),
    ],
)
def test_secret_values_in_data_files_are_found(data, label) -> None:
    problems = check_bundle.find_problems([("settings.dat", data)], MODULES, REQUIRED)

    assert problems == [f"{label} in settings.dat"]


def test_secret_compiled_into_a_module_is_found() -> None:
    modules = {
        **MODULES,
        "like_spotify.hosts._common": b"\xe3...GOCSPX-abcdefghijklmnop...",
    }

    problems = check_bundle.find_problems([], modules, REQUIRED)

    assert problems == ["Google client secret in module like_spotify.hosts._common"]


def test_missing_required_module_is_reported() -> None:
    modules = {"like_spotify.extensions.spotify": b""}

    problems = check_bundle.find_problems([], modules, REQUIRED)

    assert problems == ["module missing from bundle: winrt.windows.media.control"]


def test_required_modules_cover_every_extension_package() -> None:
    required = check_bundle.required_modules()
    root = (
        Path(check_bundle.__file__).resolve().parent.parent
        / "like_spotify"
        / "extensions"
    )
    packages = {d.name for d in root.iterdir() if (d / "__init__.py").exists()}

    extensions = {
        m.split(".")[2] for m in required if m.startswith("like_spotify.extensions.")
    }

    # Exactly the packages: a leftover folder holding only __pycache__ is not
    # an extension and must not be required.
    assert extensions == packages
    assert "like_spotify.hosts.settings.window" in required


def test_main_rejects_a_missing_exe(tmp_path, capsys) -> None:
    assert check_bundle.main([str(tmp_path / "nope.exe")]) == 2
    assert "no such file" in capsys.readouterr().err


def test_native_binaries_are_name_checked_but_not_scanned() -> None:
    files = [("_winrt.pyd", b"GOCSPX-abcdefghijklmnop"), ("upload.jks", b"")]

    problems = check_bundle.find_problems(files, MODULES, REQUIRED)

    assert problems == ["credential-like file bundled: upload.jks"]
