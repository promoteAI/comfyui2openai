# comfyui2openai

将 ComfyUI 工作流转换为 OpenAI 兼容的 API 服务，便于其他系统集成。

## 特性

- **OpenAI API 兼容**：支持 `/v1/images/generations`、`/v1/images/edits`、`/v1/chat/completions` 等端点
- **多工作流支持**：文生图、图生图、文生视频、图生视频
- **工作流热重载**：监听工作流目录变更，自动加载新工作流
- **任务队列管理**：后台任务队列，支持并发执行和进度推送
- **WebSocket 进度**：通过 WebSocket 实时订阅任务执行进度
- **灵活认证**：支持 Bearer Token 认证和签名 URL
- **多种图片上传模式**：支持 ComfyUI 上传、本地写入或自动降级

## 快速开始

### 环境要求

- Python >= 3.11
- ComfyUI 已安装并运行（默认地址：`http://127.0.0.1:8188`）

### 安装

```bash
# 克隆项目
git clone <repository-url>
cd comfyui2openai

# 安装依赖（使用 uv）
uv pip install -e .

# 或使用 pip
pip install -e .
```

### 配置

1. 复制环境变量模板：
```bash
cp .env.example .env
```

2. 修改 `.env` 文件，至少配置 `COMFYUI_BASE_URL`：
```env
COMFYUI_BASE_URL=http://127.0.0.1:8188
```

### 运行

```bash
# 方式1：使用模块运行
python -m src

# 方式2：使用 uvicorn
uvicorn src.app:app --host 0.0.0.0 --port 8000

# 方式3：使用环境变量文件
uvicorn --env-file .env src.app:app --host 0.0.0.0 --port 8000
```

服务启动后，访问 `http://127.0.0.1:8000/health` 检查健康状态。

## 配置说明

所有配置通过环境变量管理，可在 `.env` 文件中设置：

### API 服务配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `API_LISTEN` | `0.0.0.0` | API 服务监听地址 |
| `API_PORT` | `8000` | API 服务监听端口 |
| `API_TOKEN` | _(空)_ | Bearer Token 认证（留空则不认证） |
| `PUBLIC_BASE_URL` | _(空)_ | 对外可访问的 URL（用于生成输出链接，反代场景） |

### ComfyUI 连接配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `COMFYUI_BASE_URL` | `http://127.0.0.1:8188` | ComfyUI 服务地址 |
| `COMFYUI_STARTUP_CHECK` | `true` | 启动时检查 ComfyUI 可达性 |

### 工作流配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WORKFLOWS_DIR` | `./comfyui_api_workflows` | 工作流 JSON 文件目录 |
| `ENABLE_WORKFLOW_WATCH` | `true` | 监听工作流目录变更并热重载 |

### 图片上传配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `IMAGE_UPLOAD_MODE` | `auto` | 图片上传模式：`comfy`/`local`/`auto` |
| `COMFYUI_INPUT_DIR` | _(自动检测)_ | ComfyUI input 目录（local 模式需要） |
| `INPUT_SUBDIR` | `comfyui2openai` | 图片存放的子目录名 |

**上传模式说明**：
- `comfy`：通过 ComfyUI `POST /upload/image` 上传（推荐，适用于 WSL/Docker/远端）
- `local`：直接写入 `COMFYUI_INPUT_DIR/INPUT_SUBDIR/`（需要共享磁盘）
- `auto`：优先使用 `comfy`，失败则降级到 `local`

### 任务管理配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WORKER_CONCURRENCY` | `1` | 并发执行任务数 |
| `JOB_RETENTION_DAYS` | _(空)_ | 任务保留天数（优先级高于秒） |
| `JOB_RETENTION_SECONDS` | `604800` | 任务保留秒数（默认7天） |
| `MAX_JOBS_IN_MEMORY` | `1000` | 内存中最多保留任务数 |
| `JOB_CLEANUP_INTERVAL_S` | `60` | 清理扫描间隔（秒） |

### 请求限制配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MAX_BODY_BYTES` | `30000000` | 请求体最大字节数（约30MB） |
| `MAX_IMAGE_BYTES` | `20000000` | 图片最大字节数（约20MB） |
| `TIMEOUT_S` | `3600` | 任务执行超时（秒） |
| `POLL_INTERVAL_S` | `0.5` | 轮询 ComfyUI 状态间隔（秒） |
| `HTTP_TIMEOUT_S` | `30` | HTTP 请求超时（秒） |

### 签名 URL 配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SIGNED_URL_SECRET` | _(空)_ | 签名密钥（留空则使用 API_TOKEN） |
| `SIGNED_URL_TTL_SECONDS` | `3600` | 签名 URL 有效期（秒） |

### 默认工作流配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DEFAULT_TXT2IMG_WORKFLOW` | `文生图.json` | 默认文生图工作流 |
| `DEFAULT_IMG2IMG_WORKFLOW` | `图片编辑.json` | 默认图生图工作流 |
| `DEFAULT_TXT2VIDEO_WORKFLOW` | `文生视频.json` | 默认文生视频工作流 |
| `DEFAULT_IMG2VIDEO_WORKFLOW` | `图生视频.json` | 默认图生视频工作流 |

## API 使用说明

### 端点概览

