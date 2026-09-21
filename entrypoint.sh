#!/usr/bin/env bash
# Vibe-Trading container entrypoint:
#   inject config -> start server -> start IM channel -> self-check -> keep alive
# NOTE: keep this file ASCII-only and LF-only (a stray non-ASCII byte can break bash parsing).
set -euo pipefail

VT_HOME="${VIBE_TRADING_HOME:-/root/.vibe-trading}"
VT_PORT="${VT_PORT:-8000}"
mkdir -p "$VT_HOME" /data/runs /data/sessions /data/swarm

echo "=== [1/5] write LLM config: $VT_HOME/.env ==="
cat > "$VT_HOME/.env" <<EOF
LANGCHAIN_PROVIDER=${LANGCHAIN_PROVIDER:-minimax}
LANGCHAIN_MODEL_NAME=${LANGCHAIN_MODEL_NAME:-MiniMax-M2.7}
LANGCHAIN_TEMPERATURE=${LANGCHAIN_TEMPERATURE:-0.0}
MINIMAX_API_KEY=${MINIMAX_API_KEY:?MINIMAX_API_KEY is required}
MINIMAX_BASE_URL=${MINIMAX_BASE_URL:-https://api.minimaxi.com/v1}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-120}
MAX_RETRIES=${MAX_RETRIES:-2}
EOF
echo "    done (MINIMAX_API_KEY length ${#MINIMAX_API_KEY})"

echo "=== [2/5] write channel config: $VT_HOME/agent.json ==="
if [ -n "${FEISHU_APP_ID:-}" ] && [ -n "${FEISHU_APP_SECRET:-}" ]; then
  VT_HOME="$VT_HOME" python - <<'PY'
import json, os, pathlib

p = pathlib.Path(os.environ["VT_HOME"]) / "agent.json"
try:
    cfg = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    cfg = {}

# Upstream FeishuConfig.model_validate() is plain pydantic: snake_case keys are required.
section = {
    "enabled": True,
    "app_id": os.environ.get("FEISHU_APP_ID", ""),
    "app_secret": os.environ.get("FEISHU_APP_SECRET", ""),
    "domain": os.environ.get("FEISHU_DOMAIN", "feishu"),
    "group_policy": "mention",
    "streaming": True,
    "reply_to_message": False,
}
allow = [s.strip() for s in os.environ.get("FEISHU_ALLOW_FROM", "").split(",") if s.strip()]
if allow:
    section["allow_from"] = allow
    print("    allow_from =", allow)

cfg.setdefault("channels", {})["feishu"] = section
p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
print("    wrote channels.feishu app_id =", section["app_id"], "enabled =", section["enabled"])
PY
else
  echo "    [warn] FEISHU_APP_ID / FEISHU_APP_SECRET missing: starting API only"
fi

echo "=== [3/5] start server on 127.0.0.1:$VT_PORT ==="
vibe-trading serve --port "$VT_PORT" &
SERVE_PID=$!

for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$VT_PORT/channels/status" || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    echo "    server ready (HTTP $code after $((i * 2))s)"
    break
  fi
  sleep 2
done

echo "=== [4/5] start IM channels ==="
for attempt in 1 2 3; do
  echo "    attempt $attempt"
  vibe-trading channels start 2>&1 | tail -2 || true
  sleep 10
done

echo "=== [5/5] self-check ==="
python - <<'PY'
import importlib.util
import socket

spec = importlib.util.find_spec("lark_oapi")
print("    lark_oapi installed:", spec is not None)
if spec:
    try:
        import lark_oapi
        print("    lark_oapi version:", getattr(lark_oapi, "__version__", "unknown"))
    except Exception as exc:
        print("    import lark_oapi failed:", type(exc).__name__, exc)

for host in ("msg-frontier.feishu.cn", "open.feishu.cn"):
    try:
        ip = socket.gethostbyname(host)
        with socket.create_connection((ip, 443), timeout=10):
            print("    %s -> %s : TCP 443 OK" % (host, ip))
    except Exception as exc:
        print("    %s : FAILED %s %s" % (host, type(exc).__name__, exc))


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
        found.append("err:%s" % exc)
    return found


conns = sorted(set(established_443("/proc/net/tcp") + established_443("/proc/net/tcp6")))
print("    established :443 conns:", ", ".join(conns) if conns else "none")
PY

echo "=== keep-alive (serve pid $SERVE_PID) ==="
wait "$SERVE_PID"
