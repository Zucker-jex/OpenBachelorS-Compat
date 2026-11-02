#!/data/data/com.termux/files/usr/bin/bash
#
# One-time environment setup for OpenBachelorS on Termux.
#
# Why this replaces the old pkg-heavy script:
#   * no `pkg upgrade -y`  - it can break an otherwise healthy Termux install
#   * no rust / binutils   - orjson (the only Rust dependency) is shimmed
#   * no postgresql        - psycopg is stubbed while use_db=false
#   * no tmux / aria2      - neither is needed to serve
#   * everything Python lives in .venv, so `rm -rf .venv` uninstalls it cleanly
#
# Run this from the OpenBachelorS root:
#     bash setup.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/.venv"
cd "$ROOT"

# pip 镜像，可用 OBC_PIP_INDEX 覆盖
PIP_INDEX="${OBC_PIP_INDEX:-https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple}"

# TUR (Termux User Repository) ships prebuilt wheels for packages that PyPI only
# offers as source. pydantic-core is the one that matters here: it is a Rust
# extension, and compiling it on a phone takes forever and usually looks like a
# hang.
TUR_INDEX="${OBC_TUR_INDEX:-https://termux-user-repository.github.io/pypi/}"

# The venv must NOT live inside the project: OpenBachelorS sits on /sdcard
# (Android shared storage over FUSE), which does not support symlinks, and
# `python -m venv` always creates a `lib64 -> lib` symlink. ${HOME} is on the
# app's real filesystem, so the venv goes there instead.
VENV="${OBC_VENV:-$HOME/.obc/venv}"

