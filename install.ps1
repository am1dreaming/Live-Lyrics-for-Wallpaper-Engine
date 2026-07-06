# MinenkoY
# lyric music by am1dreaming - installer.
param(
  [ValidateSet('Ask','Full','NoWallpaper','WallpaperOnly','Custom')]
  [string]$Preset = 'Ask',
  [switch]$SkipSpotify,
  [switch]$SkipNode,
  [switch]$SkipFfmpeg,
  [switch]$SkipSpicetify,
  [switch]$SkipBridge,
  [switch]$SkipAutostart,
  [switch]$SkipUpdateBlock,
  [switch]$SkipWallpaper,
  [switch]$Yes
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir -and $MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $self = $PSCommandPath
  if ($self -and (Test-Path -LiteralPath $self)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
      $val = $kv.Value
      if ($val -is [System.Management.Automation.SwitchParameter]) {
        if ($val.IsPresent) { $argList += "-$($kv.Key)" }
      } else {
        $argList += "-$($kv.Key)"
        $argList += [string]$val
      }
    }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList }
    catch { Write-Host "[ERROR] Could not elevate: $($_.Exception.Message)" }
  } else {
    Start-Process ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Verb RunAs
  }
  return
}

$Root = $ScriptDir
$Wallpaper = Join-Path $Root "wallpaper"
$Bridge = Join-Path $Root "bridge"
$ExtName = "spicetify-lyrics-bridge.js"
$Port = 8973
$ProjectId = "lyric-music-by-am1dreaming"
$TaskName = "LyricMusicRelay"
$Warnings = New-Object System.Collections.ArrayList

function Stage($m) { 
    Write-Host "`n== $m ==" 
}
function OK($m)    { 
    Write-Host "  [OK] $m"
}
function Note($m)  { 
    Write-Host "  $m" 
}
function Warn($m)  { 
    Write-Host "  [!] $m"; [void]$Warnings.Add($m) 
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
              [Environment]::GetEnvironmentVariable("Path", "User")
}
function Resolve-Exe([string]$name, [string[]]$fallbacks) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) {
      return $c.Source
  }
  foreach ($f in $fallbacks) { 
      if ($f -and (Test-Path -LiteralPath $f)) { 
          return $f 
      }
  }
  return $null
}
function Have-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }

function Ask-YN([string]$question, [bool]$default) {
  if ($Yes) { 
      return $default 
  }
  $suffix = if ($default) { "[Y/n]" } else { 
      "[y/N]" 
  }
  while ($true) {
    $a = (Read-Host "  $question $suffix").Trim().ToLower()
    if ($a -eq "") { 
        return $default 
    }
    if ($a -eq "y" -or $a -eq "yes") { 
        return $true
    }
    if ($a -eq "n" -or $a -eq "no")  { 
        return $false
    }
  }
}

