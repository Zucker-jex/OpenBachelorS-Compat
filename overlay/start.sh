#!/data/data/com.termux/files/usr/bin/bash
#
# OpenBachelorS launcher.
#
# Resolves the project root from this file's own location, so it works the same
# whether it was started by termux-login.sh, by hand, or through a symlink.
# Everything the server needs - cwd = project root, the venv, and the overlay on
# PYTHONPATH - is arranged here, and only here.
#
# Because setup.sh registers this script in termux-login.sh, it runs on *every*
# Termux start. The interactive gate below exists so that is a choice rather
# than a surprise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kept in sync with setup.sh: the venv lives under $HOME because /sdcard does
# not support the symlink `python -m venv` needs.
VENV="${OBC_VENV:-$HOME/.obc/venv}"

LOGIN_SCRIPT="$PREFIX/etc/termux-login.sh"
AUTOSTART_CMD="bash ~/storage/downloads/OpenBachelorS/start.sh"

# ---------------------------------------------------------------------------
# 0. 存储权限
#
# Termux 的 ~/storage 只有在 termux-setup-storage 授权后才会出现，而项目就放在
# ~/storage/downloads 下。没有它，连项目目录都进不去。
# ---------------------------------------------------------------------------
if [ ! -d "$HOME/storage/downloads" ]; then
    echo "[obc] 还没有存储权限：$HOME/storage/downloads 不存在" >&2
    echo "[obc] 请先运行：termux-setup-storage" >&2
    echo "[obc] 弹窗里选择「允许」，然后重新执行本脚本" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. 交互确认
#
#   Enter / y = 启动
#   n         = 这次跳过
#   q         = 顺便从 termux-login.sh 里删掉自启项
#
# 没有 TTY（例如被其他脚本调用）时不停下来等输入，直接用 OBC_YES=1 的语义继续。
# OBC_PROMPT=1 可以强制弹出提示（在被管道/包装脚本调用时用得上）。
INTERACTIVE=0
if [ "${OBC_YES:-0}" != "1" ]; then
    if [ -t 0 ] || [ "${OBC_PROMPT:-0}" = "1" ]; then
        INTERACTIVE=1
    fi
fi

if [ "$INTERACTIVE" = "1" ]; then
    printf '\n[obc] 启动 OpenBachelorS 服务端？\n'
    printf '      Enter = 启动    n = 跳过这次    q = 取消以后的开机自启\n'
    read -r -p '[obc] > ' ANSWER || ANSWER=""

    case "$ANSWER" in
        [nN])
            echo "[obc] 已跳过"
            exit 0
            ;;
        [qQ])
            if [ -f "$LOGIN_SCRIPT" ] && grep -qxF "$AUTOSTART_CMD" "$LOGIN_SCRIPT"; then
                TMP_FILE="$(mktemp)"
                grep -vxF "$AUTOSTART_CMD" "$LOGIN_SCRIPT" > "$TMP_FILE" || true
                mv "$TMP_FILE" "$LOGIN_SCRIPT"
                echo "[obc] 已取消开机自启：$LOGIN_SCRIPT"
            else
                echo "[obc] 没有找到自启项，可能已经取消过了"
            fi
            exit 0
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# 2. 运行环境
# ---------------------------------------------------------------------------
if [ ! -x "$VENV/bin/python" ]; then
    echo "[obc] 未找到虚拟环境：$VENV" >&2
    echo "[obc] 请先运行一次：cd $ROOT && bash setup.sh" >&2
    exit 1
fi

if [ ! -f "$ROOT/start.py" ]; then
    echo "[obc] 缺少 $ROOT/start.py" >&2
    echo "[obc] 请在应用里的「OBS 服务端」卡片点一次「部署兼容层」" >&2
    exit 1
fi

# The overlay must be importable before any application code, which is what
# makes obc/sitecustomize.py effective.
export PYTHONPATH="$ROOT/obc${PYTHONPATH:+:$PYTHONPATH}"

# Every data path in the server is relative (conf/, res/, sav/, tmp/), so the
# working directory has to be the project root.
cd "$ROOT"

exec "$VENV/bin/python" "$ROOT/start.py" "$@"
