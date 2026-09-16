# Live Lyrics by am1dreaming - health check.
# Read-only: this script never installs, patches, starts or stops anything.
param(
  [switch]$Json,           # dump the raw result objects as JSON after the report
  [switch]$SkipNetwork,    # skip the lyrics/artwork endpoint probes
  [int]$WaitSeconds = 6,   # how long to wait for the relay to push a track over WS
  [string]$SourceDir       # release folder to compare the installed copies against
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- constants --
$Port          = 8973
$PortSpan      = 4                      # relay and clients walk PORT..PORT+3
$ProjectId     = "lyric-music-by-am1dreaming"
$TaskName      = "LyricMusicRelay"
$ExtName       = "spicetify-lyrics-bridge.js"
$WorkshopId    = "3759157919"
$InstallDir    = Join-Path $env:LOCALAPPDATA "LyricMusic"
$BridgeInstall = Join-Path $InstallDir "bridge"
$SpicetifyDir  = Join-Path $env:APPDATA "spicetify"
$SpicetifyExts = Join-Path $SpicetifyDir "Extensions"
$SpicetifyConf = Join-Path $SpicetifyDir "config-xpui.ini"
$SpotifyExe    = Join-Path $env:APPDATA "Spotify\Spotify.exe"
$SpotifyUpdate = Join-Path $env:LOCALAPPDATA "Spotify\Update"

if (-not $SourceDir) {
  $SourceDir = $PSScriptRoot
  if (-not $SourceDir -and $MyInvocation.MyCommand.Path) {
    $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  }
}

# ------------------------------------------------------------------ plumbing --
$script:Rows   = New-Object System.Collections.ArrayList
$script:Counts = @{ "OK" = 0; "WARN" = 0; "FAIL" = 0; "INFO" = 0; "SKIP" = 0 }
$script:Facts  = @{}

function Section([string]$title) {
  Write-Host ""
  $pad = 62 - $title.Length
  if ($pad -lt 3) { $pad = 3 }
  Write-Host ("-- " + $title + " " + ("-" * $pad)) -ForegroundColor Cyan
}

function Row([string]$status, [string]$name, [string]$detail, [string]$fix) {
  $color = "Gray"
  if ($status -eq "OK")   { $color = "Green" }
  if ($status -eq "WARN") { $color = "Yellow" }
  if ($status -eq "FAIL") { $color = "Red" }
  if ($status -eq "SKIP") { $color = "DarkGray" }
  $line = "  [" + $status.PadRight(4) + "] " + $name
  if ($detail) { $line = $line + " - " + $detail }
  Write-Host $line -ForegroundColor $color
  $script:Counts[$status] = $script:Counts[$status] + 1
  [void]$script:Rows.Add([pscustomobject]@{
    status = $status; check = $name; detail = $detail; fix = $fix
  })
}

function Resolve-Exe([string]$name, [string[]]$fallbacks) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($f in $fallbacks) {
    if ($f -and (Test-Path -LiteralPath $f)) { return $f }
  }
  return $null
}

function File-Hash([string]$p) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
  try { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } catch { return $null }
}

# Compares an installed copy against the one in the release folder.
function Check-Drift([string]$name, [string]$installed, [string]$source, [string]$fix) {
  if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) { return }
  if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
    Row "SKIP" $name "no source copy to compare against"
    return
  }
  $a = File-Hash $installed
  $b = File-Hash $source
  if ($a -and $b -and $a -eq $b) {
    Row "OK" $name "matches the release folder"
  } else {
    $ta = (Get-Item -LiteralPath $installed).LastWriteTime
    $tb = (Get-Item -LiteralPath $source).LastWriteTime
    $which = "installed copy is older"
    if ($ta -gt $tb) { $which = "installed copy is newer" }
    Row "WARN" $name ("differs from the release folder (" + $which + ")") $fix
  }
}

function Http-Banner([int]$p, [int]$timeoutMs) {
  $res = [pscustomobject]@{ reached = $false; body = ""; error = "" }
  try {
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:" + $p + "/")
    $req.Timeout = $timeoutMs
    $req.ReadWriteTimeout = $timeoutMs
    $resp = $req.GetResponse()
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $res.body = $sr.ReadToEnd().Trim()
    $res.reached = $true
    $sr.Close()
    $resp.Close()
  } catch [System.Net.WebException] {
    $res.error = $_.Exception.Status.ToString()
    if ($_.Exception.Response) { $res.reached = $true; $res.error = "http error" }
  } catch {
    $res.error = $_.Exception.Message
  }
  return $res
}

