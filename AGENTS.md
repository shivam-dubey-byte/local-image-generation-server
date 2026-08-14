# AGENTS.md

Instructions for an AI coding agent (Claude Code, Copilot, Codex, etc.)
tasked with setting up this repo on a Windows machine. Follow this file
directly — it is written as executable steps, not narrative documentation.
`README.md` is for humans; this file is for you.

## Goal

Get a working local image-generation HTTP API running on the current
machine, reachable both at `http://127.0.0.1:<apiPort>` and at a public
HTTPS URL via Cloudflare Tunnel, with all three components (ComfyUI, API
wrapper, tunnel) set to autostart.

## Preconditions to verify before starting

1. OS is Windows with an NVIDIA GPU. Run `nvidia-smi`. If it fails or no
   GPU is listed, stop and tell the user — do not proceed with a CPU-only
   install silently, generation will be unusably slow.
2. `winget` is available (`winget --version`). If missing, tell the user to
   install "App Installer" from the Microsoft Store, then stop.
3. The user has (or has created) a Cloudflare account with a domain already
   added as a zone. You cannot create a Cloudflare account or add a domain
   for them — ask if unsure.

## Setup procedure

1. Copy `config.example.json` to `config.json` in the repo root if it
   doesn't already exist.
2. Fill in `config.json`:
   - `domain`: a real subdomain on a domain already in the user's
     Cloudflare account (e.g. `image.theirdomain.com`). Ask the user for
     this — do not invent one.
   - `installDir`: where to install everything. Default to a drive with
     enough free space (model + dependencies need ~15-20GB). Check free
     space with `Get-PSDrive` before picking one if not specified.
   - `checkpointUrl` / `checkpointFilename`: if the user gives you a direct
     download URL for a `.safetensors` SD/SDXL checkpoint, fill both in. If
     they don't have one yet, leave both blank — the install script will
     skip the download step and print where to place the file manually.
     Do not pick a model on the user's behalf without asking; checkpoint
     choice affects output style significantly.
   - `apiKey`: leave blank. The install script auto-generates one.
   - `apiPort`: leave as the default (`47913`) unless it's already in use
     on this machine — check with
     `Get-NetTCPConnection -LocalPort 47913 -ErrorAction SilentlyContinue`
     before changing it. If you do change it, avoid common dev ports:
     3000, 3001, 5000, 8000, 8080, 5173, 4200.
