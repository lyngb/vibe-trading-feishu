# Vibe-Trading 飞书 bot —— VPS 部署包

让 `005-Vibe-trading-HKUDS` 24 小时在线（不依赖你本机开机）。

## 目标架构

```
飞书 App (005-Vibe-trading-HKUDS)
   │  ① 长连接 WebSocket（无需公网域名 / 回调地址）
   ▼
VPS:148.230.88.192 (Ubuntu 24.04 + Coolify)
   └─ docker 容器 vibe-trading
        ├─ vibe-trading serve --port 8000   （API + 通道宿主）
        ├─ channels start → feishu 长连接
        ├─ 卷 ./data/vibe-trading → /root/.vibe-trading （.env / agent.json / sessions.db / pairing.json）
        └─ 卷 ./data/runtime     → /data             （runs / sessions / swarm 产物）
```

## ⚠️ 部署前必读

1. **同一个飞书 App 只能有一条长连接在工作**。部署 VPS 前，先停掉本机服务
   （`停止飞书bot.ps1`），否则两条连接会抢消息，表现为"有时回有时不回"。
2. 上游把运行时目录写死在 `site-packages`（`src/agent/loop.py` 的 `RUNS_DIR`），
   镜像里已软链到 `/data`，所以**不要删 Dockerfile 里那段 `ln -s`**。
3. `agent.json` 的 `channels.feishu` 必须是 **snake_case**（`app_id`/`app_secret`）；
   entrypoint 已经按这个写，别改成 camelCase。

## 方案 A · Coolify 纳管（与现有 DSH 桥一致，推荐）

1. 把这整个 `vps-deploy/` 目录推到仓库（如 `lyngb/vibe-trading-deploy`）。
2. Coolify → 项目 → **+ New Resource → Docker Compose**（选该仓库 / 该目录）。
3. Environment Variables 里逐条填（或粘贴 `.env` 内容）：
   `MINIMAX_API_KEY`、`MINIMAX_BASE_URL`、`LANGCHAIN_PROVIDER`、`LANGCHAIN_MODEL_NAME`、
   `FEISHU_APP_ID`、`FEISHU_APP_SECRET`、`FEISHU_DOMAIN`、`TZ`。
4. 部署后看 Logs，应出现：
   `[Lark] [INFO] connected to wss://msg-frontier.feishu.cn/ws/v2 ...`
5. 端口不需要对外开放（长连接是出站），保持 `127.0.0.1:8000` 即可。

## 方案 B · 纯 docker compose（不经过 Coolify）

```bash
ssh root@148.230.88.192
mkdir -p /opt/vibe-trading && cd /opt/vibe-trading
# 上传 Dockerfile / entrypoint.sh / docker-compose.yml / .env 到这里
cp .env.example .env && vi .env          # 填真实值
chmod 600 .env
docker compose up -d --build
docker compose logs -f --tail=50
```

## 验证清单

| 检查 | 命令 | 期望 |
| --- | --- | --- |
| 容器在跑 | `docker ps \| grep vibe-trading` | Up (healthy) |
| 飞书已连 | `docker logs vibe-trading 2>&1 \| grep -i lark` | `connected to wss://msg-frontier.feishu.cn` |
| 通道状态 | `docker exec vibe-trading vibe-trading channels status` | feishu = configured/enabled/loaded |
| 新用户授权 | `docker exec -it vibe-trading vibe-trading channels pairing approve <码>` | Approved |
| 端到端 | 飞书里发一条 A 股问题 | 30~90 秒内回复 |

> 注意：`channels status` 表里 `running` 列上游有 bug，恒显示 `no`。
> 判断是否真的连通，用**日志里的 `[Lark] connected`** 或
> `docker exec vibe-trading netstat -tnp | grep 443`。

## 日常运维

```bash
docker compose logs -f --tail=100        # 看日志
docker compose restart                   # 重启（会重连飞书）
docker compose pull && docker compose up -d --build   # 升级 vibe-trading-ai
docker exec -it vibe-trading vibe-trading --list      # 看历史 run
```

数据都在 `./data/`，升级/重建容器不丢。备份直接打包这个目录。

## 安全

- `.env` 权限 600，不要提交 git；飞书 `app_secret` 只以环境变量形式存在
- 8000 端口只绑 127.0.0.1（本包默认如此）
- 飞书侧默认 `group_policy=mention`，群聊需 @ 机器人才响应