# Real WebSocket handshake, plus the "last track" frame the relay replays to any
# fresh client. Getting that frame proves the Spicetify side actually fed it.
function Test-RelayWebSocket([int]$p, [int]$waitSeconds) {
  $out = [pscustomobject]@{
    connected = $false; gotMessage = $false; track = ""; lyrics = ""; error = ""
  }
  $cws = $null
  try {
    $cws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(5000)
    $uri = New-Object System.Uri("ws://127.0.0.1:" + $p)
    $cws.ConnectAsync($uri, $cts.Token).Wait()
    if ($cws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
      $out.error = "socket state " + $cws.State
      return $out
    }
    $out.connected = $true

    $deadline = (Get-Date).AddSeconds($waitSeconds)
    $buf = New-Object byte[] 262144
    while ((Get-Date) -lt $deadline) {
      $left = [int]((New-TimeSpan -Start (Get-Date) -End $deadline).TotalMilliseconds)
      if ($left -le 50) { break }
      $rcts = New-Object System.Threading.CancellationTokenSource
      $rcts.CancelAfter($left)
      $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
      try {
        $task = $cws.ReceiveAsync($seg, $rcts.Token)
        $task.Wait()
        $count = $task.Result.Count
        if ($count -le 0) { continue }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $count)
        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch { }
        if ($obj -and $obj.track) {
          $out.gotMessage = $true
          $out.track = ("" + $obj.track.artist + " - " + $obj.track.title).Trim()
          if ($obj.lyrics -and $obj.lyrics.type) {
            $out.lyrics = "" + $obj.lyrics.type + ", " + @($obj.lyrics.lines).Count + " lines"
          } else {
            $out.lyrics = "none"
          }
          break
        }
        if ($obj -and ($obj.PSObject.Properties.Name -contains "position")) {
          $out.gotMessage = $true
          if (-not $out.track) { $out.track = "(position updates only)" }
        }
      } catch { break }
    }
  } catch {
    if ($_.Exception.InnerException) { $out.error = $_.Exception.InnerException.Message }
    else { $out.error = $_.Exception.Message }
  } finally {
    if ($cws) { try { $cws.Dispose() } catch { } }
  }
  return $out
}

function Test-PortBindable([int]$p) {
  $l = $null
  try {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
    $l.Start()
    $l.Stop()
    return [pscustomobject]@{ bindable = $true; error = "" }
  } catch {
    if ($l) { try { $l.Stop() } catch { } }
    return [pscustomobject]@{ bindable = $false; error = $_.Exception.Message }
  }
}

function Get-SteamLibraries {
  $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
  if (-not $steam) { return @() }
  $steam = $steam -replace "/", "\"
  $libs = @($steam)
  $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
  if (Test-Path -LiteralPath $vdf) {
    Get-Content -LiteralPath $vdf | Select-String '"path"\s+"(.+?)"' | ForEach-Object {
      $libs += ($_.Matches.Groups[1].Value -replace "\\\\", "\")
    }
  }
  return ($libs | Select-Object -Unique)
}

function Get-WEProjects {
  foreach ($l in (Get-SteamLibraries)) {
    $p = Join-Path $l "steamapps\common\wallpaper_engine\projects\myprojects"
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Read-IniValue([string]$path, [string]$key) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $pattern = "^\s*" + [regex]::Escape($key) + "\s*=\s*(.*)$"
  foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
    if ($line -match $pattern) { return $Matches[1].Trim() }
  }
  return $null
}

# config-xpui.ini reuses key names across sections (Backup/version is the one
# that records which Spotify build Spicetify last patched).
function Read-IniSectionValue([string]$path, [string]$section, [string]$key) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $want = "[" + $section + "]"
  $pattern = "^\s*" + [regex]::Escape($key) + "\s*=\s*(.*)$"
  $inside = $false
  foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
    $t = $line.Trim()
    if ($t.StartsWith("[")) { $inside = ($t -eq $want); continue }
    if ($inside -and ($line -match $pattern)) { return $Matches[1].Trim() }
  }
  return $null
}

# The decisive test: is our extension actually inside the running Spotify UI?
# Spicetify ships two layouts - it either extracts xpui.spa into an Apps\xpui
# folder (current CLI) or leaves a patched .spa zip behind (older CLI). Both
# carry a spicetifyWrapper marker; a Spotify update throws either one away.
function Test-SpotifyPatched([string]$appsDir, [string]$extName) {
  $out = [pscustomobject]@{
    readable = $false; layout = ""; hasWrapper = $false; hasExtension = $false; error = ""
  }

  $folder = Join-Path $appsDir "xpui"
  $index = Join-Path $folder "index.html"
  if (Test-Path -LiteralPath $index -PathType Leaf) {
    $out.readable = $true
    $out.layout = "extracted folder"
    try {
      $html = Get-Content -LiteralPath $index -Raw -ErrorAction Stop
      $out.hasWrapper = [bool]($html -match "spicetifyWrapper")
      if ($html -match [regex]::Escape($extName)) { $out.hasExtension = $true }
    } catch { $out.error = $_.Exception.Message }
    # spicetify copies every configured extension next to the app
    $extFile = Join-Path (Join-Path $folder "extensions") $extName
    if (Test-Path -LiteralPath $extFile -PathType Leaf) { $out.hasExtension = $true }
    return $out
  }

  $spa = Join-Path $appsDir "xpui.spa"
  if (-not (Test-Path -LiteralPath $spa -PathType Leaf)) {
    $out.error = "neither an Apps\xpui folder nor xpui.spa was found"
    return $out
  }
  $zip = $null
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($spa)
    $names = @($zip.Entries | Select-Object -ExpandProperty FullName)
    $out.readable = $true
    $out.layout = "xpui.spa archive"
    $out.hasWrapper = [bool]($names -match "spicetifyWrapper")
    $out.hasExtension = [bool]($names -match [regex]::Escape($extName))
  } catch {
    $out.error = $_.Exception.Message
  } finally {
    if ($zip) { try { $zip.Dispose() } catch { } }
  }
  return $out
}

