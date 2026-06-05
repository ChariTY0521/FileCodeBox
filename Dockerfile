FROM python:3.12-slim-bookworm
LABEL author="Lan"
LABEL email="xzu@live.com"

WORKDIR /app

# 复制项目文件（包含本地构建好的 themes/）
COPY . .

# 设置时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo 'Asia/Shanghai' > /etc/timezone

# 安装 Python 依赖
RUN pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt

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
