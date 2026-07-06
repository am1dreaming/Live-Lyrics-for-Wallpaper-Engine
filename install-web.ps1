# MinenkoY
# lyric music by am1dreaming - web bootstrap installer.
# One-liner (run in PowerShell):
#     iwr -useb https://raw.githubusercontent.com/am1dreaming/Live-Lyrics-for-Wallpaper-Engine/main/install-web.ps1 | iex
$Owner = 'am1dreaming'
$Repo = 'Live-Lyrics-for-Wallpaper-Engine'
$Branch = 'main'

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail($m) {
    Write-Host "[ERROR] $m" -ForegroundColor Red; throw $m
}

Write-Host ""
Write-Host "lyric music by am1dreaming - web installer"
Write-Host "create by MinenkoY"
Write-Host ""

$dest = Join-Path $env:TEMP ("lmb-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$zip = Join-Path $dest 'src.zip'

$urls = @(
  "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/$Branch",
  "https://github.com/$Owner/$Repo/archive/refs/heads/$Branch.zip"
)

$downloaded = $false
foreach ($u in $urls) {
  try {
    Write-Host "Downloading $Owner/$Repo ($Branch)..."
    Invoke-WebRequest -UseBasicParsing $u -OutFile $zip
    if ((Get-Item -LiteralPath $zip).Length -gt 0) { 
        $downloaded = $true; 
        break 
    }
  } catch { }
}
if (-not $downloaded) { Fail "Could not download the project archive. Check the repo name/branch and your internet." }

Write-Host "Extracting..."
try { 
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force 
}
catch { 
    Fail "Extract failed: $($_.Exception.Message)" 
}

$rootDir = Get-ChildItem -LiteralPath $dest -Directory |
  Where-Object { 
      Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') 
  } |
  Select-Object -First 1
if (-not $rootDir) { 
    Fail "install.ps1 not found inside the downloaded archive."
}

$installer = Join-Path $rootDir.FullName 'install.ps1'

$passArgs = @()
if ($env:LMB_PRESET) { 
    $passArgs += '-Preset'; $passArgs += $env:LMB_PRESET 
}
if ($env:LMB_ARGS)   { 
    $passArgs += ($env:LMB_ARGS -split '\s+' | Where-Object { $_ })
}

Write-Host "Starting installer..."
Write-Host ""
& $installer @passArgs
