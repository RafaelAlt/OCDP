<#
.SYNOPSIS
    OCDP - OpenCode Desktop Portable launcher.
.DESCRIPTION
    Isolates the app environment (USERPROFILE/APPDATA/LOCALAPPDATA and the
    XDG_* slots point into home\), keeps the app up to date from the official
    feed, and starts OpenCode in portable mode. The machine's real profile
    folders are never touched.
.NOTES
    Called by OCDP.cmd. Requires PowerShell 5.1+.
    Code/comments are always English; user-facing text is localized (i18n).
    Must stay saved as UTF-8 with BOM (PS 5.1 reads BOM-less files as ANSI,
    which would corrupt the accented strings).
#>
[CmdletBinding()]
param(
    [switch]$NoUpdate,   # skip version check/download
    [switch]$Force,      # reinstall even if up to date
    [string]$Lang,       # override UI language (e.g. 'en', 'pt-BR')
    [switch]$Help        # show usage and exit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Render localized accents correctly regardless of the console codepage.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# PS 5.1 may default to TLS 1.0/1.1; the feed requires TLS 1.2+.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# --- Paths ----------------------------------------------------------------
$Root   = Split-Path -Parent $PSScriptRoot          # portable root (parent of launcher\)
# Folder name is historical ('app-64'); it holds the $Arch build (x64 or arm64).
$AppDir = Join-Path $Root 'app-64'
$Exe    = Join-Path $AppDir 'OpenCode.exe'

# The app's isolated environment: everything the app (and the sidecar and the
# tools it spawns) resolves inside this folder, so the machine's real profile
# is never touched. USERPROFILE carries the Electron profile and the service
# state (Chromium resolves its folders from the registry's %USERPROFILE%
# templates, expanded with the process env — APPDATA alone does NOT redirect
# them, as verified empirically).
$HomeDir         = Join-Path $Root 'home'
$HomeAppData  = Join-Path $HomeDir 'AppData\Roaming'   # Electron profile (ai.opencode.desktop)
$HomeLocalData= Join-Path $HomeDir 'AppData\Local'     # LOCALAPPDATA slot
$HomeShare    = Join-Path $HomeDir '.local\share'      # XDG_DATA_HOME (db, logs)
$HomeConfig   = Join-Path $HomeDir '.config'           # XDG_CONFIG_HOME
$HomeCache    = Join-Path $HomeDir '.cache'            # XDG_CACHE_HOME

$Launcher = Join-Path $Root 'launcher'
$Seven    = Join-Path $Launcher '7za.exe'
$Sqlite   = Join-Path $Launcher 'sqlite3.exe'   # repairs saved desktop state (drafts.sqlite)
$Feed   = 'https://opencode.ai/update/api/latest/desktop/opencode/latest.yml'

# Default home for projects (created on every run): keeps projects inside the
# portable folder so they travel with it, and gives restored sessions a valid
# fallback when their saved path no longer exists on this machine.
$Projects = Join-Path $Root 'projects'
# Previous portable root, written after each successful run: lets the launcher
# remap saved absolute paths when the folder moved to a different path/machine.
# Launcher state now lives next to the log (both are local, never committed).
$RootMarker = Join-Path $Launcher 'root.marker'

# v2 layout (pre-3.0): data\<name> folders hijacked the real profile paths with
# NTFS junctions. Moved into home\ on the first v3 run; data\ is then retired.
$OldData = Join-Path $Root 'data'

# Real machine profile, captured BEFORE any environment override: the launcher
# always runs outside isolation (via OCDP.cmd), so this is the genuine profile.
# Kept for HOME at launch so git/ssh keep finding .gitconfig/.ssh.
$RealUserProfile = $env:USERPROFILE

# Keep OpenCode's own updater (CLI and sidecar) disabled.
$env:OPENCODE_DISABLE_AUTOUPDATE = '1'

$LogFile = Join-Path $Launcher 'ocdp.log'

# =============================================================================
# i18n - localized UI strings
#   - Code, identifiers and log tags stay English.
#   - User-facing text lives in these tables, keyed by message id.
#   - Missing keys fall back to 'en', then to the key itself.
# =============================================================================
$Strings = @{
    'en' = @{
        # Tasks (printed cyan, no newline) and their results (same line, after ': ').
        'taskInstance'     = 'checking for a running instance'
        'taskRoot'         = 'configuring portable root'
        'taskKill'         = 'stopping related processes'
        'taskScratch'      = 'cleaning session scratch'
        'taskMigrate'      = 'migrating data into the portable home'
        'taskUpdater'      = 'disabling the native updater'
        'taskAgents'       = 'deploying the managed AGENTS.md'
        'taskCheck'        = 'checking for updates'
        'taskVerify'       = 'verifying integrity (sha512)'
        'taskExtract'      = 'extracting application'
        'taskApply'        = 'applying new version'
        'taskRemoveOld'    = 'removing previous version'
        'taskLaunch'       = 'starting the app'
        'taskShortcut'     = 'repointing stray OpenCode shortcut'
        'resRoot'          = 'ok ({0} · {1})'
        'resNone'          = 'ok (none running)'
        'resKilled'        = 'ok (stopped: {0})'
        'resMigrated'      = 'ok ({0} folder(s) moved, {1} junction(s) removed)'
        'resMigrateFresh'  = 'ok (fresh home created)'
        'resMigratedClean' = 'ok (layout already current)'
        'resUpdaterRewrite'= 'ok (invalid opencode.json rewritten)'
        'resAgentsDeployed'= 'ok (updated)'
        'resAgentsForeign' = 'ok (kept — not OCDP-managed)'
        'resUpToDate'      = 'ok (up to date: {0})'
        'resNewVersion'    = 'ok (new version: {0})'
        'resRemoteUnknown' = 'ok (remote version unknown: {0})'
        'resIgnored'       = 'ignored ({0})'
        'resIgnoredForce'  = 'ignored (-Force; reinstalling)'
        'resApplied'       = 'ok ({0} {1} active)'
        'resOldKept'       = 'ok (kept: locked, removed on next run)'
        'resLaunch'        = 'ok — this window closes by itself'
        'resNoGuard'       = 'ok (guard failed; continuing unguarded)'
        'resShortcutRepointed' = 'ok (repointed to OCDP)'
        'resShortcutOk'    = 'ok (already points to OCDP)'
        'resShortcutSkip'  = 'ok (kept as-is)'
        'shortcutAbsent'   = 'absent'
        'taskProjects'     = 'preparing the default projects folder'
        'resProjectsCreated' = 'ok (created: {0})'
        'resProjectsOk'    = 'ok ({0})'
        'taskGitBoundary'  = 'ensuring project git boundaries'
        'resGitBoundary'   = 'ok ({0} created)'
        'gitMissing'       = 'git.exe not found'
        'taskLocations'    = 'repairing saved session locations'
        'resLocationsOk'   = 'ok (all valid)'
        'resLocationsFixed'= 'ok ({0})'
        'locRemapped'      = '{0} path(s) remapped'
        'locProjects'      = '{0} project(s) dropped'
        'locTabs'          = '{0} tab(s) dropped'
        'locLastProject'   = 'lastProject reset'
        'skipSqlite'       = 'sqlite3.exe missing'
        'skipDb'           = 'drafts.sqlite missing'
        'skipSqliteFail'   = 'sqlite3 failed'
        'skipParse'        = 'unreadable saved state'
        'locSidecar'       = '{0} session-db path(s) remapped'
        'locRestored'      = '{0} project(s) restored to the list'
        'locSidecarFail'   = 'session db update failed'
        'killFail'         = 'could not stop: {0}. Close them manually.'
        'feedFail'         = 'could not read the update feed'
        'conflictingFlags' = '-NoUpdate and -Force cannot be combined'
        'oldDirBusy'       = 'old folder still present and locked: {0}; close OpenCode and retry'
        'stageBusy'        = 'staging folder still locked: {0}; close OpenCode and retry'
        'alreadyRunning'   = 'another OCDP instance is already running; try again in a moment'
        'swapFail'         = 'could not apply the update: {0}; previous install restored'
        'help'             = @'
OCDP - OpenCode Desktop Portable

Usage:  OCDP.cmd [-NoUpdate] [-Force] [-Lang <code>] [-Help]

  -NoUpdate   run without checking for updates (fails if not installed)
  -Force      reinstall even if already up to date (cannot combine with -NoUpdate)
  -Lang       UI language, e.g. en, pt-BR (env OCDP_LANG also works)
  -Help       this text

Every run: kills running OpenCode processes, migrates the old data\ layout
into home\ (first v3 run), wipes the session temp (%TEMP%\opencode), prepares
the default projects folder (projects\), repairs saved session locations
(drafts.sqlite), checks the official feed (sha512-verified) and launches the
app with an isolated environment: USERPROFILE/APPDATA/LOCALAPPDATA and the
XDG_* slots point into home\ (the machine profile is never touched); HOME
stays on the real profile so git/ssh keep finding .gitconfig/.ssh.
Docs: README.md   Log: ocdp.log
'@
        'migrateFail'      = "failed to migrate '{0}' (robocopy={1})"
        'removeFail'       = "could not remove '{0}' after migration"
        'noExtractor'      = 'extractor missing: {0}'
        'taskDownload'     = 'downloading {0} build ({1} MB)'
        'dlFail'           = 'download failed'
        'shaMismatch'      = 'sha512 mismatch - corrupted download'
        'sizeMismatch'     = 'size does not match the feed'
        'extractFail'      = 'app extraction failed (7za={0})'
        'noExeAfterExtract'= 'OpenCode.exe missing after extraction'
        'noBuild'          = 'no {0} build found in the feed'
        'noUpdateNoInstall'= 'no app-64\OpenCode.exe and -NoUpdate requested. Run without -NoUpdate to install.'
        'noBinary'         = 'binary missing: {0}'
        'launchFail'       = 'could not start the app: {0}'
        'error'            = 'ERROR'
    }
    'pt-BR' = @{
        # Tarefas (ciano, sem quebra de linha) e resultados (na mesma linha, após ': ').
        'taskInstance'     = 'verificando instância única'
        'taskRoot'         = 'configurando raiz portátil'
        'taskKill'         = 'encerrando processos relacionados'
        'taskScratch'      = 'limpando raspeiro de sessão'
        'taskMigrate'      = 'migrando dados para o home portátil'
        'taskUpdater'      = 'desabilitando atualização nativa'
        'taskAgents'       = 'implantando o AGENTS.md gerenciado'
        'taskCheck'        = 'checando atualizações'
        'taskVerify'       = 'verificando integridade (sha512)'
        'taskExtract'      = 'extraindo aplicativo'
        'taskApply'        = 'aplicando nova versão'
        'taskRemoveOld'    = 'removendo versão anterior'
        'taskLaunch'       = 'iniciando o app'
        'taskShortcut'     = 'reapontando atalho OpenCode'
        'resRoot'          = 'ok ({0} · {1})'
        'resNone'          = 'ok (nenhum em execução)'
        'resKilled'        = 'ok (encerrados: {0})'
        'resMigrated'      = 'ok ({0} pasta(s) movida(s), {1} junction(s) removida(s))'
        'resMigrateFresh'  = 'ok (home novo criado)'
        'resMigratedClean' = 'ok (layout já atual)'
        'resUpdaterRewrite'= 'ok (opencode.json inválido reescrito)'
        'resAgentsDeployed'= 'ok (atualizado)'
        'resAgentsForeign' = 'ok (mantido — não gerenciado pelo OCDP)'
        'resUpToDate'      = 'ok (já atual: {0})'
        'resNewVersion'    = 'ok (nova versão: {0})'
        'resRemoteUnknown' = 'ok (versão remota desconhecida: {0})'
        'resIgnored'       = 'ignorado ({0})'
        'resIgnoredForce'  = 'ignorado (-Force; reinstalando)'
        'resApplied'       = 'ok ({0} {1} ativa)'
        'resOldKept'       = 'ok (mantida: travada, sai na próxima execução)'
        'resLaunch'        = 'ok — esta janela fecha sozinha'
        'resNoGuard'       = 'ok (proteção falhou; seguindo sem mutex)'
        'resShortcutRepointed' = 'ok (reapontado para o OCDP)'
        'resShortcutOk'    = 'ok (já aponta para o OCDP)'
        'resShortcutSkip'  = 'ok (mantido como está)'
        'shortcutAbsent'   = 'ausente'
        'taskProjects'     = 'preparando a pasta padrão de projetos'
        'resProjectsCreated' = 'ok (criada: {0})'
        'resProjectsOk'    = 'ok ({0})'
        'taskGitBoundary'  = 'garantindo fronteiras git dos projetos'
        'resGitBoundary'   = 'ok ({0} criada(s))'
        'gitMissing'       = 'git.exe não encontrado'
        'taskLocations'    = 'reparando localizações de sessão salvas'
        'resLocationsOk'   = 'ok (todas válidas)'
        'resLocationsFixed'= 'ok ({0})'
        'locRemapped'      = '{0} caminho(s) remapeado(s)'
        'locProjects'      = '{0} projeto(s) removido(s)'
        'locTabs'          = '{0} aba(s) removida(s)'
        'locLastProject'   = 'lastProject redefinido'
        'skipSqlite'       = 'sqlite3.exe ausente'
        'skipDb'           = 'drafts.sqlite ausente'
        'skipSqliteFail'   = 'falha do sqlite3'
        'skipParse'        = 'estado salvo ilegível'
        'locSidecar'       = '{0} caminho(s) do banco de sessões remapeado(s)'
        'locRestored'      = '{0} projeto(s) restaurado(s) na lista'
        'locSidecarFail'   = 'falha ao atualizar o banco de sessões'
        'killFail'         = 'não foi possível encerrar: {0}. Feche manualmente.'
        'feedFail'         = 'não foi possível ler o feed de atualização'
        'conflictingFlags' = '-NoUpdate e -Force não podem ser combinados'
        'oldDirBusy'       = 'pasta antiga ainda presente e travada: {0}; feche o OpenCode e tente de novo'
        'stageBusy'        = 'pasta de preparação ainda travada: {0}; feche o OpenCode e tente de novo'
        'alreadyRunning'   = 'outra instância do OCDP já está em execução; tente de novo em instantes'
        'swapFail'         = 'não foi possível aplicar a atualização: {0}; instalação anterior restaurada'
        'help'             = @'
OCDP — OpenCode Desktop Portable

Uso:  OCDP.cmd [-NoUpdate] [-Force] [-Lang <código>] [-Help]

  -NoUpdate   executa sem checar atualizações (falha se não estiver instalado)
  -Force      reinstala mesmo atualizado (não combina com -NoUpdate)
  -Lang       idioma da interface, ex.: en, pt-BR (env OCDP_LANG também vale)
  -Help       este texto

Toda execução: encerra processos do OpenCode, migra o layout antigo data\
para home\ (primeira execução v3), esvazia o raspeiro de sessão
(%TEMP%\opencode), prepara a pasta padrão de projetos (projects\), repara
as localizações de sessão salvas (drafts.sqlite), verifica o feed oficial
(sha512) e abre o app com ambiente isolado: USERPROFILE/APPDATA/
LOCALAPPDATA e os slots XDG_* apontam para home\ (o perfil real da máquina
nunca é tocado); HOME permanece no perfil real para git/ssh acharem
.gitconfig/.ssh.
Documentação: README.md   Log: ocdp.log
'@
        'migrateFail'      = "falha ao migrar '{0}' (robocopy={1})"
        'removeFail'       = "não foi possível remover '{0}' após migração"
        'noExtractor'      = 'extrator ausente: {0}'
        'taskDownload'     = 'baixando build {0} ({1} MB)'
        'dlFail'           = 'download falhou'
        'shaMismatch'      = 'sha512 divergente - download corrompido'
        'sizeMismatch'     = 'tamanho divergente do feed'
        'extractFail'      = 'extração do app falhou (7za={0})'
        'noExeAfterExtract'= 'OpenCode.exe ausente após extração'
        'noBuild'          = 'nenhum build {0} encontrado no feed'
        'noUpdateNoInstall'= 'sem app-64\OpenCode.exe e -NoUpdate pedido. Rode sem -NoUpdate para instalar.'
        'noBinary'         = 'binário ausente: {0}'
        'launchFail'       = 'não foi possível iniciar o app: {0}'
        'error'            = 'ERRO'
    }
}

# Resolve UI locale: -Lang param > $env:OCDP_LANG > Windows display language > 'en'.
function Get-UiLocale([string]$Override) {
    $c = $Override
    if (-not $c) { $c = $env:OCDP_LANG }
    if (-not $c) { try { $c = (Get-UICulture).Name } catch { $c = '' } }
    if (-not $c) { $c = 'en' }
    if ($Strings.ContainsKey($c)) { return $c }
    foreach ($k in $Strings.Keys) { if ($k -ieq $c) { return $k } }
    $two = ($c -split '-')[0]
    foreach ($k in $Strings.Keys) { if ((($k -split '-')[0]) -ieq $two) { return $k } }
    return 'en'
}
$UiLocale = Get-UiLocale $Lang
$Dict     = $Strings[$UiLocale]

# Translate a message id, applying -f format args. Falls back en -> key.
function T([string]$Key, [object[]]$Format) {
    $text = $Dict[$Key]
    if (-not $text) { $text = $Strings['en'][$Key] }
    if (-not $text) { return $Key }
    if ($Format -and $Format.Count) {
        try { return ($text -f $Format) } catch { return $text }
    }
    return $text
}

# Early exit: usage.
if ($Help) { Write-Host (T 'help'); exit 0 }

function Write-Log([string]$Msg) {
    # Timestamped append; silent if it cannot write.
    try { Add-Content -LiteralPath $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) -Encoding UTF8 } catch {}
}
# Task/result console lines: Task prints the task name (cyan, no newline);
# Done appends ": result" on the same line and logs one combined line. Fail
# completes an open task with the error, or prints a standalone error line.
$script:OpenTask = $null
function Task([string]$Msg) {
    if ($script:OpenTask) { Done '-' }
    $script:OpenTask = $Msg
    Write-Host "[OCDP] $Msg" -NoNewline -ForegroundColor Cyan
}
function Done([string]$Result) {
    Write-Host ": $Result"
    if ($script:OpenTask) { Write-Log "$($script:OpenTask): $Result" }
    else { Write-Log $Result }
    $script:OpenTask = $null
}
function Fail($Msg) {
    if ($script:OpenTask) {
        Write-Host ": $(T 'error'): $Msg" -ForegroundColor Red
        Write-Log "$($script:OpenTask): $(T 'error'): $Msg"
    } else {
        Write-Host "[OCDP] $(T 'error'): $Msg" -ForegroundColor Red
        Write-Log "$(T 'error'): $Msg"
    }
    exit 1
}

