# OCDP — OpenCode Desktop Portable

> [Leia em português](README.pt-BR.md)

Portable launcher for **OpenCode Desktop** on Windows: keeps all application
data inside the portable folder itself (via junctions), keeps the app updated
from the official feed with integrity checks (sha512), and starts it in
portable mode.

> Requirements: Windows 10+ (x64 or arm64), PowerShell 5.1. `curl.exe`
> (Win10 1803+) is used when available, with automatic fallback without it.

## Usage

- **Double-click `launcher\OCDP.cmd`** — does everything (doors → update → launch).
- Flags (via `launcher\OCDP.cmd -Flag`):

| Flag | Effect |
|---|---|
| `-NoUpdate` | Skips update check/download. Fails if no app is installed. |
| `-Force` | Reinstalls even if up to date. Incompatible with `-NoUpdate`. |
| `-Lang` | Forces the interface language (`en`, `pt-BR`). |
| `-Help` | Shows help and exits. |

- The `OCDP_LANG` environment variable does the same as `-Lang` (the parameter wins).
- Default language: Windows display language, falling back to English.

## Install from a clone (GitHub)

1. Clone or download the repository — it contains only `launcher\`, this README
   and the licenses (OpenCode itself is **not** included).
2. Double-click `launcher\OCDP.cmd`.
3. On first run, the launcher downloads OpenCode from the official feed (~226 MB,
   sha512-validated), creates `app-64\` and `data\` next to it, and opens the app.
4. Settings, sessions and credentials live in `data\` — deleting `app-64\`
   is safe (the launcher reinstalls); deleting `data\` deletes your real data.

## Layout

```
OCDP\
├── README.md           this file
├── README.pt-BR.md     same docs in Portuguese
├── LICENSE             OCDP MIT license
├── AGENTS.md           universal agent rules (the launcher deploys them to the global slot on each run)
├── .gitignore          what stays out of GitHub (app-64, data, logs)
├── app-64\             the application (historic name; holds the x64 or arm64 build)
├── data\               ALL OpenCode data (junction targets)
└── launcher\           everything OCDP-specific (goes to GitHub)
    ├── OCDP.cmd        entry point (sets OPENCODE_DISABLE_AUTOUPDATE)
    ├── ocdp.ps1        the launcher (code/comments in English, localized UI)
    ├── ocdp.log        run log (rotates to ocdp.log.old past 512 KB)
    ├── 7za.exe/.dll    NSIS installer extractor
    ├── LICENSE-7za.txt 7-Zip license (LGPL)
    ├── sweep-files.ps1 opencode/ocdp file scan (read-only)
    └── sweep-system.ps1 registry/system scan (read-only)
```

### What's in `data\`

| Folder | Original location | Contents | User data? |
|---|---|---|---|
| `share-opencode` | `~\.local\share\opencode` | `opencode.db` database (sessions, messages, credentials/API keys), logs, snapshots | 🔑 Yes |
| `config-opencode` | `~\.config\opencode` | `opencode.json` (settings), `service.json` | ⚠️ Yes |
| `state-opencode` | `~\.local\state\opencode` | Current run state (PID, port, local password) | ⚠️ Volatile |
| `ai.opencode.desktop` | `%APPDATA%\ai.opencode.desktop` | Electron profile: drafts, Local Storage, cookies, logs, caches, `cli\opencode-cli.exe` | ⚠️ Partial |
| `cache-opencode` | `~\.cache\opencode` | Cache (e.g. `rg.exe`) — deletable | ❌ No |

## How it works (summary)

1. **Instance lock** (mutex per portable root): a second simultaneous `OCDP.cmd`
   fails fast instead of competing over download/swap.
2. **Stops any `*opencode*` process** (app, "opencode-cli" sidecar, TUI,
   installer) — avoids locked files during migration/swap — and empties the
   session scratch dir (`%TEMP%\opencode`).
3. **Doors (junctions)**: the app looks for its data at fixed addresses
   (`%APPDATA%\ai.opencode.desktop`, `~\.config\opencode`, etc.). The script
   creates junctions at those addresses pointing into `data\`. It is always
   the SAME physical file — deleting content through a door deletes the real data.
4. **Native updater disabled on purpose** (3 layers):
   `OPENCODE_DISABLE_AUTOUPDATE=1` (env), `opencode.json` (`update: disable` /
   `autoupdate: false`) and removal of `resources\app-update.yml`. Updates
   come ONLY from this script (official feed + sha512).
5. **Update**: reads the official `latest.yml` (with retry and TLS 1.2), compares
   versions, downloads the installer (curl with fallback), **validates sha512 +
   size**, extracts with 7za into `app-64.new`, removes `app-update.yml`, swaps
   (`app-64` → `app-64.old` → removal with retries). Locked folders are retried
   automatically and only then reported as errors, never silent corruption; if
   applying the new version fails mid-swap, the previous install is restored
   automatically (rollback).
6. **Launch** of `app-64\OpenCode.exe` — the launcher window **closes by
   itself** (the app runs detached from the console); on error it stays open
   with a readable message.

## Troubleshooting

| Symptom | Explanation / action |
|---|---|
| "stopping related processes..." on start | Normal (by design): avoids file conflicts. |
| "another OCDP instance is already running" | Wait a moment and run again. |
| "old/staging folder still locked" | Only shown if something holds it after automatic retries — close the processes (`OpenCode`, `opencode-cli`) and try again. |
| "could not read the update feed" | See `launcher\ocdp.log` — the real cause (DNS/TLS/proxy) is logged there. |
| "could not stop: ..." | Close manually via Task Manager and run again. |
| Where to look for problems | `launcher\ocdp.log` (launcher) and `data\share-opencode\log\opencode.log` (app). |

## Important notes

- **Never delete the contents of `data\`** thinking they are a "copy" of the C:
  folders — the C: folders are doors; the data lives here.
- Deleting *a door* is safe: the next run recreates it. To remove only the
  door, use `rmdir "C:\path\to\door"` (never "delete contents").
- **Moving the whole OCDP folder is safe**: the doors are relinked by themselves.
- The launcher deploys the universal `AGENTS.md` (English, no machine paths) to
  `~\.config\opencode\AGENTS.md` on each run — idempotent; it only overwrites
  files carrying the `<!-- OCDP-managed -->` mark, never a third-party global.
  Personal/machine notes: `AGENTS.user.md` next to it — never read nor written
  by the launcher and out of git; the managed `AGENTS.md` tells agents it
  exists (not auto-loaded: the agent reads it when present).
- Keep `launcher\ocdp.ps1` saved as **UTF-8 with BOM** (PS 5.1 requirement
  for pt-BR accents).
- Launching `app-64\OpenCode.exe` directly works (the doors already exist), but
  skips the update check — prefer `launcher\OCDP.cmd`.
- If the app recreates the `OpenCode` Start Menu shortcut pointing at the `.exe`,
  the launcher repoints it to `launcher\OCDP.cmd` on each run (it never
  creates the shortcut: if you delete it, it stays deleted).

## License

OCDP under **MIT** (see root `LICENSE`). The bundled 7-Zip
(`launcher\7za.exe/.dll`) follows its own 7-Zip license — see
`launcher\LICENSE-7za.txt`.

## Credits

Designed by **Rafael Alt**; code generated by AI models.
Extractor: [7-Zip](https://www.7-zip.org/) 26.04 © Igor Pavlov (LGPL — see
`launcher\LICENSE-7za.txt`).
