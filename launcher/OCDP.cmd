@echo off
setlocal EnableExtensions
rem ============================================================
rem  OCDP - OpenCode Desktop Portable
rem  Portable root = parent of this .cmd's folder (launcher\)  (%~dp0..)
rem
rem  Code/comments stay English; user-facing text is localized
rem  inside ocdp.ps1 (i18n table, auto language detection).
rem ============================================================

rem Keep OpenCode's own updater disabled (inherited by the child
rem opencode-cli.exe and by the standalone CLI). Re-enforced in ocdp.ps1.
set "OPENCODE_DISABLE_AUTOUPDATE=1"

rem Forward arguments (-NoUpdate, -Force, -Lang, -Help) to the script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ocdp.ps1" %*
set "RC=%ERRORLEVEL%"

rem On error, hold the window so the (localized) message stays readable.
if not "%RC%"=="0" pause
exit /b %RC%
