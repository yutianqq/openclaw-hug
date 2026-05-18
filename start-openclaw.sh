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
MODEL="${MODEL:-meta/llama-3.1-8b-instruct}"
PORT="${PORT:-7860}"

QQ_APP_ID="${QQBOT_APP_ID:-${QQ_BOT_APP_ID:-}}"
QQ_CLIENT_SECRET="${QQBOT_CLIENT_SECRET:-${QQ_BOT_CLIENT_SECRET:-}}"
QQ_BOT_ENABLED="false"
if [ -n "$QQ_APP_ID" ] && [ -n "$QQ_CLIENT_SECRET" ]; then
  QQ_BOT_ENABLED="true"
else
  echo "QQ Official Bot: SKIPPED — set Secrets: QQBOT_APP_ID + QQBOT_CLIENT_SECRET"
fi

if echo "$MODEL" | grep -qiE '480b|405b|340b'; then
  echo "WARN: MODEL=$MODEL is very large; replies may timeout on HF Space. Use e.g. meta/llama-3.1-8b-instruct"
fi

# 4. 用 Python 写配置（避免 Secret 含引号时破坏 JSON）
QQ_BOT_ENABLED_PY="False"
[ "$QQ_BOT_ENABLED" = "true" ] && QQ_BOT_ENABLED_PY="True"

OPENCLAW_GATEWAY_PASSWORD="${OPENCLAW_GATEWAY_PASSWORD:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ZHIPU_API_KEY="${ZHIPU_API_KEY:-${GLM_API_KEY:-}}"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"

python3 - "$QQ_BOT_ENABLED_PY" "$QQ_APP_ID" "$QQ_CLIENT_SECRET" "$CLEAN_BASE" "$MODEL" "$PORT" "$OPENCLAW_GATEWAY_PASSWORD" "$OPENAI_API_KEY" "$ZHIPU_API_KEY" "$OPENROUTER_API_KEY" <<'PY'
import json, sys

enabled = sys.argv[1] == "True"
app_id, secret = sys.argv[2], sys.argv[3]
base, model, port = sys.argv[4], sys.argv[5], sys.argv[6]
gw_token, nvidia_key = sys.argv[7], sys.argv[8]
zhipu_key, openrouter_key = sys.argv[9], sys.argv[10]

# NVIDIA integrate API — 适合 OpenClaw / HF Space 的极速小模型
NVIDIA_FAST = [
    ("meta/llama-3.2-1b-instruct", "Llama 3.2 1B", 128000),
    ("meta/llama-3.2-3b-instruct", "Llama 3.2 3B", 128000),
    ("meta/llama-3.1-8b-instruct", "Llama 3.1 8B", 128000),
    ("google/gemma-2-2b-it", "Gemma 2 2B", 8192),
    ("microsoft/phi-4-mini-instruct", "Phi-4 Mini", 128000),
    ("nvidia/llama-3.1-nemotron-nano-8b-v1", "Nemotron Nano 8B", 128000),
    ("deepseek-ai/deepseek-v4-flash", "DeepSeek V4 Flash", 128000),
    ("stepfun-ai/step-3-5-flash", "Step 3.5 Flash", 128000),
]

# OpenRouter — 低延迟、适合 agent 工具调用
OPENROUTER_FAST = [
    ("google/gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite", 1048576),
    ("google/gemini-2.5-flash", "Gemini 2.5 Flash", 1048576),
    ("meta-llama/llama-3.2-3b-instruct", "Llama 3.2 3B", 131072),
    ("qwen/qwen-2.5-7b-instruct", "Qwen 2.5 7B", 32768),
]

ZHIPU_BASE = "https://open.bigmodel.cn/api/paas/v4"
ZHIPU_MODEL = ("glm-4.7-flash", "GLM-4.7-Flash 免费", 200000)

def nvidia_catalog():
    seen, out = set(), []
    for mid, name, ctx in NVIDIA_FAST:
        if mid not in seen:
            seen.add(mid)
            out.append({"id": mid, "name": name, "contextWindow": ctx})
    bare = model.split("/", 1)[-1] if "/" in model else model
    if bare not in seen:
        out.append({"id": bare, "name": bare, "contextWindow": 128000})
    return out

def resolve_primary():
    if "/" in model:
        return model
    return f"nvidia/{model}"

providers = {}
env = {}
agent_models = {}
primary = resolve_primary()
fallbacks = []

if nvidia_key:
    providers["nvidia"] = {
        "baseUrl": base,
        "apiKey": nvidia_key,
        "api": "openai-completions",
        "models": nvidia_catalog(),
    }
    for mid, name, _ in NVIDIA_FAST:
        agent_models[f"nvidia/{mid}"] = {"alias": f"NVIDIA {name}"}

if zhipu_key:
    mid, name, ctx = ZHIPU_MODEL
    providers["zhipu"] = {
        "baseUrl": ZHIPU_BASE,
        "apiKey": zhipu_key,
        "api": "openai-completions",
        "models": [{"id": mid, "name": name, "contextWindow": ctx}],
    }
    agent_models[f"zhipu/{mid}"] = {"alias": name}
    env["ZHIPU_API_KEY"] = zhipu_key

if openrouter_key:
    env["OPENROUTER_API_KEY"] = openrouter_key
    for mid, name, ctx in OPENROUTER_FAST:
        ref = f"openrouter/{mid}"
        agent_models[ref] = {"alias": f"OR {name}"}

if zhipu_key and primary != "zhipu/glm-4.7-flash":
    fallbacks.append("zhipu/glm-4.7-flash")
if openrouter_key:
    for mid, _, _ in OPENROUTER_FAST[:2]:
        ref = f"openrouter/{mid}"
        if ref != primary:
            fallbacks.append(ref)
for mid, _, _ in NVIDIA_FAST[:3]:
    ref = f"nvidia/{mid}"
    if ref != primary and ref not in fallbacks:
        fallbacks.append(ref)

fallbacks = [f for f in fallbacks if f != primary][:6]

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

if zhipu_key:
    # GLM-4.7-Flash 开启 tools 时可能 network_error，使用 minimal 工具策略
    cfg["tools"] = {"byProvider": {"zhipu": {"profile": "minimal"}}}

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
if [ -n "$ZHIPU_API_KEY" ]; then echo "ZHIPU_API_KEY (智谱): yes"; else echo "ZHIPU_API_KEY (智谱): NO — set for GLM-4.7-Flash free"; fi
if [ -n "$OPENROUTER_API_KEY" ]; then echo "OPENROUTER_API_KEY: yes"; else echo "OPENROUTER_API_KEY: NO"; fi
openclaw plugins list 2>/dev/null | grep -i qq || echo "WARN: qqbot not in plugin list"
echo "MODEL=${MODEL} (primary ref: use provider/model or bare id for nvidia)"

(while true; do sleep 3600; python3 /app/sync.py backup; done) &

# 不用 doctor --fix，避免覆盖 plugins/channels 配置
openclaw doctor 2>/dev/null || true

exec openclaw gateway run --port "$PORT"