3. Run `scripts/install.ps1` from an elevated (Administrator) PowerShell
   session. It is idempotent — safe to re-run after fixing something.
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\install.ps1
   ```
4. The script will stop with exit code 1 and a clear message in exactly
   two situations that need a human:
   - `cloudflared tunnel login` hasn't been run yet on this machine (opens
     a browser for Cloudflare OAuth — you cannot complete this step
     yourself, wait for the user to confirm they've done it, then re-run
     `install.ps1`).
   - No checkpoint file present and none configured to auto-download (wait
     for the user to either provide a `checkpointUrl` or manually place a
     `.safetensors` file in `<installDir>\ComfyUI\models\checkpoints\`,
     matching `checkpointFilename` in config.json, then re-run).
   Any other failure: read the error output, it is intentionally verbose.
   Do not blindly retry more than twice — diagnose from the actual error
   text first.
5. After a clean run, verify all three layers independently, in this
   order (matches how failures actually present in practice — check from
   the inside out, not outside in):
   ```powershell
   Invoke-WebRequest http://127.0.0.1:<comfyPort>              # ComfyUI itself
   Invoke-WebRequest http://127.0.0.1:<apiPort>/health          # API wrapper
   Invoke-WebRequest https://<domain>/health                    # public tunnel
   ```
   All three must return HTTP 200 before declaring success. ComfyUI can
   take 1-3 minutes after start to finish loading the model — if the first
   check fails immediately after install, wait and retry a few times
   before treating it as a real failure.
6. Confirm generation actually works end to end, not just health checks:
   ```powershell
   $headers = @{ "x-api-key" = "<apiKey from config.json>"; "Content-Type" = "application/json" }
   Invoke-RestMethod -Uri "https://<domain>/generate-image" -Method Post -Headers $headers -Body '{"prompt":"a test image"}'
   ```
   A `success: true` response with a `filename` means the whole chain
   works. Report the actual result to the user; do not assume success
   from health checks alone — a 200 on `/health` does not guarantee
   generation itself works (e.g. it can't tell you if a checkpoint file
   is corrupt).

## Known failure modes and how to recognize/fix them

These are real issues encountered running this exact stack, not
hypothetical:

**`torch.cuda.is_available()` crashes / `nvcuda64.dll` access violation**
Symptom: ComfyUI process dies immediately on start, `comfyui_stderr.log`
shows a `Windows fatal exception: access violation` with `nvcuda64.dll` in
the stack trace. This is a GPU driver state issue, not a code bug. Fix:
tell the user to reboot the machine. If it recurs immediately after
reboot, the driver itself likely needs a clean reinstall (DDU + fresh
driver) — that requires Safe Mode and GUI interaction you cannot perform;
hand this back to the user with clear steps.

**"An Application Control policy has blocked this file"**
Symptom: a Python import fails with this exact message, referencing a
`.dll` or `.pyd` file. This is Windows Smart App Control blocking an
unsigned native binary. Check if it's active:
```powershell
citool.exe -lp -json | ConvertFrom-Json | Select-Object -ExpandProperty Policies | Where-Object FriendlyName -eq "VerifiedAndReputableDesktop"
```
If `IsEnforced: true`, do not disable Smart App Control outright without
asking the user first (it's a one-way, whole-machine change, irreversible
without a Windows reinstall). Instead build a scoped supplemental allow
policy for just the venv folder:
```powershell
New-CIPolicy -FilePath policy.xml -ScanPath "<ComfyUI venv>\Lib\site-packages" -Level FilePath -UserPEs -Fallback Hash -MultiplePolicyFormat
Set-CIPolicyIdInfo -FilePath policy.xml -SupplementsBasePolicyID 0283ac0f-fff1-49ae-ada1-8a933130cad6 -PolicyName "ImageGen-Venv-Allow"
Set-RuleOption -FilePath policy.xml -Option 3 -Delete   # remove default Audit Mode so it actually enforces
ConvertFrom-CIPolicy -XmlFilePath policy.xml -BinaryFilePath policy.cip
citool.exe --update-policy policy.cip
citool.exe --refresh
```
Requires an elevated PowerShell session. Verify the fix by re-running the
Python import that was failing, not by trusting the policy's own
`IsEnforced`/`IsAuthorized` metadata fields (these are unreliable
indicators for supplemental policies — test actual behavior instead).

**Health check returns 200 but wrong/unexpected content**
Symptom: `/health` responds successfully but the body isn't the expected
JSON (e.g. it's an HTML page). This means another process on the machine
is also bound to the same port and is answering instead of your service.
Diagnose:
```powershell
Get-NetTCPConnection -LocalPort <port> | Select-Object OwningProcess
Get-CimInstance Win32_Process -Filter "ProcessId=<pid>" | Select-Object CommandLine
```
Fix: do not kill a process you can't positively identify as belonging to
this install. Instead, change `apiPort` in `config.json` to a different,
uncommon port and re-run `install.ps1` — it will regenerate the `.env`,
tunnel config, and launcher scripts consistently.

**Tunnel shows connectivity errors / "no healthy connector"**
Check the tunnel process is actually running and check its logs at
`<installDir>\logs\tunnel_stderr.log`. If a restart-check script is
involved, make sure it detects "already running" via a port/network check
(as `run_tunnel.ps1` in this repo does), not by inspecting other
processes' command lines via WMI — that approach silently returns blank
under multi-user permission conditions and produces exactly this
symptom.

## Things to never do without asking the user first

- Kill or stop a process you have not positively identified via its exact
  command line as belonging to this install.
- Disable Smart App Control, Windows Defender, or any other system-wide
  security control, even temporarily.
- Force-push, rewrite git history, or push to any repo other than the one
  this file lives in.
- Pick a checkpoint model on the user's behalf.
- Reboot the machine without telling the user first (it drops any other
  active sessions on a shared machine).

## Files an agent should know about

- `config.json` — the single source of truth for this install. Regenerate
  dependent files (`.env`, `config.yml`, launcher scripts) by re-running
  `install.ps1` after editing it; don't hand-edit the generated files.
- `scripts/install.ps1` — the entire install, idempotent, safe to re-run.
- `templates/api-wrapper/` — source for the API wrapper, copied into
  `<installDir>\api-wrapper` on install. Edit here if changing wrapper
  behavior, not in the copied output.
- `<installDir>\logs\*.log` — stdout/stderr for all three services. Check
  these first for any runtime failure, before re-running anything.
