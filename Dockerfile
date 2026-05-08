FROM node:22-slim

# 1. 基础依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    git openssh-client build-essential python3 python3-pip \
    g++ make ca-certificates && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir huggingface_hub --break-system-packages

# 2. 安装 OpenClaw
RUN npm install -g openclaw@latest --unsafe-perm
# RUN npm install -g @larksuiteoapi/node-sdk --unsafe-perm && \
    # npm install -g openclaw@2026.2.26 --unsafe-perm

# 3. 安装 QQ Bot 通道插件
RUN openclaw plugins install @openclaw/qqbot

# 4. 设置工作目录并拷贝脚本
WORKDIR /app
COPY sync.py .
COPY start-openclaw.sh .
RUN chmod +x start-openclaw.sh

# 5. 环境变量
ENV PORT=7860 HOME=/root

EXPOSE 7860
CMD ["./start-openclaw.sh"]