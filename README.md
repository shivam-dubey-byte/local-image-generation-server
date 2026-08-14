# Local Image Generation Server — Setup Guide

A complete guide to running your own AI image generation server on a local
Windows PC with an NVIDIA GPU, and exposing it as a private HTTPS API without
needing a public server, port forwarding, or a static IP.

This is the exact setup used to run a self-hosted image generation API from a
home/office PC, reachable over the internet through Cloudflare Tunnel.

## Architecture

```
Internet
   |
   v
Cloudflare Tunnel (encrypted, no open ports on your router)
   |
   v
Express.js API wrapper  (port of your choice, e.g. 47913)
   |  - handles auth (API key)
   |  - handles the generation request/response cycle
   |  - polls ComfyUI until the image is ready
   v
ComfyUI  (port 8188, localhost only)
   |  - runs the actual Stable Diffusion / SDXL model
   |  - uses the GPU (CUDA) to generate the image
   v
GPU (NVIDIA, via CUDA)
```

Three separate pieces, each replaceable independently:

1. **ComfyUI** — the actual image generation engine. Loads a Stable Diffusion
   / SDXL checkpoint model and runs inference on your GPU.
2. **A small API wrapper** (Node/Express here, could be anything) — exposes a
   simple `POST /generate-image` endpoint, talks to ComfyUI's own API
   internally, and returns a clean JSON response with the result.
3. **Cloudflare Tunnel** — makes your local server reachable over HTTPS at a
   real domain, without opening any ports on your router/firewall.

## Requirements

- Windows PC with an NVIDIA GPU (8GB+ VRAM recommended for SDXL-class models)
- Latest NVIDIA driver installed
- Python 3.11+ (a dedicated virtual environment is strongly recommended)
- Node.js (for the API wrapper — swap for any language/framework you prefer)
- A domain you control, added to Cloudflare (free plan is fine)
- A `cloudflared` binary (Cloudflare Tunnel client)

## 1. Install ComfyUI

```
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
```

Install a PyTorch build matching your GPU's CUDA version — check
https://pytorch.org for the correct command for your setup. Getting the
torch/CUDA version wrong is the single most common cause of crashes (see
Troubleshooting below).

Download a checkpoint model (`.safetensors` file) into
`ComfyUI/models/checkpoints/`. Any SDXL or SD1.5-based checkpoint works —
pick one suited to the style of images you want (realistic photo, anime,
illustration, etc.) from a model-sharing site.

Start it once manually to confirm it works:

```
python main.py
```

It should come up on `http://127.0.0.1:8188`. Leave this local-only — don't
expose this port directly to the internet.

## 2. Build a thin API wrapper around it

ComfyUI has its own internal API, but it's low-level (you submit a raw
"workflow" graph and poll for results). A thin wrapper on top makes it
usable as a simple product API:

- `GET /health` → confirms the wrapper and ComfyUI are both reachable
- `POST /generate-image` → accepts a prompt (and optional parameters),
  submits the right workflow to ComfyUI, polls until the image is ready,
  returns the file path / URL

Key things worth building in from the start:
- **API key auth** on the generate endpoint (a simple header check is
  enough for a personal/small-team setup) — without this, anyone who finds
  your URL can burn your GPU time.
- **A generation timeout** — image generation can occasionally hang;
  don't let a request wait forever.
- **A configurable port** via `.env`, not hardcoded — makes it much easier
  to avoid port collisions with other things running on the same machine
  (see Troubleshooting).

Example `.env`:
```
PORT=47913
COMFY_URL=http://127.0.0.1:8188
COMFY_CHECKPOINT=your-checkpoint-name.safetensors
API_KEY=<generate a long random string>
GENERATION_TIMEOUT_MS=900000
```

Pick an uncommon port (not `3000`, `5000`, `8000`, `8080` — all common dev
tool defaults, easy to collide with something else on the same machine).

## 3. Expose it with Cloudflare Tunnel

Cloudflare Tunnel lets you point a real subdomain at a service running on
your own PC, over an outbound-only encrypted connection — no port
forwarding, no exposing your home IP, no static IP needed.

