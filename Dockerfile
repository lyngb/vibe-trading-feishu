# Vibe-Trading 飞书 bot —— 容器镜像
# 方案：官方 PyPI 包 + 长连接（WebSocket），不需要公网域名/回调地址
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    VIBE_TRADING_HOME=/root/.vibe-trading \
    VT_PORT=8000

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 安装本体 + 飞书 SDK
RUN pip install --no-cache-dir vibe-trading-ai lark-oapi

# 上游把运行时目录写死在安装目录（src/agent/loop.py: RUNS_DIR = parents[2]/"runs"），
# 容器里把它软链到 /data，重启不丢数据。
RUN SP="$(python -c 'import site;print(site.getsitepackages()[0])')" \
 && mkdir -p /data/runs /data/sessions /data/swarm \
 && rm -rf "$SP/runs" "$SP/sessions" "$SP/.swarm" \
 && ln -s /data/runs "$SP/runs" \
 && ln -s /data/sessions "$SP/sessions" \
 && ln -s /data/swarm "$SP/.swarm" \
 && echo "linked runtime dirs from $SP to /data"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/root/.vibe-trading", "/data"]
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -s -o /dev/null "http://127.0.0.1:${VT_PORT}/channels/status" || exit 1

ENTRYPOINT ["/entrypoint.sh"]
