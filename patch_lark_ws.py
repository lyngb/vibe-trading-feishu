"""Widen the Feishu (lark) WebSocket keepalive timeout inside the image.

Why: lark_oapi calls websockets.connect(url, proxy=None) without ping settings, so the
websockets defaults (ping_interval=20s, ping_timeout=20s) apply. On a cross-border link,
or while this process is busy running analysis, a 20s stall makes the client close the
socket with 1011 "keepalive ping timeout". Widening the timeout keeps the long connection
alive. Only connection parameters change; no business logic is touched.
"""
from __future__ import annotations

import pathlib
import site
import sys

OLD = '        return {"proxy": None}'
NEW = (
    '        return {"proxy": None, "ping_interval": 20, "ping_timeout": 90,\n'
    '                "close_timeout": 10}'
)


def main() -> int:
    target = pathlib.Path(site.getsitepackages()[0]) / "lark_oapi" / "ws" / "client.py"
    if not target.exists():
        print("lark ws client not found:", target)
        return 1
    src = target.read_text(encoding="utf-8")
    if "ping_timeout" in src:
        print("already patched")
        return 0
    if OLD not in src:
        print("anchor not found; SDK layout changed, skipping patch")
        return 1
    target.write_text(src.replace(OLD, NEW, 1), encoding="utf-8")
    print("patched:", target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