# =================================================================== report ===
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host "  Live Lyrics by am1dreaming - health check" -ForegroundColor White
Write-Host ("  " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "    user: " + $env:USERNAME) -ForegroundColor DarkGray
Write-Host "==============================================================" -ForegroundColor White

# ---------------------------------------------------------------------------
Section "Environment"

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
Row "INFO" "Windows" ("" + $os.Caption + " build " + [Environment]::OSVersion.Version.Build)
Row "INFO" "PowerShell" $PSVersionTable.PSVersion.ToString()

$node = Resolve-Exe "node" @(
  (Join-Path $env:ProgramFiles "nodejs\node.exe"),
  (Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe")
)
if ($node) {
  $nv = ""
  try { $nv = (& $node --version) 2>$null } catch { }
  Row "OK" "Node.js" (("" + $nv).Trim() + "   " + $node)
} else {
  Row "FAIL" "Node.js" "not found" "The relay cannot run without it - install Node.js LTS from https://nodejs.org"
}

$npm = Resolve-Exe "npm" @((Join-Path $env:ProgramFiles "nodejs\npm.cmd"))
if ($npm) { Row "OK" "npm" $npm }
else { Row "WARN" "npm" "not found" "Only needed to reinstall the relay's 'ws' dependency." }

$ffmpeg = Resolve-Exe "ffmpeg" @((Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\ffmpeg.exe"))
if (-not $ffmpeg) {
  $pkgs = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
  if (Test-Path -LiteralPath $pkgs) {
    $hit = Get-ChildItem -LiteralPath $pkgs -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "*ffmpeg*" } |
      ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue } |
      ForEach-Object { Join-Path $_.FullName "bin\ffmpeg.exe" } |
      Where-Object { Test-Path -LiteralPath $_ } |
      Select-Object -First 1
    if ($hit) { $ffmpeg = $hit }
  }
}
if ($ffmpeg) {
  Row "OK" "ffmpeg" ("animated covers enabled   " + $ffmpeg)
} else {
  Row "WARN" "ffmpeg" "not found - animated covers and Spotify Canvas stay off" "Optional: winget install Gyan.FFmpeg"
}

# ---------------------------------------------------------------------------
Section "Relay installation"

$srcBridge = ""
if ($SourceDir) {
  $cand = Join-Path $SourceDir "bridge"
  if (Test-Path -LiteralPath $cand) { $srcBridge = $cand }
}
if ($srcBridge) { Row "INFO" "Release folder" $SourceDir }
else { Row "INFO" "Release folder" "not detected - version drift checks will be skipped" }

if (Test-Path -LiteralPath $BridgeInstall) {
  Row "OK" "Install folder" $BridgeInstall

  foreach ($f in @("bridge-server.js", "package.json", "start-bridge.vbs")) {
    $p = Join-Path $BridgeInstall $f
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      $it = Get-Item -LiteralPath $p
      Row "OK" ("  " + $f) ("" + [math]::Round($it.Length / 1KB, 1) + " KB, " + $it.LastWriteTime.ToString("yyyy-MM-dd HH:mm"))
    } else {
      Row "FAIL" ("  " + $f) "missing" "Re-run install.ps1 to restore the relay files."
    }
  }

  $wsmod = Join-Path $BridgeInstall "node_modules\ws"
  if (Test-Path -LiteralPath $wsmod) {
    $wsver = ""
    $wspkg = Join-Path $wsmod "package.json"
    if (Test-Path -LiteralPath $wspkg) {
      try { $wsver = "v" + ((Get-Content -LiteralPath $wspkg -Raw | ConvertFrom-Json).version) } catch { }
    }
    Row "OK" "  dependency: ws" $wsver
  } else {
    Row "FAIL" "  dependency: ws" "node_modules/ws is missing - the relay crashes on startup" ("Run: cd '" + $BridgeInstall + "' ; npm install ws")
  }

  if ($srcBridge) {
    Check-Drift "  bridge-server.js version" (Join-Path $BridgeInstall "bridge-server.js") (Join-Path $srcBridge "bridge-server.js") "Re-run install.ps1 so the installed relay matches this release."
  }
} else {
  Row "FAIL" "Install folder" ($BridgeInstall + " does not exist") "The relay was never installed - run install.ps1."
}

