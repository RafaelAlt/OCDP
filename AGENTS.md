<!-- OCDP-managed: this file is deployed verbatim by the launcher to the portable
     config slot (home\.config\opencode\AGENTS.md — the app's isolated global
     config) on every run. Universal content only: no machine-specific paths, no
     personal information. Personal or machine-specific notes belong in
     AGENTS.user.md, next to this file — the launcher never reads or writes
     that file. -->

# OpenCode portable environment (OCDP)

This repository, once deployed, IS a live portable OpenCode installation.

- **Never run the launcher** (`launcher\OCDP.cmd` / `launcher\ocdp.ps1`) during an agent session: it kills every `*opencode*` process — including this session's own sidecar. Validate changes with `ocdp.ps1 -Help` (exits before the main flow) or isolated snippets.
- **Never install or update OpenCode yourself**: the native updater is intentionally disabled; the launcher updates from the official feed with sha512 verification.
- `home\` is **live user data** (session database, credentials/API keys, drafts, Electron profile): never delete, move or "clean" it.
- `app-64\` is a re-downloadable binary, git-ignored: deleting it is safe — the launcher reinstalls on the next run.
- The app runs with an **isolated environment**: `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` and `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` point into `home\` — every file the app and its sidecar write lands there. The machine's real profile folders are never touched.
- `HOME` deliberately stays on the real user profile: git and ssh inside agent sessions must keep finding `.gitconfig` and `.ssh`.
- **Never launch `app-64\OpenCode.exe` directly**: without the launcher's environment it runs against the real machine profile (separate data). Always start via `launcher\OCDP.cmd`.
- Nothing in `%TEMP%\opencode` is durable: the launcher wipes it on every launch.
- Personal or machine-specific context, if any, lives in `AGENTS.user.md` next to this file. It is NOT auto-loaded — read it when present; the launcher never touches it.
- Keep `launcher\ocdp.ps1` saved as UTF-8 **with BOM** (PowerShell 5.1 reads BOM-less files as ANSI, corrupting accented strings).
- UI text lives in the i18n table (`en` + `pt-BR`); code and comments in English.
