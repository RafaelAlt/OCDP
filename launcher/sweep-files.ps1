<#
.SYNOPSIS
    Sweep the filesystem for any leftover opencode/ocdp footprint.
.DESCRIPTION
    Read-only diagnostic. Walks the usual roots, finds items named
    opencode/ocdp and buckets them: junction doors, Windows Search index,
    Recycle Bin, temp, and OUTSIDE-of-known (the interesting ones).
.NOTES
    Safe to run: it only lists; it never writes or deletes.
    Moved here from the session temp (it used to be auto-wiped with it).
    Output labels are pt-BR (operator-facing); code/comments are English.
#>
$ErrorActionPreference = 'SilentlyContinue'
$sw = [Diagnostics.Stopwatch]::StartNew()
$u  = $env:USERPROFILE

# Junction doors + other known/legit locations: never reported as "outside".
$knownPrefixes = @(
  "$u\.cache\opencode",
  "$u\.config\opencode",
  "$u\.local",
  "$u\AppData\Roaming\ai.opencode.desktop"
)
$searchPrefix = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.Search"
$rbPrefix     = 'C:\$Recycle.Bin'
$tempPrefix   = "$env:LOCALAPPDATA\Temp"

$roots = @('C:\Users','C:\ProgramData','C:\Program Files','C:\Program Files (x86)','C:\$Recycle.Bin','C:\Windows\Temp')
$lines = New-Object System.Collections.Generic.List[string]
foreach ($r in $roots) {
  $cmd = 'dir /s /b /a "' + $r + '" 2>nul | findstr /i /c:"opencode" /c:"ocdp"'
  $out = & cmd.exe /d /s /c $cmd
  foreach ($l in $out) { if ($l) { $lines.Add($l.Trim()) } }
}

$buckets = @{ junction = 0; search = 0; recycle = 0; temp = 0 }
$outside = New-Object System.Collections.Generic.List[string]
foreach ($l in $lines) {
  $isKnown = $false
  foreach ($p in $knownPrefixes) {
    if ($l.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { $isKnown = $true; break }
  }
  if ($isKnown) { $buckets.junction++; continue }
  if ($l.StartsWith($searchPrefix, [StringComparison]::OrdinalIgnoreCase)) { $buckets.search++; continue }
  if ($l.StartsWith($rbPrefix,     [StringComparison]::OrdinalIgnoreCase)) { $buckets.recycle++; continue }
  if ($l.StartsWith($tempPrefix,   [StringComparison]::OrdinalIgnoreCase)) { $buckets.temp++; continue }
  $outside.Add($l)
}

"TOTAL de itens com nome opencode/ocdp: $($lines.Count)"
"Dentro das portas (junctions):  $($buckets.junction)"
"Indice Windows Search:          $($buckets.search)"
"Lixeira:                        $($buckets.recycle)"
"Temp (transitorio):             $($buckets.temp)"
"FORA dos conhecidos:            $($outside.Count)"
if ($outside.Count) {
  "---- LISTA FORA ----"
  $outside | Sort-Object -Unique | ForEach-Object { $_ }
}
"---- raiz de C: (1 nivel) ----"
Get-ChildItem 'C:\' -Directory -Force | Where-Object { $_.Name -match 'opencode|ocdp' } | ForEach-Object { $_.FullName }
"Duracao: $([int]$sw.Elapsed.TotalSeconds)s"
