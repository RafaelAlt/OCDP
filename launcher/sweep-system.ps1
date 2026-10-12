<#
.SYNOPSIS
    Sweep registry + system state for opencode/ocdp traces.
.DESCRIPTION
    Read-only diagnostic. Checks target folders, package-manager installs,
    crash dumps, prefetch, HKCU/HKLM keys (uninstall, Run, protocol,
    MuiCache, CompatAssist), env vars, scheduled tasks, services and
    shortcuts (.lnk -> target).
.NOTES
    Safe to run: it only lists; it never writes or deletes.
    Prefetch/Some HKLM reads may need elevation; failures stay silent.
    Moved here from the session temp (it used to be auto-wiped with it).
    Output labels are pt-BR (operator-facing); code/comments are English.
#>
$ErrorActionPreference = 'SilentlyContinue'
$u = $env:USERPROFILE

Write-Output '=== Pastas-alvo especificas ==='
$targets = @(
 "$u\.opencode",
 "$u\.bun",
 "$u\scoop",
 "$env:LOCALAPPDATA\opencode",
 "$env:LOCALAPPDATA\OpenCode",
 "$env:LOCALAPPDATA\@opencodedesktop-updater",
 "$env:APPDATA\OpenCode",
 "$env:APPDATA\npm",
 "$env:LOCALAPPDATA\Temp\OCDP",
 "$env:LOCALAPPDATA\CrashDumps",
 "$u\Documents\Default Project",
 'C:\OCDP','C:\OpenCode','C:\opencode'
)
foreach ($t in $targets) {
  if (Test-Path -LiteralPath $t) {
    $i = Get-Item -LiteralPath $t -Force
    $extra = ''
    if ($i.LinkType) { $extra = " [$($i.LinkType) -> $($i.Target)]" }
    "EXISTE: $t$extra"
    if (-not $i.LinkType) {
      Get-ChildItem -LiteralPath $t -Force | Select-Object -First 12 | ForEach-Object { "   - $($_.Name)" }
    }
  } else { "ausente: $t" }
}

Write-Output '=== CLI via package managers? ==='
foreach ($pm in @("$env:APPDATA\npm", "$u\.bun\bin", "$u\scoop\shims", 'C:\ProgramData\chocolatey\bin')) {
  if (Test-Path $pm) {
    $f = Get-ChildItem $pm -Filter '*opencode*' -ErrorAction SilentlyContinue
    if ($f) { $f | ForEach-Object { "$pm :: $($_.Name)" } } else { "$pm :: (existe, sem opencode)" }
  } else { "$pm :: (nao existe)" }
}

Write-Output '=== CrashDumps *opencode* ==='
Get-ChildItem "$env:LOCALAPPDATA\CrashDumps" -Filter '*opencode*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }

Write-Output '=== Prefetch *OPENCODE* (pode falhar sem admin) ==='
Get-ChildItem 'C:\Windows\Prefetch' -Filter '*OPENCODE*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }

Write-Output '=== HKCU\Software *opencode* ==='
Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'opencode' } | ForEach-Object { $_.PSChildName }

Write-Output '=== Entradas de desinstalacao ==='
foreach ($root in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
  Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.DisplayName -match 'opencode' -or $_.PSChildName -match 'opencode') { "$_ :: $($p.DisplayName) :: $($p.InstallLocation)" }
  }
}

Write-Output '=== Run / autostart ==='
foreach ($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
  (Get-ItemProperty $rk -ErrorAction SilentlyContinue).PSObject.Properties |
    Where-Object { $_.Name -notlike 'PS*' -and ($_.Name -match 'opencode' -or $_.Value -match 'opencode') } |
    ForEach-Object { "$rk :: $($_.Name) = $($_.Value)" }
}

Write-Output '=== Protocolo opencode:// ==='
"HKCU: $(Test-Path 'HKCU:\Software\Classes\opencode')  HKLM: $(Test-Path 'HKLM:\SOFTWARE\Classes\opencode')"

Write-Output '=== MuiCache (exes ja vistos pelo Explorer) ==='
(Get-Item 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache' -ErrorAction SilentlyContinue).Property | Where-Object { $_ -match 'opencode' }

Write-Output '=== CompatAssist Store (exes ja executados) ==='
(Get-Item 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store' -ErrorAction SilentlyContinue).Property | Where-Object { $_ -match 'opencode' }

Write-Output '=== Variaveis de ambiente persistentes ==='
foreach ($scope in 'User','Machine') {
  [Environment]::GetEnvironmentVariables($scope).GetEnumerator() |
    Where-Object { $_.Key -match 'OPENCODE' -or $_.Value -match 'opencode' } |
    ForEach-Object { "$scope :: $($_.Key) = $($_.Value)" }
}

Write-Output '=== Tarefas agendadas ==='
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'opencode' -or ($_.Actions | ForEach-Object { $_.Execute }) -match 'opencode' } | ForEach-Object { $_.TaskPath + $_.TaskName }

Write-Output '=== Servicos ==='
Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'opencode' -or $_.DisplayName -match 'opencode' } | ForEach-Object { $_.Name }

Write-Output '=== Atalhos (menus iniciar, desktop, taskbar) ==='
$sh = New-Object -COMObject WScript.Shell
$smRoots = @(
 'C:\ProgramData\Microsoft\Windows\Start Menu',
 "$u\AppData\Roaming\Microsoft\Windows\Start Menu",
 "$u\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch",
 'C:\Users\Public\Desktop',
 "$u\Desktop"
)
foreach ($sm in $smRoots) {
  Get-ChildItem $sm -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match 'opencode|ocdp' } |
    ForEach-Object { $t = $sh.CreateShortcut($_.FullName); "$($_.FullName) -> $($t.TargetPath)" }
}
Write-Output 'FIM'
