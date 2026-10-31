#!/usr/bin/env python3
"""
为 vendored esptool 应用 Python 3.9 兼容补丁。

背景
----
App 把 esptool 源码打包进 Resources/esptool_deps/，并通过系统自带的
`/usr/bin/python3` 运行（macOS 保证存在的解释器）。但 macOS 自带的
python3 目前为 3.9.x，而 esptool 5.6.0 使用了 Python 3.10+ 的特性：

1. PEP604 联合类型注解 `str | None`，且**没有** `from __future__ import
   annotations`。这类注解在函数定义时会被求值，在 3.9 上直接抛
   `TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'`。
2. `typing.TypeAlias` 是 3.10 才引入的，3.9 上 `from typing import
   TypeAlias` 会 ImportError。

本脚本为这两处加上兼容写法，使 esptool 能在 3.9 上运行。

幂等：重复执行不会重复插入或破坏文件。

用法
----
    python3 ESP32Firmware/Resources/esptool_deps/patch_python39.py

修改 vendored 第三方源码后，务必同步更新本脚本并重新执行。
"""

import pathlib
import re
import sys

# 需要打补丁的第三方包目录（相对 esptool_deps）
TARGET_PACKAGES = ["esptool", "esp_pylib"]

FUTURE_IMPORT = "from __future__ import annotations"


def add_future_import(source: str) -> tuple[str, bool]:
    """在模块 docstring 之后插入 `from __future__ import annotations`。

    PEP 563 会让所有注解变成字符串，PEP604 联合类型便不再在定义时求值，
    从而在 3.9 上可用。
    """
    if FUTURE_IMPORT in source:
        return source, False

    # 插入点：文件头部的注释块与 docstring 之后；都没有则放在最前面。
    match = re.search(r'^(?:#.*\n)*("""(?:.|\n)*?"""|\'\'\'(?:.|\n)*?\'\'\')\s*\n', source, re.M)
    index = match.end() if match else 0
    return source[:index] + f"\n{FUTURE_IMPORT}\n" + source[index:], True


def patch_util_module(source: str) -> tuple[str, bool]:
    """替换 `typing.TypeAlias` 用法，改用 3.9 可用的 `typing.Union`。

    `ImageSource` 是模块级运行时类型别名，赋值语句右侧会被立即求值，
    因此不能只靠 `from __future__ import annotations`（那只影响注解）。
    """
    patched = source.replace(
        "from typing import IO, TypeAlias",
        "from typing import IO, Union",
    ).replace(
        "ImageSource: TypeAlias = str | bytes | IO[bytes]",
        "ImageSource = Union[str, bytes, IO[bytes]]",
    )
    return patched, patched != source


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent
    changed_files = []

    for package in TARGET_PACKAGES:
        package_dir = root / package
        if not package_dir.is_dir():
            print(f"[警告] 目录不存在，跳过: {package_dir}", file=sys.stderr)
            continue

        for py_file in sorted(package_dir.rglob("*.py")):
            if "__pycache__" in py_file.parts:
                continue

            source = py_file.read_text(encoding="utf-8")
            updated = source
            file_changed = False

            updated, changed = add_future_import(updated)
            file_changed |= changed

            if py_file.name == "util.py":
                updated, changed = patch_util_module(updated)
                file_changed |= changed

            if file_changed:
                py_file.write_text(updated, encoding="utf-8")
                changed_files.append(str(py_file.relative_to(root)))

    if changed_files:
        print(f"[完成] 已修补 {len(changed_files)} 个文件:")
        for path in changed_files:
            print(f"  - {path}")
    else:
        print("[完成] 无需修补（已是最新状态）")

    return 0


if __name__ == "__main__":
    sys.exit(main())