# ---------------------------------------------------------------------------
Section "Autostart"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$startupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Lyric Music Relay.lnk"
$haveAutostart = $false

if ($task) {
  $haveAutostart = $true
  $state = "" + $task.State
  if ($state -eq "Disabled") {
    Row "FAIL" "Scheduled task" ($TaskName + " exists but is DISABLED") ("Enable it: Enable-ScheduledTask -TaskName " + $TaskName)
  } else {
    Row "OK" "Scheduled task" ($TaskName + " - " + $state)
  }
  $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($info) {
    $last = "never"
    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) {
      $last = $info.LastRunTime.ToString("yyyy-MM-dd HH:mm")
    }
    $code = $info.LastTaskResult
    if ($code -eq 0) {
      Row "OK" "  last run" ($last + ", result 0")
    } elseif ($code -eq 267011) {
      Row "INFO" "  last run" ($last + ", has not run yet")
    } else {
      Row "WARN" "  last run" ($last + ", result " + $code) "Non-zero result means the relay failed to start at logon - see the relay section below."
    }
  }
  $logonTrig = @($task.Triggers) | Where-Object { $_.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" }
  if ($logonTrig) { Row "OK" "  trigger" "at logon" }
  else { Row "WARN" "  trigger" "no logon trigger" "The relay will not start automatically - re-run install.ps1." }
} else {
  Row "INFO" "Scheduled task" ($TaskName + " not registered")
}

if (Test-Path -LiteralPath $startupLnk) {
  $haveAutostart = $true
  Row "OK" "Startup shortcut" $startupLnk
} else {
  Row "INFO" "Startup shortcut" "not present"
}

if (-not $haveAutostart) {
  Row "FAIL" "Autostart" "no scheduled task and no Startup shortcut" "The relay will not come back after a reboot - re-run install.ps1."
}

# ---------------------------------------------------------------------------
Section "Relay process and port"

$portFile = Join-Path $BridgeInstall "bridge-port.json"
$reportedPort = 0
if (Test-Path -LiteralPath $portFile -PathType Leaf) {
  try {
    $pf = Get-Content -LiteralPath $portFile -Raw | ConvertFrom-Json
    $reportedPort = [int]$pf.port
    $extra = ""
    if ($pf.preferredPort -and ([int]$pf.preferredPort) -ne $reportedPort) {
      $extra = "  (fell back from preferred " + $pf.preferredPort + ")"
    }
    Row "INFO" "Port file" ("last bound port " + $reportedPort + $extra + ", pid " + $pf.pid)
  } catch {
    Row "WARN" "Port file" "bridge-port.json is unreadable" "Harmless - it is rewritten on the next relay start."
  }
} else {
  Row "INFO" "Port file" "not written yet (older relay build, or it never started)"
}

$listenPort = 0
$listenPid = 0
for ($i = 0; $i -lt $PortSpan; $i++) {
  $cand = $Port + $i
  $conn = Get-NetTCPConnection -LocalPort $cand -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $conn) {
    Row "INFO" ("Port " + $cand) "nothing listening"
    continue
  }
  $banner = Http-Banner $cand 2500
  if ($banner.reached -and $banner.body -like "lyrics-bridge relay*") {
    $listenPort = $cand
    $listenPid = [int]$conn.OwningProcess
    $note = ""
    if ($cand -ne $Port) { $note = "   (fallback port - preferred " + $Port + " was not usable)" }
    Row "OK" ("Port " + $cand) ("our relay is listening, PID " + $conn.OwningProcess + $note)
    Row "INFO" "  banner" $banner.body
    break
  }
  $who = ""
  $op = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
  if ($op) { $who = $op.ProcessName + " (PID " + $op.Id + ")" } else { $who = "PID " + $conn.OwningProcess }
  Row "WARN" ("Port " + $cand) ("held by another program: " + $who) "Not our relay - the relay will move to the next port in the ladder."
}

# Identify the process behind the socket. A relay started by the elevated
# installer hides its Path and CommandLine from an ordinary user session, so the
# socket owner - not the WMI command line - is the authoritative answer here.
$relayProcs = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*bridge-server.js*" })

