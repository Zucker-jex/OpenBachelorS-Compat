"""OpenBachelorS Termux overlay - runtime adaptation layer.

Python's ``site`` module imports ``sitecustomize`` automatically at interpreter
start, i.e. before any application code runs. ``start.sh`` puts this directory on
PYTHONPATH, so the adaptations below apply to every interpreter launched for the
server *without editing a single file under* ``src/``.

Why this exists: the stock server needs three packages that are painful on
Termux, and none of them are really required for local play.

    orjson   Rust extension - building it pulls in a whole Rust toolchain.
    psycopg  Loads libpq even to import, and the server runs with use_db=false.
    Crypto   Needs a C build, or Termux's ``python-pycryptodomex`` twin package.

Each replacement is installed *only when the real package is missing*, so a
proper installation always takes precedence over the shim.
"""

from __future__ import annotations

import os
import sys
import types


__all__ = ["installed"]


#: Names of the shims that were actually installed in this interpreter.
installed: list[str] = []


def _warn(message: str) -> None:
    print(f"[obc] {message}", file=sys.stderr)


def _module_available(name: str) -> bool:
    """True when `name` can be imported, without importing it."""
    import importlib.util

    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        # A broken parent package raises instead of returning None.
        return False


# ---------------------------------------------------------------------------
# orjson -> json
# ---------------------------------------------------------------------------

#: Option flags the real orjson exposes. Callers may pass them through
#: ``dumps(..., option=orjson.OPT_...)``; the fallback accepts and ignores them
#: rather than dying on an AttributeError.
_ORJSON_OPTIONS = (
    "OPT_APPEND_NEWLINE",
    "OPT_INDENT_2",
    "OPT_NAIVE_UTC",
    "OPT_NON_STR_KEYS",
    "OPT_OMIT_MICROSECONDS",
    "OPT_PASSTHROUGH_DATACLASS",
    "OPT_PASSTHROUGH_DATETIME",
    "OPT_PASSTHROUGH_SUBCLASS",
    "OPT_SERIALIZE_DATACLASS",
    "OPT_SERIALIZE_NUMPY",
    "OPT_SERIALIZE_UUID",
    "OPT_SORT_KEYS",
    "OPT_STRICT_INTEGER",
    "OPT_UTC_Z",
)


def _install_orjson_shim() -> None:
    """Provides the two things the server actually uses: dumps() and loads()."""
    import json

    module = types.ModuleType("orjson")
    module.__doc__ = "Pure-Python orjson fallback (OpenBachelorS Termux overlay)."

    def loads(obj, **kwargs):
        return json.loads(obj, **kwargs)

    def dumps(obj, default=None, option=None, **kwargs):
        # orjson always emits UTF-8 (never \\uXXXX escapes) and without spaces.
        # Match that so the bytes on the wire are byte-identical.
        kwargs.setdefault("ensure_ascii", False)
        kwargs.setdefault("separators", (",", ":"))
        if default is not None:
            kwargs["default"] = default

        try:
            return json.dumps(obj, **kwargs).encode("utf-8")
        except TypeError:
            # orjson serialises datetime/Decimal natively; json does not.
            # Degrading to str keeps the request alive instead of returning 500.
            kwargs["default"] = str
            return json.dumps(obj, **kwargs).encode("utf-8")

    module.loads = loads
    module.dumps = dumps
    module.JSONDecodeError = json.JSONDecodeError

    for flag in _ORJSON_OPTIONS:
        setattr(module, flag, 0)

    sys.modules["orjson"] = module
    installed.append("orjson")


# ---------------------------------------------------------------------------
# psycopg -> lazy stub
# ---------------------------------------------------------------------------

_DB_HINT = (
    "psycopg is stubbed out by the OpenBachelorS Termux overlay because the "
    "server is running with use_db=false. Install a real psycopg (plus libpq) "
    "and set use_db to true in conf/config.json to enable the database."
)


def _install_psycopg_stub() -> None:
    """Satisfies `import psycopg` without libpq; any real use raises clearly."""

    def _unavailable(*_args, **_kwargs):
        raise RuntimeError(_DB_HINT)

    psycopg = types.ModuleType("psycopg")
    psycopg.__doc__ = "Stub installed by the OpenBachelorS Termux overlay."
    psycopg.connect = _unavailable
    psycopg.Connection = object

    # `from psycopg import sql` then sql.SQL(...) / sql.Identifier(...)
    sql_module = types.ModuleType("psycopg.sql")

    def _sql_passthrough(value=None, *_args, **_kwargs):
        return value

    for name in ("SQL", "Identifier", "Literal", "Composed", "Placeholder"):
        setattr(sql_module, name, _sql_passthrough)
    psycopg.sql = sql_module

    # `from psycopg.types.json import Json`
    types_module = types.ModuleType("psycopg.types")
    json_module = types.ModuleType("psycopg.types.json")

    class Json:
        """Tag a Python value as jsonb, exactly like psycopg's wrapper."""

        def __init__(self, obj):
            self.obj = obj

        def __repr__(self) -> str:
            return f"Json({self.obj!r})"

    json_module.Json = Json
    types_module.json = json_module
    psycopg.types = types_module

    # `from psycopg_pool import AsyncConnectionPool`
    pool_module = types.ModuleType("psycopg_pool")

    class AsyncConnectionPool:  # noqa: N801 - mirrors the real class name
        def __init__(self, *_args, **_kwargs):
            raise RuntimeError(_DB_HINT)

    pool_module.AsyncConnectionPool = AsyncConnectionPool

    sys.modules.update(
        {
            "psycopg": psycopg,
            "psycopg.sql": sql_module,
            "psycopg.types": types_module,
            "psycopg.types.json": json_module,
            "psycopg_pool": pool_module,
        }
    )
    installed.append("psycopg")


# ---------------------------------------------------------------------------
# Crypto -> Cryptodome (Termux's python-pycryptodomex)
# ---------------------------------------------------------------------------


def _install_crypto_alias() -> bool:
    """Aliases `Cryptodome` to `Crypto` when only the renamed twin is installed.

    Termux ships ``python-pycryptodomex``, which is the very same library under
    the ``Cryptodome`` namespace - so no compilation is needed, only a name.
    """
    try:
        import Cryptodome  # noqa: F401
    except ImportError:
        return False

    # Submodules resolve through the parent's __path__, so registering the
    # package object is enough for `from Crypto.Cipher import AES` to work.
    sys.modules.setdefault("Crypto", Cryptodome)
    installed.append("Crypto")
    return True


# ---------------------------------------------------------------------------


def _main() -> None:
    if os.environ.get("OBC_NO_SHIM") == "1":
        return

    try:
        if not _module_available("orjson"):
            _install_orjson_shim()
            _warn("orjson missing - using the pure-Python json fallback")

        if not _module_available("psycopg"):
            _install_psycopg_stub()
            _warn("psycopg missing - stubbed (use_db=false, no libpq needed)")

        if not _module_available("Crypto") and not _install_crypto_alias():
            _warn(
                "neither Crypto nor Cryptodome is installed - "
                "run: pkg install python-pycryptodomex"
            )
    except Exception as exc:  # never let the overlay break the interpreter
        _warn(f"overlay setup failed: {exc!r}")


_main()