1. Install `cloudflared` (from Cloudflare's official releases).
2. Authenticate it against your Cloudflare account:
   ```
   cloudflared tunnel login
   ```
3. Create a named tunnel:
   ```
   cloudflared tunnel create my-image-api
   ```
   This generates a credentials file and a Tunnel ID.
4. Write a `config.yml`:
   ```yaml
   tunnel: my-image-api
   credentials-file: C:\Users\<you>\.cloudflared\<tunnel-id>.json

   ingress:
     - hostname: image.yourdomain.com
       service: http://127.0.0.1:47913
     - service: http_status:404
   ```
5. Route DNS to the tunnel:
   ```
   cloudflared tunnel route dns my-image-api image.yourdomain.com
   ```
6. Run it:
   ```
   cloudflared tunnel --config config.yml run my-image-api
   ```

Your API is now live at `https://image.yourdomain.com`, fully HTTPS, with
Cloudflare's network in front of it.

## 4. Keep everything running automatically

The simplest reliable approach on Windows, without needing a full Windows
Service setup:

- Write a small `.bat`/`.ps1` launcher for each piece (ComfyUI, the API
  wrapper, the tunnel), each of which:
  - checks if it's already running (e.g. by checking if its port responds)
    before starting a new copy — this avoids duplicate processes
  - redirects stdout/stderr to a log file, so failures are diagnosable
- Drop shortcuts to these scripts into your Startup folder
  (`shell:startup`), so they launch automatically on login.

**Important limitation:** Startup-folder items only run when that specific
Windows user account logs in interactively — not on a plain reboot if
nobody logs into that account. If you need true "runs even if nobody logs
in" behavior, use a proper Windows Scheduled Task (trigger: "At startup",
run whether user is logged in or not) or a Windows Service instead.

## Troubleshooting

**GPU/CUDA crashes on startup** (`access violation` in `nvcuda64.dll`, or
`torch.cuda.is_available()` crashing outright):
This is almost always a driver-state or driver/torch-version mismatch, not
your code. First thing to try: reboot the machine — this clears a surprising
number of "stuck" GPU driver states. If it persists after reboot, do a clean
driver reinstall (Display Driver Uninstaller + fresh driver download).

**Windows blocks a `.dll`/`.pyd` file with "An Application Control policy
has blocked this file"**:
This is Windows Smart App Control (a built-in Windows 11 security feature),
blocking unsigned native files it doesn't recognize — common with Python
packages that bundle compiled binaries (video/audio codecs, GPU libraries,
etc.). You have two options:
- Turn Smart App Control off entirely (Windows Security → App & browser
  control). Simple, but **irreversible without a clean Windows reinstall**,
  and disables this protection machine-wide.
- Add a scoped allow-list for just your project's folder, using Windows'
  own policy tooling (`ConfigCI` PowerShell module: `New-CIPolicy` to scan
  and hash the files, `Set-CIPolicyIdInfo` to bind it as a supplemental
  policy, `citool.exe --update-policy` to deploy). More setup, but keeps
  protection active for the rest of the system. Worth it if the machine is
  shared or handles anything sensitive.

**API responds but with the wrong content, or requests seem to go to a
different app entirely**:
Check for a port collision — `netstat -ano` and look for more than one
process bound to the port you think your API is using. This is especially
likely on a shared machine with multiple people/services running. Fix: move
your service to a different, less common port and update every place that
references it (`.env`, tunnel config, any "already running" health-check
scripts).

**Tunnel shows as down / "no healthy connector" errors**:
Check that your tunnel process is actually still running (`cloudflared`
crashes or gets killed and needs restarting) and that whatever
watchdog/restart script you're using to keep it alive is actually working
— test it by deliberately killing the process and confirming it comes back.
A common bug is a restart-check that relies on inspecting other processes'
command lines, which can silently fail depending on permissions; checking
whether the port itself responds is more reliable.

## Notes

- This describes the general pattern, not a specific production deployment.
  Replace all example hostnames, ports, and file paths with your own.
- Keep your API key out of git — use `.env` (and `.gitignore` it), never
  commit it directly.
