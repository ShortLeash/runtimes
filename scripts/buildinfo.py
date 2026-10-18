#!/usr/bin/env python3
"""Writes a voice-engines build's BUILDINFO.json.

Usage: python3 scripts/buildinfo.py <out.json> key=value... key=@file.json...

Records the pins from scripts/voice-engines.env, plus each key=value given
(a value of @file reads that JSON file). DevKit reads msvc from it to pin
the Visual C++ Redistributable it installs to at least that version.

>>> parse_env("# note\\nA=1\\nB_2=x y\\n")
{'A': '1', 'B_2': 'x y'}
"""

import json
import pathlib
import re
import sys


def parse_env(text: str) -> dict:
    out = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
        if m:
            out[m[1]] = m[2].strip()
    return out


def main() -> None:
    dest = pathlib.Path(sys.argv[1])
    pins = parse_env((pathlib.Path(__file__).resolve().parent / "voice-engines.env").read_text())
    info = {
        "transcribe": {"version": pins["TRANSCRIBE_VERSION"], "commit": pins["TRANSCRIBE_COMMIT"],
                       "crate": f"transcribe-cpp-sys {pins['TRANSCRIBE_VERSION']}",
                       "crate_sha256": pins["TRANSCRIBE_CPP_SYS_SHA256"]},
        "llama": {"commit": pins["LLAMA_COMMIT"], "crate": f"llama-cpp-sys-2 {pins['LLAMA_CPP_SYS_VERSION']}",
                  "crate_sha256": pins["LLAMA_CPP_SYS_SHA256"]},
    }
    for arg in sys.argv[2:]:
        key, _, value = arg.partition("=")
        info[key] = json.loads(pathlib.Path(value[1:]).read_text(encoding="utf-8")) if value.startswith("@") else value
    dest.write_text(json.dumps(info, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
