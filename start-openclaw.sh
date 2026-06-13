#!/bin/bash

set -e

mkdir -p /root/.openclaw/agents/main/sessions
mkdir -p /root/.openclaw/credentials
mkdir -p /root/.openclaw/sessions
mkdir -p /root/.openclaw/workspace

# 1.5 初始化工作区核心文件（如果不存在）
WORKSPACE="/root/.openclaw/workspace"
for file in SOUL.md AGENTS.md TOOLS.md IDENTITY.md USER.md; do
  if [ ! -f "$WORKSPACE/$file" ]; then
    touch "$WORKSPACE/$file"
    echo "Created missing workspace file: $file"
  fi
done

# 1. 先确保 QQ 插件已安装（必须在写配置、启动 gateway 之前）
if ! openclaw plugins list 2>/dev/null | grep -qE '@openclaw/qqbot|"qqbot"'; then
  echo "Installing QQ Official Bot plugin..."
  openclaw plugins install --dangerously-force-unsafe-install @openclaw/qqbot
fi

# 1.6 安装联网搜索 Skill
if ! openclaw skills list 2>/dev/null | grep -q "web-search"; then
  echo "Installing web-search skill (DuckDuckGo)..."
  npx clawhub@latest install web-search 2>/dev/null || echo "web-search skill install skipped (will retry after gateway starts)"
fi

# 1.7 安装其他实用 Skills（跳过已安装的）
for skill in summarize memory-wiki github weather translate qr-code document-processing image-gen; do
  if ! openclaw skills list 2>/dev/null | grep -q "$skill"; then
    echo "Installing skill: $skill ..."
    npx clawhub@latest install "$skill" 2>/dev/null || echo "$skill skill install skipped"
  fi
done

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

#    GitHub Skill（可选，需在 HF Secrets 配置 GH_TOKEN）
echo "GitHub skill: $([ -n "$GH_TOKEN" ] && echo 'ENABLED' || echo 'SKIPPED — set Secret: GH_TOKEN')"

# 4. 用 Python 写配置（从环境变量读取多 provider，避免 Secret 经 argv 传递）
QQ_BOT_ENABLED_PY="False"
[ "$QQ_BOT_ENABLED" = "true" ] && QQ_BOT_ENABLED_PY="True"

export QQ_BOT_ENABLED_PY QQ_APP_ID QQ_CLIENT_SECRET PORT
export PROVIDERS MODEL MODEL_FALLBACKS OPENCLAW_GATEWAY_PASSWORD

python3 /app/sync.py generate_config

openclaw config set model.thinking false 2>/dev/null || true
openclaw config set fastMode.enabled true 2>/dev/null || true
openclaw config set stream true 2>/dev/null || true

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
