# OpenBachelorC-Compat

OpenBachelorS 的 **Termux 兼容层** 独立仓库。

兼容层让原版 OpenBachelorS 能在 Termux 里跑起来，而不需要改它的 `src/` 一行代码：
用 `obc/sitecustomize.py` 在解释器启动时注入垫片，把三个难以在手机上安装的依赖
替换成纯 Python 实现。

| 原始依赖 | 处理方式 | 省掉了什么 |
|---|---|---|
| `orjson`（Rust 扩展） | 用 `json` 垫片替换 | 整个 Rust 工具链 |
| `psycopg`（需要 libpq） | `use_db=false` 时打惰性桩 | PostgreSQL / libpq |
| `pycryptodome`（C 扩展） | 别名到 Termux 的 `python-pycryptodomex` | C 编译器 |

## 包内容

`obs-compat-<version>.zip` 解压后是：

```
COMPAT_VERSION       内容派生的版本号
setup.sh             一次性环境准备（venv + 依赖 + 自启）
start.sh             启动器（交互确认、存储权限检查）
start.py             启动入口（host/port/reload 走环境变量）
requirements.txt     纯 Python 依赖清单，可自行修改
obc/sitecustomize.py 运行时兼容层
```

## 怎么用

在 [OpenBachelorC](https://github.com/Zucker-jex) 安卓客户端里：

1. 「OBS 服务端」卡片 → **导入兼容层 ZIP**，选本仓库 Releases 里的 zip
2. **部署兼容层**，写进 `Download/OpenBachelorS`
3. 回 Termux 执行：

```bash
cd ~/storage/downloads/OpenBachelorS
bash setup.sh
bash start.sh
```

也可以直接把本仓库的 `overlay/` 内容复制进 OpenBachelorS 根目录，效果相同。

## 版本号

版本号取自内容哈希（路径 + 字节，SHA-256 前 12 位），不是手工维护的。
同样的文件永远得到同样的版本号，客户端据此判断「是否已是最新」。

改完 `overlay/` 里的文件，推送即可：GitHub Actions 会自动打包并发行新 tag
`compat-<version>`，版本号跟着内容变。

## 本地打包

```bash
python tools/build_compat.py
# 输出 dist/obs-compat-<version>.zip
```

## 维护提示

- `requirements.txt` 会在部署时被**保护**：客户端不会覆盖用户改过的版本，
  所以想强制更新依赖时要提醒用户手动替换。
- `start.py` 每次启动会把 `conf/config.json` 的 `redirect_asset` 纠正为 `true`，
  否则服务端会在手机上拉取游戏资源。
- 虚拟环境必须建在 `$HOME/.obc/venv`，因为 `/sdcard` 不支持符号链接。
