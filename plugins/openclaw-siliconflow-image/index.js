const SILICONFLOW_DEFAULT_BASE = "https://api.siliconflow.cn/v1";
const SILICONFLOW_DEFAULT_MODEL = "Kwai-Kolors/Kolors";
const TIMEOUT_MS = 180000;

function getApiKey(api) {
  return (
    process.env.SILICONFLOW_API_KEY ||
    (api && api.config && api.config.SILICONFLOW_API_KEY) ||
    ""
  );
}

function getBaseUrl(api) {
  return (
    (api &&
      api.pluginConfig &&
      api.pluginConfig.openclawSiliconflowImage &&
      api.pluginConfig.openclawSiliconflowImage.baseUrl) ||
    SILICONFLOW_DEFAULT_BASE
  );
}

async function generateImage(params) {
  const { prompt, model, size, n = 1 } = params || {};
  const apiKey = getApiKey(this.api);
  const baseUrl = getBaseUrl(this.api);
  if (!apiKey) throw new Error("SILICONFLOW_API_KEY not set");

  const modelId = model || SILICONFLOW_DEFAULT_MODEL;
  const imageSize = parseSize(size);

  const body = {
    model: modelId,
    prompt: prompt,
    image_size: imageSize,
  };
  if (params.negative_prompt) body.negative_prompt = params.negative_prompt;
  if (typeof params.seed === "number") body.seed = params.seed;
  if (typeof params.num_inference_steps === "number")
    body.num_inference_steps = params.num_inference_steps;

  const resp = await fetch(`${baseUrl}/images/generations`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!resp.ok) {
    const errText = await resp.text().catch(() => "");
    throw new Error(
      `SiliconFlow image gen failed: HTTP ${resp.status} ${errText}`
    );
  }
  const data = await resp.json();
  const images = (data.images || data.data || []).map((img) => ({
    url: img.url || null,
    b64_json: img.b64_json || null,
  }));
  return {
    created: Math.floor(Date.now() / 1000),
    data: images,
  };
}

function parseSize(size) {
  if (!size) return "1024x1024";
  const s = String(size).toLowerCase();
  if (/^\d+x\d+$/.test(s)) return s;
  const map = {
    square: "1024x1024",
    "1:1": "1024x1024",
    portrait: "768x1024",
    "3:4": "768x1024",
    landscape: "1024x768",
    "4:3": "1024x768",
    tall: "576x1024",
    "9:16": "576x1024",
    wide: "1024x576",
    "16:9": "1024x576",
  };
  return map[s] || "1024x1024";
}

async function listModels() {
  return [
    { id: "Kwai-Kolors/Kolors", name: "Kolors", free: true },
    { id: "black-forest-labs/FLUX.1-schnell", name: "FLUX.1-schnell", free: true },
    { id: "black-forest-labs/FLUX.1-dev", name: "FLUX.1-dev" },
    { id: "Qwen/Qwen-Image", name: "Qwen-Image" },
  ];
}

module.exports = function (api) {
  const providerId = "siliconflow";

  if (api && typeof api.registerImageGenerationProvider === "function") {
    api.registerImageGenerationProvider({
      id: providerId,
      name: "SiliconFlow",
      generate: generateImage.bind({ api }),
      listModels: listModels,
      capabilities: {
        generate: true,
        edit: false,
        maxImages: 4,
        sizes: [
          "512x512",
          "768x1024",
          "1024x768",
          "576x1024",
          "1024x576",
          "1024x1024",
        ],
      },
    });
    console.log(
      `[siliconflow-image] Registered image generation provider (base=${getBaseUrl(
        api
      )})`
    );
  } else {
    console.warn(
      "[siliconflow-image] registerImageGenerationProvider not available on api object"
    );
  }

  return { id: providerId };
};
