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
      "enabled": true,
      "appId": "${QQ_BOT_APP_ID:-}",
      "clientSecret": "${QQ_BOT_CLIENT_SECRET:-}",
      "markdownSupport": true,
      "c2cMarkdownDeliveryMode": "proactive-all"
    }
  }
}
EOF

# 5. 启动定时备份 (每 1 小时)
(while true; do sleep 3600; python3 /app/sync.py backup; done) &

# 6. 运行
openclaw doctor --fix

exec openclaw gateway run --port $PORT