if ($listenPid -gt 0) {
  $owner = Get-Process -Id $listenPid -ErrorAction SilentlyContinue
  $ownerName = "unknown"
  if ($owner) { $ownerName = $owner.ProcessName }
  $known = @($relayProcs | Where-Object { $_.ProcessId -eq $listenPid })
  if ($known.Count -gt 0) {
    $since = ""
    try { $since = " since " + $known[0].CreationDate.ToString("yyyy-MM-dd HH:mm") } catch { }
    Row "OK" "Relay process" ("PID " + $listenPid + $since)
    if (-not ($known[0].CommandLine -like ("*" + $BridgeInstall + "*"))) {
      Row "WARN" "  running copy" $known[0].CommandLine "Started from outside the install folder, so it may be a different version."
    }
  } else {
    Row "OK" "Relay process" ("PID " + $listenPid + " (" + $ownerName + ".exe), command line not readable")
    Row "INFO" "  elevated" "the relay runs as administrator - install.ps1 elevates itself and starts it from there; the logon task will start it unelevated next time"
  }
} elseif ($relayProcs.Count -gt 0) {
  Row "WARN" "Relay process" ("" + $relayProcs.Count + " relay process(es) running but none is serving a port") "A relay that failed to bind is useless - check the port rows above."
  foreach ($rp in $relayProcs) { Row "INFO" ("  PID " + $rp.ProcessId) $rp.CommandLine }
} else {
  Row "FAIL" "Relay process" "no relay process found" ("Start it: wscript '" + (Join-Path $BridgeInstall "start-bridge.vbs") + "'  - or just log out and back in.")
}

$extraRelays = @($relayProcs | Where-Object { $_.ProcessId -ne $listenPid })
if ($extraRelays.Count -gt 0) {
  Row "WARN" "Extra relays" ("" + $extraRelays.Count + " more relay process(es) are running") "Only one is needed - the others are leftovers."
  foreach ($rp in $extraRelays) { Row "INFO" ("  PID " + $rp.ProcessId) $rp.CommandLine }
}

if ($listenPort -eq 0) {
  $bind = Test-PortBindable $Port
  if ($bind.bindable) {
    Row "FAIL" "Relay socket" ("nothing serving ports " + $Port + "-" + ($Port + $PortSpan - 1) + "; port " + $Port + " is free") "The relay is simply not running - start it and re-run this check."
  } else {
    Row "FAIL" "Relay socket" ("port " + $Port + " will not open even for this script: " + $bind.error) "Nothing is listening, yet the port refuses to bind. That is the fingerprint of a firewall or antivirus blocking local sockets - allow node.exe or exclude the install folder."
  }
  $script:Facts["relay"] = $false
} else {
  $script:Facts["relay"] = $true
  if ($reportedPort -and $reportedPort -ne $listenPort) {
    Row "WARN" "  port file mismatch" ("file says " + $reportedPort + ", actually on " + $listenPort) "Stale file from an earlier run - harmless."
  }

  $wsr = Test-RelayWebSocket $listenPort $WaitSeconds
  if ($wsr.connected) {
    Row "OK" "WebSocket handshake" ("ws://127.0.0.1:" + $listenPort + " accepted the connection")
    if ($wsr.gotMessage) {
      $script:Facts["data"] = $true
      $script:Facts["lyrics"] = ($wsr.lyrics -and $wsr.lyrics -ne "none")
      if ($script:Facts["lyrics"]) {
        Row "OK" "  live data" ("now playing: " + $wsr.track + "   lyrics: " + $wsr.lyrics)
      } else {
        Row "WARN" "  live data" ("now playing: " + $wsr.track + "   lyrics: none") "Track data flows but the message carries no lyrics. Spotify has none for this track and the relay did not fill them in from LRCLIB - check that the installed relay is current."
      }
    } else {
      Row "WARN" "  live data" ("no track pushed within " + $WaitSeconds + "s") "The relay is up but nothing feeds it - see the Spicetify section."
      $script:Facts["data"] = $false
    }
  } else {
    Row "FAIL" "WebSocket handshake" ("failed: " + $wsr.error) "The port speaks HTTP but not WebSocket - the relay may be mid-restart."
    $script:Facts["data"] = $false
  }
}

$locks = @(Get-ChildItem -LiteralPath $BridgeInstall -Filter "bridge-*.lock" -ErrorAction SilentlyContinue)
foreach ($lk in $locks) {
  $alive = $false
  $lockPid = 0
  try {
    $lj = Get-Content -LiteralPath $lk.FullName -Raw | ConvertFrom-Json
    $lockPid = [int]$lj.pid
    $alive = [bool](Get-Process -Id $lockPid -ErrorAction SilentlyContinue)
  } catch { }
  if ($alive) { Row "OK" ("Lock " + $lk.Name) ("held by live PID " + $lockPid) }
  else { Row "INFO" ("Lock " + $lk.Name) ("stale, PID " + $lockPid + " is gone - the next start clears it") }
}

# ---------------------------------------------------------------------------
Section "Spotify and Spicetify"

$store = Get-AppxPackage -Name "SpotifyAB.SpotifyMusic" -ErrorAction SilentlyContinue
if ($store) {
  Row "FAIL" "Spotify build" "Microsoft Store version installed - Spicetify cannot patch it" "Uninstall the Store version, then install the desktop build from https://www.spotify.com/download/windows"
}

