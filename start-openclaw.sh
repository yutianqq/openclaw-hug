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
MODEL="${MODEL:-}"
NVIDIA_MODELS="${NVIDIA_MODELS:-}"
OPENROUTER_MODELS="${OPENROUTER_MODELS:-}"
MODEL_FALLBACKS="${MODEL_FALLBACKS:-}"
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
  echo "WARN: MODEL=$MODEL may timeout on HF Space; prefer smaller free models in NVIDIA_MODELS / OPENROUTER_MODELS"
fi

# 4. 用 Python 写配置（避免 Secret 含引号时破坏 JSON）
QQ_BOT_ENABLED_PY="False"
[ "$QQ_BOT_ENABLED" = "true" ] && QQ_BOT_ENABLED_PY="True"

OPENCLAW_GATEWAY_PASSWORD="${OPENCLAW_GATEWAY_PASSWORD:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"

python3 - "$QQ_BOT_ENABLED_PY" "$QQ_APP_ID" "$QQ_CLIENT_SECRET" "$CLEAN_BASE" "$MODEL" "$PORT" "$OPENCLAW_GATEWAY_PASSWORD" "$OPENAI_API_KEY" "$OPENROUTER_API_KEY" "$NVIDIA_MODELS" "$OPENROUTER_MODELS" "$MODEL_FALLBACKS" <<'PY'
import json, sys

enabled = sys.argv[1] == "True"
app_id, secret = sys.argv[2], sys.argv[3]
base, model, port = sys.argv[4], sys.argv[5], sys.argv[6]
gw_token, nvidia_key, openrouter_key = sys.argv[7], sys.argv[8], sys.argv[9]
nvidia_models_raw, openrouter_models_raw, fallbacks_raw = sys.argv[10], sys.argv[11], sys.argv[12]

def parse_list(s):
    return [x.strip() for x in s.split(",") if x.strip()]

nvidia_ids = parse_list(nvidia_models_raw)
openrouter_ids = parse_list(openrouter_models_raw)

def resolve_primary():
    if model:
        if model.startswith(("nvidia/", "openrouter/")):
            return model
        if model in nvidia_ids:
            return f"nvidia/{model}"
        if model in openrouter_ids:
            return f"openrouter/{model}"
        return model
    if nvidia_ids:
        return f"nvidia/{nvidia_ids[0]}"
    if openrouter_ids:
        return f"openrouter/{openrouter_ids[0]}"
    return None

def resolve_fallbacks(primary):
    out = []
    for item in parse_list(fallbacks_raw):
        if item.startswith(("nvidia/", "openrouter/")):
            ref = item
        elif item in nvidia_ids:
            ref = f"nvidia/{item}"
        elif item in openrouter_ids:
            ref = f"openrouter/{item}"
        else:
            ref = item
        if ref != primary and ref not in out:
            out.append(ref)
    return out

providers = {}
env = {}
agent_models = {}
primary = resolve_primary()
fallbacks = resolve_fallbacks(primary) if primary else []

if nvidia_key and nvidia_ids:
    providers["nvidia"] = {
        "baseUrl": base,
        "apiKey": nvidia_key,
        "api": "openai-completions",
        "models": [{"id": mid, "name": mid, "contextWindow": 128000} for mid in nvidia_ids],
    }
    for mid in nvidia_ids:
        agent_models[f"nvidia/{mid}"] = {"alias": mid}

if openrouter_key:
    env["OPENROUTER_API_KEY"] = openrouter_key
    for mid in openrouter_ids:
        agent_models[f"openrouter/{mid}"] = {"alias": mid}

agents_defaults = {}
if agent_models:
    agents_defaults["models"] = agent_models
if primary:
    agents_defaults["model"] = {"primary": primary, "fallbacks": fallbacks}

cfg = {
    "models": {"mode": "merge", "providers": providers},
    "agents": {"defaults": agents_defaults},
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
or_env = "yes" if openrouter_key else "no"
print(
    f"Wrote {path} (qqbot={enabled}, primary={primary or 'unset'}, "
    f"providers={providers_on}, openrouter_key={or_env}, "
    f"nvidia_models={len(nvidia_ids)}, openrouter_models={len(openrouter_ids)})"
)
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
if [ -n "$OPENROUTER_API_KEY" ]; then echo "OPENROUTER_API_KEY: yes"; else echo "OPENROUTER_API_KEY: NO"; fi
echo "NVIDIA_MODELS=${NVIDIA_MODELS:-<empty>}"
echo "OPENROUTER_MODELS=${OPENROUTER_MODELS:-<empty>}"
echo "MODEL=${MODEL:-<unset>} MODEL_FALLBACKS=${MODEL_FALLBACKS:-<empty>}"
openclaw plugins list 2>/dev/null | grep -i qq || echo "WARN: qqbot not in plugin list"

(while true; do sleep 7200; python3 /app/sync.py backup; done) &

# 不用 doctor --fix，避免覆盖 plugins/channels 配置
openclaw doctor 2>/dev/null || true

exec openclaw gateway run --port "$PORT"
