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
# Steam Workshop page for the wallpaper - subscribing there is the recommended
# install (one click, auto-updates). Put the published Workshop item id here.
$WorkshopUrl = "https://steamcommunity.com/sharedfiles/filedetails/?id=3759157919"
$TaskName = "LyricMusicRelay"
$Warnings = New-Object System.Collections.ArrayList

# The relay must run from a PERMANENT location - never from the folder the
# installer was launched from. The web installer extracts to %TEMP%\lmb-<guid>,
# which Windows later purges; the relay was left pointing at deleted files, so
# lyrics kept working (in memory) while live covers died (cache/ was gone).
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


function Setup-Spicetify {
  Stage "Spicetify + lyrics extension"
  # IMPORTANT: Spicetify must NOT run with administrator rights - doing so breaks
  # Spotify's file permissions and 'spicetify apply' fails. This installer runs
  # elevated (needed for Node/winget), so we do NOT drive Spicetify here. We drop
  # the extension file in place and print the exact commands to finish in a
  # normal, non-admin terminal.
  $extSrc = Join-Path $Bridge $ExtName
  if (-not (Test-Path -LiteralPath $extSrc)) { Warn "Missing $extSrc - run the installer from inside the release folder."; return }

  $sp = Resolve-Exe "spicetify" @("$env:LOCALAPPDATA\spicetify\spicetify.exe")

  # Pre-place the extension into the user's Spicetify folder (best effort) so the
  # user only has to enable + apply it.
  $extDir = Join-Path $env:APPDATA "spicetify\Extensions"
  try {
    New-Item -ItemType Directory -Force -Path $extDir | Out-Null
    Copy-Item -LiteralPath $extSrc -Destination $extDir -Force
    OK "Extension file copied to $extDir."
  } catch { Warn "Could not copy the extension automatically: $($_.Exception.Message)" }

  Write-Host ""
  if ($sp) {
    Note "Spicetify is installed - but it must be applied WITHOUT admin rights."
  } else {
    Note "Spicetify is NOT installed. It refuses to run as admin, so this installer"
    Note "cannot set it up for you. Install page: https://spicetify.app/docs/getting-started"
  }
  Write-Host ""
  Note "Finish in a NORMAL (non-admin) PowerShell window - copy & paste:"
  if (-not $sp) {
    Note "  iwr -useb https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | iex"
  }
  Note "  spicetify config extensions $ExtName"
  Note "  spicetify apply"
  Write-Host ""
  Note "If 'apply' fails because Spotify is newer: run 'spicetify upgrade' then 'spicetify apply'."
  Note "Lyrics start working right after a successful 'spicetify apply'."
  [void]$Warnings.Add("Spicetify must be finished in a non-admin terminal (commands printed above).")
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

function Install-BridgeFiles {
  Stage "Relay files"
  $srcFull = [IO.Path]::GetFullPath($Bridge).TrimEnd('\')
  $dstFull = [IO.Path]::GetFullPath($BridgeInstall).TrimEnd('\')
  if ($srcFull -ieq $dstFull) { OK "Relay already at its install location."; return }
  New-Item -ItemType Directory -Force -Path $BridgeInstall | Out-Null
  # Copy the relay to the stable location. Keep already-installed deps and the
  # accumulated cover cache across re-installs (no /PURGE, skip those folders).
  robocopy $Bridge $BridgeInstall /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XD node_modules cache | Out-Null
  if ($LASTEXITCODE -ge 8) { Warn "robocopy hit locked files copying the relay - stop the relay / close the wallpaper and re-run." }
  if (Test-Path -LiteralPath (Join-Path $BridgeInstall "bridge-server.js")) { OK "Relay installed to $BridgeInstall." }
  else { throw "Failed to copy the relay to $BridgeInstall." }
}

function Install-BridgeDeps {
  Stage "Relay dependencies"
  $npm = Resolve-Exe "npm" @("$env:ProgramFiles\nodejs\npm.cmd")
  if (-not $npm) { throw "npm not found after Node.js install." }
  Push-Location -LiteralPath $BridgeInstall
  try {
    Note "npm install ws..."
    & $npm install ws --omit=dev --no-audit --no-fund --loglevel=error
    if ($LASTEXITCODE -eq 0) { OK "Dependencies installed." } else { Warn "npm install failed - check internet and re-run." }
  } finally { Pop-Location }
}

function Setup-Autostart {
  Stage "Relay autostart (port $Port)"
  $vbs = Join-Path $BridgeInstall "start-bridge.vbs"
  if (-not (Test-Path -LiteralPath $vbs)) { Warn "start-bridge.vbs missing - autostart skipped."; return }


  try {
    $act = New-ScheduledTaskAction -Execute "wscript.exe" -Argument ('"' + $vbs + '"') -WorkingDirectory $BridgeInstall
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
    $s.TargetPath = "wscript.exe"; $s.Arguments = '"' + $vbs + '"'; $s.WorkingDirectory = $BridgeInstall; $s.WindowStyle = 7
    $s.Save()
    OK "Startup shortcut created."
  }

  # Always (re)start from the freshly-installed permanent copy. Stop whatever is
  # already on the port first - it may be an old instance running from a temp
  # folder whose files Windows has since purged.
  $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($busy) {
    $busy | Select-Object -Expand OwningProcess -Unique | ForEach-Object {
      try { Stop-Process -Id $_ -Force -ErrorAction Stop; Note "Stopped a previous relay (PID $_)." } catch {}
    }
    Start-Sleep 1
  }
  Start-Process -FilePath "wscript.exe" -ArgumentList @($vbs) -WorkingDirectory $BridgeInstall
  Start-Sleep 2
  if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { OK "Relay started on port $Port." }
  else {
      Warn "Relay did not confirm start - it should come up on next login."
  }
}

function Install-Wallpaper {
  Stage "Wallpaper Engine"
  if (-not (Test-Path -LiteralPath (Join-Path $Wallpaper "index.html"))) { throw "wallpaper folder not found next to the installer." }

  Note "Recommended - subscribe on the Steam Workshop (one click, auto-updates):"
  Note "  $WorkshopUrl"
  Write-Host ""

  # Do NOT copy by default. Only import the local files if the user opts in.
  $copy = Ask-YN "Also copy the local wallpaper files into your Wallpaper Engine library?" $false
  if (-not $copy) {
    Note "Skipped local copy - use the Workshop link above (or import by hand)."
    Show-ManualWallpaper
    return
  }

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
      OK "Wallpaper copied to the WE library as '$ProjectId'."
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
      $script:doWallpaper = Ask-YN "Set up the wallpaper (show Workshop link + optional local copy)?" $true
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
Note ("Spicetify + ext .... " + $(if ($doSpicetify) { "file + manual steps" } else { "skip" }))
Note ("Block auto-update .. " + $(if ($doUpdateBlock) { "yes" } else { "skip" }))
Note ("Relay deps ......... " + $(if ($doBridge) { "yes" } else { "skip" }))
Note ("Relay autostart .... " + $(if ($doAutostart) { "yes" } else { "skip" }))
Note ("Wallpaper .......... " + $(if ($doWallpaper) { "Workshop link + optional copy" } else { "link only" }))

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
    Setup-Spicetify
  }
  if ($doUpdateBlock) { 
      Block-SpotifyUpdate 
  }
  if ($doBridge -or $doAutostart) {
      Install-BridgeFiles
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
      Stage "Wallpaper Engine"
      Note "Wallpaper step skipped. Subscribe on the Steam Workshop:"
      Note "  $WorkshopUrl"
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
  1. Finish Spicetify in a NON-admin PowerShell (commands are printed above) - lyrics need it.
  2. Add the wallpaper: subscribe on the Steam Workshop, or use the local copy if you chose it.
       $WorkshopUrl
  3. In Wallpaper Engine, pick "lyric music by am1dreaming" and play a track in Spotify.
     The relay auto-starts at logon; with no Spotify you get a demo track.

Uninstall: double-click Uninstall.bat.
create by MinenkoY
"@

Read-Host "`nPress Enter to exit"