$spotifyVersion = ""
if (Test-Path -LiteralPath $SpotifyExe -PathType Leaf) {
  try { $spotifyVersion = (Get-Item -LiteralPath $SpotifyExe).VersionInfo.FileVersion } catch { }
  Row "OK" "Spotify (desktop)" ("v" + $spotifyVersion)
} elseif (-not $store) {
  Row "WARN" "Spotify (desktop)" "not found" "Without Spotify the relay has no source and the wallpaper uses the slower Windows media path."
}

$spotifyProc = @(Get-Process -Name "Spotify" -ErrorAction SilentlyContinue)
if ($spotifyProc.Count -gt 0) {
  Row "INFO" "Spotify running" ("yes - " + $spotifyProc.Count + " process(es)")
  $script:Facts["spotifyRunning"] = $true
} else {
  Row "INFO" "Spotify running" "no"
  $script:Facts["spotifyRunning"] = $false
}

$spicetify = Resolve-Exe "spicetify" @((Join-Path $env:LOCALAPPDATA "spicetify\spicetify.exe"))
if ($spicetify) {
  $sv = ""
  try { $sv = (& $spicetify -v) 2>$null } catch { }
  Row "OK" "Spicetify CLI" ((("" + $sv).Trim()) + "   " + $spicetify)
} else {
  Row "FAIL" "Spicetify CLI" "not found" "Install it in a NON-admin PowerShell: iwr -useb https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | iex"
}

$extInstalled = Join-Path $SpicetifyExts $ExtName
if (Test-Path -LiteralPath $extInstalled -PathType Leaf) {
  Row "OK" "Extension file" $extInstalled
  if ($srcBridge) {
    Check-Drift "  extension version" $extInstalled (Join-Path $srcBridge $ExtName) ("Copy the new file to " + $SpicetifyExts + " and run: spicetify apply")
  }
} else {
  Row "FAIL" "Extension file" ($ExtName + " is not in " + $SpicetifyExts) ("Copy it from the release bridge folder, then run: spicetify config extensions " + $ExtName + " ; spicetify apply")
}

if (Test-Path -LiteralPath $SpicetifyConf -PathType Leaf) {
  $extList = Read-IniValue $SpicetifyConf "extensions"
  if ($extList -and ($extList -like ("*" + $ExtName + "*"))) {
    Row "OK" "Spicetify config" ("extension registered: " + $extList)
  } else {
    $shown = $extList
    if (-not $shown) { $shown = "(empty)" }
    Row "FAIL" "Spicetify config" ("extension NOT registered; extensions = " + $shown) ("Run: spicetify config extensions " + $ExtName + " ; spicetify apply")
  }

  $backupVersion = Read-IniSectionValue $SpicetifyConf "Backup" "version"
  if (-not $backupVersion) {
    Row "WARN" "Spicetify backup" "no [Backup] version recorded - Spicetify has never applied a patch" "Run in a NON-admin terminal: spicetify backup apply"
  } elseif ($spotifyVersion) {
    $a = (($spotifyVersion -split "\.") | Select-Object -First 3) -join "."
    $b = (($backupVersion -split "\.") | Select-Object -First 3) -join "."
    if ($a -eq $b) {
      Row "OK" "Patch vs Spotify version" ("both " + $b)
    } else {
      Row "FAIL" "Patch vs Spotify version" ("Spicetify patched v" + $backupVersion + ", Spotify is now v" + $spotifyVersion) "Spotify updated and dropped the patch. In a NON-admin terminal: spicetify upgrade ; spicetify backup apply"
    }
  }
} else {
  Row "WARN" "Spicetify config" "config-xpui.ini not found" "Spicetify has never been configured for this account."
}

$appsDir = Join-Path $env:APPDATA "Spotify\Apps"
$patch = Test-SpotifyPatched $appsDir $ExtName
if (-not $patch.readable) {
  Row "WARN" "Spotify patch state" ("could not be inspected: " + $patch.error)
} elseif ($patch.hasExtension) {
  Row "OK" "Spotify patch state" ("patched (" + $patch.layout + ") and our extension is inside it")
  $script:Facts["patched"] = $true
} elseif ($patch.hasWrapper) {
  Row "FAIL" "Spotify patch state" ("Spicetify patched Spotify (" + $patch.layout + "), but our extension is NOT in it") ("The extension is installed yet not part of the patch. In a NON-admin terminal: spicetify config extensions " + $ExtName + " ; spicetify apply")
  $script:Facts["patched"] = $false
  $script:Facts["patchedWithoutExt"] = $true
} else {
  Row "FAIL" "Spotify patch state" ("no Spicetify patch at all (" + $patch.layout + ") - the bridge cannot load") "Spotify overwrote its own files, usually an auto-update. In a NON-admin terminal: spicetify upgrade ; spicetify backup apply"
  $script:Facts["patched"] = $false
}

