#!/bin/bash

set -e

mkdir -p /root/.openclaw/agents/main/sessions
mkdir -p /root/.openclaw/credentials
mkdir -p /root/.openclaw/sessions

# 1. 先确保 QQ 插件已安装（必须在写配置、启动 gateway 之前）
if ! openclaw plugins list 2>/dev/null | grep -qE '@openclaw/qqbot|"qqbot"'; then
  echo "Installing QQ Official Bot plugin..."
  openclaw plugins install --dangerously-force-unsafe-install @openclaw/qqbot
fi

# 2. 恢复会话备份（不依赖备份里的 openclaw.json，下面会重新生成）
python3 /app/sync.py restore

# 3. 环境变量
CLEAN_BASE=$(echo "${OPENAI_API_BASE:-https://integrate.api.nvidia.com/v1}" | sed 's|/chat/completions||g' | sed 's|/v1/|/v1|g' | sed 's|/v1$|/v1|g')
MODEL="${MODEL:-stepfun-ai/step-3-5-flash}"
PORT="${PORT:-7860}"

QQ_APP_ID="${QQBOT_APP_ID:-${QQ_BOT_APP_ID:-}}"
QQ_CLIENT_SECRET="${QQBOT_CLIENT_SECRET:-${QQ_BOT_CLIENT_SECRET:-}}"
QQ_BOT_ENABLED="false"
if [ -n "$QQ_APP_ID" ] && [ -n "$QQ_CLIENT_SECRET" ]; then
  QQ_BOT_ENABLED="true"
else
  echo "QQ Official Bot: SKIPPED — set Secrets: QQBOT_APP_ID + QQBOT_CLIENT_SECRET"
fi

if echo "$MODEL" | grep -qiE '480b|405b|340b|70b|49b'; then
  echo "WARN: MODEL=$MODEL may timeout on HF Space. Use stepfun-ai/step-3-5-flash or huggingface/*:fastest"
fi

# 4. 用 Python 写配置（避免 Secret 含引号时破坏 JSON）
QQ_BOT_ENABLED_PY="False"
[ "$QQ_BOT_ENABLED" = "true" ] && QQ_BOT_ENABLED_PY="True"

OPENCLAW_GATEWAY_PASSWORD="${OPENCLAW_GATEWAY_PASSWORD:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
HF_TOKEN="${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}"

python3 - "$QQ_BOT_ENABLED_PY" "$QQ_APP_ID" "$QQ_CLIENT_SECRET" "$CLEAN_BASE" "$MODEL" "$PORT" "$OPENCLAW_GATEWAY_PASSWORD" "$OPENAI_API_KEY" "$HF_TOKEN" <<'PY'
import json, sys

enabled = sys.argv[1] == "True"
app_id, secret = sys.argv[2], sys.argv[3]
base, model, port = sys.argv[4], sys.argv[5], sys.argv[6]
gw_token, nvidia_key, hf_key = sys.argv[7], sys.argv[8], sys.argv[9]

NVIDIA_MODEL = ("stepfun-ai/step-3-5-flash", "Step 3.5 Flash", 128000)
HF_BASE = "https://router.huggingface.co/v1"
# HF Inference Providers — :fastest 自动选吞吐最高的后端（Groq 等）
HF_FAST = [
    ("Qwen/Qwen2.5-0.5B-Instruct:fastest", "Qwen2.5 0.5B", 32768),
    ("google/gemma-2-2b-it:fastest", "Gemma 2 2B", 8192),
    ("meta-llama/Llama-3.2-1B-Instruct:fastest", "Llama 3.2 1B", 131072),
]

def resolve_primary():
    if model.startswith(("nvidia/", "huggingface/")):
        return model
    if model.startswith("stepfun-ai/"):
        return f"nvidia/{model}"
    return f"nvidia/{NVIDIA_MODEL[0]}"

providers = {}
env = {}
agent_models = {}
primary = resolve_primary()
fallbacks = []

