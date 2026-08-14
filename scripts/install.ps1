<#
.SYNOPSIS
  End-to-end installer for a local image generation server:
  ComfyUI + API wrapper + Cloudflare Tunnel + autostart.

.DESCRIPTION
  Idempotent — safe to re-run. Each step checks whether it's already done
  and skips if so, so you can fix one thing (e.g. add a checkpoint URL) and
  re-run without repeating everything else.

  Reads config from config.json in the repo root (copy config.example.json
  to config.json and fill it in first, or pass -ConfigPath).

.NOTES
  Manual steps this script CANNOT fully automate, and why:
    - NVIDIA driver install/update: risky to blindly automate (can require a
      reboot mid-script, wrong driver branch can break things). This script
      only verifies a driver is present and working.
    - `cloudflared tunnel login`: Cloudflare requires an interactive browser
      OAuth confirmation for security. This script detects whether it's
      already done and tells you the exact one command to run if not.
    - Picking/acquiring a checkpoint model file: if you provide a direct
      download URL in config.json it will fetch it; otherwise it tells you
      where to place the file yourself (model files are large, multi-GB,
      and licensing differs by source, so this script won't guess for you).
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config.json")
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    WARN: $msg" -ForegroundColor Yellow }
function Write-Skip($msg) { Write-Host "    SKIP: $msg" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 0. Load config
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    $examplePath = Join-Path $PSScriptRoot "..\config.example.json"
    Write-Host "No config.json found. Creating one from config.example.json — edit it, then re-run this script." -ForegroundColor Yellow
    Copy-Item $examplePath $ConfigPath
    exit 1
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not $cfg.domain -or $cfg.domain -eq "image.yourdomain.com") {
    Write-Error "config.json: set 'domain' to a real hostname on a domain already added to your Cloudflare account."
}

$InstallDir = $cfg.installDir
$ComfyDir = Join-Path $InstallDir "ComfyUI"
$ApiDir = Join-Path $InstallDir "api-wrapper"
$CloudflaredDir = Join-Path $InstallDir "cloudflared"
$LogDir = Join-Path $InstallDir "logs"
New-Item -ItemType Directory -Force -Path $InstallDir, $LogDir | Out-Null

if (-not $cfg.apiKey) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $cfg.apiKey = [Convert]::ToHexString($bytes).ToLower()
    $cfg | ConvertTo-Json | Set-Content $ConfigPath
    Write-Ok "Generated a random API key and saved it to config.json"
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

function Test-Cmd($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

if (-not (Test-Cmd "winget")) {
    Write-Error "winget is required and not found. Install 'App Installer' from the Microsoft Store, then re-run."
}

$deps = @(
    @{ Cmd = "git"; Id = "Git.Git" },
    @{ Cmd = "node"; Id = "OpenJS.NodeJS.LTS" },
    @{ Cmd = "python"; Id = "Python.Python.3.11" }
)
foreach ($dep in $deps) {
    if (Test-Cmd $dep.Cmd) {
        Write-Ok "$($dep.Cmd) already installed"
    } else {
        Write-Host "    Installing $($dep.Id) via winget..."
        winget install --id $dep.Id -e --accept-source-agreements --accept-package-agreements | Out-Null
        Write-Ok "$($dep.Cmd) installed"
    }
}

$gpu = $null
try { $gpu = & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null } catch {}
if ($gpu) {
    Write-Ok "GPU detected: $gpu"
} else {
    Write-Warn "No NVIDIA GPU detected via nvidia-smi. Generation will be extremely slow or fail on CPU-only setups. Install/verify your NVIDIA driver manually, then re-run."
}

# ---------------------------------------------------------------------------
# 2. ComfyUI
# ---------------------------------------------------------------------------
Write-Step "Setting up ComfyUI"

if (Test-Path $ComfyDir) {
    Write-Skip "ComfyUI already cloned at $ComfyDir"
} else {
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git $ComfyDir
    Write-Ok "Cloned ComfyUI"
}

$Venv = Join-Path $ComfyDir "venv"
$VenvPython = Join-Path $Venv "Scripts\python.exe"
if (Test-Path $VenvPython) {
    Write-Skip "Virtual environment already exists"
} else {
    python -m venv $Venv
    Write-Ok "Created virtual environment"
}

$torchInstalled = & $VenvPython -c "import torch" 2>$null; $torchOk = ($LASTEXITCODE -eq 0)
if ($torchOk) {
    Write-Skip "PyTorch already installed"
} else {
    Write-Host "    Installing PyTorch (CUDA build)... this is a multi-GB download and will take a while."
    & $VenvPython -m pip install --upgrade pip | Out-Null
    & $VenvPython -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
    Write-Ok "PyTorch installed"
    Write-Warn "If your GPU is very new (e.g. released after this script was written), you may need a newer CUDA build than cu124 — check https://pytorch.org for the current recommended command and re-run: <venv>\Scripts\python.exe -m pip install torch torchvision --index-url <url>"
}

& $VenvPython -m pip install -r (Join-Path $ComfyDir "requirements.txt") | Out-Null
Write-Ok "ComfyUI Python dependencies installed"

$CheckpointDir = Join-Path $ComfyDir "models\checkpoints"
New-Item -ItemType Directory -Force -Path $CheckpointDir | Out-Null
$checkpointPath = Join-Path $CheckpointDir $cfg.checkpointFilename

if ($cfg.checkpointFilename -and (Test-Path $checkpointPath)) {
    Write-Skip "Checkpoint already present: $($cfg.checkpointFilename)"
} elseif ($cfg.checkpointUrl -and $cfg.checkpointFilename) {
    Write-Host "    Downloading checkpoint model (multi-GB, this will take a while)..."
    Invoke-WebRequest -Uri $cfg.checkpointUrl -OutFile $checkpointPath
    Write-Ok "Checkpoint downloaded: $($cfg.checkpointFilename)"
} else {
    Write-Warn "No checkpointUrl/checkpointFilename set in config.json. Manually download a .safetensors SD/SDXL checkpoint into: $CheckpointDir  — then set checkpointFilename in config.json to match and re-run."
}

# ---------------------------------------------------------------------------
# 3. API wrapper
# ---------------------------------------------------------------------------
Write-Step "Setting up the API wrapper"

$TemplateDir = Join-Path $PSScriptRoot "..\templates\api-wrapper"
if (-not (Test-Path $ApiDir)) {
    Copy-Item -Recurse $TemplateDir $ApiDir
    Write-Ok "Copied API wrapper template to $ApiDir"
} else {
    Write-Skip "API wrapper already present at $ApiDir"
}

$EnvFile = Join-Path $ApiDir ".env"
@"
PORT=$($cfg.apiPort)
COMFY_URL=http://127.0.0.1:$($cfg.comfyPort)
COMFY_CHECKPOINT=$($cfg.checkpointFilename)
API_KEY=$($cfg.apiKey)
GENERATION_TIMEOUT_MS=900000
POLL_INTERVAL_MS=2000
"@ | Set-Content $EnvFile
Write-Ok "Wrote .env (port $($cfg.apiPort))"

Push-Location $ApiDir
npm install --no-fund --no-audit | Out-Null
Pop-Location
Write-Ok "npm dependencies installed"

# ---------------------------------------------------------------------------
# 4. Cloudflare Tunnel
# ---------------------------------------------------------------------------
Write-Step "Setting up Cloudflare Tunnel"

if (Test-Cmd "cloudflared") {
    Write-Skip "cloudflared already installed"
} else {
    winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements | Out-Null
    Write-Ok "cloudflared installed"
}

$CertPath = Join-Path $env:USERPROFILE ".cloudflared\cert.pem"
if (-not (Test-Path $CertPath)) {
    Write-Warn "Cloudflare account not yet linked on this machine."
    Write-Host ""
    Write-Host "    ACTION NEEDED (one-time, interactive — this is a Cloudflare security requirement, cannot be scripted):" -ForegroundColor Yellow
    Write-Host "      cloudflared tunnel login" -ForegroundColor Yellow
    Write-Host "    Complete the browser login, then re-run this script." -ForegroundColor Yellow
    exit 1
}
Write-Ok "Cloudflare account already linked"

$existingTunnel = (cloudflared tunnel list 2>$null) | Select-String $cfg.cloudflareTunnelName
if ($existingTunnel) {
    Write-Skip "Tunnel '$($cfg.cloudflareTunnelName)' already exists"
} else {
    cloudflared tunnel create $cfg.cloudflareTunnelName
    Write-Ok "Created tunnel '$($cfg.cloudflareTunnelName)'"
}

$tunnelId = (cloudflared tunnel list 2>$null | Select-String $cfg.cloudflareTunnelName) -replace '\s+', ' ' -split ' ' | Select-Object -First 1
$CredFile = Join-Path $env:USERPROFILE ".cloudflared\$tunnelId.json"

New-Item -ItemType Directory -Force -Path $CloudflaredDir | Out-Null
$ConfigYml = Join-Path $CloudflaredDir "config.yml"
@"
tunnel: $($cfg.cloudflareTunnelName)
credentials-file: $CredFile

ingress:
  - hostname: $($cfg.domain)
    service: http://127.0.0.1:$($cfg.apiPort)
  - service: http_status:404
"@ | Set-Content $ConfigYml
Write-Ok "Wrote tunnel config: $ConfigYml"

cloudflared tunnel route dns $cfg.cloudflareTunnelName $cfg.domain 2>$null
Write-Ok "DNS routed: $($cfg.domain) -> tunnel"

# ---------------------------------------------------------------------------
# 5. Launcher scripts (idempotent start, used by autostart tasks below)
# ---------------------------------------------------------------------------
Write-Step "Writing launcher scripts"

@"
`$ErrorActionPreference = "Continue"
`$Python = "$VenvPython"
`$Main = "$(Join-Path $ComfyDir 'main.py')"
`$LogDir = "$LogDir"
try {
    Invoke-WebRequest -Uri "http://127.0.0.1:$($cfg.comfyPort)" -UseBasicParsing -TimeoutSec 5 | Out-Null
    exit 0  # already running
} catch {}
Start-Process -FilePath `$Python -ArgumentList "`"`$Main`"" -WorkingDirectory "$ComfyDir" -WindowStyle Hidden ``
    -RedirectStandardOutput (Join-Path `$LogDir "comfyui_stdout.log") -RedirectStandardError (Join-Path `$LogDir "comfyui_stderr.log")
"@ | Set-Content (Join-Path $InstallDir "run_comfyui.ps1")

@"
`$ErrorActionPreference = "Continue"
`$LogDir = "$LogDir"
try {
    Invoke-WebRequest -Uri "http://127.0.0.1:$($cfg.apiPort)/health" -UseBasicParsing -TimeoutSec 5 | Out-Null
    exit 0  # already running
} catch {}
Start-Process -FilePath "node" -ArgumentList "`"$(Join-Path $ApiDir 'src\server.js')`"" -WorkingDirectory "$ApiDir" -WindowStyle Hidden ``
    -RedirectStandardOutput (Join-Path `$LogDir "api_stdout.log") -RedirectStandardError (Join-Path `$LogDir "api_stderr.log")
"@ | Set-Content (Join-Path $InstallDir "run_api.ps1")

@"
`$ErrorActionPreference = "Continue"
`$LogDir = "$LogDir"
`$MetricsPort = 20242
try {
    `$t = Test-NetConnection -ComputerName "127.0.0.1" -Port `$MetricsPort -WarningAction SilentlyContinue
    if (`$t.TcpTestSucceeded) { exit 0 }  # already running
} catch {}
Start-Process -FilePath "cloudflared" -ArgumentList "tunnel --config `"$ConfigYml`" --metrics `"127.0.0.1:`$MetricsPort`" run $($cfg.cloudflareTunnelName)" ``
    -WorkingDirectory "$CloudflaredDir" -WindowStyle Hidden ``
    -RedirectStandardOutput (Join-Path `$LogDir "tunnel_stdout.log") -RedirectStandardError (Join-Path `$LogDir "tunnel_stderr.log")
"@ | Set-Content (Join-Path $InstallDir "run_tunnel.ps1")

Write-Ok "Launcher scripts written to $InstallDir"

# ---------------------------------------------------------------------------
# 6. Autostart (Scheduled Tasks — more reliable than Startup-folder shortcuts,
#    since those only fire on interactive login for one specific user)
# ---------------------------------------------------------------------------
Write-Step "Registering autostart (Scheduled Tasks, run at user logon)"

$tasks = @(
    @{ Name = "ImageGen-ComfyUI"; Script = (Join-Path $InstallDir "run_comfyui.ps1") },
    @{ Name = "ImageGen-ApiWrapper"; Script = (Join-Path $InstallDir "run_api.ps1") },
    @{ Name = "ImageGen-Tunnel"; Script = (Join-Path $InstallDir "run_tunnel.ps1") }
)
foreach ($t in $tasks) {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($t.Script)`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Ok "Registered scheduled task: $($t.Name)"
}
Write-Warn "Scheduled Tasks run 'At log on' for this user — same limitation as Startup shortcuts: nothing starts if this Windows account never logs in after a reboot. For true run-without-login autostart, edit these tasks to run as SYSTEM with an 'At startup' trigger (GPU/CUDA access under SYSTEM can be unreliable — test it before relying on it)."

# ---------------------------------------------------------------------------
# 7. Start everything now and verify
# ---------------------------------------------------------------------------
Write-Step "Starting services"
& (Join-Path $InstallDir "run_comfyui.ps1")
Start-Sleep -Seconds 5
& (Join-Path $InstallDir "run_api.ps1")
& (Join-Path $InstallDir "run_tunnel.ps1")

Write-Host "`nInstall complete." -ForegroundColor Green
Write-Host "ComfyUI can take 1-3 minutes to finish loading the model on first start." -ForegroundColor Gray
Write-Host "Verify with:" -ForegroundColor Gray
Write-Host "  Invoke-WebRequest http://127.0.0.1:$($cfg.comfyPort)" -ForegroundColor Gray
Write-Host "  Invoke-WebRequest http://127.0.0.1:$($cfg.apiPort)/health" -ForegroundColor Gray
Write-Host "  Invoke-WebRequest https://$($cfg.domain)/health" -ForegroundColor Gray
Write-Host "`nYour API key (also saved in config.json and $EnvFile):" -ForegroundColor Gray
Write-Host "  $($cfg.apiKey)" -ForegroundColor Gray
