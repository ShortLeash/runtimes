#!/usr/bin/env python3
"""Completes a llama.cpp install prefix for DevKit and writes lib/llama-link.json.

Usage: python3 scripts/llama_manifest.py <llama.cpp source> <build dir> <prefix> <macos|windows> <metal ON|OFF> [--shared]

`cmake --install` leaves out two libraries llama.cpp's common library needs
(llama-common-base and cpp-httplib) and every header of common, which
DevKit's chat shim includes (chat.h, common.h and what they include). This
copies them in, then writes a link manifest in the shape transcribe.cpp's
lib/transcribe-link.json has, so one reader in DevKit's build handles both:

    libraries      link order, most dependent first
    system_libs    and frameworks: what the libraries need from the system
    backend_dl     whether ggml's backends are loadable modules in module_dir

Apple builds list CoreGraphics: Metal only gives a process its default GPU
when it links CoreGraphics.

>>> link_order(["ggml-base", "llama", "ggml-cpu", "llama-common", "ggml", "cpp-httplib", "llama-common-base", "ggml-metal"])
['llama-common', 'llama-common-base', 'cpp-httplib', 'llama', 'ggml', 'ggml-metal', 'ggml-cpu', 'ggml-base']
"""

import json
import pathlib
import re
import shutil
import subprocess
import sys

ORDER = ["llama-common", "llama-common-base", "cpp-httplib", "llama", "ggml"]
LAST = ["ggml-cpu", "ggml-base"]


def link_order(names: list) -> list:
    """Most dependent first: common, llama, ggml, its GPU backends, then CPU and base."""
    head = [n for n in ORDER if n in names]
    tail = [n for n in LAST if n in names]
    middle = sorted(n for n in names if n not in head and n not in tail)
    return head + middle + tail


def lib_name(path: pathlib.Path) -> str:
    """
    >>> lib_name(pathlib.Path("libggml-cpu.a")), lib_name(pathlib.Path("llama.lib"))
    ('ggml-cpu', 'llama')
    """
    name = path.name
    for suffix in (".a", ".lib", ".dylib"):
        if name.endswith(suffix):
            name = name[: -len(suffix)]
    return name[3:] if name.startswith("lib") else name


def main() -> None:
    src, build, prefix = (pathlib.Path(p) for p in sys.argv[1:4])
    platform, metal = sys.argv[4], sys.argv[5] == "ON"
    shared = "--shared" in sys.argv[6:]
    lib = prefix / "lib"
    ext = ".lib" if platform == "windows" else ".a"

    # The static libraries cmake --install leaves out (on Windows these two
    # stay static even when llama.cpp's own libraries are DLLs).
    for name in ("llama-common-base", "cpp-httplib"):
        stem = name if platform == "windows" else f"lib{name}"
        found = [p for p in build.rglob(stem + ext) if "CMakeFiles" not in p.parts]
        if not found:
            sys.exit(f"{name}{ext} wasn't built")
        shutil.copy2(found[0], lib / found[0].name)

    # common's headers, keeping their folders (jinja/, parsers/).
    include = prefix / "include" / "common"
    for header in (src / "common").rglob("*"):
        if header.suffix in (".h", ".hpp"):
            dest = include / header.relative_to(src / "common")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(header, dest)

    names = sorted({lib_name(p) for p in lib.iterdir() if p.suffix in (".a", ".lib")})
    modules = sorted(p.name for p in (prefix / "bin").glob("ggml-*.dll") if p.name != "ggml-base.dll") if platform == "windows" else []
    # ggml-cpu-haswell.dll and its siblings are one CPU backend, picked at run time.
    backends = sorted({n[len("ggml-"):] for n in names if n.startswith("ggml-") and n != "ggml-base"}
                      | {m[len("ggml-"):-len(".dll")].split("-")[0] for m in modules})
    if platform == "windows":
        system_libs, frameworks = ["ws2_32", "advapi32"], []
    else:
        system_libs = ["c++"]
        frameworks = ["Accelerate", "Foundation"] + (["Metal", "MetalKit", "CoreGraphics"] if metal else [])
    commit = subprocess.run(["git", "-C", str(src), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    version = re.search(r"Version: (\S+)", (lib / "pkgconfig" / "llama.pc").read_text(encoding="utf-8"))
    manifest = {
        "commit": commit,
        "version": version[1] if version else None,
        "shared": shared,
        "backend_dl": bool(modules),
        "module_dir": "bin" if modules else None,
        "modules": modules,
        "backends": backends,
        "metal_embed": metal,
        "include_dirs": ["include", "include/common"],
        "lib_dir": "lib",
        "libraries": link_order(names),
        "system_libs": system_libs,
        "frameworks": frameworks,
    }
    (lib / "llama-link.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