function Invoke-LogRotation {
    # Keep the log bounded; every run appends, and the file lives in a synced folder.
    try {
        $lf = Get-Item -LiteralPath $LogFile -ErrorAction Stop
        if ($lf.Length -gt 512KB) {
            $old = "$LogFile.old"
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
            Move-Item -LiteralPath $LogFile -Destination $old -Force
        }
    } catch {}
}

# --- Architecture ---------------------------------------------------------
function Get-Arch {
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    if ($a -ieq 'ARM64') { return 'arm64' }
    return 'x64'
}
$Arch = Get-Arch

# --- Home isolation & v2 migration ----------------------------------------
# v2 hijacked the real profile paths with NTFS junctions pointing into data\.
# v3 never touches the machine: the app runs with an isolated environment
# (USERPROFILE/APPDATA/LOCALAPPDATA/XDG_* -> home\). On the first v3 run the
# old data\ layout is moved into home\ (same volume: renames, not copies) and
# the leftover junctions are dropped (the link only — never the content).

# True when the path exists and is a junction/reparse point. Enumerates the
# parent instead of testing the path: a DANGLING junction fails Test-Path
# (the target is what resolves), but must still be detected and removed.
function Test-Junction([string]$Path) {
    $parent = Split-Path -Parent $Path
    $name   = Split-Path -Leaf   $Path
    if (-not $parent -or -not (Test-Path -LiteralPath $parent)) { return $false }
    try {
        foreach ($d in [IO.DirectoryInfo]::new($parent).GetDirectories($name)) {
            if ($d.Name -ieq $name) { return [bool]($d.Attributes -band [IO.FileAttributes]::ReparsePoint) }
        }
    } catch {}
    return $false
}

