<!-- OCDP-managed: this file is deployed verbatim by the launcher to the global
     config slot (~/.config/opencode/AGENTS.md) on every run. Universal content
     only: no machine-specific paths, no personal information. Personal or
     machine-specific notes belong in AGENTS.user.md, next to this file — the
     launcher never reads or writes that file. -->

# OpenCode portable environment (OCDP)

This repository, once deployed, IS a live portable OpenCode installation.

- **Never run the launcher** (`launcher\OCDP.cmd` / `launcher\ocdp.ps1`) during an agent session: it kills every `*opencode*` process — including this session's own sidecar. Validate changes with `ocdp.ps1 -Help` (exits before the main flow) or isolated snippets.
- **Never install or update OpenCode yourself**: the native updater is intentionally disabled; the launcher updates from the official feed with sha512 verification.
- `data\` is **live user data** (session database, credentials/API keys, drafts, extensions): never delete, move or "clean" it.
- `app-64\` is a re-downloadable binary, git-ignored: deleting it is safe — the launcher reinstalls on the next run.
- The profile folders for OpenCode data are NTFS junctions (doors) into `data\`: the real data lives in `data\`.
- Nothing in `%TEMP%\opencode` is durable: the launcher wipes it on every launch.
- Personal or machine-specific context, if any, lives in `AGENTS.user.md` next to this file. It is NOT auto-loaded — read it when present; the launcher never touches it.
- Keep `launcher\ocdp.ps1` saved as UTF-8 **with BOM** (PowerShell 5.1 reads BOM-less files as ANSI, corrupting accented strings).
- UI text lives in the i18n table (`en` + `pt-BR`); code and comments in English.
