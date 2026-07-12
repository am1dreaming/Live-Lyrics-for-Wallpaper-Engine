# MinenkoY
# lyric music by am1dreaming - uninstaller (ASCII-only).


$ErrorActionPreference = "Continue"

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir -and $MyInvocation.MyCommand.Path) { 
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path 
}
if (-not $ScriptDir) { 
    $ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $self = $PSCommandPath
  if ($self -and (Test-Path -LiteralPath $self)) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self)
  } else {
    Start-Process ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Verb RunAs
  }
  return
}

$Root = $ScriptDir
$Bridge = Join-Path $Root "bridge"
$ExtName = "spicetify-lyrics-bridge.js"
$Port = 8973
$TaskName = "LyricMusicRelay"
$InstallDir    = Join-Path $env:LOCALAPPDATA "LyricMusic"
$BridgeInstall = Join-Path $InstallDir "bridge"

function Stage($m) {
    Write-Host "`n== $m ==" 
}
function OK($m)    { 
    Write-Host "  [OK] $m"
}
function Note($m)  { 
    Write-Host "  $m"
}

function Resolve-Exe([string]$n, [string[]]$fb) {
  $c = Get-Command $n -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($f in $fb) { 
      if ($f -and (Test-Path -LiteralPath $f)) {
          return $f 
      } 
  }
  return $null
}
function Get-WEProjects {
  $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
  if (-not $steam) { 
      return $null 
  }
  $steam = $steam -replace "/", "\"
  $libs = @($steam)
  $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
  if (Test-Path -LiteralPath $vdf) { Get-Content -LiteralPath $vdf | Select-String '"path"\s+"(.+?)"' | ForEach-Object { $libs += ($_.Matches.Groups[1].Value -replace "\\\\","\") } }
  foreach ($l in ($libs | Select-Object -Unique)) {
    $p = Join-Path $l "steamapps\common\wallpaper_engine\projects\myprojects"
    if (Test-Path -LiteralPath $p) {
        return $p 
    }
  }
  return $null
}

Write-Host "`nlyric music by am1dreaming - uninstall"
Write-Host "create by MinenkoY`n"

Stage "Relay autostart"
schtasks /Delete /TN "$TaskName" /F 2>$null | Out-Null
Unregister-ScheduledTask -TaskName "$TaskName" -Confirm:$false -ErrorAction SilentlyContinue
foreach ($name in @("Lyric Music Relay.lnk", "Spicy Lyrics Relay.lnk")) {
  $lnk = Join-Path ([Environment]::GetFolderPath("Startup")) $name
  if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
}
OK "Autostart removed."
$conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($conns) { 
    $conns | Select-Object -Expand OwningProcess -Unique | ForEach-Object { try { Stop-Process -Id $_ -Force -ErrorAction Stop; 
    OK "Relay stopped (PID $_)." 
    } catch {} } }
else { 
    Note "Relay not running."
}

Stage "Spotify auto-update"
$updDir = "$env:LOCALAPPDATA\Spotify\Update"
if (Test-Path -LiteralPath $updDir -PathType Leaf) { Remove-Item -LiteralPath $updDir -Force; OK "Auto-update re-enabled." }
else { Note "Auto-update was not blocked." }

Stage "Spicetify extension"
$sp = Resolve-Exe "spicetify" @("$env:LOCALAPPDATA\spicetify\spicetify.exe")
if ($sp) {
  Stop-Process -Name "Spotify" -Force -ErrorAction SilentlyContinue
  Start-Sleep 1
  & $sp config extensions "$ExtName-" | Out-Null
  & $sp apply | Out-Null
  OK "Extension disabled, Spicetify applied."
  $userdata = $null
  try { $userdata = (& $sp path userdata) 2>$null } catch {}
  if (-not $userdata) { $userdata = "$env:APPDATA\spicetify" }
  $extFile = Join-Path (Join-Path ($userdata | Out-String).Trim() "Extensions") $ExtName
  if (Test-Path -LiteralPath $extFile) { Remove-Item -LiteralPath $extFile -Force; OK "Extension file removed." }
} else { Note "Spicetify not found - skipping." }

Stage "Relay files & cover cache"
if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $InstallDir)) { OK "Relay files and cache removed ($InstallDir)." }
    else { Note "Some relay files were locked; delete $InstallDir manually if needed." }
} else {
    Note "No installed relay files."
}
# Legacy: cache/deps that older builds left next to the source folder.
foreach ($legacy in @((Join-Path $Bridge "cache"), (Join-Path $Bridge "node_modules"))) {
    if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue }
}

Stage "Wallpaper Engine"
$projects = Get-WEProjects
if ($projects) {
  foreach ($id in @("lyric-music-by-am1dreaming", "lyric-music-by-yaroslav")) {
    $dst = Join-Path $projects $id
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force; OK "Removed $id from the WE library." }
  }
} else { Note "Wallpaper Engine not found - remove the wallpaper manually if needed." }

Write-Host "`nUninstall complete."
Write-Host @"

Left installed (shared tools): Spotify, Node.js, ffmpeg, Spicetify.
Fully revert Spotify to stock: spicetify restore
Remove Spicetify itself: delete %LOCALAPPDATA%\spicetify and %APPDATA%\spicetify
create by MinenkoY
"@

Read-Host "`nPress Enter to exit"