function Remove-Junction([string]$Path) {
    # DirectoryInfo.Delete() on a junction removes the reparse point only.
    $parent = Split-Path -Parent $Path
    $name   = Split-Path -Leaf   $Path
    foreach ($d in [IO.DirectoryInfo]::new($parent).GetDirectories($name)) {
        if ($d.Name -ieq $name) { $d.Delete(); return $true }
    }
    return $false
}

function Move-Tree([string]$From, [string]$To) {
    # Same volume: Move-Item is a rename (instant, no copy). Cross-volume or
    # when the target already exists: robocopy /E /MOVE merges and deletes
    # the source, with retries for briefly-locked files.
    if (-not (Test-Path -LiteralPath $To)) {
        $parent = Split-Path -Parent $To
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        try { Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop; return }
        catch { Write-Log "  move failed ('$From'): $($_.Exception.Message); falling back to robocopy" }
    }
    $null = robocopy $From $To /E /MOVE /R:3 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { Fail (T 'migrateFail' @($From, $LASTEXITCODE)) }
}

# v2 data\<name> folder  ->  v3 home target  /  v2 profile source (junction).
$HomeMigrationMap = @(
    @{ Name = 'share-opencode';      Source = Join-Path $RealUserProfile '.local\share\opencode';  Target = Join-Path $HomeShare     'opencode' }
    @{ Name = 'config-opencode';     Source = Join-Path $RealUserProfile '.config\opencode';       Target = Join-Path $HomeConfig    'opencode' }
    @{ Name = 'state-opencode';      Source = Join-Path $RealUserProfile '.local\state\opencode';  Target = Join-Path $HomeDir          '.local\state\opencode' }
    @{ Name = 'cache-opencode';      Source = Join-Path $RealUserProfile '.cache\opencode';        Target = Join-Path $HomeCache     'opencode' }
    @{ Name = 'ai.opencode.desktop'; Source = Join-Path $env:APPDATA      'ai.opencode.desktop';  Target = Join-Path $HomeAppData   'ai.opencode.desktop' }
)

function Invoke-HomeMigration {
    $fresh = -not (Test-Path -LiteralPath $HomeDir)
    $moved = 0
    $links = 0

    # 1. Drop v2 junction leftovers in the real profile (link only). The app
    #    ignores those paths under isolation; failures are logged and retried
    #    next run instead of blocking the launch.
    foreach ($m in $HomeMigrationMap) {
        if (Test-Junction $m.Source) {
            try {
                Remove-Junction $m.Source | Out-Null
                $links++
                Write-Log "  junction removed: $($m.Source)"
            } catch {
                Write-Log "  junction removal FAILED for '$($m.Source)': $($_.Exception.Message)"
            }
        }
    }

    # 2. Move the old data\ layout into home\.
    if (Test-Path -LiteralPath $OldData) {
        foreach ($m in $HomeMigrationMap) {
            $from = Join-Path $OldData $m.Name
            if (-not (Test-Path -LiteralPath $from)) { continue }
            Move-Tree $from $m.Target
            $moved++
            Write-Log "  migrated: $($m.Name) -> $($m.Target)"
        }
        # Root marker: launcher state now lives next to the log.
        $oldMarker = Join-Path $OldData 'root.marker'
        if ((Test-Path -LiteralPath $oldMarker) -and -not (Test-Path -LiteralPath $RootMarker)) {
            Move-Item -LiteralPath $oldMarker -Destination $RootMarker -Force
        }
        # data\ must now be empty; unknown leftovers are kept as-is (never
        # delete anything the launcher did not put there).
        $left = @(Get-ChildItem -LiteralPath $OldData -Force -ErrorAction SilentlyContinue)
        if (-not $left.Count) {
            Remove-Item -LiteralPath $OldData -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $OldData) { Write-Log '  data\ could not be removed (locked); will retry next run' }
        } else {
            Write-Log ("  data\ kept: unknown entries remain ({0})" -f (($left | Select-Object -First 5 -ExpandProperty Name) -join ', '))
        }
    }

    # 3. Make sure the full home tree exists (fresh installs and every run).
    foreach ($d in @($HomeAppData, $HomeLocalData, $HomeShare, $HomeConfig, $HomeCache, (Join-Path $HomeDir '.local\state'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    return @{ moved = $moved; links = $links; fresh = $fresh }
}

# --- Config: disable the built-in updater ---------------------------------
function Set-DisableUpdateConfig([string]$ConfigDir) {
    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    $file = Join-Path $ConfigDir 'opencode.json'

    $rewrote = $false
    $cfg = @{}
    if (Test-Path -LiteralPath $file) {
        try {
            $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                $obj = $raw | ConvertFrom-Json
                $cfg = @{}
                $obj.PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
            }
        } catch {
            $rewrote = $true
            $cfg = @{}
        }
    }

    # v2 uses "update"; v1 uses "autoupdate". Unknown fields are ignored.
    $cfg['update']      = 'disable'
    $cfg['autoupdate']  = $false

    # Depth 100 keeps deeply nested user config intact (the default depth of 2
    # silently flattens deeper objects into strings). UTF-8 without BOM: PS
    # 5.1's -Encoding UTF8 always emits one and some JSON parsers reject it.
    $json = $cfg | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($file, $json, [Text.UTF8Encoding]::new($false))
    return $rewrote
}

# Deploy the universal AGENTS.md to the portable global config slot so that
# every OpenCode session opened inside the portable environment knows the
# portable rules. Idempotent: writes only when the content differs, and never
# touches a file that is not OCDP-managed (marker check).
function Set-GlobalAgents {
    $src = Join-Path $Root 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $src)) { return 'noop' }
    $dst = Join-Path $HomeConfig 'opencode\AGENTS.md'
    $new = [IO.File]::ReadAllText($src)
    if (Test-Path -LiteralPath $dst) {
        $cur = [IO.File]::ReadAllText($dst)
        if ($cur -eq $new) { return 'noop' }
        if (-not $cur.Contains('<!-- OCDP-managed')) { return 'foreign' }
    } else {
        $dir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    [IO.File]::WriteAllText($dst, $new, [Text.UTF8Encoding]::new($false))
    return 'deployed'
}

