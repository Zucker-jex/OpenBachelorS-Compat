"""OpenBachelorS entry point for Termux.

Same uvicorn target as the stock ``start.py``, but host/port/reload come from
the environment so this file never has to be edited per device.

Environment variables:
    OBC_HOST        listen address           (default 0.0.0.0)
    OBC_PORT        listen port              (default 8443)
    OBC_RELOAD      1 = reload on src change (default 1)
    OBC_LOG_LEVEL   uvicorn log level        (default info)

Run it through ``start.sh``: the server resolves every data path relative to
the working directory, so the launcher must ``cd`` to the project root first.
"""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path


def _ensure_redirect_asset(project_root: Path) -> None:
    """Force `redirect_asset` on before the server reads its config.

    The shipped conf/config.json has it **disabled**, which makes
    OpenBachelorS download and cache the game's assets itself - hundreds of
    megabytes pulled onto the phone for no reason. Enabling it makes the
    server redirect the client to the real asset CDN instead.

    Done here rather than by editing the shipped file so it survives the
    "overwrite" package updates the app performs.
    """
    config_path = project_root / "conf" / "config.json"
    if not config_path.is_file():
        return

    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return

    if data.get("redirect_asset") is True:
        return

    data["redirect_asset"] = True
    try:
        config_path.write_text(
            json.dumps(data, ensure_ascii=False, indent=4) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        print(f"[obc] 无法写入 conf/config.json：{exc}", file=sys.stderr)
        return

    print("[obc] 已把 redirect_asset 设为 true（否则会在手机上拉取资源）")


def _env_str(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        print(f"[obc] {name}={raw!r} 不是整数，回退到 {default}", file=sys.stderr)
        return default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw not in {"0", "false", "no", "off"}


def _port_is_free(host: str, port: int) -> bool:
    """Best-effort check so a port clash is reported in plain language."""
    probe_host = "127.0.0.1" if host in {"0.0.0.0", "::", ""} else host
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((probe_host, port))
        except OSError:
            return False
    return True


def main() -> int:
    project_root = Path(__file__).resolve().parent
    src_path = project_root / "src"

    if not src_path.is_dir():
        print(
            f"[obc] 没找到 {src_path}\n"
            "      请确认 start.py 放在 OpenBachelorS 根目录下。",
            file=sys.stderr,
        )
        return 1

    config_file = project_root / "conf" / "config.json"
    if not config_file.is_file():
        print(f"[obc] 警告：{config_file} 不存在，服务端可能无法启动", file=sys.stderr)

    if str(src_path) not in sys.path:
        sys.path.insert(0, str(src_path))

    # Must happen before uvicorn imports openbachelors.app, which reads the
    # config at import time.
    _ensure_redirect_asset(project_root)

    host = _env_str("OBC_HOST", "0.0.0.0")
    port = _env_int("OBC_PORT", 8443)
    reload_enabled = _env_bool("OBC_RELOAD", True)
    log_level = _env_str("OBC_LOG_LEVEL", "info")

    if not _port_is_free(host, port):
        print(
            f"[obc] 端口 {port} 已被占用。\n"
            "      可能是另一个 OBS 实例还在运行；\n"
            "      也可以换端口启动：OBC_PORT=8444 bash start.sh",
            file=sys.stderr,
        )
        return 2

    print(f"[obc] OpenBachelorS -> http://{host}:{port}")
    print(f"[obc] 项目目录 {project_root}")
    print(f"[obc] reload={'on' if reload_enabled else 'off'}  log={log_level}")

    import uvicorn

    uvicorn.run(
        "openbachelors.app:app",
        host=host,
        port=port,
        reload=reload_enabled,
        log_level=log_level,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