if nvidia_key:
    mid, name, ctx = NVIDIA_MODEL
    providers["nvidia"] = {
        "baseUrl": base,
        "apiKey": nvidia_key,
        "api": "openai-completions",
        "models": [{"id": mid, "name": name, "contextWindow": ctx}],
    }
    agent_models[f"nvidia/{mid}"] = {"alias": name}

if hf_key:
    providers["huggingface"] = {
        "baseUrl": HF_BASE,
        "apiKey": hf_key,
        "api": "openai-completions",
        "models": [
            {"id": mid, "name": name, "contextWindow": ctx}
            for mid, name, ctx in HF_FAST
        ],
    }
    env["HF_TOKEN"] = hf_key
    for mid, name, _ in HF_FAST:
        agent_models[f"huggingface/{mid}"] = {"alias": f"HF {name}"}
        ref = f"huggingface/{mid}"
        if ref != primary:
            fallbacks.append(ref)

fallbacks = [f for f in fallbacks if f != primary][:3]

cfg = {
    "models": {"mode": "merge", "providers": providers},
    "agents": {
        "defaults": {
            "model": {"primary": primary, "fallbacks": fallbacks},
            "models": agent_models,
        }
    },
    "commands": {"restart": True},
    "plugins": {
        "allow": (["qqbot"] if enabled else []),
        "entries": {"qqbot": {"enabled": enabled}},
    },
    "gateway": {
        "mode": "local",
        "bind": "lan",
        "port": int(port),
        "trustedProxies": ["0.0.0.0/0"],
        "auth": {"mode": "token", "token": gw_token},
        "controlUi": {
            "enabled": True,
            "allowInsecureAuth": True,
            "dangerouslyDisableDeviceAuth": True,
            "dangerouslyAllowHostHeaderOriginFallback": True,
        },
    },
    "channels": {
        "qqbot": {
            "enabled": enabled,
            "appId": app_id,
            "clientSecret": secret,
            "dmPolicy": "open",
            "groupPolicy": "open",
            "requireMention": True,
            "markdownSupport": True,
            "c2cMarkdownDeliveryMode": "proactive-all",
        }
    },
}

if env:
    cfg["env"] = env

path = "/root/.openclaw/openclaw.json"
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
providers_on = ",".join(providers.keys()) or "none"
print(f"Wrote {path} (qqbot={enabled}, primary={primary}, providers={providers_on})")
PY

if [ "$QQ_BOT_ENABLED" = "true" ]; then
  echo "QQ Official Bot: enabled appId=${QQ_APP_ID}"
  # 登记渠道账号（失败不阻断启动）
  openclaw channels add --channel qqbot --token "${QQ_APP_ID}:${QQ_CLIENT_SECRET}" 2>/dev/null \
    && echo "QQ channel account registered" \
    || echo "QQ channel add skipped (may already exist)"
fi

echo "=== Startup check ==="
if [ -n "$QQ_APP_ID" ]; then echo "QQBOT_APP_ID set: yes"; else echo "QQBOT_APP_ID set: NO"; fi
if [ -n "$QQ_CLIENT_SECRET" ]; then echo "QQBOT_CLIENT_SECRET set: yes"; else echo "QQBOT_CLIENT_SECRET set: NO"; fi
if [ -n "$OPENAI_API_KEY" ]; then echo "OPENAI_API_KEY (NVIDIA): yes"; else echo "OPENAI_API_KEY (NVIDIA): NO"; fi
if [ -n "$HF_TOKEN" ]; then echo "HF_TOKEN (Inference): yes"; else echo "HF_TOKEN: NO — Space 通常自动注入，或设置 HUGGINGFACE_HUB_TOKEN"; fi
openclaw plugins list 2>/dev/null | grep -i qq || echo "WARN: qqbot not in plugin list"
echo "MODEL=${MODEL} (default: nvidia/stepfun-ai/step-3-5-flash)"

(while true; do sleep 7200; python3 /app/sync.py backup; done) &

# 不用 doctor --fix，避免覆盖 plugins/channels 配置
openclaw doctor 2>/dev/null || true

exec openclaw gateway run --port "$PORT"