# The app recreates .\Start Menu\Programs\OpenCode.lnk pointing at its raw
# exe (bypassing the launcher). Hijack it: if the stray entry exists but
# points elsewhere, repoint it at OCDP.cmd so the Start Menu opens the app
# through the launcher (update check, isolated environment). Never creates
# the entry: a deleted shortcut stays deleted (if the app recreates it raw,
# the next run repoints it again). Under isolation the app no longer writes
# the real Start Menu, so this only touches entries created before v3.
function Repair-OpenCodeShortcut {
    $cmd = Join-Path $Launcher 'OCDP.cmd'
    $want = [IO.Path]::GetFullPath($cmd).TrimEnd('\')
    $paths = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OpenCode.lnk'),
        (Join-Path $env:USERPROFILE 'Desktop\OpenCode.lnk')
    )
    $found = $false
    $repointed = $false
    try {
        $shell = New-Object -ComObject WScript.Shell
    } catch {
        Write-Log "  shortcut COM unavailable: $($_.Exception.Message)"
        return 'skip'
    }
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $found = $true
        try {
            $lnk = $shell.CreateShortcut($p)
            $cur = $lnk.TargetPath
            if ($cur -and ([IO.Path]::GetFullPath($cur).TrimEnd('\') -ieq $want)) { continue }
            $lnk.TargetPath = $cmd
            $lnk.WorkingDirectory = $Launcher
            if (Test-Path -LiteralPath $Exe) { $lnk.IconLocation = "$Exe,0" }
            $lnk.Save()
            $repointed = $true
        } catch {
            Write-Log "  shortcut repoint failed for '$p': $($_.Exception.Message)"
            return 'skip'
        }
    }
    if ($repointed) { return 'repointed' }
    if ($found) { return 'ok' }
    return 'absent'
}

# Each project folder under the default home gets its own git boundary: the
# sidecar resolves a directory to the nearest enclosing git repository, so a
# plain folder inside the portable root would be swallowed by the root
# project's identity (name, icon color, session lists). Returns the number of
# repositories created, or -1 when git.exe is unavailable.
function Set-ProjectGitBoundaries([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        Write-Log '  git.exe not found: project git boundaries skipped'
        return -1
    }
    $created = 0
    foreach ($folder in (Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $folder.FullName '.git')) { continue }
        $null = & git.exe -C $folder.FullName init --quiet 2>&1
        if ($LASTEXITCODE -eq 0) {
            $created++
            Write-Log "  git boundary created: $($folder.FullName)"
        } else {
            Write-Log "  git boundary failed for '$($folder.FullName)' (exit $LASTEXITCODE)"
        }
    }
    return $created
}

# --- Saved desktop locations (drafts.sqlite + session database) -------------
# The desktop app restores the last project and the open tabs from its
# drafts.sqlite (table `state`), stored as ABSOLUTE paths; the sidecar keeps
# session/project locations in home\.local\share\opencode\opencode.db. A
# synced portable folder that lands on a different path (or machine) — or
# projects moved into projects\ — leaves those paths dangling and the app
# hangs on a broken restore (a screen offering only restart/update). While
# every OpenCode process is stopped, three fixes are applied, in order:
#   1. Remap  — launcher\root.marker holds the previous portable root; saved
#      paths that start with it and no longer exist are rewritten to the
#      current root, but only when the remapped target exists on this machine.
#   2. Wake   — a saved path that is gone but whose longest tail exists under
#      the default projects folder is re-pointed there (projects moved into
#      projects\ wake up by folder name, desktop and session database).
#   3. Repair — saved locations still missing are dropped (project list,
#      recently-closed, tab entries) and a stale lastProject falls back to
#      the default projects folder; project entries pruned by earlier runs
#      are restored from the sidecar worktrees.
# Any failure is logged and skipped: it must never block the launch.

# Invoke $Fn for every string leaf of a parsed-JSON node (in place).
function Update-StringLeaves([object]$Node, [scriptblock]$Fn) {
    if ($null -eq $Node) { return $Node }
    if ($Node -is [string]) { return (& $Fn $Node) }
    if ($Node -is [PSCustomObject]) {
        foreach ($p in @($Node.PSObject.Properties)) {
            $before = $p.Value
            $after  = Update-StringLeaves $before $Fn
            # A collection property must stay a collection: function output
            # unrolls single-element arrays on the way back.
            if (($before -is [System.Collections.ICollection]) -and ($after -isnot [System.Collections.ICollection])) {
                $p.Value = @($after)
            } else {
                $p.Value = $after
            }
        }
        return $Node
    }
    if ($Node -is [System.Collections.ICollection]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            $Node[$i] = Update-StringLeaves $Node[$i] $Fn
        }
        return $Node
    }
    return $Node
}

# True when a subtree contains a 'directory' string pointing to a path that
# does not exist on this machine (tab entries carry it at their root; closed
# tabs nest it under 'info').
function Test-StaleDirectory([object]$Node) {
    if ($null -eq $Node) { return $false }
    if ($Node -is [PSCustomObject]) {
        $d = $Node.PSObject.Properties['directory']
        if ($d -and ($d.Value -is [string]) -and $d.Value -and -not (Test-Path -LiteralPath $d.Value)) { return $true }
        foreach ($p in $Node.PSObject.Properties) {
            if (Test-StaleDirectory $p.Value) { return $true }
        }
        return $false
    }
    if ($Node -is [System.Collections.ICollection]) {
        foreach ($item in $Node) {
            if (Test-StaleDirectory $item) { return $true }
        }
    }
    return $false
}

# Serialize a parsed-JSON node the way it goes back into the state table.
# -InputObject keeps single-element arrays (the pipeline form unwraps them).
function ConvertTo-StateJson([object]$Node) {
    if ($Node -is [System.Collections.ICollection] -and $Node.Count -eq 0) { return '[]' }
    return ConvertTo-Json -InputObject $Node -Depth 100 -Compress
}

# SQL string literal (single quotes doubled; ConvertTo-Json escapes non-ASCII,
# so the generated .sql file stays ASCII-safe for the sqlite3 CLI).
function Escape-SqlLiteral([string]$Text) {
    return "'" + ($Text -replace "'", "''") + "'"
}

# Parse a saved-state JSON document. PS 5.1's ConvertFrom-Json folds ANY
# top-level JSON array into one consolidated object (in every invocation
# form), so array documents ride inside a single-element wrapper and come
# back from the 'items' property intact. The unary comma keeps the function
# from unrolling single-element arrays on return (pipeline semantics).
function ConvertFrom-StateJson([string]$Text) {
    $t = $Text.Trim()
    if (-not $t) { return $null }
    if ($t.StartsWith('[')) {
        $wrapped = ConvertFrom-Json -InputObject ('[{"items": ' + $t + '}]')
        return ,@($wrapped.items)
    }
    return ConvertFrom-Json -InputObject $t
}

