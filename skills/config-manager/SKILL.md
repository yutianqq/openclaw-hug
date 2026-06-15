---
name: config-manager
description: >
  Manage OpenClaw configuration through conversation.
  Use when the user wants to: view current config, change model, switch provider,
  toggle features, add/modify API keys, adjust gateway settings, or any config change
  without restarting the service. All changes take effect immediately (hot-reload).
---

# Config Manager

通过对话管理 OpenClaw 配置，**无需重启，立即生效**。

## 核心原则

1. **所有配置变更使用 `openclaw config set/get` 命令** — 支持热重载，无需重启
2. **修改前先读取当前值** — 用 `openclaw config get <key>` 确认现状
3. **修改后回读确认** — 再次 get 验证写入成功
4. **敏感操作需告知用户** — API Key、密码等敏感信息变更前要确认

## 可用命令

### 读取配置

```bash
# 读取单个配置项
openclaw config get <key>

# 常用读取示例
openclaw config get agents.defaults.model          # 当前主模型
openclaw config get models.providers                # 所有 Provider
openclaw config get gateway.port                    # 端口
openclaw config get session.dmScope                 # 会话策略
openclaw config get channels.qqbot.enabled           # QQ 是否启用
openclaw config get fastMode.enabled                # 快速模式
openclaw config get stream                          # 流式输出
```

### 修改配置（热生效）

```bash
# 通用设置
openclaw config set <key> <value>

# 模型相关
openclaw config set agents.defaults.model.primary "nvidia/meta-llama/Llama-4-Scout-17B-16E"
openclaw config set model.thinking false
openclaw config set fastMode.enabled true
openclaw config set stream true

# 网关相关
openclaw config set gateway.port 7860
openclaw config set gateway.bind lan

# 会话管理
openclaw config set session.dmScope per-channel-peer
openclaw config set session.maintenance.mode enforce
openclaw config set session.maintenance.pruneAfter 7d
openclaw config set session.maintenance.maxEntries 500

# 渠道开关
openclaw config set channels.qqbot.enabled true
openclaw config set channels.qqbot.requireMention true
```

### Provider 管理

```bash
# 注意：Provider 的增删改涉及 JSON 结构，需要用 Python 脚本处理
python3 /app/sync.py update_provider --action add --slug <name> \
  --base-url "<url>" --models "<model1>,<model2>" --api-key "<key>"

python3 /app/sync.py update_provider --action remove --slug <name>

python3 /app/sync.py update_provider --action update --slug <name> \
  --base-url "<url>" --models "<model1>,<model2>"

# 列出当前所有 Provider
python3 /app/sync.py list_providers
```

### 备份与恢复

```bash
# 手动触发备份（保存到 HF Dataset）
python3 /app/sync.py backup

# 从备份恢复会话数据
python3 /app/sync.py restore
```

## 用户意图识别与操作映射

| 用户说 | 执行操作 |
|--------|----------|
| "切换模型到 xxx" | `config set agents.defaults.model.primary` |
| "查看当前模型" | `config get agents.defaults.model` |
| "开启/关闭快速模式" | `config set fastMode.enabled true/false` |
| "开启/关闭流式输出" | `config set stream true/false` |
| "开启/关闭 QQ" | `config set channels.qqbot.enabled true/false` |
| "增加一个 Provider" | `sync.py update_provider --action add` |
| "删除 xxx Provider" | `sync.py update_provider --action remove` |
| "改 API Key/Base URL" | `sync.py update_provider --action update` |
| "调整会话保留时间" | `config set session.maintenance.pruneAfter` |
| "现在配置是什么" | 批量 get 关键项 |
| "备份一下" | `sync.py backup` |

## 操作流程模板

```
用户: 把模型换成 xxx

Agent:
1. openclaw config get agents.defaults.model        # 读当前值
2. openclaw config set agents.defaults.model.primary "xxx"  # 写新值
3. openclaw config get agents.defaults.model        # 回读确认
4. 告知用户：已切换，立即生效，无需重启
```

## 安全规则

- **绝不** 在对话中明文回显完整的 API Key，只显示前 4 位和后 4 位（如 `sk-****....abcd`）
- **删除 Provider 前** 必须确认该 Provider 不是当前主模型或 fallback
- **修改端口等网络配置** 后提示用户可能需要等待几秒生效
- 如果命令执行失败，告诉用户具体错误信息，不要静默忽略

## 不支持的操作（需要重启）

以下配置变更**需要重启 Gateway** 才能生效，请明确告知用户：

- 新增插件 (`plugins.install`)
- 删除插件 (`plugins.uninstall`)
- 修改 `gateway.auth.token`
- 修改 `gateway.controlUi` 相关安全设置

对于这些操作，告知用户："此变更需要重启服务才能生效。在 Hugging Face Spaces 中可以通过 Restart Space 操作来完成。"

## 重要说明：持久化 vs 运行时

通过对话修改的配置（Provider 增删改、模型切换等）**立即生效且在容器不重启时持续有效**。

但如果容器**重启**（HF Space 休眠恢复、手动 Restart），`generate_config()` 会从环境变量重新生成基础配置。此时：
- **环境变量中定义的 Provider**（HF Space Settings）→ 始终保留
- **运行时通过对话添加的 Provider** → 自动保留（会从旧配置合并）
- **`openclaw config set` 修改的简单键值** → 可能被覆盖（如 fastMode、stream 等）

如果用户需要**永久性修改**，应同时更新 HF Space Settings 中的对应环境变量。
