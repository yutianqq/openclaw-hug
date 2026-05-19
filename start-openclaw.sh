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
  echo "WARN: MODEL=$MODEL may timeout on HF Space. Default: stepfun-ai/step-3-5-flash"
fi

# 4. 用 Python 写配置（避免 Secret 含引号时破坏 JSON）
QQ_BOT_ENABLED_PY="False"
[ "$QQ_BOT_ENABLED" = "true" ] && QQ_BOT_ENABLED_PY="True"

OPENCLAW_GATEWAY_PASSWORD="${OPENCLAW_GATEWAY_PASSWORD:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
# 在 Space Secrets 中自行添加免费模型 id，逗号分隔（不含 provider 前缀）
NVIDIA_MODELS="${NVIDIA_MODELS:-}"
OPENROUTER_MODELS="${OPENROUTER_MODELS:-}"
MODEL_FALLBACKS="${MODEL_FALLBACKS:-}"

python3 - "$QQ_BOT_ENABLED_PY" "$QQ_APP_ID" "$QQ_CLIENT_SECRET" "$CLEAN_BASE" "$MODEL" "$PORT" "$OPENCLAW_GATEWAY_PASSWORD" "$OPENAI_API_KEY" "$OPENROUTER_API_KEY" "$NVIDIA_MODELS" "$OPENROUTER_MODELS" "$MODEL_FALLBACKS" <<'PY'
import json, sys

enabled = sys.argv[1] == "True"
app_id, secret = sys.argv[2], sys.argv[3]
base, model, port = sys.argv[4], sys.argv[5], sys.argv[6]
gw_token, nvidia_key, openrouter_key = sys.argv[7], sys.argv[8], sys.argv[9]
nvidia_models_csv, openrouter_models_csv, fallbacks_csv = sys.argv[10], sys.argv[11], sys.argv[12]

DEFAULT_NVIDIA_ID = "stepfun-ai/step-3-5-flash"
OPENROUTER_BASE = "https://openrouter.ai/api/v1"

def parse_csv(csv):
    return [m.strip() for m in (csv or "").split(",") if m.strip()]

def resolve_primary():
    if model.startswith(("nvidia/", "openrouter/")):
        return model
    if model:
        return f"nvidia/{model}"
    return f"nvidia/{DEFAULT_NVIDIA_ID}"

def nvidia_model_entries():
    ids = parse_csv(nvidia_models_csv)
    if DEFAULT_NVIDIA_ID not in ids:
        ids.insert(0, DEFAULT_NVIDIA_ID)
    seen, out = set(), []
    for mid in ids:
        if mid in seen:
            continue
        seen.add(mid)
        name = "Step 3.5 Flash" if mid == DEFAULT_NVIDIA_ID else mid
        out.append({"id": mid, "name": name, "contextWindow": 128000})
    return out

providers = {}
env = {}
agent_models = {}
primary = resolve_primary()
fallbacks = parse_csv(fallbacks_csv)

if nvidia_key:
    entries = nvidia_model_entries()
    providers["nvidia"] = {
        "baseUrl": base,
        "apiKey": nvidia_key,
        "api": "openai-completions",
        "models": entries,
    }
    for e in entries:
        agent_models[f"nvidia/{e['id']}"] = {"alias": e["name"]}

if openrouter_key:
    env["OPENROUTER_API_KEY"] = openrouter_key
    or_ids = parse_csv(openrouter_models_csv)
    if or_ids:
        providers["openrouter"] = {
            "baseUrl": OPENROUTER_BASE,
            "apiKey": openrouter_key,
            "api": "openai-completions",
            "models": [
                {"id": mid, "name": mid, "contextWindow": 128000} for mid in or_ids
            ],
        }
        for mid in or_ids:
            agent_models[f"openrouter/{mid}"] = {"alias": mid}

if not fallbacks:
    for ref in list(agent_models.keys()):
        if ref != primary:
            fallbacks.append(ref)

fallbacks = [f for f in fallbacks if f != primary][:8]

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
if [ -n "$OPENROUTER_API_KEY" ]; then echo "OPENROUTER_API_KEY: yes"; else echo "OPENROUTER_API_KEY: NO"; fi
echo "NVIDIA_MODELS=${NVIDIA_MODELS:-<empty, only default>}"
echo "OPENROUTER_MODELS=${OPENROUTER_MODELS:-<empty>}"
openclaw plugins list 2>/dev/null | grep -i qq || echo "WARN: qqbot not in plugin list"
echo "MODEL=${MODEL} (default primary: nvidia/stepfun-ai/step-3-5-flash)"

(while true; do sleep 7200; python3 /app/sync.py backup; done) &

# 不用 doctor --fix，避免覆盖 plugins/channels 配置
openclaw doctor 2>/dev/null || true

exec openclaw gateway run --port "$PORT"