# True when the string cannot be a filesystem path (control characters such
# as the newlines inside tab keys, quotes, etc.) — safe Test-Path guard.
function Test-InvalidPath([string]$Text) {
    return $Text.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0
}

# Auto-wake for the default projects home: a saved path whose folder was moved
# into projects\ keeps working when the longest tail of the old path that
# exists under the home becomes the new location (e.g. old\projects\direito ->
# <root>\projects\direito). Returns $null when the path is still valid or
# nothing under the home matches. Logs every wake it performs.
function Get-HomeRemap([string]$Path, [string]$ProjectsHome) {
    if (-not $Path -or (Test-InvalidPath $Path)) { return $null }
    if (-not $ProjectsHome -or -not (Test-Path -LiteralPath $ProjectsHome)) { return $null }
    $segs = @($Path.Split([char[]]@('\', '/')) | Where-Object { $_ })
    if ($segs.Count -lt 2) { return $null }
    for ($i = 1; $i -lt $segs.Count; $i++) {
        $cand = Join-Path $ProjectsHome (($segs[$i..($segs.Count - 1)]) -join '\')
        if (($cand -ine $Path) -and (Test-Path -LiteralPath $cand)) {
            Write-Log "  wake: $Path -> $cand"
            return $cand
        }
    }
    return $null
}

# Structural repair of the 'server' row: drop projects whose worktree is gone,
# fall back to the default projects folder for a stale lastProject, and prune
# missing paths from recentlyClosed. Returns $true when something changed.
function Repair-ServerState([object]$Srv, [string]$ProjectsDir, [hashtable]$Counts) {
    $changed = $false

    $projects = $Srv.PSObject.Properties['projects']
    if ($projects -and $projects.Value) {
        $local = $projects.Value.PSObject.Properties['local']
        if ($local -and ($local.Value -is [System.Collections.ICollection])) {
            $kept = @()
            foreach ($item in @($local.Value)) {
                $w = $item.PSObject.Properties['worktree']
                if ($w -and ($w.Value -is [string]) -and $w.Value -and -not (Test-Path -LiteralPath $w.Value)) {
                    $Counts.projects++
                    $changed = $true
                } else {
                    $kept += $item
                }
            }
            if ($changed) { $local.Value = $kept }
        }
    }

    $last = $Srv.PSObject.Properties['lastProject']
    if ($last -and ($last.Value -is [PSCustomObject])) {
        foreach ($p in @($last.Value.PSObject.Properties)) {
            if (($p.Value -is [string]) -and $p.Value -and -not (Test-Path -LiteralPath $p.Value)) {
                $p.Value = $ProjectsDir
                $Counts.lastProject++
                $changed = $true
            }
        }
    }

    $rc = $Srv.PSObject.Properties['recentlyClosed']
    if ($rc -and ($rc.Value -is [PSCustomObject])) {
        foreach ($p in @($rc.Value.PSObject.Properties)) {
            if ($p.Value -is [System.Collections.ICollection]) {
                $all  = @($p.Value)
                $kept = @($all | Where-Object { ($_ -isnot [string]) -or -not $_ -or (Test-Path -LiteralPath $_) })
                if ($kept.Count -ne $all.Count) {
                    $Counts.projects += ($all.Count - $kept.Count)
                    $p.Value = $kept
                    $changed = $true
                }
            }
        }
    }

    return $changed
}

function Repair-SavedLocations {
    if (-not (Test-Path -LiteralPath $Sqlite)) { return 'skipSqlite' }
    $db = Join-Path $HomeAppData 'ai.opencode.desktop\drafts.sqlite'
    if (-not (Test-Path -LiteralPath $db)) { return 'skipDb' }

    # Previous portable root (written by the last successful run of this folder).
    $oldRoot = $null
    try {
        if (Test-Path -LiteralPath $RootMarker) {
            $oldRoot = (Get-Content -LiteralPath $RootMarker -Raw -ErrorAction Stop).Trim()
        }
    } catch { $oldRoot = $null }
    if ($oldRoot) { $oldRoot = $oldRoot.TrimEnd('\') }
    $newRoot = $Root.TrimEnd('\')
    $moved = ($oldRoot -and ($oldRoot -ine $newRoot))

    $Counts = @{ remap = 0; tabs = 0; projects = 0; lastProject = 0; sidecar = 0; restored = 0; sidecarFail = 0 }
    # Path transform applied to every saved string: (1) previous-root prefix
    # remap when the portable folder itself moved; (2) auto-wake into the
    # default projects home (a project moved there wakes up by folder name).
    $remapFn = {
        param($s)
        if (-not (($s -is [string]) -and $s)) { return $s }
        if ($moved) {
            $mapped = $null
            if ($s -ieq $oldRoot) { $mapped = $newRoot }
            elseif ($s.StartsWith($oldRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $mapped = $newRoot + $s.Substring($oldRoot.Length)
            }
            if ($mapped -and -not (Test-Path -LiteralPath $s) -and (Test-Path -LiteralPath $mapped)) {
                $Counts.remap++
                Write-Log "  remap: $s -> $mapped"
                return $mapped
            }
        }
        $woken = Get-HomeRemap $s $Projects
        if ($woken) { $Counts.remap++; return $woken }
        return $s
    }.GetNewClosure()

    # Sidecar database (sessions/projects): paths are stored with forward
    # slashes. Only four tables hold live locations; the guarded remap runs
    # per distinct value and becomes one CASE-based UPDATE per table.
    $sidecarDb = Join-Path $HomeShare 'opencode\opencode.db'
    $sidecarUpdates = @()
    $homeWorktrees = @()
    if (Test-Path -LiteralPath $sidecarDb) {
        try {
            foreach ($tc in @(@('project','worktree'), @('worktree','directory'), @('project_directory','directory'), @('session_v2','directory'))) {
                $table = $tc[0]; $col = $tc[1]
                $vals = & $Sqlite $sidecarDb "SELECT DISTINCT $col FROM $table;" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "select $table.$col failed" }
                $map = @{}
                foreach ($v in @($vals)) {
                    if (($v -isnot [string]) -or -not $v.Trim()) { continue }
                    $m = $null
                    if ($moved) {
                        $vNorm = $v.Replace('/', '\')
                        if ($vNorm -ieq $oldRoot) { $m = $newRoot }
                        elseif ($vNorm.StartsWith($oldRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                            $m = $newRoot + $vNorm.Substring($oldRoot.Length)
                        }
                        if ($m) {
                            if (Test-Path -LiteralPath $v) { $m = $null }   # still valid here
                            elseif (-not (Test-Path -LiteralPath $m)) { $m = $null }
                            elseif ($v.Contains('/')) { $m = $m.Replace('\', '/') }
                        }
                    }
                    if (-not $m) {
                        $m = Get-HomeRemap $v $Projects
                        if ($m -and $v.Contains('/')) { $m = $m.Replace('\', '/') }
                    }
                    if ($m -and ($m -cne $v)) { $map[$v] = $m }
                }
                if ($map.Count) {
                    $cases = @(); $ins = @()
                    foreach ($k in $map.Keys) {
                        $cases += "WHEN $(Escape-SqlLiteral $k) THEN $(Escape-SqlLiteral $map[$k])"
                        $ins   += (Escape-SqlLiteral $k)
                        $Counts.sidecar++
                        if ($table -eq 'project') { $homeWorktrees += ($map[$k].Replace('/', '\')) }
                    }
                    $sidecarUpdates += "UPDATE $table SET $col = CASE $col $($cases -join ' ') ELSE $col END WHERE $col IN ($($ins -join ', '));"
                }
                # Projects living under the default home belong in the sidebar
                # list, even when this pass had nothing to remap (the list may
                # have been pruned by an earlier run).
                if ($table -eq 'project') {
                    foreach ($v in @($vals)) {
                        if (($v -isnot [string]) -or -not $v.Trim()) { continue }
                        $vNorm = $v.Replace('/', '\')
                        if ($vNorm.StartsWith($Projects + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $vNorm)) {
                            $homeWorktrees += $vNorm
                        }
                    }
                }
            }
        } catch {
            Write-Log "  sidecar repair failed: $($_.Exception.Message)"
            $Counts.sidecarFail = 1
            $sidecarUpdates = @()
            $homeWorktrees = @()
        }
    }

    # Two-phase read, PS 5.1-proof: the row list comes in plain mode (ids
    # never contain '|'), then each row's value is fetched with a single-row
    # -json SELECT. A multi-row -json output is unusable here because PS 5.1
    # folds top-level JSON arrays into one consolidated object (see
    # ConvertFrom-StateJson).
    $where = "WHERE (name = 'opencode.global.dat' AND key = 'server') OR (name LIKE 'opencode.window.%.dat' AND key IN ('tabs','tabs.info','tabs.recent','tabs.closed','tabs.panes'))"
    $list = & $Sqlite $db "SELECT name || '|' || key FROM state $where;" 2>&1
    if ($LASTEXITCODE -ne 0) { return 'skipSqliteFail' }

    $updates = @{}
    $serverNode = $null; $serverName = $null; $serverKey = $null
    foreach ($line in @($list)) {
        if (($line -isnot [string]) -or -not $line.Trim()) { continue }
        $sep = $line.IndexOf('|')
        if ($sep -lt 1) { continue }
        $rowName = $line.Substring(0, $sep)
        $rowKey  = $line.Substring($sep + 1)

        $raw = & $Sqlite -json $db "SELECT value FROM state WHERE name = $(Escape-SqlLiteral $rowName) AND key = $(Escape-SqlLiteral $rowKey);" 2>&1
        if ($LASTEXITCODE -ne 0) { continue }
        $wrapper = ((@($raw) | Where-Object { $_ -is [string] }) -join '').Trim()
        if (-not $wrapper) { continue }
        # The -json output is a one-row array: [{"value": "<the JSON text>"}].
        try { $rowArr = ConvertFrom-StateJson $wrapper } catch { continue }
        $valText = $rowArr[0].value
        if (($valText -isnot [string]) -or -not $valText.Trim()) { continue }
        try { $node = ConvertFrom-StateJson $valText } catch { continue }
        if ($null -eq $node) { continue }

        $remapBefore = $Counts.remap
        $changed = $false
        if ($remapFn) { $null = Update-StringLeaves $node $remapFn }
        if ($Counts.remap -gt $remapBefore) { $changed = $true }

        if ($rowKey -eq 'server') {
            if (Repair-ServerState $node $Projects $Counts) { $changed = $true }
            $serverNode = $node; $serverName = $rowName; $serverKey = $rowKey
        } else {
            # Tab restore rows: drop top-level entries/items holding a stale
            # directory (tabs.info: object of tab entries; tabs/tabs.closed:
            # arrays of tab records; tabs.recent/tabs.panes: usually inert).
            if ($node -is [PSCustomObject]) {
                $stale = @(@($node.PSObject.Properties) | Where-Object { Test-StaleDirectory $_.Value })
                foreach ($p in $stale) {
                    $node.PSObject.Properties.Remove($p.Name)
                    $Counts.tabs++
                }
                if ($stale.Count) { $changed = $true }
            } elseif ($node -is [System.Collections.ICollection]) {
                $all  = @($node)
                $kept = @($all | Where-Object { -not (Test-StaleDirectory $_) })
                if ($kept.Count -ne $all.Count) {
                    $Counts.tabs += ($all.Count - $kept.Count)
                    $node = $kept
                    $changed = $true
                }
            }
        }

        if ($changed) {
            $json = Escape-SqlLiteral (ConvertTo-StateJson $node)
            $now  = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            $updates["$rowName|$rowKey"] = "UPDATE state SET value = $json, updated_at = $now WHERE name = $(Escape-SqlLiteral $rowName) AND key = $(Escape-SqlLiteral $rowKey);"
        }
    }

    # Restore sidebar entries a previous prune may have removed: project
    # locations learned from the sidecar belong in the projects list.
    if ($homeWorktrees.Count -and $serverNode) {
        $projectsProp = $serverNode.PSObject.Properties['projects']
        if (-not $projectsProp -or -not $projectsProp.Value) {
            $serverNode | Add-Member -MemberType NoteProperty -Name projects -Value ([pscustomobject]@{})
            $projectsProp = $serverNode.PSObject.Properties['projects']
        }
        $local = $projectsProp.Value.PSObject.Properties['local']
        if (-not $local) {
            $projectsProp.Value | Add-Member -MemberType NoteProperty -Name local -Value @()
            $local = $projectsProp.Value.PSObject.Properties['local']
        }
        if ($local.Value -isnot [System.Collections.ICollection]) { $local.Value = @() }
        $added = $false
        foreach ($wt in @($homeWorktrees | Select-Object -Unique)) {
            $known = $false
            foreach ($item in @($local.Value)) {
                $w = $item.PSObject.Properties['worktree']
                if ($w -and ($w.Value -ieq $wt)) { $known = $true; break }
            }
            if (-not $known) {
                $local.Value = @($local.Value) + @([pscustomobject]@{ worktree = $wt; expanded = $true })
                $Counts.restored++
                $added = $true
                Write-Log "  restored to project list: $wt"
            }
        }
        if ($added) {
            $json = Escape-SqlLiteral (ConvertTo-StateJson $serverNode)
            $now  = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            $updates["$serverName|$serverKey"] = "UPDATE state SET value = $json, updated_at = $now WHERE name = $(Escape-SqlLiteral $serverName) AND key = $(Escape-SqlLiteral $serverKey);"
        }
    }

    if ($updates.Count) {
        # Insurance for the edited database: one backup per changing run.
        try { Copy-Item -LiteralPath $db -Destination "$db.ocdp.bak" -Force } catch {
            Write-Log "  drafts backup failed: $($_.Exception.Message)"
        }
        $sqlFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'OCDP-repair-' + [IO.Path]::GetRandomFileName() + '.sql')
        [IO.File]::WriteAllText($sqlFile, (($updates.Values | Sort-Object) -join "`r`n"), [Text.UTF8Encoding]::new($false))
        try {
            $null = & $Sqlite $db ".read '$(($sqlFile -replace '\\','/'))'" 2>&1
            if ($LASTEXITCODE -ne 0) { return 'skipSqliteFail' }
        } finally {
            Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ($sidecarUpdates.Count) {
        # Surgical UPDATEs on four small tables; no file backup here (the
        # session database is large and synced — the per-remap log lines are
        # the audit trail).
        $sqlFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'OCDP-sidecar-' + [IO.Path]::GetRandomFileName() + '.sql')
        [IO.File]::WriteAllText($sqlFile, ($sidecarUpdates -join "`r`n"), [Text.UTF8Encoding]::new($false))
        try {
            $null = & $Sqlite $sidecarDb ".read '$(($sqlFile -replace '\\','/'))'" 2>&1
            if ($LASTEXITCODE -ne 0) {
                $Counts.sidecarFail = 1
                Write-Log "  sidecar update failed (exit $LASTEXITCODE)"
            }
        } finally {
            Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Record the current root only after a successful pass: a failure keeps
    # the previous marker so the move is retried (not forgotten) next run.
    try { [IO.File]::WriteAllText($RootMarker, $Root, [Text.UTF8Encoding]::new($false)) } catch {
        Write-Log "  root marker write failed: $($_.Exception.Message)"
    }

    return $Counts
}

# --- Feed / version -------------------------------------------------------
function Get-RemoteInfo([string]$ArchSel) {
    # PS 5.1 returns Byte[] for content-type application/yaml -> decode.
    # Retry: a transient network blip must not kill the whole launch.
    $resp = $null
    $lastErr = $null
    for ($a = 1; $a -le 3; $a++) {
        try { $resp = Invoke-WebRequest -Uri $Feed -UseBasicParsing -TimeoutSec 30; break }
        catch { $lastErr = $_.Exception.Message; if ($a -lt 3) { Start-Sleep -Seconds 2 } }
    }
    if (-not $resp) {
        # Keep the real cause (DNS/TLS/proxy) in the log for troubleshooting.
        if ($lastErr) { Write-Log "  feed error: $lastErr" }
        Fail (T 'feedFail')
    }
    $raw  = $resp.Content
    if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }

    $ver = $null
    if ($raw -match '(?m)^version:\s*(\S+)') { $ver = $Matches[1] }

    # File entries: split on each "- url:" item (the lookahead keeps the key)
    # so the field order inside an entry (url/sha512/size) does not matter.
    $want = if ($ArchSel -eq 'arm64') { '-win-arm64.exe' } else { '-win-x64.exe' }
    foreach ($block in [regex]::Split($raw, '(?m)^\s*-\s+(?=url:)')) {
        $u = [regex]::Match($block, '(?m)^url:\s*(\S+)').Groups[1].Value
        if (-not $u -or -not $u.EndsWith($want)) { continue }
        $sha  = [regex]::Match($block, '(?m)sha512:\s*(\S+)').Groups[1].Value
        $size = [regex]::Match($block, '(?m)size:\s*(\d+)').Groups[1].Value
        return [pscustomobject]@{
            Version = $ver
            Url     = $u
            Sha512  = $sha
            Size    = if ($size) { [int64]$size } else { 0 }
        }
    }
    Fail (T 'noBuild' @($ArchSel))
}

function Get-LocalVersion([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $vi = (Get-Item -LiteralPath $Path).VersionInfo
    $s = $vi.ProductVersion
    if (-not $s) { $s = $vi.FileVersion }
    if (-not $s) { return $null }
    try { return [version]$s } catch { return $null }
}

function Get-FileSha512Base64([string]$Path) {
    $sha = [Security.Cryptography.SHA512]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { $bytes = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

# --- Download + update ----------------------------------------------------
# Remove a path that may be briefly locked (AV scan, lingering handle):
# retry a few times before giving up. Returns $true when gone.
function Remove-PathRetry([string]$Path, [int]$Tries = 5) {
    for ($i = 1; $i -le $Tries; $i++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Start-Sleep -Seconds 1
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Invoke-Update([pscustomobject]$Info) {
    if (-not (Test-Path -LiteralPath $Seven)) { Fail (T 'noExtractor' @($Seven)) }

    $tmp = Join-Path $env:TEMP 'OCDP'
    if (-not (Remove-PathRetry $tmp)) { Fail (T 'stageBusy' @($tmp)) }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    try {
        # 1. Download
        $installer = Join-Path $tmp 'installer.exe'
        Task (T 'taskDownload' @($Arch, [math]::Round($Info.Size/1MB)))
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            curl.exe -sSLf --retry 3 --connect-timeout 30 -o $installer $Info.Url
            if (($LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $installer)) { Fail (T 'dlFail') }
        } else {
            # Fallback for machines without curl.exe. No timeout: a big
            # download over a slow link must be allowed to finish.
            try { Invoke-WebRequest -Uri $Info.Url -OutFile $installer -UseBasicParsing }
            catch { Fail (T 'dlFail') }
        }
        Done 'ok'

        # 2. Verify integrity (sha512 + size), if the feed provides them.
        if ($Info.Sha512 -or $Info.Size) {
            Task (T 'taskVerify')
            if ($Info.Sha512) {
                $got = Get-FileSha512Base64 $installer
                if ($got -ne $Info.Sha512) { Fail (T 'shaMismatch') }
            }
            if ($Info.Size -and (Get-Item -LiteralPath $installer).Length -ne $Info.Size) {
                Fail (T 'sizeMismatch')
            }
            Done 'ok'
        }

        # 3. Extract the app straight from the NSIS installer into staging
        #    (app-64.new). 7-Zip inflates the internal app-XX.7z automatically
        #    and yields the final files (OpenCode.exe, resources\, locales\).
        Task (T 'taskExtract')
        $newDir = "$AppDir.new"
        if (-not (Remove-PathRetry $newDir)) { Fail (T 'stageBusy' @($newDir)) }
        $sevenOut = & $Seven x $installer "-o$newDir" -y 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Keep the tail of 7-Zip output in the log: it names the root cause.
            if ($sevenOut) { $sevenOut | Select-Object -Last 8 | ForEach-Object { Write-Log "  7za: $_" } }
            Fail (T 'extractFail' @($LASTEXITCODE))
        }
        if (-not (Test-Path -LiteralPath (Join-Path $newDir 'OpenCode.exe'))) {
            Fail (T 'noExeAfterExtract')
        }
        Done 'ok'

        # Disable Electron's auto-updater: unlike the CLI (OPENCODE_DISABLE_AUTOUPDATE),
        # electron-updater only honors this file; removing it neutralizes the
        # updater (the app then just logs a recurring ENOENT, harmlessly).
        $upd = Join-Path (Join-Path $newDir 'resources') 'app-update.yml'
        if (Test-Path -LiteralPath $upd) { Remove-Item -LiteralPath $upd -Force }

        # 4. Swap: app-64 -> app-64.old ; app-64.new -> app-64
        Task (T 'taskApply')
        # Processes were stopped at startup, but the download takes minutes:
        # if anything came back meanwhile, stop it again instead of failing.
        Get-Process -Name '*opencode*' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $AppDir) {
            $oldDir = "$AppDir.old"
            if (-not (Remove-PathRetry $oldDir)) { Fail (T 'oldDirBusy' @($oldDir)) }
            Move-Item -LiteralPath $AppDir -Destination $oldDir
        }
        # Move .new into place; if that fails, roll the previous install back.
        try {
            Move-Item -LiteralPath $newDir -Destination $AppDir -ErrorAction Stop
        } catch {
            $err = $_.Exception.Message
            Write-Log "  swap error: $err"
            if ((Test-Path -LiteralPath "$AppDir.old") -and -not (Test-Path -LiteralPath $AppDir)) {
                Move-Item -LiteralPath "$AppDir.old" -Destination $AppDir -ErrorAction SilentlyContinue
            }
            Fail (T 'swapFail' @($err))
        }
        Done (T 'resApplied' @($Arch, $Info.Version))

        # Remove the old folder (retry if locked).
        Task (T 'taskRemoveOld')
        $oldDir = "$AppDir.old"
        if (Test-Path -LiteralPath $oldDir) {
            for ($i = 1; $i -le 5; $i++) {
                Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $oldDir)) { break }
                Start-Sleep -Seconds 1
            }
            if (Test-Path -LiteralPath $oldDir) { Done (T 'resOldKept') } else { Done 'ok' }
        } else {
            Done 'ok'
        }
    }
    finally {
        # 5. Clean the whole OCDP folder in %TEMP%.
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# MAIN
# =============================================================================
# Single-instance guard, scoped to this portable root (fail fast, never wait:
# a second launcher must not download/swap while the first one is working).
Task (T 'taskInstance')
$Mutex = $null
try {
    $hb = [Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant()))
    $Mutex = New-Object Threading.Mutex($false, ('Local\OCDP_' + ([BitConverter]::ToString($hb).Replace('-','').Substring(0,12))))
    $acquired = $false
    try { $acquired = $Mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { Fail (T 'alreadyRunning') }
    Done 'ok'
} catch {
    # Fail() above already exited on contention; any other error means the guard
    # itself broke, so continue unguarded rather than blocking startup.
    if ($Mutex) { try { $Mutex.Dispose() } catch {} ; $Mutex = $null }
    Done (T 'resNoGuard')
}

Invoke-LogRotation

Task (T 'taskRoot')
Done (T 'resRoot' @($Root, $Arch))

# 0. ALWAYS stop lingering OpenCode before touching any data. The desktop app
#    spawns opencode-cli (the sidecar, shown as "Bun" in Task Manager) and it
#    often outlives the app window. The home migration and the swap move the
#    shared data folders, so any running instance must be stopped first.
# Wildcard on purpose: catches the app, the sidecar, the TUI and the installer.
$procNames = '*opencode*'
$running   = Get-Process -Name $procNames -ErrorAction SilentlyContinue
Task (T 'taskKill')
if ($running) {
    $names = ($running | Select-Object -ExpandProperty ProcessName | Sort-Object -Unique) -join ', '

    # Graceful close first (lets the app flush state), then force after a beat.
    foreach ($p in $running) {
        try { $p.CloseMainWindow() | Out-Null } catch {}
    }
    Start-Sleep -Seconds 3
    Get-Process -Name $procNames -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    # Wait up to ~10s for them to actually exit.
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Milliseconds 500
        $running = Get-Process -Name $procNames -ErrorAction SilentlyContinue
        if (-not $running) { break }
    }
    if ($running) {
        $left = ($running | Select-Object -ExpandProperty ProcessName | Sort-Object -Unique) -join ', '
        Fail (T 'killFail' @($left))
    }
    Done (T 'resKilled' @($names))
} else {
    Done (T 'resNone')
}

# Session scratch hygiene: %TEMP%\opencode is recreated by the app and all
# *opencode* processes are dead by now, so a wipe is safe.
Task (T 'taskScratch')
$scratch = Join-Path $env:TEMP 'opencode'
if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
Done 'ok'

# 1. Isolated home. First v3 run: move the v2 data\ layout into home\ and
#    drop the leftover profile junctions (link only — content was moved).
#    Subsequent runs: just make sure the home tree exists (idempotent).
Task (T 'taskMigrate')
$mig = Invoke-HomeMigration
if ($mig.moved -or $mig.links) { Done (T 'resMigrated' @($mig.moved, $mig.links)) }
elseif ($mig.fresh) { Done (T 'resMigrateFresh') }
else { Done (T 'resMigratedClean') }

# 2. Config that disables the built-in updater (lives in home\.config\opencode;
#    the sidecar reads it through XDG_CONFIG_HOME at launch).
Task (T 'taskUpdater')
$rewrote = Set-DisableUpdateConfig -ConfigDir (Join-Path $HomeConfig 'opencode')
if ($rewrote) { Done (T 'resUpdaterRewrite') } else { Done 'ok' }

# 2b. Deploy the universal AGENTS.md to the portable global slot (idempotent).
Task (T 'taskAgents')
switch (Set-GlobalAgents) {
    'deployed' { Done (T 'resAgentsDeployed') }
    'foreign'  { Done (T 'resAgentsForeign') }
    default    { Done 'ok' }
}

# 2c. Hijack a stray OpenCode shortcut the app may have recreated (repoint
#     at OCDP.cmd; never created — a deleted entry stays deleted).
Task (T 'taskShortcut')
switch (Repair-OpenCodeShortcut) {
    'repointed' { Done (T 'resShortcutRepointed') }
    'skip'      { Done (T 'resShortcutSkip') }
    'ok'        { Done (T 'resShortcutOk') }
    default     { Done (T 'resIgnored' @((T 'shortcutAbsent'))) }
}

# 2d. Default projects folder: a synced home for projects that exists on every
#     machine the portable folder lands on; also the fallback location for
#     sessions restored with a stale lastProject (see 2e).
Task (T 'taskProjects')
if (Test-Path -LiteralPath $Projects) {
    Done (T 'resProjectsOk' @($Projects))
} else {
    New-Item -ItemType Directory -Path $Projects -Force | Out-Null
    Done (T 'resProjectsCreated' @($Projects))
}

# 2d-bis. Git boundary per project folder: the sidecar resolves a directory to
#     the nearest enclosing git repository, so plain folders under projects\
#     would share the portable root's project identity.
Task (T 'taskGitBoundary')
$gitBoundaries = Set-ProjectGitBoundaries $Projects
if ($gitBoundaries -lt 0) { Done (T 'resIgnored' @(T 'gitMissing')) }
else { Done (T 'resGitBoundary' @($gitBoundaries)) }

# 2e. Repair saved desktop locations (drafts.sqlite): remap saved paths when
#     the portable folder moved to another path/machine, then drop whatever
#     is still missing so the app never boots into a broken restore.
Task (T 'taskLocations')
try {
    $loc = Repair-SavedLocations
} catch {
    Write-Log "  saved-location repair crashed: $($_.Exception.Message)"
    $loc = 'skipSqliteFail'
}
if ($loc -is [string]) {
    Done (T 'resIgnored' @(T $loc))
} else {
    $locParts = @()
    if ($loc.remap)       { $locParts += (T 'locRemapped' @($loc.remap)) }
    if ($loc.sidecar)     { $locParts += (T 'locSidecar' @($loc.sidecar)) }
    if ($loc.projects)    { $locParts += (T 'locProjects' @($loc.projects)) }
    if ($loc.tabs)        { $locParts += (T 'locTabs' @($loc.tabs)) }
    if ($loc.restored)    { $locParts += (T 'locRestored' @($loc.restored)) }
    if ($loc.lastProject) { $locParts += (T 'locLastProject') }
    if ($loc.sidecarFail) { $locParts += (T 'locSidecarFail') }
    if ($locParts.Count) { Done (T 'resLocationsFixed' @($locParts -join ', ')) }
    else { Done (T 'resLocationsOk') }
}

# 3. Install / update needed?
if ($NoUpdate -and $Force) { Fail (T 'conflictingFlags') }
$need = $Force -or -not (Test-Path -LiteralPath $Exe)
$info = $null

Task (T 'taskCheck')
if (-not $need -and -not $NoUpdate) {
    $info = Get-RemoteInfo -ArchSel $Arch
    $local = Get-LocalVersion -Path $Exe
    if ($info.Version) {
        $remote = $null
        try { $remote = [version]$info.Version } catch { $remote = $null }
        if ($remote -and $local -and ($local -lt $remote)) {
            Done (T 'resNewVersion' @($remote))
            $need = $true
        } elseif ($remote -and -not $local) {
            Done (T 'resNewVersion' @($remote))
            $need = $true
        } elseif (-not $remote) {
            # Unknown remote version: keep local instead of churning a full
            # download on every start.
            $rv = $info.Version
            if (-not $rv) { $rv = '?' }
            Done (T 'resRemoteUnknown' @($rv))
        } else {
            Done (T 'resUpToDate' @($local))
        }
    } else {
        # Feed without a version line at all: keep local, launch as-is.
        Done (T 'resRemoteUnknown' @('?'))
    }
} elseif ($need -and $NoUpdate -and -not (Test-Path -LiteralPath $Exe)) {
    Fail (T 'noUpdateNoInstall')
} elseif ($NoUpdate) {
    Done (T 'resIgnored' @('-NoUpdate'))
} elseif ($Force) {
    Done (T 'resIgnoredForce')
}

if ($need) {
    # Reuse the feed read from the check above; fetch only when not read yet
    # (first-install / -Force path).
    if (-not $info) { $info = Get-RemoteInfo -ArchSel $Arch }
    Invoke-Update -Info $info
}

# 4. Launch — with the isolated environment. USERPROFILE carries the Electron
#    profile and the service state: Chromium resolves its profile folders from
#    the registry's %USERPROFILE% templates expanded with the process env, so
#    APPDATA/LOCALAPPDATA alone do NOT redirect them (verified in tests).
#    HOME keeps its real value (or derives from the real profile): git/ssh
#    inside agent sessions must keep finding .gitconfig/.ssh. XDG_STATE_HOME
#    is never set (the desktop deletes it anyway) — state rides on USERPROFILE
#    into home\.
Task (T 'taskLaunch')
if (-not (Test-Path -LiteralPath $Exe)) { Fail (T 'noBinary' @($Exe)) }
$env:USERPROFILE     = $HomeDir
$env:APPDATA         = $HomeAppData
$env:LOCALAPPDATA    = $HomeLocalData
$env:XDG_DATA_HOME   = $HomeShare
$env:XDG_CONFIG_HOME = $HomeConfig
$env:XDG_CACHE_HOME  = $HomeCache
Remove-Item Env:\XDG_STATE_HOME -ErrorAction SilentlyContinue
$realHome = $env:HOME
if (-not $realHome) { $realHome = $RealUserProfile }
if ($realHome) { $env:HOME = $realHome }
Done (T 'resLaunch')

# Detach from this console BEFORE launching: the app (and the sidecar it
# spawns) would otherwise attach to this console and keep the launcher
# window open for as long as they run. With no console for the child to
# inherit/attach, the launcher window closes by itself once this script
# and OCDP.cmd exit. Error paths exit above, so Fail messages still keep
# the window open (pause in OCDP.cmd) with the details readable.
Add-Type -Name Native -Namespace OCDP -MemberDefinition '
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AttachConsole(uint dwProcessId);
' -ErrorAction SilentlyContinue
try { [OCDP.Native]::FreeConsole() | Out-Null } catch {}

# ATTACH_PARENT_PROCESS (0xFFFFFFFF): reattach to the parent console so a
# start failure stays visible (Fail holds the window open via OCDP.cmd).
try {
    Start-Process -FilePath $Exe -WorkingDirectory $AppDir
} catch {
    try { [OCDP.Native]::AttachConsole([uint32]::MAXDWORD) | Out-Null } catch {}
    Fail (T 'launchFail' @($_.Exception.Message))
}
if ($Mutex) { try { $Mutex.ReleaseMutex(); $Mutex.Dispose() } catch {} }
exit 0
