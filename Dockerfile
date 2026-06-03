# 第一阶段：构建前端主题
FROM node:20-alpine AS frontend-builder

RUN apk add --no-cache git python3 make g++

WORKDIR /build

# 克隆 2024 主题源码
RUN git clone --depth 1 https://github.com/vastsa/FileCodeBoxFronted.git /build/fronted-2024

# 复制前端补丁文件（在构建前覆盖源码）
COPY patches/frontend/ /build/fronted-2024/src/

# 构建 2024 主题
RUN cd /build/fronted-2024 && \
    npm install && \
    npm run build

# 克隆并构建 2023 主题
RUN git clone --depth 1 https://github.com/vastsa/FileCodeBoxFronted2023.git /build/fronted-2023 && \
    cd /build/fronted-2023 && \
    npm install --legacy-peer-deps && \
    npm run build

# 第二阶段：构建最终镜像
FROM python:3.12-slim-bookworm
LABEL author="Lan"
LABEL email="xzu@live.com"

WORKDIR /app

# 复制项目文件（通过 .dockerignore 排除不必要的文件）
COPY . .

# 设置时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo 'Asia/Shanghai' > /etc/timezone

# 从构建阶段复制编译好的前端主题
COPY --from=frontend-builder /build/fronted-2024/dist ./themes/2024
COPY --from=frontend-builder /build/fronted-2023/dist ./themes/2023

# 安装 Python 依赖
RUN pip install --no-cache-dir -r requirements.txt

# 环境变量配置
ENV HOST="0.0.0.0" \
    PORT=12345 \
    WORKERS=1 \
    LOG_LEVEL="info"

EXPOSE 12345

# 生产环境启动命令
CMD uvicorn main:app \
    --host $HOST \
    --port $PORT \
    --workers $WORKERS \
    --log-level $LOG_LEVEL \
    --proxy-headers \
    --forwarded-allow-ips "*"