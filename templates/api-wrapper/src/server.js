require('dotenv').config();
const express = require('express');
const fetch = require('node-fetch');
const { v4: uuidv4 } = require('uuid');

const PORT = process.env.PORT || 47913;
const COMFY_URL = process.env.COMFY_URL || 'http://127.0.0.1:8188';
const CHECKPOINT = process.env.COMFY_CHECKPOINT;
const API_KEY = process.env.API_KEY;
const GENERATION_TIMEOUT_MS = Number(process.env.GENERATION_TIMEOUT_MS || 900000);
const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS || 2000);

if (!CHECKPOINT) {
  console.error('COMFY_CHECKPOINT is not set in .env — refusing to start.');
  process.exit(1);
}
if (!API_KEY) {
  console.error('API_KEY is not set in .env — refusing to start.');
  process.exit(1);
}

const app = express();
app.use(express.json());

function requireApiKey(req, res, next) {
  if (req.get('x-api-key') !== API_KEY) {
    return res.status(401).json({ success: false, error: { message: 'Invalid or missing API key' } });
  }
  next();
}

// Standard ComfyUI text-to-image graph (CheckpointLoader -> CLIPTextEncode x2
// -> EmptyLatentImage -> KSampler -> VAEDecode -> SaveImage). Works with any
// SD1.5/SDXL-class checkpoint without modification.
function buildWorkflow({ prompt, negativePrompt, width, height, steps, cfg, seed }) {
  return {
    '3': {
      class_type: 'KSampler',
      inputs: {
        cfg,
        denoise: 1,
        latent_image: ['5', 0],
        model: ['4', 0],
        negative: ['7', 0],
        positive: ['6', 0],
        sampler_name: 'euler',
        scheduler: 'normal',
        seed,
        steps,
      },
    },
    '4': {
      class_type: 'CheckpointLoaderSimple',
      inputs: { ckpt_name: CHECKPOINT },
    },
    '5': {
      class_type: 'EmptyLatentImage',
      inputs: { batch_size: 1, height, width },
    },
    '6': {
      class_type: 'CLIPTextEncode',
      inputs: { clip: ['4', 1], text: prompt },
    },
    '7': {
      class_type: 'CLIPTextEncode',
      inputs: { clip: ['4', 1], text: negativePrompt || '' },
    },
    '8': {
      class_type: 'VAEDecode',
      inputs: { samples: ['3', 0], vae: ['4', 2] },
    },
    '9': {
      class_type: 'SaveImage',
      inputs: { filename_prefix: 'api', images: ['8', 0] },
    },
  };
}

async function submitPrompt(workflow) {
  const clientId = uuidv4();
  const res = await fetch(`${COMFY_URL}/prompt`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: workflow, client_id: clientId }),
  });
  if (!res.ok) {
    throw new Error(`ComfyUI rejected the prompt: ${res.status} ${await res.text()}`);
  }
  const data = await res.json();
  return data.prompt_id;
}

async function waitForResult(promptId) {
  const deadline = Date.now() + GENERATION_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const res = await fetch(`${COMFY_URL}/history/${promptId}`);
    if (res.ok) {
      const data = await res.json();
      const entry = data[promptId];
      if (entry && entry.outputs) {
        for (const nodeOutput of Object.values(entry.outputs)) {
          if (nodeOutput.images && nodeOutput.images.length > 0) {
            return nodeOutput.images[0];
          }
        }
      }
    }
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
  throw new Error('Timed out waiting for ComfyUI to finish generating.');
}

app.get('/health', async (req, res) => {
  try {
    const comfyRes = await fetch(`${COMFY_URL}/system_stats`, { timeout: 5000 });
    if (!comfyRes.ok) throw new Error('ComfyUI not responding');
    res.json({ success: true, service: 'image-gen-api-wrapper', comfy_url: COMFY_URL });
  } catch (err) {
    res.status(503).json({
      success: false,
      error: { message: 'ComfyUI is not reachable. Make sure ComfyUI is running on COMFY_URL.', details: err.message },
    });
  }
});

app.post('/generate-image', requireApiKey, async (req, res) => {
  const {
    prompt,
    negativePrompt = '',
    width = 1024,
    height = 1024,
    steps = 25,
    cfg = 7,
    seed = Math.floor(Math.random() * 1e15),
  } = req.body || {};

  if (!prompt || typeof prompt !== 'string') {
    return res.status(400).json({ success: false, error: { message: 'Missing required field: prompt (string)' } });
  }

  try {
    const workflow = buildWorkflow({ prompt, negativePrompt, width, height, steps, cfg, seed });
    const promptId = await submitPrompt(workflow);
    const image = await waitForResult(promptId);

    res.json({
      success: true,
      prompt_id: promptId,
      filename: image.filename,
      comfy_view_url: `${COMFY_URL}/view?filename=${encodeURIComponent(image.filename)}&subfolder=${encodeURIComponent(image.subfolder || '')}&type=${image.type}`,
    });
  } catch (err) {
    res.status(502).json({ success: false, error: { message: 'Generation failed', details: err.message } });
  }
});

app.listen(PORT, () => {
  console.log(`image-gen-api-wrapper listening on http://127.0.0.1:${PORT}`);
  console.log(`  -> forwarding to ComfyUI at ${COMFY_URL}`);
});
