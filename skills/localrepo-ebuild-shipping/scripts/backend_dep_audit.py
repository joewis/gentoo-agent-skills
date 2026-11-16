#!/usr/bin/env python3
"""Audit a set of Python tools before packaging them: which third-party imports do
they actually have, and is each dep already in ::gentoo?

The answer decides the SHAPE of every ebuild you are about to write, so run this
BEFORE promising the bundled-wheel venv pattern. On a real set of 14 MCP servers
the direct dep set turned out to be tiny and almost entirely in-tree, so no wheel
bundle was needed at all — while the tool's own venv held 102 packages (nearly all
transitive). Reading the venv size alone would have produced the wrong plan.

Usage:
    python3 backend_dep_audit.py /path/to/tool1 /path/to/tool2 ...
    python3 backend_dep_audit.py --venv /path/to/venv /path/to/tool1

Reports, per file: third-party imports (stdlib subtracted). Then a summary of every
distinct module seen, marked in-tree / NOT in-tree / provided-by-a-non-python-package.
"""
from __future__ import annotations

import ast
import pathlib
import subprocess
import sys

TREE = pathlib.Path("/var/db/repos/gentoo")

# Imports that resolve to local sibling modules, not distributable packages.
LOCAL_HINTS = {"plugins", "config", "schema", "sources", "spam", "ingest"}


def imports_of(path: pathlib.Path) -> set[str]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8", errors="ignore"))
    except SyntaxError:
        return set()
    mods: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                mods.add(a.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            mods.add(node.module.split(".")[0])
    return mods


def in_tree(mod: str) -> str | None:
    """Return the ::gentoo CPV if this import name is packaged, else None."""
    # Module name != package name in general; try the common dev-python/<name> form
    # first, then a bounded search for any category.
    cand = TREE / "dev-python" / mod
    if cand.is_dir():
        return f"dev-python/{mod}"
    hit = subprocess.run(
        ["find", str(TREE), "-maxdepth", "2", "-type", "d", "-name", mod],
        capture_output=True, text=True,
    ).stdout.split()
    if hit:
        return hit[0].replace(str(TREE) + "/", "")
    return None


def main() -> int:
    args = sys.argv[1:]
    venv = None
    if args and args[0] == "--venv":
        venv, args = args[1], args[2:]
    if not args:
        print(__doc__)
        return 2

    stdlib = set(sys.stdlib_module_names)
    seen: set[str] = set()

    print("=" * 72)
    for target in args:
        root = pathlib.Path(target)
        files = sorted(root.rglob("*.py")) if root.is_dir() else [root]
        for f in files:
            third = sorted(
                m for m in imports_of(f) - stdlib - LOCAL_HINTS
                if not (f.parent / f"{m}.py").exists()
                and not (f.parent / m).is_dir()
            )
            if third:
                seen.update(third)
                print(f"  {str(f):<58} {', '.join(third)}")

    print("\n" + "=" * 72)
    print("DISTINCT THIRD-PARTY IMPORTS — in-tree or must-bundle?")
    print("=" * 72)
    missing = []
    for mod in sorted(seen):
        cpv = in_tree(mod)
        if cpv:
            print(f"  in tree      {mod:<28} -> {cpv}")
        else:
            missing.append(mod)
            print(f"  NOT in tree  {mod:<28} -> bundle or write an ebuild")

    if venv:
        sp = pathlib.Path(venv) / "lib"
        if sp.is_dir():
            pkgs = [p for p in next(iter(sp.glob("python*")), sp).glob("*dist-info")]
            print(f"\n  venv at {venv} holds {len(pkgs)} packages "
                  f"(most transitive — do not plan from this number alone)")

    print(f"\n  {len(seen) - len(missing)} of {len(seen)} imports already packaged.")
    if missing:
        print(f"  Only these need work: {', '.join(missing)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
