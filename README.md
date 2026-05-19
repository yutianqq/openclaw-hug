---
title: Openclaw
emoji: 📈
colorFrom: green
colorTo: gray
sdk: docker
pinned: false
---

在 Space **Settings** 中配置模型，无内置默认模型。支持多个 OpenAI 兼容 API（如英伟达、OpenRouter 等）。

## 多 Provider 配置（推荐）

**Variable**

| 名称 | 说明 |
|------|------|
| `PROVIDERS` | Provider 列表，逗号分隔，如 `nvidia,openrouter` |
| `MODEL` | 默认主模型，建议写 `provider/model_id` |
| `MODEL_FALLBACKS` | 备用模型，逗号分隔（可选） |

每个 provider（以 `nvidia` 为例，环境变量前缀为 **大写** `NVIDIA`）：

| 类型 | 名称 | 说明 |
|------|------|------|
| Variable | `NVIDIA_OPENAI_API_BASE` | Base URL |
| Variable | `NVIDIA_MODELS` | 模型 ID，逗号分隔 |
| Secret | `NVIDIA_API_KEY` | API Key |

OpenRouter 同理：`OPENROUTER_OPENAI_API_BASE`、`OPENROUTER_MODELS`、`OPENROUTER_API_KEY`。

模型引用格式：`{provider}/{model_id}`，例如 `nvidia/meta/llama-3.1-8b-instruct`。

### 英伟达 + OpenRouter 示例

**Variables**

```
PROVIDERS=nvidia,openrouter
NVIDIA_OPENAI_API_BASE=https://integrate.api.nvidia.com/v1
NVIDIA_MODELS=meta/llama-3.1-8b-instruct,meta/llama-3.3-70b-instruct
OPENROUTER_OPENAI_API_BASE=https://openrouter.ai/api/v1
OPENROUTER_MODELS=anthropic/claude-sonnet-4,openai/gpt-4o-mini
MODEL=nvidia/meta/llama-3.1-8b-instruct
MODEL_FALLBACKS=openrouter/anthropic/claude-sonnet-4
```

**Secrets**

```
NVIDIA_API_KEY=nvapi-...
OPENROUTER_API_KEY=sk-or-...
```

## 单 Provider（可选，向后兼容）

不设置 `PROVIDERS` 时，可用旧变量名：

| 类型 | 名称 |
|------|------|
| Variable | `OPENAI_API_BASE`, `MODELS`, `PROVIDER_NAME`（默认 `default`） |
| Secret | `OPENAI_API_KEY` |

## 其他 Secrets / Variables

| 类型 | 名称 | 说明 |
|------|------|------|
| Secret | `OPENCLAW_GATEWAY_PASSWORD` | Gateway token（可选） |
| Secret | `QQBOT_APP_ID`, `QQBOT_CLIENT_SECRET` | QQ 机器人（可选） |
| Secret | `HF_TOKEN` | 会话备份（可选） |
| Variable | `HF_DATASET` | 备份数据集 repo id（可选） |

---

参考：[Spaces configuration](https://huggingface.co/docs/hub/spaces-config-reference)