log() { printf '\033[1;34m[obc]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[obc]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. sanity
# ---------------------------------------------------------------------------
[ -d "$ROOT/src/openbachelors" ] || die "这里不是 OpenBachelorS 根目录：$ROOT（缺少 src/openbachelors）"
[ -f "$ROOT/requirements.txt" ] || die "缺少 $ROOT/requirements.txt"
command -v pkg >/dev/null 2>&1 || die "未检测到 pkg：请在 Termux 中运行本脚本"

log "项目目录 $ROOT"

# 开机自启写的是 ~/storage/downloads/... 这个路径，只有 termux-setup-storage
# 授权之后才存在；缺了它，登录时 bash 会直接报「No such file or directory」。
if [ ! -d "$HOME/storage/downloads" ]; then
    log "警告：$HOME/storage 还没创建，开机自启将无法工作"
    log "      请先执行 termux-setup-storage 并在弹窗里允许"
fi

# ---------------------------------------------------------------------------
# 1. 系统包：只装真正需要的
# ---------------------------------------------------------------------------
if ! command -v python >/dev/null 2>&1; then
    log "安装 python ..."
    pkg install -y python
else
    log "python 已安装：$(python --version 2>&1)"
fi

# pycryptodomex 是 pycryptodome 的孪生包（同库不同命名空间），装它就不需要
# C 编译器；overlay 会把 Cryptodome 别名成 Crypto。
CRYPTO_OK=0
python -c "import Crypto" >/dev/null 2>&1 && CRYPTO_OK=1
python -c "import Cryptodome" >/dev/null 2>&1 && CRYPTO_OK=1

if [ "$CRYPTO_OK" = "0" ]; then
    log "安装 python-pycryptodomex（免编译方案）..."
    if pkg install -y python-pycryptodomex; then
        CRYPTO_OK=1
    else
        log "pycryptodomex 装不上，稍后尝试 pip 安装 pycryptodome"
    fi
fi

# ---------------------------------------------------------------------------
# 2. pip 镜像
# ---------------------------------------------------------------------------
log "pip 镜像 -> $PIP_INDEX"
python -m pip config set global.index-url "$PIP_INDEX" >/dev/null 2>&1 \
    || log "写入 pip 配置失败，稍后显式传 --index-url"

# ---------------------------------------------------------------------------
# 3. 虚拟环境
# ---------------------------------------------------------------------------
# 清掉旧版本留下的项目内 .venv：它在 /sdcard 上建不完整，且会把搜索顺序搞乱。
if [ -d "$ROOT/.venv" ]; then
    log "清理项目内残留的 .venv（共享存储不支持符号链接）..."
    rm -rf "$ROOT/.venv"
fi

if [ -x "$VENV/bin/python" ]; then
    log "复用已有虚拟环境 $VENV"
else
    log "创建虚拟环境 $VENV（--system-site-packages 以便使用 Termux 预编译包）..."
    mkdir -p "$(dirname "$VENV")"
    python -m venv --system-site-packages "$VENV" \
        || die "创建虚拟环境失败；可用 OBC_VENV=<路径> 指定其他位置"
fi

PY="$VENV/bin/python"

# ---------------------------------------------------------------------------
# 4. 纯 Python 依赖
# ---------------------------------------------------------------------------
log "升级 pip ..."
"$PY" -m pip install --upgrade pip --index-url "$PIP_INDEX" >/dev/null 2>&1 \
    || log "pip 升级失败，继续"

# ---------------------------------------------------------------------------
# pydantic-core：最容易卡住的地方
#
# 它是 Rust 扩展，PyPI 只提供源码包，在 Termux 上编译会长时间无输出、看着像
# 死掉了。做法是先单独从 TUR 装预编译 wheel（--no-deps 跳过依赖解析，因为
# typing-extensions 已经先装好），再让主安装复用它，从而完全绕开编译。
# ---------------------------------------------------------------------------
if ! "$PY" -c "import pydantic_core" >/dev/null 2>&1; then
    log "预装 typing-extensions ..."
    "$PY" -m pip install --index-url "$PIP_INDEX" "typing-extensions>=4.16.0" \
        || log "typing-extensions 安装失败，继续"

    log "从 TUR 预装 pydantic-core（预编译 wheel，跳过依赖解析）..."
    if "$PY" -m pip install --index-url "$TUR_INDEX" --no-deps pydantic-core; then
        log "pydantic-core 已就位：$("$PY" -c 'import pydantic_core; print(pydantic_core.__version__)' 2>/dev/null || echo '?')"
    else
        log "TUR 预装失败，下一步可能触发源码编译"
    fi
fi

log "安装依赖 ..."
# --only-binary=:all: 保证不会编译任何东西：没有可用 wheel 时立刻报错，
# 而不是卡在 Rust 构建上。
if ! "$PY" -m pip install \
        --index-url "$PIP_INDEX" \
        --extra-index-url "$TUR_INDEX" \
        --only-binary=:all: \
        -r "$ROOT/requirements.txt"; then

    if [ "${OBC_ALLOW_BUILD:-0}" = "1" ]; then
        log "允许源码编译（OBC_ALLOW_BUILD=1），重新安装，可能会很慢 ..."
        "$PY" -m pip install \
            --index-url "$PIP_INDEX" \
            --extra-index-url "$TUR_INDEX" \
            -r "$ROOT/requirements.txt"
    else
        die "缺少预编译 wheel。可以重跑并加 OBC_ALLOW_BUILD=1 允许源码编译（很慢），或检查网络后重试"
    fi
fi

# 兜底：如果两个 Crypto 包都没有，试一次 pip 编译安装（需要 clang）
if ! "$PY" -c "import Crypto" >/dev/null 2>&1 && ! "$PY" -c "import Cryptodome" >/dev/null 2>&1; then
    log "尝试 pip 安装 pycryptodome（需要 clang）..."
    "$PY" -m pip install --index-url "$PIP_INDEX" pycryptodome \
        || log "pycryptodome 安装失败；战斗日志解码将不可用（其余功能正常）"
fi

# 记录实际解析到的版本，方便复现
"$PY" -m pip freeze > "$ROOT/requirements.lock"
log "依赖版本已锁定到 requirements.lock"

# ---------------------------------------------------------------------------
# 5. 自检：确认 overlay 生效、关键模块可导入
# ---------------------------------------------------------------------------
export PYTHONPATH="$ROOT/obc${PYTHONPATH:+:$PYTHONPATH}"

log "自检 ..."
"$PY" - <<'PY'
import importlib
import sys

if sys.version_info < (3, 12):
    print(f"  note  当前 Python {sys.version.split()[0]}（上游要求 3.12+，通常仍可运行）")

required = ["fastapi", "uvicorn", "httpx", "aiofiles", "multipart", "pathvalidate", "truststore"]
optional = ["orjson", "psycopg", "Crypto"]

failed = []
for name in required:
    try:
        importlib.import_module(name)
        print(f"  ok    {name}")
    except Exception as exc:
        print(f"  FAIL  {name}: {exc}")
        failed.append(name)

for name in optional:
    try:
        module = importlib.import_module(name)
        origin = getattr(module, "__file__", "?") or "?"
        print(f"  ok    {name}  ({origin})")
    except Exception as exc:
        print(f"  warn  {name}: {exc}")

if failed:
    print("\n缺少必需依赖：" + ", ".join(failed))
    print("请重新运行：bash setup.sh")
    sys.exit(1)
PY

log "环境就绪"

# ---------------------------------------------------------------------------
# 6. 启动项
#
# Termux 登录时会执行 $PREFIX/etc/termux-login.sh，客户端的 setup.sh 会往里
# 面写一行 "bash ~/storage/downloads/OpenBachelorC/start.sh" 来实现自启。
#
# 如果你只想要服务端（OBS），这里把那行客户端自启换成 OBS 的启动命令；
# 回答 N 则完全不改动该文件。
# ---------------------------------------------------------------------------
LOGIN_SCRIPT="$PREFIX/etc/termux-login.sh"
OBS_START_CMD="bash ~/storage/downloads/OpenBachelorS/start.sh"
CLIENT_START_CMDS=(
    "bash ~/storage/downloads/OpenBachelorC/start.sh"
    "bash ~/storage/downloads/OpenBachelorC-M/start.sh"
)

if [ "${OBC_SKIP_LOGIN:-0}" = "1" ]; then
    log "已跳过启动项配置（OBC_SKIP_LOGIN=1）"
else
    # `|| OBS_ONLY=""` keeps `set -e` from aborting when stdin is not a TTY
    # (e.g. `bash setup.sh | tee install.log`); an empty answer means "N".
    read -r -p "只启用 OBS（服务端），不自动启动客户端？[y/N]: " OBS_ONLY || OBS_ONLY=""

    case "$OBS_ONLY" in
        [yY] | [yY][eE][sS])
            mkdir -p "$(dirname "$LOGIN_SCRIPT")"
            touch "$LOGIN_SCRIPT"

            # 先摘掉已有的客户端自启行，避免登录时客户端和 OBS 同时启动。
            TMP_FILE="$(mktemp)"
            grep -vxF \
                -e "${CLIENT_START_CMDS[0]}" \
                -e "${CLIENT_START_CMDS[1]}" \
                "$LOGIN_SCRIPT" > "$TMP_FILE" || true
            mv "$TMP_FILE" "$LOGIN_SCRIPT"

            grep -qxF "$OBS_START_CMD" "$LOGIN_SCRIPT" || echo "$OBS_START_CMD" >> "$LOGIN_SCRIPT"

            log "已配置：Termux 登录时只启动 OBS"
            log "  $LOGIN_SCRIPT -> $OBS_START_CMD"
            ;;
        *)
            log "保持原有启动配置不变（未修改 $LOGIN_SCRIPT）"
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# 7. 完成
# ---------------------------------------------------------------------------
cat <<EOF

============================================================
 安装完成

 启动：     bash $ROOT/start.sh
 换端口：   OBC_PORT=8444 bash $ROOT/start.sh
 关热重载： OBC_RELOAD=0 bash $ROOT/start.sh

 虚拟环境： $VENV
            （放在 $HOME 下，因为 /sdcard 不支持符号链接）

 卸载：     rm -rf "$VENV"
============================================================

EOF
