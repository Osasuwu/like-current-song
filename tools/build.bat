@echo off
:: Build LikeSpotify.exe (no terminal window).
:: Output: dist\LikeSpotify.exe (single-file, windowed).
::
:: Run from repo root: tools\build.bat   (or from tools\ directly).
::
:: Requires: Python 3.11+ and the `like-current-song` package installed with
:: dev extras (PyInstaller). One-liner from a clean clone:
::
::     pip install -e .[dev]

setlocal
pushd "%~dp0\.."

python -m PyInstaller --noconfirm tools\LikeSpotify.spec

popd
endlocal

echo.
echo Done: dist\LikeSpotify.exe
echo.
echo Next steps:
echo   1. Copy dist\LikeSpotify.exe somewhere convenient.
echo   2. From a terminal, run once for setup:
echo        LikeSpotify.exe --setup
echo      (Or `python -m like_spotify --setup` with the dev install.)
echo   3. Double-click LikeSpotify.exe to launch the tray host.
echo   4. Default hotkey: Ctrl+Shift+Alt+W
pause