function Get-WEProjects {
  $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
  if (-not $steam) { 
      return $null
  }
  $steam = $steam -replace "/", "\"
  $libs = @($steam)
  $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
  if (Test-Path -LiteralPath $vdf) {
    Get-Content -LiteralPath $vdf | Select-String '"path"\s+"(.+?)"' | ForEach-Object {
      $libs += ($_.Matches.Groups[1].Value -replace "\\\\", "\")
    }
  }
  foreach ($l in ($libs | Select-Object -Unique)) {
    $p = Join-Path $l "steamapps\common\wallpaper_engine\projects\myprojects"
    if (Test-Path -LiteralPath $p) { 
        return $p
    }
  }
  return $null
}

function Get-SpotifyVersion {
  $desktopExe = "$env:APPDATA\Spotify\Spotify.exe"
  if (Test-Path -LiteralPath $desktopExe) {
    try {
      $vi = (Get-Item -LiteralPath $desktopExe).VersionInfo
      $v = $vi.ProductVersion; if (-not $v) {
          $v = $vi.FileVersion 
      }
      if ($v) { 
          return $v.Trim()
      }
    } catch {}
  }
  $store = Get-AppxPackage -Name "SpotifyAB.SpotifyMusic" -ErrorAction SilentlyContinue
  if ($store) { 
      return "$($store.Version) (Microsoft Store)"
  }
  return $null
}

function Ensure-Spotify {
  Stage "Spotify"
  $desktopExe = "$env:APPDATA\Spotify\Spotify.exe"
  $store = Get-AppxPackage -Name "SpotifyAB.SpotifyMusic" -ErrorAction SilentlyContinue
  if ($store) {
    Warn "Spotify is the Microsoft Store build; Spicetify cannot patch it."
    Note "Removing the Store build..."
    try { 
        $store | Remove-AppxPackage -ErrorAction Stop; OK "Store build removed."
    }
    catch {
        Warn "Could not remove it automatically: $($_.Exception.Message). Remove Spotify from Start menu manually, then re-run."; return
    }
    Install-DesktopSpotify $desktopExe
  }
  elseif (-not (Test-Path -LiteralPath $desktopExe)) {
    Note "Spotify not found; installing the desktop build..."
    Install-DesktopSpotify $desktopExe
  }
  else { OK "Desktop Spotify already installed." }
}
function Install-DesktopSpotify([string]$desktopExe) {
  $setup = Join-Path $env:TEMP "SpotifySetup.exe"
  Note "Downloading the official Spotify installer..."
  Invoke-WebRequest "https://download.scdn.co/SpotifySetup.exe" -OutFile $setup
  Note "Installing Spotify..."
  Start-Process -FilePath $setup -Wait
  $deadline = (Get-Date).AddMinutes(3)
  while (-not (Test-Path -LiteralPath $desktopExe) -and (Get-Date) -lt $deadline) {
      Start-Sleep 3 
  }
  if (Test-Path -LiteralPath $desktopExe) {
      OK "Spotify installed." 
  } else { 
      Warn "Spotify may not have finished installing; check manually" 
  }
  Start-Sleep 4
  Stop-Process -Name "Spotify" -Force -ErrorAction SilentlyContinue
}

function Ensure-Node {
  Stage "Node.js"
  if (Resolve-Exe "node" @("$env:ProgramFiles\nodejs\node.exe")) { OK "Node.js already installed."; Refresh-Path; return }
  if (-not (Have-Winget)) { throw "Node.js missing and winget unavailable. Install Node.js LTS from https://nodejs.org and re-run." }
  Note "Installing Node.js LTS via winget..."
  winget install --id OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements | Out-Null
  Refresh-Path
  if (Resolve-Exe "node" @("$env:ProgramFiles\nodejs\node.exe")) { 
      OK "Node.js installed" 
  }
  else { 
      throw "Node.js did not install. Install it manually from https://nodejs.org" 
  }
}

function Ensure-Ffmpeg {
  Stage "ffmpeg (animated covers)"
  $ff = Resolve-Exe "ffmpeg" @()
  if (-not $ff) {
    $pkgs = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $pkgs) { $ff = (Get-ChildItem -LiteralPath $pkgs -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -Expand FullName) }
  }
  if ($ff) { 
      OK "ffmpeg found."; return 
  }
  if (-not (Have-Winget)) {
      Warn "ffmpeg missing and no winget; animated covers disabled (lyrics and static cover still work)."; return 
  }
  Note "Installing ffmpeg via winget..."
  try { 
      winget install --id Gyan.FFmpeg --silent --accept-source-agreements --accept-package-agreements | Out-Null; Refresh-Path; OK "ffmpeg installed."
  }
  catch { 
      Warn "ffmpeg did not install; animated covers disabled, everything else works." 
  }
}


function Ensure-Spicetify {
  Stage "Spicetify"
  $sp = Resolve-Exe "spicetify" @("$env:LOCALAPPDATA\spicetify\spicetify.exe")
  if ($sp) { OK "Spicetify already installed."; return $sp }
  Note "Installing Spicetify CLI (no Marketplace)..."
  Invoke-Expression (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/spicetify/cli/main/install.ps1").Content
  Refresh-Path
  $sp = Resolve-Exe "spicetify" @("$env:LOCALAPPDATA\spicetify\spicetify.exe")
  if (-not $sp) { throw "Spicetify did not install. See https://spicetify.app/docs/getting-started" }
  OK "Spicetify installed."
  return $sp
}


function Ensure-Compatible([string]$sp) {
  Stage "Spicetify <-> Spotify compatibility"
  $spotVer = Get-SpotifyVersion
  if ($spotVer) { Note "Spotify version:   $spotVer" } else { Note "Spotify version:   unknown (Spotify not found yet)" }

  $spVer = $null
  try { $spVer = (& $sp -v) 2>$null } catch {}
  if ($spVer) { Note "Spicetify version: $(($spVer | Out-String).Trim())" }

  Note "Updating Spicetify to the latest release so it matches the newest Spotify..."
  try {
    & $sp upgrade | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $spVer2 = $null
      try { $spVer2 = (& $sp -v) 2>$null } catch {}
      if ($spVer2) { OK "Spicetify is up to date: $(($spVer2 | Out-String).Trim())" } else { OK "Spicetify upgrade finished." }
    } else {
      Warn "spicetify upgrade returned a non-zero code; continuing with the installed version."
    }
  } catch {
    Warn "Could not run 'spicetify upgrade': $($_.Exception.Message). Continuing."
  }
}

