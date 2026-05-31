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

# 3. 环境变量（均在 HF Space Settings 中配置）
#    Variable PROVIDERS: 逗号分隔的 provider 名称，如 nvidia,openrouter
#    每个 provider 需配置（NAME 为大写 slug）:
#      {NAME}_OPENAI_API_BASE  (Variable)
#      {NAME}_MODELS           (Variable，逗号分隔模型 ID)
#      {NAME}_API_KEY          (Secret)
#    全局:
#      MODEL, MODEL_FALLBACKS  (Variable)
#    单 provider 兼容（PROVIDERS 留空时）:
#      OPENAI_API_BASE, MODELS, OPENAI_API_KEY, PROVIDER_NAME
PROVIDERS="${PROVIDERS:-}"
MODEL="${MODEL:-}"
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

# 4. 用 Python 写配置（从环境变量读取多 provider，避免 Secret 经 argv 传递）
QQ_BOT_ENABLED_PY="False"
[ "$QQ_BOT_ENABLED" = "true" ] && QQ_BOT_ENABLED_PY="True"

export QQ_BOT_ENABLED_PY QQ_APP_ID QQ_CLIENT_SECRET PORT
export PROVIDERS MODEL MODEL_FALLBACKS OPENCLAW_GATEWAY_PASSWORD

python3 <<'PY'
import json, os, re

def parse_list(s):
    return [x.strip() for x in (s or "").split(",") if x.strip()]

def clean_base(url):
    if not url:
        return ""
    u = url.strip()
    u = re.sub(r"/chat/completions/?$", "", u)
    u = re.sub(r"/v1/?$", "/v1", u)
    return u

def provider_slugs():
    raw = os.environ.get("PROVIDERS", "").strip()
    if raw:
        return [s.strip().lower() for s in raw.split(",") if s.strip()]
    # 单 provider 向后兼容
    if os.environ.get("OPENAI_API_BASE") or os.environ.get("MODELS") or os.environ.get("OPENAI_API_KEY"):
        return [os.environ.get("PROVIDER_NAME", "default").strip().lower() or "default"]
    return []

def load_provider(slug):
    key = slug.upper()
    base = clean_base(os.environ.get(f"{key}_OPENAI_API_BASE", ""))
    models = parse_list(os.environ.get(f"{key}_MODELS", ""))
    api_key = os.environ.get(f"{key}_API_KEY", "")
    if slug == os.environ.get("PROVIDER_NAME", "default").strip().lower():
        base = base or clean_base(os.environ.get("OPENAI_API_BASE", ""))
        models = models or parse_list(os.environ.get("MODELS", ""))
        api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
    return base, models, api_key

enabled = os.environ.get("QQ_BOT_ENABLED_PY") == "True"
app_id = os.environ.get("QQ_APP_ID", "")
secret = os.environ.get("QQ_CLIENT_SECRET", "")
model = os.environ.get("MODEL", "").strip()
fallbacks_raw = os.environ.get("MODEL_FALLBACKS", "")
port = int(os.environ.get("PORT", "7860"))
gw_token = os.environ.get("OPENCLAW_GATEWAY_PASSWORD", "")

# model_id -> [slug, ...]（用于解析未带前缀的 MODEL）
id_to_slugs = {}
providers = {}
agent_models = {}

for slug in provider_slugs():
    base, model_ids, api_key = load_provider(slug)
    if not api_key:
        print(f"WARN: {slug.upper()}_API_KEY (Secret) not set — skip provider '{slug}'")
        continue
    if not base:
        print(f"WARN: {slug.upper()}_OPENAI_API_BASE (Variable) not set — skip provider '{slug}'")
        continue
    if not model_ids:
        print(f"WARN: {slug.upper()}_MODELS (Variable) not set — skip provider '{slug}'")
        continue

    providers[slug] = {
        "baseUrl": base,
        "apiKey": api_key,
        "api": "openai-completions",
        "models": [{"id": mid, "name": mid, "contextWindow": 128000} for mid in model_ids],
    }
    for mid in model_ids:
        ref = f"{slug}/{mid}"
        agent_models[ref] = {"alias": mid}
        id_to_slugs.setdefault(mid, []).append(slug)

