<#
.SYNOPSIS
    OCDP - OpenCode Desktop Portable launcher.
.DESCRIPTION
    Concentrates data via junctions, keeps the app up to date from the
    official feed, and starts OpenCode in portable mode.
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
$Root   = Split-Path -Parent $PSScriptRoot          # portable root (parent of tools\)
# Folder name is historical ('app-64'); it holds the $Arch build (x64 or arm64).
$AppDir = Join-Path $Root 'app-64'
$Exe    = Join-Path $AppDir 'OpenCode.exe'
$Data   = Join-Path $Root 'data'
$Launcher = Join-Path $Root 'launcher'
$Seven    = Join-Path $Launcher '7za.exe'
$Feed   = 'https://opencode.ai/update/api/latest/desktop/opencode/latest.yml'

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
        'taskJunctions'    = 'checking data junctions'
        'taskUpdater'      = 'disabling the native updater'
        'taskAgents'       = 'deploying global AGENTS.md'
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
        'resJunctionsOk'   = 'ok ({0})'
        'resJunctionsChg'  = 'ok ({0}; {1})'
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

Every run: kills running OpenCode processes, relinks junctions, repoints a
stray OpenCode shortcut at OCDP.cmd, wipes the session temp
(%TEMP%\opencode), checks the official feed (sha512-verified) and launches
the app.
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
        # Junction state labels (tokens returned by Set-PortableJunction).
        'js.ok'            = 'ok'
        'js.created'       = 'created'
        'js.migrated'      = 'migrated'
        'js.relinked'      = 'relinked'
    }
    'pt-BR' = @{
        # Tarefas (ciano, sem quebra de linha) e resultados (na mesma linha, após ': ').
        'taskInstance'     = 'verificando instância única'
        'taskRoot'         = 'configurando raiz portátil'
        'taskKill'         = 'encerrando processos relacionados'
        'taskScratch'      = 'limpando raspeiro de sessão'
        'taskJunctions'    = 'verificando portas de dados'
        'taskUpdater'      = 'desabilitando atualização nativa'
        'taskAgents'       = 'implantando AGENTS.md global'
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
        'resJunctionsOk'   = 'ok ({0})'
        'resJunctionsChg'  = 'ok ({0}; {1})'
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

Toda execução: encerra processos do OpenCode, refaz as junctions, reaponta
um atalho OpenCode estranho para o OCDP.cmd, esvazia o raspeiro de sessão
(%TEMP%\opencode), verifica o feed oficial (sha512) e abre o app.
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
        'js.ok'            = 'ok'
        'js.created'       = 'criada'
        'js.migrated'      = 'migrada'
        'js.relinked'      = 'relinkada'
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

# --- Junctions ------------------------------------------------------------
# Each entry: subfolder name under %~dp0data  <->  real source in the profile.
$JunctionMap = @(
    @{ Name = 'ai.opencode.desktop'; Source = Join-Path $env:APPDATA      'ai.opencode.desktop' }
    @{ Name = 'share-opencode';      Source = Join-Path $env:USERPROFILE  '.local\share\opencode' }
    @{ Name = 'config-opencode';     Source = Join-Path $env:USERPROFILE  '.config\opencode' }
    @{ Name = 'state-opencode';      Source = Join-Path $env:USERPROFILE  '.local\state\opencode' }
    @{ Name = 'cache-opencode';      Source = Join-Path $env:USERPROFILE  '.cache\opencode' }
)

function Test-LinkTarget([string]$LinkPath, [string]$WantTarget) {
    $item = Get-Item -LiteralPath $LinkPath -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $cur = @($item.Target)[0]
    if (-not $cur) { return $false }
    return ([IO.Path]::GetFullPath($cur).TrimEnd('\') -ieq [IO.Path]::GetFullPath($WantTarget).TrimEnd('\'))
}

function Set-PortableJunction([string]$Source, [string]$Target) {
    # Ensure the destination exists inside the portable folder.
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Source) {
        $item = Get-Item -LiteralPath $Source -Force

        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if (Test-LinkTarget $Source $Target) { return 'ok' }
            # Junction points elsewhere / broken: drop the link only and recreate.
            $item.Delete()
            New-Item -ItemType Junction -Path $Source -Target $Target | Out-Null
            return 'relinked'
        }

        # Real directory with content: migrate it into the portable folder.
        $null = robocopy $Source $Target /E /MOVE /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) { Fail (T 'migrateFail' @($Source, $LASTEXITCODE)) }
        Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Source) { Fail (T 'removeFail' @($Source)) }
        New-Item -ItemType Junction -Path $Source -Target $Target | Out-Null
        return 'migrated'
    }

    # Source missing: create the folder and the link.
    $parent = Split-Path -Parent $Source
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    New-Item -ItemType Junction -Path $Source -Target $Target | Out-Null
    return 'created'
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

# Deploy the universal AGENTS.md to the global config slot so that every
# OpenCode session — even ones opened outside the portable root — knows the
# portable rules. Idempotent: writes only when the content differs, and never
# touches a global file that is not OCDP-managed (marker check).
function Set-GlobalAgents {
    $src = Join-Path $Launcher 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $src)) { return 'noop' }
    $dst = Join-Path $env:USERPROFILE '.config\opencode\AGENTS.md'
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
# through the launcher (update check, junctions, env). Never creates the
# entry: a deleted shortcut stays deleted (if the app recreates it raw, the
# next run repoints it again).
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

        # Disable Electron's auto-updater (electron-updater reads this file).
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
#    often outlives the app window. The migration/junction and the swap move
#    the shared data folders, so any running instance must be stopped first.
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

# 1. Junctions
Task (T 'taskJunctions')
$changes = @()
foreach ($j in $JunctionMap) {
    $target = Join-Path $Data $j.Name
    $state  = Set-PortableJunction -Source $j.Source -Target $target
    if ($state -ne 'ok') { $changes += ("{0}: {1}" -f $j.Name, (T "js.$state")) }
}
if ($changes.Count) { Done (T 'resJunctionsChg' @($JunctionMap.Count, ($changes -join '; '))) }
else { Done (T 'resJunctionsOk' @($JunctionMap.Count)) }

# 2. Config that disables the built-in updater (lives in .\data\config-opencode via junction)
Task (T 'taskUpdater')
$rewrote = Set-DisableUpdateConfig -ConfigDir (Join-Path $Data 'config-opencode')
if ($rewrote) { Done (T 'resUpdaterRewrite') } else { Done 'ok' }

# 2b. Deploy the universal AGENTS.md to the global slot (idempotent).
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

# 4. Launch
Task (T 'taskLaunch')
if (-not (Test-Path -LiteralPath $Exe)) { Fail (T 'noBinary' @($Exe)) }
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