function Install-Extension([string]$sp) {
  Stage "Extension"
  $extSrc = Join-Path $Bridge $ExtName
  if (-not (Test-Path -LiteralPath $extSrc)) { throw "Missing $extSrc - run the installer from inside the release folder." }
  $userdata = $null
  try {
    # 'spicetify path userdata' can emit extra log/colored lines (esp. right
    # after a failed upgrade); strip ANSI escapes and keep only a real drive
    # path so Join-Path never chokes on illegal characters.
    $userdata = @(& $sp path userdata 2>$null) |
      ForEach-Object { ([string]$_) -replace "$([char]27)\[[0-9;]*[A-Za-z]", '' } |
      Where-Object { $_ -match '[A-Za-z]:\\' } |
      Select-Object -Last 1
    if ($userdata) { $userdata = $userdata.Trim() }
  } catch {}
  if (-not $userdata) { $userdata = Join-Path $env:APPDATA 'spicetify' }
  $extDir = Join-Path $userdata "Extensions"
  New-Item -ItemType Directory -Force -Path $extDir | Out-Null
  Copy-Item -LiteralPath $extSrc -Destination $extDir -Force
  OK "Extension copied."

  Stop-Process -Name "Spotify" -Force -ErrorAction SilentlyContinue
  Start-Sleep 1
  & $sp config extensions "$ExtName" | Out-Null
  & $sp apply
  if ($LASTEXITCODE -ne 0) { Note "First apply - creating backup..."; & $sp backup apply }
  if ($LASTEXITCODE -eq 0) { OK "Spicetify applied." }
  else { Warn "spicetify apply failed. Spotify may be newer than this Spicetify supports - run 'spicetify upgrade' then 'spicetify apply', or wait for the next Spicetify update." }
}

function Block-SpotifyUpdate {
  Stage "Keep Spicetify persistent (block Spotify auto-update)"
  $updDir = "$env:LOCALAPPDATA\Spotify\Update"
  try {
    if (Test-Path -LiteralPath $updDir -PathType Container) { Remove-Item -LiteralPath $updDir -Recurse -Force }
    if (-not (Test-Path -LiteralPath $updDir)) { New-Item -ItemType File -Path $updDir -Force | Out-Null }
    Set-ItemProperty -LiteralPath $updDir -Name IsReadOnly -Value $true
    OK "Spotify auto-update blocked (Spicetify will survive reboots)."
  } catch { Warn "Could not block Spotify updates: $($_.Exception.Message). If lyrics vanish after a Spotify update, re-run this installer." }
}

function Install-BridgeDeps {
  Stage "Relay dependencies"
  $npm = Resolve-Exe "npm" @("$env:ProgramFiles\nodejs\npm.cmd")
  if (-not $npm) { throw "npm not found after Node.js install." }
  Push-Location -LiteralPath $Bridge
  try {
    Note "npm install ws..."
    & $npm install ws --omit=dev --no-audit --no-fund --loglevel=error
    if ($LASTEXITCODE -eq 0) { OK "Dependencies installed." } else { Warn "npm install failed - check internet and re-run." }
  } finally { Pop-Location }
}

