#!/usr/bin/env python3
"""Smoke-tests a voice-engines package on the CPU.

Usage: python3 scripts/engine_smoke.py --pkg <dir> --dr-wav <dir> --transcribe-model <gguf>
           --llama-model <gguf> --template <jinja> --fixtures <dir> --results <json>
           [--cc "cc ..." --cxx "c++ ..." | --msvc] [--run-prefix "arch -x86_64"]

Compiles scripts/smoke/transcribe_smoke.c and scripts/smoke/llama_smoke.cpp
against the package, with link lines built from nothing but
transcribe/lib/transcribe-link.json and llama/lib/llama-link.json (what
DevKit's build reads), then runs them: transcribe.cpp must transcribe
fixtures/en.wav close to its reference text, and llama.cpp must generate,
render a chat template with a tool and parse a tool call. Writes what it saw
to --results.
"""

import argparse
import json
import os
import pathlib
import shlex
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from speech_check import fixture_error_rate  # noqa: E402

SMOKE = pathlib.Path(__file__).resolve().parent / "smoke"
# whisper-tiny is a weak model; this catches a broken engine, not a weak one.
MAX_ERROR = 0.4


def unix_command(compiler: str, source: pathlib.Path, prefix: pathlib.Path, manifest: dict,
                 includes: list, out: pathlib.Path) -> list:
    """A cc/c++ link line from a manifest.

    >>> m = {"include_dir": "include", "lib_dir": "lib", "libraries": ["a", "b"], "system_libs": ["c++"],
    ...      "frameworks": ["Metal"], "shared": False}
    >>> " ".join(unix_command("cc -arch arm64", pathlib.Path("t.c"), pathlib.Path("/p"), m, [], pathlib.Path("t")))
    'cc -arch arm64 t.c -o t -I/p/include -L/p/lib -la -lb -lc++ -framework Metal'
    """
    dirs = manifest.get("include_dirs") or [manifest["include_dir"]]
    cmd = shlex.split(compiler) + [str(source), "-o", str(out)]
    cmd += [f"-I{prefix / d}" for d in dirs] + [f"-I{d}" for d in includes]
    cmd += manifest.get("link_flags", [])
    cmd += [f"-L{prefix / manifest['lib_dir']}"]
    cmd += [f"-l{n}" for n in manifest["libraries"]] + manifest.get("library_paths", [])
    cmd += [f"-l{n}" for n in manifest["system_libs"]]
    for fw in manifest.get("frameworks", []):
        cmd += ["-framework", fw]
    if manifest["shared"]:
        cmd += [f"-Wl,-rpath,{prefix / manifest['lib_dir']}"]
    return cmd


def msvc_command(source: pathlib.Path, prefix: pathlib.Path, manifest: dict, includes: list,
                 out: pathlib.Path) -> list:
    """A cl.exe line from a manifest, with the dynamic C runtime (/MD) the
    package is built with.

    >>> m = {"include_dir": "include", "lib_dir": "lib", "libraries": ["a"], "system_libs": ["ws2_32"], "shared": True}
    >>> " ".join(msvc_command(pathlib.Path("t.cpp"), pathlib.Path("p"), m, [], pathlib.Path("t.exe")))
    'cl /nologo /O2 /MD /EHsc /std:c++17 /utf-8 t.cpp /Ip\\\\include /Fe:t.exe /link /LIBPATH:p\\\\lib a.lib ws2_32.lib'
    """
    dirs = manifest.get("include_dirs") or [manifest["include_dir"]]
    cmd = ["cl", "/nologo", "/O2", "/MD", "/EHsc", "/std:c++17", "/utf-8", str(source)]
    cmd += [f"/I{pathlib.PureWindowsPath(prefix, d)}" for d in dirs] + [f"/I{d}" for d in includes]
    cmd += [f"/Fe:{out}", "/link", f"/LIBPATH:{pathlib.PureWindowsPath(prefix, manifest['lib_dir'])}"]
    cmd += [f"{n}.lib" for n in manifest["libraries"]] + [f"{n}.lib" for n in manifest["system_libs"]]
    return cmd


