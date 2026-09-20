#!/usr/bin/env bash
# Vibe-Trading 容器入口：注入配置 → 起服务 → 起飞书通道 → 自检 → 保活
set -euo pipefail

VT_HOME="${VIBE_TRADING_HOME:-/root/.vibe-trading}"
VT_PORT="${VT_PORT:-8000}"
mkdir -p "$VT_HOME" /data/runs /data/sessions /data/swarm

echo "=== [1/5] 写入 LLM 配置 $VT_HOME/.env ==="
cat > "$VT_HOME/.env" <<EOF
LANGCHAIN_PROVIDER=${LANGCHAIN_PROVIDER:-minimax}
LANGCHAIN_MODEL_NAME=${LANGCHAIN_MODEL_NAME:-MiniMax-M2.7}
LANGCHAIN_TEMPERATURE=${LANGCHAIN_TEMPERATURE:-0.0}
MINIMAX_API_KEY=${MINIMAX_API_KEY:?MINIMAX_API_KEY is required}
MINIMAX_BASE_URL=${MINIMAX_BASE_URL:-https://api.minimaxi.com/v1}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-120}
MAX_RETRIES=${MAX_RETRIES:-2}
EOF
echo "    已写入（MINIMAX_API_KEY 长度 ${#MINIMAX_API_KEY}）"

echo "=== [2/5] 写入通道配置 $VT_HOME/agent.json ==="
if [ -n "${FEISHU_APP_ID:-}" ] && [ -n "${FEISHU_APP_SECRET:-}" ]; then
  FEISHU_APP_ID="$FEISHU_APP_ID" FEISHU_APP_SECRET="$FEISHU_APP_SECRET" \
  FEISHU_DOMAIN="${FEISHU_DOMAIN:-feishu}" VT_HOME="$VT_HOME" \
  python - <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ["VT_HOME"]) / "agent.json"
try:
    cfg = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    cfg = {}
# 注意：上游 FeishuConfig.model_validate 是裸 pydantic，必须用 snake_case
cfg.setdefault("channels", {})["feishu"] = {
    "enabled": True,
    "app_id": os.environ["FEISHU_APP_ID"],
    "app_secret": os.environ["FEISHU_APP_SECRET"],
    "domain": os.environ.get("FEISHU_DOMAIN", "feishu"),
    "group_policy": "mention",
    "streaming": True,
    "reply_to_message": False,
}
p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
print("    已写入 channels.feishu =", os.environ["FEISHU_APP_ID"])
PY
else
  echo "    [warn] 未提供 FEISHU_APP_ID/SECRET，跳过（只起 API，不起飞书）"
fi

echo "=== [3/5] 启动服务 http://127.0.0.1:$VT_PORT ==="
vibe-trading serve --port "$VT_PORT" &
SERVE_PID=$!

for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$VT_PORT/channels/status" || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    echo "    服务已就绪（HTTP $code，第 ${i} 次探测）"
    break
  fi
  sleep 2
done

echo "=== [4/5] 启动 IM 通道（最多重试 3 轮）==="
for attempt in 1 2 3; do
  echo "  --- 第 $attempt 轮 channels start ---"
  vibe-trading channels start 2>&1 | tail -3 || true
  sleep 10
done

echo "=== [5/5] 容器内自检 ==="
python - <<'PY'
import importlib.util, socket

spec = importlib.util.find_spec("lark_oapi")
print("  lark_oapi 已安装:", spec is not None)
if spec:
    try:
        import lark_oapi
        print("  lark_oapi 版本:", getattr(lark_oapi, "__version__", "unknown"))
    except Exception as exc:
        print("  import lark_oapi 失败:", type(exc).__name__, exc)

for host in ("msg-frontier.feishu.cn", "open.feishu.cn"):
    try:
        ip = socket.gethostbyname(host)
        with socket.create_connection((ip, 443), timeout=10):
            print(f"  {host} -> {ip}  TCP 443 连通 OK")
    except Exception as exc:
        print(f"  {host} 连通失败: {type(exc).__name__} {exc}")


def established_443(path):
    found = []
    try:
        with open(path, encoding="utf-8") as fh:
            next(fh)
            for line in fh:
                parts = line.split()
                if len(parts) < 4 or parts[3] != "01":
                    continue
                rem_ip, rem_port = parts[2].split(":")
                if int(rem_port, 16) != 443:
                    continue
                if len(rem_ip) == 8:
                    found.append(".".join(str(int(rem_ip[i:i + 2], 16)) for i in (6, 4, 2, 0)))
                else:
                    found.append("v6:" + rem_ip[:16])
    except FileNotFoundError:
        pass
    except Exception as exc:
        found.append(f"err:{exc}")
    return found


conns = established_443("/proc/net/tcp") + established_443("/proc/net/tcp6")
print("  已建立的 443 连接:", ", ".join(sorted(set(conns))) if conns else "无")
PY

echo "=== 进入保活（serve PID=$SERVE_PID）==="
wait "$SERVE_PID"
