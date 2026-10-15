# OCDP — OpenCode Desktop Portable

> [Leia em português](README.pt-BR.md)

Portable launcher for **OpenCode Desktop** on Windows: runs the app with an
isolated environment whose data lives inside the portable folder itself (no
junctions, no machine-profile writes), keeps it updated from the official feed
with integrity checks (sha512), and starts it in portable mode.

> Requirements: Windows 10+ (x64 or arm64), PowerShell 5.1. `curl.exe`
> (Win10 1803+) is used when available, with automatic fallback without it.

## Usage

- **Double-click `launcher\OCDP.cmd`** — does everything (isolate → update → launch).
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
   sha512-validated), creates `app-64\`, `home\` and `projects\` next to it, and
   opens the app. Coming from v2 (old `data\` layout)? The first run moves
   `data\*` into `home\` automatically and removes the old junctions — see
   `ocdp.log`.
4. Settings, sessions and credentials live in `home\` — deleting `app-64\`
   is safe (the launcher reinstalls); deleting `home\` deletes your real data.

## Layout

```
OCDP\
├── README.md           this file
├── README.pt-BR.md     same docs in Portuguese
├── LICENSE             OCDP MIT license
├── AGENTS.md           universal agent rules (the launcher deploys them to the portable global slot on each run)
├── .gitignore          what stays out of GitHub (app-64, home, logs)
├── app-64\             the application (historic name; holds the x64 or arm64 build)
├── projects\           default home for your projects (travels with the folder)
├── home\               the app's isolated environment: ALL OpenCode data lives here
└── launcher\           everything OCDP-specific (goes to GitHub)
    ├── OCDP.cmd        entry point (sets OPENCODE_DISABLE_AUTOUPDATE)
    ├── ocdp.ps1        the launcher (code/comments in English, localized UI)
    ├── ocdp.log        run log (rotates to ocdp.log.old past 512 KB)
    ├── root.marker     previous portable root (path-remap state, rewritten on each run)
    ├── 7za.exe/.dll    NSIS installer extractor
    ├── sqlite3.exe     saved-state repair tool (public domain)
    ├── LICENSE-7za.txt 7-Zip license (LGPL)
    ├── sweep-files.ps1 opencode/ocdp file scan (read-only)
    └── sweep-system.ps1 registry/system scan (read-only)
