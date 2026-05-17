#!/bin/bash

set -e

# 1. 补全目录
mkdir -p /root/.openclaw/agents/main/sessions
mkdir -p /root/.openclaw/credentials
mkdir -p /root/.openclaw/sessions

# 2. 执行恢复
python3 /app/sync.py restore

# 3. 处理 API 地址
CLEAN_BASE=$(echo "$OPENAI_API_BASE" | sed "s|/chat/completions||g" | sed "s|/v1/|/v1|g" | sed "s|/v1$|/v1|g")

# QQ 官方 Bot 凭证（支持官方环境变量名，并兼容旧命名）
QQ_APP_ID="${QQBOT_APP_ID:-${QQ_BOT_APP_ID:-}}"
QQ_CLIENT_SECRET="${QQBOT_CLIENT_SECRET:-${QQ_BOT_CLIENT_SECRET:-}}"
QQ_BOT_ENABLED="false"
if [ -n "$QQ_APP_ID" ] && [ -n "$QQ_CLIENT_SECRET" ]; then
  QQ_BOT_ENABLED="true"
  echo "QQ Official Bot: enabled (appId=${QQ_APP_ID})"
else
  echo "QQ Official Bot: skipped (set QQBOT_APP_ID and QQBOT_CLIENT_SECRET to enable)"
fi

# 4. 生成配置文件
cat > /root/.openclaw/openclaw.json <<EOF
{
  "models": {
    "providers": {
      "nvidia": {
        "baseUrl": "$CLEAN_BASE",
        "apiKey": "$OPENAI_API_KEY",
        "api": "openai-completions",
        "models": [
          { "id": "$MODEL", "name": "$MODEL", "contextWindow": 128000 }
        ]
      }
    }
  },
  "agents": { "defaults": { "model": { "primary": "nvidia/$MODEL" } } },
  "commands": {
    "restart": true
  },
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": $PORT,
    "trustedProxies": ["0.0.0.0/0"],
    "auth": { "mode": "token", "token": "$OPENCLAW_GATEWAY_PASSWORD" },
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  },
  "channels": {
    "qqbot": {
      "enabled": $QQ_BOT_ENABLED,
      "appId": "$QQ_APP_ID",
      "clientSecret": "$QQ_CLIENT_SECRET",
      "dmPolicy": "open",
      "groupPolicy": "open",
      "requireMention": true,
      "markdownSupport": true,
      "c2cMarkdownDeliveryMode": "proactive-all"
    }
  }
}
EOF

# 5. 确保 QQ 官方 Bot 插件已安装
if ! openclaw plugins list 2>/dev/null | grep -qE "@openclaw/qqbot|qqbot"; then
  echo "Installing QQ Official Bot plugin..."
  openclaw plugins install --dangerously-force-unsafe-install @openclaw/qqbot
fi

# 6. 启动定时备份 (每 1 小时)
(while true; do sleep 3600; python3 /app/sync.py backup; done) &

# 7. 运行
openclaw doctor --fix

exec openclaw gateway run --port $PORT