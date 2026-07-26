# ============================================================
# 阶段1: 前端构建阶段 - 编译 Vue 前端到 docutranslate/static
# ============================================================
# 目录布局说明：
#   /fe/                       - frontend 源码 (package.json, src/, public/, vite.config.js)
#   /docutranslate/static/     - vite outDir 实际写入位置
#
#   vite.config.js 中 outDir: '../docutranslate/static'，相对 WORKDIR=/fe 解析为
#   /fe/../docutranslate/static = /docutranslate/static。
#
# 先把上游手动维护的 static 资源 (katex/redoc/swagger/autoRender.js 等) 复制到
# /docutranslate/static/，vite emptyOutDir=false 会保留它们，并把构建产物
# (assets/, index.html) 和 public/ 下的内容 (i18n/, favicon.ico) 一起写进去。
FROM node:20-alpine AS frontend

WORKDIR /fe

# 先复制 package 文件，利用 docker 层缓存
COPY frontend/package.json frontend/package-lock.json ./

# 安装依赖
RUN npm ci

# 复制前端源码
COPY frontend/ ./

# 复制 static 目录中的非构建资源（favicon、autoRender.js、katex、redoc、swagger、i18n 等）
# 这些是上游手动维护的，vite 不会生成，但运行时需要
# 注意：路径必须是 /docutranslate/static，与 vite outDir 一致
RUN mkdir -p /docutranslate/static
COPY docutranslate/static/ /docutranslate/static/

# 构建（vite 会把 assets/、index.html、public/i18n 写到 /docutranslate/static/）
RUN npm run build

# ============================================================
# 阶段2: Python 依赖构建阶段
# ============================================================
FROM python:3.11-slim AS builder

ENV UV_HTTP_TIMEOUT=300 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_DEV=1

WORKDIR /app

# 安装 uv
RUN pip install --no-cache-dir uv

# 创建虚拟环境并安装依赖
COPY pyproject.toml uv.lock ./
COPY docutranslate ./docutranslate
RUN uv venv && uv sync --frozen --extra mcp

# ============================================================
# 阶段3: 运行阶段
# ============================================================
FROM python:3.11-slim

LABEL authors="xunbu"

ENV PATH="/app/.venv/bin:$PATH" \
    DOCUTRANSLATE_PORT=8010

WORKDIR /app

# 只安装运行时必需的系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    pandoc \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/* /root/.cache

# 从构建阶段复制虚拟环境
COPY --from=builder /app/.venv /app/.venv

# 复制后端代码（不含 static，static 用前端构建产物覆盖）
COPY --from=builder /app/docutranslate /app/docutranslate

# 用前端构建产物覆盖 static/assets 和 index.html
COPY --from=frontend /docutranslate/static/assets /app/docutranslate/static/assets
COPY --from=frontend /docutranslate/static/index.html /app/docutranslate/static/index.html

# 创建挂载点
RUN mkdir -p /app/output

EXPOSE 8010

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${DOCUTRANSLATE_PORT}/service/meta || exit 1

# 启动命令
ENTRYPOINT ["docutranslate", "-i", "--with-mcp"]

# docker build -t xunbu/docutranslate:latest .
# docker push xunbu/docutranslate:latest
# docker run -d -p 8010:8010 xunbu/docutranslate:latest
# Web UI: http://127.0.0.1:8010
# MCP SSE: http://127.0.0.1:8010/mcp/sse