if (Test-Path -LiteralPath $SpotifyUpdate) {
  $upd = Get-Item -LiteralPath $SpotifyUpdate -Force
  if ($upd.PSIsContainer) {
    Row "WARN" "Spotify auto-update" "Update folder exists - Spotify can update and wipe the patch" "Re-run install.ps1, or block it by hand as described in the README."
  } elseif ($upd.IsReadOnly) {
    Row "OK" "Spotify auto-update" "blocked (read-only placeholder file)"
  } else {
    Row "WARN" "Spotify auto-update" "placeholder exists but is writable" "Set it read-only so Spotify cannot recreate the folder."
  }
} else {
  Row "WARN" "Spotify auto-update" "not blocked" "A Spotify update will silently remove the Spicetify patch."
}

# ---------------------------------------------------------------------------
Section "Wallpaper (Wallpaper Engine)"

$weProc = @(Get-Process -Name "wallpaper32", "wallpaper64" -ErrorAction SilentlyContinue)
if ($weProc.Count -gt 0) { Row "OK" "Wallpaper Engine" "running" }
else { Row "INFO" "Wallpaper Engine" "not running" }

$found = $false
$projects = Get-WEProjects
if ($projects) {
  Row "INFO" "myprojects folder" $projects
  $dst = Join-Path $projects $ProjectId
  if (Test-Path -LiteralPath $dst) {
    $found = $true
    Row "OK" "Local wallpaper copy" $dst
    foreach ($f in @("index.html", "app.js", "project.json")) {
      $p = Join-Path $dst $f
      if (Test-Path -LiteralPath $p -PathType Leaf) { Row "OK" ("  " + $f) "present" }
      else { Row "FAIL" ("  " + $f) "missing" "Re-copy the wallpaper folder from the release." }
    }
    if ($SourceDir) {
      Check-Drift "  app.js version" (Join-Path $dst "app.js") (Join-Path $SourceDir "wallpaper\app.js") "Re-run install.ps1 so the wallpaper inside WE matches this release."
    }
  } else {
    Row "INFO" "Local wallpaper copy" "not installed under myprojects"
  }
} else {
  Row "WARN" "Wallpaper Engine" "Steam or the WE library was not found" "If WE lives elsewhere, import the wallpaper by hand."
}

