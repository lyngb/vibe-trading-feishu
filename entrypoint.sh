#!/usr/bin/env bash
# Vibe-Trading 瀹瑰櫒鍏ュ彛锛氭敞鍏ラ厤缃?鈫?璧锋湇鍔?鈫?璧烽涔﹂€氶亾 鈫?鑷 鈫?淇濇椿
set -euo pipefail

VT_HOME="${VIBE_TRADING_HOME:-/root/.vibe-trading}"
VT_PORT="${VT_PORT:-8000}"
mkdir -p "$VT_HOME" /data/runs /data/sessions /data/swarm

echo "=== [1/5] 鍐欏叆 LLM 閰嶇疆 $VT_HOME/.env ==="
cat > "$VT_HOME/.env" <<EOF
LANGCHAIN_PROVIDER=${LANGCHAIN_PROVIDER:-minimax}
LANGCHAIN_MODEL_NAME=${LANGCHAIN_MODEL_NAME:-MiniMax-M2.7}
LANGCHAIN_TEMPERATURE=${LANGCHAIN_TEMPERATURE:-0.0}
MINIMAX_API_KEY=${MINIMAX_API_KEY:?MINIMAX_API_KEY is required}
MINIMAX_BASE_URL=${MINIMAX_BASE_URL:-https://api.minimaxi.com/v1}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-120}
MAX_RETRIES=${MAX_RETRIES:-2}
EOF
echo "    宸插啓鍏ワ紙MINIMAX_API_KEY 闀垮害 ${#MINIMAX_API_KEY}锛?

echo "=== [2/5] 鍐欏叆閫氶亾閰嶇疆 $VT_HOME/agent.json ==="
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
# 娉ㄦ剰锛氫笂娓?FeishuConfig.model_validate 鏄８ pydantic锛屽繀椤荤敤 snake_case
section = {
    "enabled": True,
    "app_id": os.environ["FEISHU_APP_ID"],
    "app_secret": os.environ["FEISHU_APP_SECRET"],
    "domain": os.environ.get("FEISHU_DOMAIN", "feishu"),
    "group_policy": "mention",
    "streaming": True,
    "reply_to_message": False,
}
# 鐧藉悕鍗曪細鍏嶉厤瀵圭洿鎺ュ彲鐢紙閫楀彿鍒嗛殧鐨?open_id锛?allow = [s.strip() for s in os.environ.get("FEISHU_ALLOW_FROM", "").split(",") if s.strip()]
if allow:
    section["allow_from"] = allow
    print("    鐧藉悕鍗?allow_from =", allow)
cfg.setdefault("channels", {})["feishu"] = section
p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
print("    宸插啓鍏?channels.feishu =", os.environ["FEISHU_APP_ID"])
PY
else
  echo "    [warn] 鏈彁渚?FEISHU_APP_ID/SECRET锛岃烦杩囷紙鍙捣 API锛屼笉璧烽涔︼級"
fi

echo "=== [3/5] 鍚姩鏈嶅姟 http://127.0.0.1:$VT_PORT ==="
vibe-trading serve --port "$VT_PORT" &
SERVE_PID=$!

for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$VT_PORT/channels/status" || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    echo "    鏈嶅姟宸插氨缁紙HTTP $code锛岀 ${i} 娆℃帰娴嬶級"
    break
  fi
  sleep 2
done

echo "=== [4/5] 鍚姩 IM 閫氶亾锛堟渶澶氶噸璇?3 杞級==="
for attempt in 1 2 3; do
  echo "  --- 绗?$attempt 杞?channels start ---"
  vibe-trading channels start 2>&1 | tail -3 || true
  sleep 10
done

echo "=== [5/5] 瀹瑰櫒鍐呰嚜妫€ ==="
python - <<'PY'
import importlib.util, socket

spec = importlib.util.find_spec("lark_oapi")
print("  lark_oapi 宸插畨瑁?", spec is not None)
if spec:
    try:
        import lark_oapi
        print("  lark_oapi 鐗堟湰:", getattr(lark_oapi, "__version__", "unknown"))
    except Exception as exc:
        print("  import lark_oapi 澶辫触:", type(exc).__name__, exc)

for host in ("msg-frontier.feishu.cn", "open.feishu.cn"):
    try:
        ip = socket.gethostbyname(host)
        with socket.create_connection((ip, 443), timeout=10):
            print(f"  {host} -> {ip}  TCP 443 杩為€?OK")
    except Exception as exc:
        print(f"  {host} 杩為€氬け璐? {type(exc).__name__} {exc}")


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
print("  宸插缓绔嬬殑 443 杩炴帴:", ", ".join(sorted(set(conns))) if conns else "鏃?)
PY

echo "=== 杩涘叆淇濇椿锛坰erve PID=$SERVE_PID锛?=="
wait "$SERVE_PID"