def build(args, name: str, source: pathlib.Path, prefix: pathlib.Path, manifest_name: str, includes: list,
          cxx: bool) -> pathlib.Path:
    manifest = json.loads((prefix / "lib" / manifest_name).read_text())
    out = pathlib.Path(args.results).parent / (name + (".exe" if args.msvc else ""))
    if args.msvc:
        cmd = msvc_command(source, prefix, manifest, includes, out)
    else:
        compiler = args.cxx + " -std=c++17" if cxx else args.cc
        cmd = unix_command(compiler, source, prefix, manifest, includes, out)
    print("compile:", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, cwd=out.parent)
    return out


def run(args, cmd: list, prefix_dirs: list) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    if args.msvc:
        # The engines' DLLs, found the way Windows finds an exe's own.
        env["PATH"] = os.pathsep.join(str(d) for d in prefix_dirs) + os.pathsep + env["PATH"]
    full = shlex.split(args.run_prefix) + cmd if args.run_prefix else cmd
    print("run:", " ".join(str(c) for c in full), flush=True)
    res = subprocess.run([str(c) for c in full], capture_output=True, text=True, encoding="utf-8", env=env,
                         timeout=600)
    sys.stdout.write(res.stdout)
    sys.stderr.write(res.stderr)
    if res.returncode != 0:
        sys.exit(f"{cmd[0]} failed with exit code {res.returncode}")
    return res


def module_dir(prefix: pathlib.Path, manifest_name: str) -> str:
    manifest = json.loads((prefix / "lib" / manifest_name).read_text())
    return str(prefix / manifest["module_dir"]) if manifest.get("backend_dl") else "-"


def main() -> None:
    p = argparse.ArgumentParser()
    for flag in ("--pkg", "--dr-wav", "--transcribe-model", "--llama-model", "--template", "--fixtures", "--results"):
        p.add_argument(flag, required=True)
    p.add_argument("--cc", default="cc")
    p.add_argument("--cxx", default="c++")
    p.add_argument("--msvc", action="store_true")
    p.add_argument("--run-prefix", default="")
    args = p.parse_args()
    pkg = pathlib.Path(args.pkg).resolve()
    pathlib.Path(args.results).parent.mkdir(parents=True, exist_ok=True)
    fixtures = json.loads((pathlib.Path(args.fixtures) / "fixtures.json").read_text())["audio"]
    results = {"run_under": args.run_prefix or None}

    t = pkg / "transcribe"
    exe = build(args, "transcribe_smoke", SMOKE / "transcribe_smoke.c", t, "transcribe-link.json", [args.dr_wav], False)
    wav = pathlib.Path(args.fixtures) / "en.wav"
    res = run(args, [exe, module_dir(t, "transcribe-link.json"), args.transcribe_model, wav], [t / "bin", t / "lib"])
    text = res.stdout.strip()
    err = fixture_error_rate(fixtures["en.wav"], text)
    backend = [line.split(" ", 1)[1] for line in res.stderr.splitlines() if line.startswith("backend ")]
    devices = [line.split(" ", 1)[1] for line in res.stderr.splitlines() if line.startswith("device ")]
    results["transcribe"] = {"model": pathlib.Path(args.transcribe_model).name, "audio": wav.name, "text": text,
                             "error_rate": round(err, 3), "backend": backend[-1] if backend else None,
                             "devices": devices}
    print(f"transcribe: error rate {err:.3f} on {wav.name}")
    if err > MAX_ERROR:
        sys.exit(f"transcribe.cpp's transcript is too far from the reference ({err:.3f} > {MAX_ERROR})")

    l = pkg / "llama"
    exe = build(args, "llama_smoke", SMOKE / "llama_smoke.cpp", l, "llama-link.json", [], True)
    res = run(args, [exe, module_dir(l, "llama-link.json"), args.llama_model, args.template], [l / "bin", l / "lib"])
    if "llama-smoke ok" not in res.stdout:
        sys.exit("llama_smoke didn't finish")
    results["llama"] = {"model": pathlib.Path(args.llama_model).name, "template": pathlib.Path(args.template).name,
                        "output": res.stdout.strip().splitlines(),
                        "devices": [line.split(" ", 1)[1] for line in res.stderr.splitlines() if line.startswith("device ")]}
    pathlib.Path(args.results).write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
    print("engine smoke tests passed")


if __name__ == "__main__":
    main()