function Setup-Autostart {
  Stage "Relay autostart (port $Port)"
  $vbs = Join-Path $Bridge "start-bridge.vbs"
  if (-not (Test-Path -LiteralPath $vbs)) { Warn "start-bridge.vbs missing - autostart skipped."; return }


  try {
    $act = New-ScheduledTaskAction -Execute "wscript.exe" -Argument ('"' + $vbs + '"') -WorkingDirectory $Bridge
    $trg = New-ScheduledTaskTrigger -AtLogOn
    $prn = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
    OK "Autostart task '$TaskName' registered."
  } catch {
    Warn "Scheduled task failed ($($_.Exception.Message)); falling back to a Startup shortcut."
    $lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Lyric Music Relay.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $s = $wsh.CreateShortcut($lnk)
    $s.TargetPath = "wscript.exe"; $s.Arguments = '"' + $vbs + '"'; $s.WorkingDirectory = $Bridge; $s.WindowStyle = 7
    $s.Save()
    OK "Startup shortcut created."
  }

  $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($busy) {
      OK "Relay already listening on port $Port."
  }
  else {
    Start-Process -FilePath "wscript.exe" -ArgumentList @($vbs) -WorkingDirectory $Bridge
    Start-Sleep 2
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { OK "Relay started on port $Port." }
    else { 
        Warn "Relay did not confirm start - it should come up on next login."
    }
  }
}

function Install-Wallpaper {
  Stage "Wallpaper Engine"
  if (-not (Test-Path -LiteralPath (Join-Path $Wallpaper "index.html"))) { throw "wallpaper folder not found next to the installer." }
  $projects = Get-WEProjects
  if (-not $projects) { 
      Warn "Wallpaper Engine not found. Import manually: WE -> Open wallpaper -> $Wallpaper\project.json"; Show-ManualWallpaper; return 
  }
  $dst = Join-Path $projects $ProjectId
  Note "Copying to $dst ..."
  robocopy $Wallpaper $dst /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XD cache | Out-Null
  if ($LASTEXITCODE -ge 8) { 
      Warn "robocopy: some files were locked (close/switch the wallpaper in WE and re-run)." 
  }
  if (Test-Path -LiteralPath (Join-Path $dst "project.json")) { 
      OK "Wallpaper installed to the WE library as '$ProjectId'."
  }
  else { 
      Warn "Copy not confirmed - check $dst." 
  }
}

function Show-ManualWallpaper {
  Stage "Wallpaper - manual import"
  Note "Auto-import was skipped. Add the wallpaper by hand:"
  Note "  1. Open Wallpaper Engine."
  Note "  2. Bottom-left: 'Open wallpaper' -> 'Open from file'."
  Note "  3. Choose:  $Wallpaper\project.json    (or index.html in the same folder)."
  Note "  Alternative: copy the whole 'wallpaper' folder into your WE library, e.g."
  Note "     <Steam>\steamapps\common\wallpaper_engine\projects\myprojects\$ProjectId\"
  Note "  4. In WE, pick 'lyric music by am1dreaming' from your library."
}

$doSpotify = -not $SkipSpotify
$doNode = -not $SkipNode
$doFfmpeg = -not $SkipFfmpeg
$doSpicetify = -not $SkipSpicetify
$doBridge = -not $SkipBridge
$doAutostart = -not $SkipAutostart
$doUpdateBlock = -not $SkipUpdateBlock
$doWallpaper = -not $SkipWallpaper

function Apply-Preset([string]$p) {
  switch ($p) {
    'Full'          { }
    'NoWallpaper'   { 
        $script:doWallpaper = $false 
    }
    'WallpaperOnly' {
      $script:doSpotify = $false; $script:doNode = $false; $script:doFfmpeg = $false
      $script:doSpicetify = $false; $script:doBridge = $false
      $script:doAutostart = $false; $script:doUpdateBlock = $false
      $script:doWallpaper = $true
    }
    'Custom' {
      $script:doSpotify = Ask-YN "Install / fix Spotify (desktop build)?" $true
      $script:doNode = Ask-YN "Install Node.js (needed for the lyrics relay)?" $true
      $script:doFfmpeg = Ask-YN "Install ffmpeg (animated covers, optional)?" $true
      $script:doSpicetify = Ask-YN "Install Spicetify + lyrics extension?" $true
      $script:doUpdateBlock = Ask-YN "Block Spotify auto-update (keeps Spicetify alive)?" $true
      $script:doBridge = Ask-YN "Install relay dependencies (npm i ws)?" $true
      $script:doAutostart = Ask-YN "Start the relay now and at every login?" $true
      $script:doWallpaper = Ask-YN "Auto-import the wallpaper into Wallpaper Engine?" $true
    }
  }
}