| 端点 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/v1/models` | GET | 列出可用工作流（作为模型） |
| `/v1/images/generations` | POST | OpenAI 兼容图像生成 |
| `/v1/images/edits` | POST | OpenAI 兼容图像编辑 |
| `/v1/chat/completions` | POST | 聊天补全（支持生成） |
| `/v1/jobs` | POST | 提交自定义任务 |
| `/v1/jobs/{job_id}` | GET | 查询任务状态 |
| `/v1/jobs/{job_id}/ws` | WebSocket | 订阅任务进度 |
| `/v1/workflows` | GET | 列出所有工作流 |
| `/v1/workflows/{name}/parameters` | GET | 查看工作流参数 |
| `/runs/{job_id}/{output_name}` | GET | 下载输出文件 |

### 认证方式

如果设置了 `API_TOKEN`，所有接口需要在 Header 中携带：
```
Authorization: Bearer <your-token>
```

或使用查询参数：
```
?authorization=Bearer%20<your-token>
```

### 文生图示例

```bash
curl -X POST http://127.0.0.1:8000/v1/images/generations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-token" \
  -d '{
    "prompt": "一只可爱的猫",
    "workflow": "文生图.json",
    "steps": 20,
    "cfg": 7.5,
    "width": 512,
    "height": 512
  }'
```

### 图生图示例

```bash
curl -X POST http://127.0.0.1:8000/v1/images/edits \
  -H "Authorization: Bearer your-token" \
  -F "image=@input.jpg" \
  -F "prompt=转换为油画风格" \
  -F "workflow=图片编辑.json"
```

### 提交自定义任务

```bash
curl -X POST http://127.0.0.1:8000/v1/jobs \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-token" \
  -d '{
    "kind": "txt2img",
    "workflow": "文生图.json",
    "prompt": "科幻城市",
    "negative_prompt": "模糊, 低质量",
    "overrides": {
      "5.width": 768,
      "5.height": 768,
      "5.steps": 30
    }
  }'
```

### 查询任务状态

```bash
curl http://127.0.0.1:8000/v1/jobs/<job_id> \
  -H "Authorization: Bearer your-token"
```

### WebSocket 订阅进度

```javascript
const ws = new WebSocket('ws://127.0.0.1:8000/v1/jobs/<job_id>/ws');
ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('任务状态:', data);
};
```

### 使用 OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    api_key="your-token",
    base_url="http://127.0.0.1:8000/v1"
)

# 图像生成
response = client.images.generate(
    model="文生图",  # 工作流文件名（不含扩展名）
    prompt="一只可爱的猫",
    size="512x512"
)
print(response.data[0].url)

# 图像编辑
response = client.images.edit(
    model="图片编辑",
    image=open("input.jpg", "rb"),
    prompt="转换为油画风格"
)
```

## 工作流配置

### 导出工作流

1. 在 ComfyUI 中设计好工作流
2. 点击菜单：`File` -> `Export (API)`
3. 将 JSON 文件保存到 `WORKFLOWS_DIR` 目录（默认 `comfyui_api_workflows/`）

### 工作流参数配置（可选）

可以为工作流创建参数配置文件，实现参数自动映射：

**文件结构**：
```
comfyui_api_workflows/
├── 文生图.json
├── 文生图.params.json    # 参数配置文件（可选）
├── 图生图.json
└── 图生视频.json
```

**参数配置示例**（`文生图.params.json`）：
```json
{
  "kind": "txt2img",
  "parameters": {
    "prompt": {
      "type": "text",
      "node_id": "5",
      "input_key": "text"
    },
    "negative_prompt": {
      "type": "text",
      "node_id": "6",
      "input_key": "text"
    },
    "steps": {
      "type": "number",
      "node_id": "5",
      "input_key": "steps"
    },
    "cfg": {
      "type": "number",
      "node_id": "5",
      "input_key": "cfg"
    }
  }
}
```

如果不提供 `.params.json`，系统会自动检测常用节点（如 CLIP Text Encode、KSampler 等）。

### 工作流类型检测

系统会根据工作流内容自动检测类型：
- **txt2img**：包含 SaveImage，不包含 LoadImage
- **img2img**：包含 SaveImage 和 LoadImage
- **txt2video**：包含 SaveVideo，不包含 LoadImage
- **img2video**：包含 SaveVideo 和 LoadImage

## 项目结构

```
comfyui2openai/
├── src/
│   ├── __main__.py          # 入口文件
│   ├── app.py               # FastAPI 应用主逻辑
│   ├── config.py            # 配置管理（环境变量）
│   ├── comfy_client.py      # ComfyUI API 客户端
│   ├── comfy_workflow.py    # 工作流解析与能力检测
│   ├── workflow_registry.py # 工作流注册与热重载
│   ├── workflow_params.py   # 工作流参数处理
│   ├── jobs.py              # 任务队列管理
│   ├── job_retention.py     # 任务清理策略
│   ├── signed_urls.py       # 签名 URL 生成与验证
│   └── util.py              # 工具函数
├── comfyui_api_workflows/   # 工作流 JSON 文件目录
├── runs/                    # 任务输出目录
├── .env.example             # 环境变量模板
├── pyproject.toml           # 项目配置
└── README.md
```

## 许可证

[LICENSE](LICENSE)  # 如有许可证文件，请取消注释

## 贡献

欢迎提交 Issue 和 Pull Request！

---

**注意**：本项目的 OpenAI 兼容 API 仅支持图像/视频生成相关功能，不支持文本对话、嵌入等标准 OpenAI 能力。