```

### What's in `home\`

The app runs with an isolated environment: `USERPROFILE`, `APPDATA`,
`LOCALAPPDATA` and the `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` slots
point into `home\`. These are the app's real paths — nothing is a junction:

| Folder | Slot | Contents | User data? |
|---|---|---|---|
| `home\.local\share\opencode` | `XDG_DATA_HOME` | `opencode.db` database (sessions, messages, credentials/API keys), logs, snapshots | 🔑 Yes |
| `home\.config\opencode` | `XDG_CONFIG_HOME` | `opencode.json` (settings), the managed `AGENTS.md` | ⚠️ Yes |
| `home\.local\state\opencode` | `USERPROFILE` | Current run state (PID, port, local password) | ⚠️ Volatile |
| `home\AppData\Roaming\ai.opencode.desktop` | `APPDATA` | Electron profile: drafts, Local Storage, cookies, logs, caches, `cli\opencode-cli.exe` | ⚠️ Partial |
| `home\.cache\opencode` | `XDG_CACHE_HOME` | Cache (e.g. `rg.exe`) — deletable | ❌ No |
| `home\AppData\Local` | `LOCALAPPDATA` | Spare slot (stray writes); usually empty | ❌ No |

The machine's real `C:\Users\<you>\...` folders are never touched; `HOME`
deliberately stays on the real profile so that git/ssh inside agent sessions
keep finding `.gitconfig`/`.ssh`.

## How it works (summary)

1. **Instance lock** (mutex per portable root): a second simultaneous `OCDP.cmd`
   fails fast instead of competing over download/swap.
2. **Stops any `*opencode*` process** (app, "opencode-cli" sidecar, TUI,
   installer) — avoids locked files during migration/swap — and empties the
   session scratch dir (`%TEMP%\opencode`).
3. **Isolated environment**: instead of rewriting the machine's folders, the
   launcher starts the app with `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` and
   `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` pointing into `home\`.
   The app and everything it spawns (sidecar, agents, tools) resolve their
   paths there. On the first run after upgrading from v2, an old `data\`
   layout is moved into `home\` and the old junctions are removed (link only)
   — the machine profile is never written to.
4. **Projects + saved sessions**: creates the default `projects\` folder and,
   with the app stopped, repairs the saved session locations in the desktop
   (`home\AppData\Roaming\ai.opencode.desktop\drafts.sqlite`) and in the
   session database (`home\.local\share\opencode\opencode.db`). If the portable folder changed
   path/machine (`launcher\root.marker` stores the previous root), saved paths
   under it are remapped. Projects moved into `projects\` wake up
   automatically: a saved path whose folder name exists under `projects\` is
   re-pointed there (desktop tabs, project list and sessions). Locations that
   still do not exist are dropped, a stale last-open project falls back to
   `projects\`, and project entries pruned by earlier runs are restored from
   the session database. This is what keeps the app from booting into a
   broken "session not found" screen on another machine. The repair never
   blocks the launch: any failure is logged (`ocdp.log`) and retried on the
   next run.
5. **Native updater disabled on purpose** (3 layers):
   `OPENCODE_DISABLE_AUTOUPDATE=1` (env), `opencode.json` (`update: disable` /
   `autoupdate: false`) and removal of `resources\app-update.yml`. Updates
   come ONLY from this script (official feed + sha512).
6. **Update**: reads the official `latest.yml` (with retry and TLS 1.2), compares
   versions, downloads the installer (curl with fallback), **validates sha512 +
   size**, extracts with 7za into `app-64.new`, removes `app-update.yml`, swaps
   (`app-64` → `app-64.old` → removal with retries). Locked folders are retried
   automatically and only then reported as errors, never silent corruption; if
   applying the new version fails mid-swap, the previous install is restored
   automatically (rollback).
7. **Launch** of `app-64\OpenCode.exe` with the isolated environment — the
   launcher window **closes by itself** (the app runs detached from the
   console); on error it stays open with a readable message.

## Troubleshooting

| Symptom | Explanation / action |
|---|---|
| "stopping related processes..." on start | Normal (by design): avoids file conflicts. |
| "another OCDP instance is already running" | Wait a moment and run again. |
| "old/staging folder still locked" | Only shown if something holds it after automatic retries — close the processes (`OpenCode`, `opencode-cli`) and try again. |
| "could not read the update feed" | See `launcher\ocdp.log` — the real cause (DNS/TLS/proxy) is logged there. |
| "could not stop: ..." | Close manually via Task Manager and run again. |
| "repairing saved session locations: ignored (...)" | The saved-state repair could not run (e.g. `sqlite3.exe` missing/blocked). Logged in `ocdp.log`; the next run retries. It never blocks the launch. |
| Where to look for problems | `launcher\ocdp.log` (launcher) and `home\.local\share\opencode\log\opencode.log` (app). |

## Important notes

- **Never delete the contents of `home\`**: it is the app's real data. Under
  isolation the app does not read the machine's profile folders, so a second
  (non-portable) OpenCode install, if any, is completely separate.
- **Moving the whole OCDP folder is safe**: `home\` travels with it; saved
  locations are remapped via `launcher\root.marker`, and the service state
  (`home\.local\state\opencode`, PID/port/password) is rebuilt automatically on
  another machine.
- **Keep projects inside `projects\`** (created automatically on each run): they
  travel with the portable folder, and sessions opened there keep working when
  the folder lands on a different path/machine — saved locations pointing at
  the previous root are remapped automatically (`launcher\root.marker`), and
  projects moved into `projects\` (from anywhere) wake up by folder name on
  the next launch, desktop state and session database included. Each folder
  under `projects\` also gets its own git repository on launch (`git init`
  when missing): the app resolves projects by the nearest git repository, so
  without that boundary plain folders would share the portable root's project
  identity (name, color). Projects kept outside the folder have no such
  safety net: when their path vanishes the saved locations are dropped at
  launch (session history stays in `opencode.db`; the app offers "Choose
  directory" to re-point a session).
- The launcher deploys the universal `AGENTS.md` (English, no machine paths) to
  `home\.config\opencode\AGENTS.md` on each run — the app's isolated global
  config slot. Idempotent; it only overwrites files carrying the
  `<!-- OCDP-managed -->` mark, never a third-party global. Note: sessions
  opened OUTSIDE the portable folder (a system-wide install, another terminal)
  use the machine's real config and do not see it. Personal/machine notes:
  `AGENTS.user.md` next to it — never read nor written by the launcher and out
  of git; the managed `AGENTS.md` tells agents it exists (not auto-loaded: the
  agent reads it when present).
- Keep `launcher\ocdp.ps1` saved as **UTF-8 with BOM** (PS 5.1 requirement
  for pt-BR accents).
- **Do not launch `app-64\OpenCode.exe` directly**: outside the launcher it runs
  against the real machine profile (separate, empty data) and may compete for
  the background service. Always use `launcher\OCDP.cmd`.
- If a pre-v3 run left an `OpenCode` Start Menu shortcut pointing at the `.exe`,
  the launcher repoints it to `launcher\OCDP.cmd` on each run (it never
  creates the shortcut: if you delete it, it stays deleted). Under isolation
  the app itself no longer writes the real Start Menu.

## License

OCDP under **MIT** (see root `LICENSE`). The bundled 7-Zip
(`launcher\7za.exe/.dll`) follows its own 7-Zip license — see
`launcher\LICENSE-7za.txt`. The bundled `sqlite3.exe` is public domain — see
`launcher\LICENSE-sqlite.txt`.

## Credits

Designed by **Rafael Alt**; code generated by AI models.
Extractor: [7-Zip](https://www.7-zip.org/) 26.04 © Igor Pavlov (LGPL — see
`launcher\LICENSE-7za.txt`). Saved-state repair: SQLite 3.54 (public domain —
see `launcher\LICENSE-sqlite.txt`).