function Show-Menu {
  Write-Host ""
  Write-Host "Choose an installation type:"
  Write-Host "  [1] Full install         - Spotify + Spicetify + relay + autostart + wallpaper   (default)"
  Write-Host "  [2] No wallpaper import  - everything except copying the wallpaper into WE"
  Write-Host "  [3] Wallpaper only       - just add the WE wallpaper (no Spotify/Spicetify/relay)"
  Write-Host "  [4] Custom               - decide each step yourself"
  Write-Host "  [5] Cancel"
  while ($true) {
    $c = (Read-Host "Enter 1-5").Trim()
    switch ($c) {
      '1' { 
          Apply-Preset 'Full';
          return $true 
      }
      ''  { 
          Apply-Preset 'Full';  
          return $true 
      }
      '2' { 
          Apply-Preset 'NoWallpaper'; 
          return $true
      }
      '3' {
          Apply-Preset 'WallpaperOnly';
          return $true 
      }
      '4' { 
          Apply-Preset 'Custom';   
          return $true }
      '5' { 
          return $false 
      }
    }
  }
}

Write-Host "`nlyric music by am1dreaming - installer"
Write-Host "create by MinenkoY`n"

if (-not (Test-Path -LiteralPath (Join-Path $Wallpaper "index.html")) -or -not (Test-Path -LiteralPath (Join-Path $Bridge $ExtName))) {
  Write-Host "[ERROR] Project files not found. Run Install.bat from the release folder"
  Write-Host "(there must be a 'wallpaper' and a 'bridge' folder next to install.ps1)."
  Read-Host "`nPress Enter to exit"
  return
}

if ($Preset -eq 'Ask') {
  if ($Yes) { Apply-Preset 'Full' }
  else { if (-not (Show-Menu)) { Write-Host "`nCancelled."; Read-Host "Press Enter to exit"; return } }
} else {
  Apply-Preset $Preset
}

Write-Host "`nPlan:"
Note ("Spotify ............ " + $(if ($doSpotify) { "yes" } else { "skip" }))
Note ("Node.js ............ " + $(if ($doNode) { "yes" } else { "skip" }))
Note ("ffmpeg ............. " + $(if ($doFfmpeg) { "yes" } else { "skip" }))
Note ("Spicetify + ext .... " + $(if ($doSpicetify) { "yes" } else { "skip" }))
Note ("Block auto-update .. " + $(if ($doUpdateBlock) { "yes" } else { "skip" }))
Note ("Relay deps ......... " + $(if ($doBridge) { "yes" } else { "skip" }))
Note ("Relay autostart .... " + $(if ($doAutostart) { "yes" } else { "skip" }))
Note ("Wallpaper import ... " + $(if ($doWallpaper) { "yes" } else { "manual" }))

try {
  if ($doSpotify) { 
      Ensure-Spotify 
  }
  if ($doNode) {
      Ensure-Node 
  }
  if ($doFfmpeg) { 
      Ensure-Ffmpeg 
  }
  if ($doSpicetify) {
    $sp = Ensure-Spicetify
    Ensure-Compatible $sp
    Install-Extension $sp
  }
  if ($doUpdateBlock) { 
      Block-SpotifyUpdate 
  }
  if ($doBridge) { 
      Install-BridgeDeps 
  }
  if ($doAutostart) {
      Setup-Autostart 
  }
  if ($doWallpaper) { 
      Install-Wallpaper 
  } else { 
      Show-ManualWallpaper
  }
}
catch {
  Write-Host "`n[ERROR] $($_.Exception.Message)"
  Write-Host "Install aborted. Fix the cause above and run Install.bat again (re-running is safe)."
  Read-Host "`nPress Enter to exit"
  return
}

Write-Host "`nDone."
if ($Warnings.Count) {
  Write-Host "`nWarnings ($($Warnings.Count)):"
  foreach ($w in $Warnings) { 
      Write-Host "  - $w" 
  }
}
Write-Host @"

Next:
  1. Open Wallpaper Engine and pick "lyric music by am1dreaming" from the library.
  2. Play any track in Spotify - lyrics appear automatically.
  3. The relay is registered to start at logon. Without Spotify you get a demo track.

Uninstall: double-click Uninstall.bat.
create by MinenkoY
"@

Read-Host "`nPress Enter to exit"