def resolve_ref(item):
    item = item.strip()
    if not item:
        return item
    if "/" in item:
        return item
    slugs = id_to_slugs.get(item, [])
    if len(slugs) == 1:
        return f"{slugs[0]}/{item}"
    if len(slugs) > 1:
        print(f"WARN: model id '{item}' exists on multiple providers {slugs}; use provider/model_id")
    return item

def resolve_primary():
    if model:
        return resolve_ref(model)
    for slug in provider_slugs():
        if slug in providers:
            mids = providers[slug]["models"]
            if mids:
                return f"{slug}/{mids[0]['id']}"
    return None

def resolve_fallbacks(primary):
    out = []
    for item in parse_list(fallbacks_raw):
        ref = resolve_ref(item)
        if ref and ref != primary and ref not in out:
            out.append(ref)
    return out

primary = resolve_primary()
fallbacks = resolve_fallbacks(primary) if primary else []

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
        "port": port,
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

old_cfg = None
try:
    with open(path, "r", encoding="utf-8") as f:
        old_cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    pass

if old_cfg and "cron" in old_cfg:
    cfg["cron"] = old_cfg["cron"]
    print(f"Merged existing cron config from previous {path}")

with open(path, "w", encoding="utf-8") as f:
    cfg.setdefault("session", {})["dmScope"] = "per-channel-peer"
    json.dump(cfg, f, indent=2, ensure_ascii=False)

total_models = sum(len(p["models"]) for p in providers.values())
print(
    f"Wrote {path} (qqbot={enabled}, primary={primary or 'unset'}, "
    f"providers={','.join(providers.keys()) or 'none'}, models={total_models})"
)
if not providers:
    print("WARN: no provider configured — set PROVIDERS and per-provider Variables/Secrets")
PY

if [ "$QQ_BOT_ENABLED" = "true" ]; then
  echo "QQ Official Bot: enabled appId=${QQ_APP_ID}"
  openclaw channels add --channel qqbot --token "${QQ_APP_ID}:${QQ_CLIENT_SECRET}" 2>/dev/null \
    && echo "QQ channel account registered" \
    || echo "QQ channel add skipped (may already exist)"
fi

echo "=== Startup check ==="
if [ -n "$QQ_APP_ID" ]; then echo "QQBOT_APP_ID set: yes"; else echo "QQBOT_APP_ID set: NO"; fi
if [ -n "$QQ_CLIENT_SECRET" ]; then echo "QQBOT_CLIENT_SECRET set: yes"; else echo "QQBOT_CLIENT_SECRET set: NO"; fi
echo "PROVIDERS=${PROVIDERS:-<unset, single-provider compat via OPENAI_* >}"
echo "MODEL=${MODEL:-<unset>} MODEL_FALLBACKS=${MODEL_FALLBACKS:-<empty>}"
echo "Session DM scope: $(openclaw config get session.dmScope 2>/dev/null || echo 'unknown')"
for slug in $(echo "${PROVIDERS:-default}" | tr ',' ' '); do
  key=$(echo "$slug" | tr '[:lower:]' '[:upper:]')
  eval "base=\${${key}_OPENAI_API_BASE:-}"
  eval "models=\${${key}_MODELS:-}"
  eval "has_key=\${${key}_API_KEY:+yes}"
  has_key=${has_key:-no}
  if [ "$slug" = "default" ] && [ -z "$base" ]; then base="${OPENAI_API_BASE:-}"; fi
  if [ "$slug" = "default" ] && [ -z "$models" ]; then models="${MODELS:-}"; fi
  if [ "$slug" = "default" ] && [ "$has_key" = "no" ] && [ -n "${OPENAI_API_KEY:-}" ]; then has_key=yes; fi
  echo "  [$slug] base=${base:-<unset>} models=${models:-<empty>} api_key=${has_key}"
done
openclaw plugins list 2>/dev/null | grep -i qq || echo "WARN: qqbot not in plugin list"

(while true; do sleep 14400; python3 /app/sync.py backup; done) &

openclaw doctor --fix --non-interactive || true

exec openclaw gateway run --port "$PORT" --bind lan
