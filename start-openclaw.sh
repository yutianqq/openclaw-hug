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

python3 - "$QQ_BOT_ENABLED_PY" "$QQ_APP_ID" "$QQ_CLIENT_SECRET" "$CLEAN_BASE" "$MODEL" "$PORT" "$OPENCLAW_GATEWAY_PASSWORD" "$OPENAI_API_KEY" <<'PY'
import json, sys

enabled = sys.argv[1] == "True"
app_id, secret = sys.argv[2], sys.argv[3]
base, model, port = sys.argv[4], sys.argv[5], sys.argv[6]
gw_token, api_key = sys.argv[7], sys.argv[8]

cfg = {
    "models": {
        "providers": {
            "nvidia": {
                "baseUrl": base,
                "apiKey": api_key,
                "api": "openai-completions",
                "models": [{"id": model, "name": model, "contextWindow": 128000}],
            }
        }
    },
    "agents": {"defaults": {"model": {"primary": f"nvidia/{model}"}}},
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

path = "/root/.openclaw/openclaw.json"
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print(f"Wrote {path} (qqbot enabled={enabled}, model=nvidia/{model})")
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
openclaw plugins list 2>/dev/null | grep -i qq || echo "WARN: qqbot not in plugin list"
echo "MODEL=${MODEL}"

(while true; do sleep 3600; python3 /app/sync.py backup; done) &

# 不用 doctor --fix，避免覆盖 plugins/channels 配置
openclaw doctor 2>/dev/null || true

exec openclaw gateway run --port "$PORT"