foreach ($lib in (Get-SteamLibraries)) {
  $wsDir = Join-Path $lib ("steamapps\workshop\content\431960\" + $WorkshopId)
  if (Test-Path -LiteralPath $wsDir) {
    $found = $true
    Row "OK" "Workshop subscription" $wsDir
    if ($SourceDir) {
      Check-Drift "  workshop app.js" (Join-Path $wsDir "app.js") (Join-Path $SourceDir "wallpaper\app.js") "Steam updates Workshop items on its own - a mismatch usually just means this release is not published yet."
    }
    break
  }
}
if (-not $found) {
  Row "WARN" "Wallpaper" "no local copy and no Workshop subscription found" ("Subscribe: https://steamcommunity.com/sharedfiles/filedetails/?id=" + $WorkshopId)
}

# ---------------------------------------------------------------------------
Section "Network endpoints"

if ($SkipNetwork) {
  Row "SKIP" "Endpoint probes" "-SkipNetwork was given"
} else {
  $endpoints = @(
    @{ name = "lrclib.net";       url = "https://lrclib.net/api/search?q=test";                 why = "lyrics for the Windows-media fallback path" },
    @{ name = "itunes.apple.com"; url = "https://itunes.apple.com/search?term=test&limit=1";    why = "album art lookup" },
    @{ name = "music.apple.com";  url = "https://music.apple.com/us/browse";                    why = "animated cover tokens" }
  )
  foreach ($e in $endpoints) {
    try {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $r = Invoke-WebRequest -Uri $e.url -UseBasicParsing -TimeoutSec 8 -Method Get
      $sw.Stop()
      Row "OK" $e.name ("HTTP " + [int]$r.StatusCode + ", " + $sw.ElapsedMilliseconds + " ms - " + $e.why)
    } catch {
      Row "WARN" $e.name ("unreachable: " + $_.Exception.Message) ("Affects " + $e.why + " - check connection, DNS, VPN or firewall.")
    }
  }
}

# ---------------------------------------------------------------------------
Section "Firewall"

try {
  $rules = @(Get-NetFirewallApplicationFilter -ErrorAction Stop |
    Where-Object { $_.Program -and ($_.Program -like "*node.exe*") } |
    ForEach-Object { $_ | Get-NetFirewallRule -ErrorAction SilentlyContinue })
  $blocks = @($rules | Where-Object { $_.Action -eq "Block" -and $_.Enabled -eq "True" })
  if ($blocks.Count -gt 0) {
    Row "WARN" "node.exe rules" ("" + $blocks.Count + " enabled BLOCK rule(s)") "A blocking rule can stop the relay from serving localhost - review them in wf.msc."
    foreach ($b in $blocks) { Row "INFO" "  rule" ($b.DisplayName + " [" + $b.Direction + "]") }
  } elseif ($rules.Count -gt 0) {
    Row "OK" "node.exe rules" ("" + $rules.Count + " rule(s), none blocking")
  } else {
    Row "INFO" "node.exe rules" "none (fine - loopback traffic needs no rule)"
  }
} catch {
  Row "SKIP" "Firewall rules" "could not be queried (usually needs an elevated shell)"
}

# =================================================================== verdict ==
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host "  Verdict" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White

$relayUp = [bool]$script:Facts["relay"]
$dataUp = [bool]$script:Facts["data"]
$spotOn = [bool]$script:Facts["spotifyRunning"]

if ($relayUp -and $dataUp -and $script:Facts["lyrics"]) {
  Write-Host "  Spicetify path is LIVE and carrying lyrics. Everything works." -ForegroundColor Green
} elseif ($relayUp -and $dataUp) {
  Write-Host "  Spicetify path is LIVE - the track reaches the wallpaper, but the" -ForegroundColor Yellow
  Write-Host "  message carries no lyrics. Spotify has none for this track; a current" -ForegroundColor Yellow
  Write-Host "  relay fills that gap from LRCLIB, so an installed copy that is behind" -ForegroundColor Yellow
  Write-Host "  the release folder is the first thing to check." -ForegroundColor Yellow
} elseif ($relayUp -and -not $spotOn) {
  Write-Host "  Relay is up, Spotify is closed. Start Spotify, play a track and" -ForegroundColor Yellow
  Write-Host "  run this check again to confirm the bridge actually feeds data." -ForegroundColor Yellow
} elseif ($relayUp -and $script:Facts["patchedWithoutExt"]) {
  Write-Host "  Relay is up and Spotify is patched, but OUR EXTENSION is not part" -ForegroundColor Yellow
  Write-Host "  of that patch, so nothing ever reaches the relay. Register it and" -ForegroundColor Yellow
  Write-Host "  re-apply in a non-admin terminal, then restart Spotify:" -ForegroundColor Yellow
  Write-Host ("      spicetify config extensions " + $ExtName) -ForegroundColor White
  Write-Host "      spicetify apply" -ForegroundColor White
  Write-Host "  Lyrics keep working through the Windows media path meanwhile," -ForegroundColor Yellow
  Write-Host "  but animated covers and Canvas need this bridge and stay off." -ForegroundColor Yellow
} elseif ($relayUp -and ($script:Facts.ContainsKey("patched")) -and (-not $script:Facts["patched"])) {
  Write-Host "  Relay is up, Spotify is playing, but the Spicetify patch is GONE," -ForegroundColor Yellow
  Write-Host "  so the extension never loads and never reaches the relay." -ForegroundColor Yellow
  Write-Host "  Re-apply it (non-admin terminal), then re-run this check:" -ForegroundColor Yellow
  Write-Host "      spicetify upgrade" -ForegroundColor White
  Write-Host "      spicetify backup apply" -ForegroundColor White
  Write-Host "  Until then the wallpaper uses the slower Windows media path." -ForegroundColor Yellow
} elseif ($relayUp) {
  Write-Host "  Relay is up but Spotify is NOT feeding it." -ForegroundColor Yellow
  Write-Host "  The Spicetify patch is the usual culprit - see the failures above." -ForegroundColor Yellow
  Write-Host "  The wallpaper still works through the slower Windows media path." -ForegroundColor Yellow
} else {
  Write-Host "  Relay is DOWN. The wallpaper falls back to the Windows media path:" -ForegroundColor Red
  Write-Host "  line-synced lyrics only - no word-by-word, no Canvas." -ForegroundColor Red
}

Write-Host ""
Write-Host ("  checks: " + $script:Counts["OK"] + " ok, " + $script:Counts["WARN"] + " warning(s), " + $script:Counts["FAIL"] + " failure(s)")

$actionable = @($script:Rows | Where-Object { $_.fix -and ($_.status -eq "FAIL" -or $_.status -eq "WARN") })
if ($actionable.Count -gt 0) {
  Write-Host ""
  Write-Host "  What to do, most important first:" -ForegroundColor White
  $n = 0
  $ordered = $actionable | Sort-Object -Property @{ Expression = { if ($_.status -eq "FAIL") { 0 } else { 1 } } }
  foreach ($r in $ordered) {
    $n++
    $c = "Yellow"
    if ($r.status -eq "FAIL") { $c = "Red" }
    Write-Host ("   " + $n + ". " + $r.check.Trim() + ": " + $r.detail) -ForegroundColor $c
    Write-Host ("      -> " + $r.fix) -ForegroundColor Gray
  }
} else {
  Write-Host ""
  Write-Host "  Nothing to fix." -ForegroundColor Green
}
Write-Host ""

if ($Json) {
  Write-Host "----- JSON -----"
  $script:Rows | ConvertTo-Json -Depth 4
}

if ($script:Counts["FAIL"] -gt 0) { exit 1 }
exit 0
