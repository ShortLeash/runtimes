#!/usr/bin/env python3
"""Decides what a run of the Build workflow builds, as GitHub step outputs.

Usage: PLATFORM=<all|macos|windows> python3 scripts/plan.py <what> <published asset names file> <PHP minor>...

<what> is the workflow input (all, php, ruby, pgvector, memcached, libwebrtc,
voice-engines, php-ext-windows or typesense), or "scheduled"
for the daily run. The daily run builds only the PHP versions whose newest
php.net release isn't on this repository's releases for both Mac
architectures yet, and nothing else. Either way it names each version's
exact release (8.4.26), looked up once here, so every runner builds the same
release rather than asking php.net itself and maybe getting another answer. PLATFORM limits a run by hand to one
platform's runners, so a test on a branch doesn't take every Mac runner.
PHP_WINDOWS_MINORS (default "8.0 8.1 8.2 8.3 8.4 8.5") names the PHP minors
php-ext-windows builds extensions for, with the pins in
scripts/php-ext-windows.env. Typesense repackages each version pinned in
scripts/typesense.env.
"""

import json
import os
import pathlib
import sys
import urllib.request

from buildinfo import parse_env

ARCHES = ("aarch64", "x86_64")
MAC_RUNNERS = ["macos-15", "macos-15-intel"]
WINDOWS_RUNNERS = ["windows-latest"]


def runners(platform: str) -> tuple:
    """The Mac runners (PHP) and all runners (Ruby, pgvector) for a platform.

    >>> runners("all")
    (['macos-15', 'macos-15-intel'], ['macos-15', 'macos-15-intel', 'windows-latest'])
    >>> runners("windows")
    ([], ['windows-latest'])
    >>> runners("macos")[1]
    ['macos-15', 'macos-15-intel']
    """
    mac = MAC_RUNNERS if platform in ("all", "macos") else []
    windows = WINDOWS_RUNNERS if platform in ("all", "windows") else []
    return mac, mac + windows


def libwebrtc_targets(what: str, platform: str) -> list:
    """The libwebrtc builds a run makes: only when asked for by name, since each
    takes an hour or two. Both Mac architectures build on the Apple silicon
    runner and both Windows ones on the x64 runner (cross-compiling).

    Windows builds use Visual Studio 2022 (windows-2022), not the newest:
    a static library built with a newer MSVC calls standard library helpers
    an older toolset's runtime doesn't have, while one built with 2022 links
    with 2022 and everything after it.

    >>> [t["arch"] for t in libwebrtc_targets("libwebrtc", "all")]
    ['aarch64', 'x86_64', 'x86_64', 'aarch64']
    >>> libwebrtc_targets("libwebrtc", "windows")[0]
    {'runner': 'windows-2022', 'os': 'windows', 'arch': 'x86_64'}
    >>> libwebrtc_targets("all", "all")
    []
    """
    if what != "libwebrtc":
        return []
    out = []
    if platform in ("all", "macos"):
        out += [{"runner": "macos-15", "os": "macos", "arch": a} for a in ("aarch64", "x86_64")]
    if platform in ("all", "windows"):
        out += [{"runner": "windows-2022", "os": "windows", "arch": a} for a in ("x86_64", "aarch64")]
    return out


def voice_engines_targets(what: str, platform: str) -> list:
    """The voice-engines builds a run makes: only when asked for by name, since
    the engines are pinned and change only with DevKit's crates. Each Mac
    architecture builds on its own runner, so the smoke tests run natively.
    Windows uses Visual Studio 2022, whose MSVC version the build records:
    DevKit installs at least that Visual C++ Redistributable.

    >>> [(t["runner"], t["arch"]) for t in voice_engines_targets("voice-engines", "all")]
    [('macos-15', 'aarch64'), ('macos-15-intel', 'x86_64'), ('windows-2022', 'x86_64')]
    >>> voice_engines_targets("voice-engines", "windows")[0]["os"]
    'windows'
    >>> voice_engines_targets("all", "all")
    []
    """
    if what != "voice-engines":
        return []
    out = []
    if platform in ("all", "macos"):
        out += [{"runner": "macos-15", "os": "macos", "arch": "aarch64"},
                {"runner": "macos-15-intel", "os": "macos", "arch": "x86_64"}]
    if platform in ("all", "windows"):
        out += [{"runner": "windows-2022", "os": "windows", "arch": "x86_64"}]
    return out


def typesense_versions(what: str, mac: list, pins: dict) -> list:
    """The Typesense versions a run repackages: each one scripts/typesense.env
    pins, for macOS only (Typesense makes no Windows build).

    >>> pins = {"TYPESENSE_VERSIONS": '"30.2 29.0"'}
    >>> typesense_versions("typesense", MAC_RUNNERS, pins), typesense_versions("all", MAC_RUNNERS, pins)
    (['30.2', '29.0'], ['30.2', '29.0'])
    >>> typesense_versions("typesense", [], pins), typesense_versions("php", MAC_RUNNERS, pins)
    ([], [])
    """
    if what not in ("all", "typesense") or not mac:
        return []
    return pins.get("TYPESENSE_VERSIONS", "").strip('"').split()


def pin(pins: dict, ext: str, key: str, minor: str) -> str:
    """One of an extension's pins in scripts/php-ext-windows.env for a PHP
    minor: <EXT>_<KEY>_PHP<XY> when it's set and not empty, else <EXT>_<KEY>,
    else "".
    php-ext-windows.ps1 reads the pins by the same rule.

    >>> pins = {"MONGODB_VERSION": "2.5.5", "MONGODB_VERSION_PHP80": "1.20.1"}
    >>> pin(pins, "mongodb", "version", "8.0"), pin(pins, "mongodb", "version", "8.4"), pin(pins, "redis", "version", "8.4")
    ('1.20.1', '2.5.5', '')
    >>> pin({"PDO_SQLSRV_TAG": "v5.13.3"}, "pdo_sqlsrv", "tag", "8.5")
    'v5.13.3'
    """
    name = f"{ext}_{key}".upper()
    return pins.get(f"{name}_PHP{minor.replace('.', '')}") or pins.get(name) or ""


def compiler(minor: str) -> str:
    """The Visual Studio windows.php.net builds a PHP minor with, as its
    releases.json names it (nts-vs16-x64, nts-vs17-x64). An extension DLL
    must be built with the same one to load.

    >>> compiler("8.3"), compiler("8.4")
    ('vs16', 'vs17')
    >>> compiler("8.10")
    'vs17'
    """
    return "vs16" if tuple(int(n) for n in minor.split(".")) <= (8, 3) else "vs17"


def ext_file(ext: str, version: str, minor: str) -> str:
    """The release file of one Windows PHP extension for one PHP minor.

    >>> ext_file("redis", "6.3.0", "8.4")
    'php-ext-redis-6.3.0-php8.4-nts-vs17-windows-x86_64.zip'
    """
    return f"php-ext-{ext}-{version}-php{minor}-nts-{compiler(minor)}-windows-x86_64.zip"


def php_ext_windows_targets(what: str, platform: str, published: set, pins: dict, minors: list) -> list:
    """The Windows PHP extension builds a run makes: only when asked for by
    name, and only the files not on this repository's releases yet. Each PHP
    minor gets two jobs, grpc alone (it takes far longer than the rest) and
    every other extension together. Visual Studio 2022 builds both
    compilers' DLLs; vs16 minors use its 14.29 toolset, which is Visual
    Studio 2019's.

    >>> p = {"PHP_EXT_WINDOWS": "redis grpc", "REDIS_VERSION": "6.3.0", "GRPC_VERSION": "1.84.0", "GRPC_SKIP": "8.0"}
    >>> [(t["minor"], t["group"], t["exts"], t["toolset"]) for t in php_ext_windows_targets("php-ext-windows", "all", set(), p, ["8.0", "8.4"])]
    [('8.0', 'main', 'redis', '14.29'), ('8.4', 'main', 'redis', ''), ('8.4', 'grpc', 'grpc', '')]
    >>> php_ext_windows_targets("php-ext-windows", "all", {ext_file("redis", "6.3.0", "8.4")}, p, ["8.4"])[0]["group"]
    'grpc'
    >>> php_ext_windows_targets("all", "all", set(), p, ["8.4"]), php_ext_windows_targets("php-ext-windows", "macos", set(), p, ["8.4"])
    ([], [])
    >>> php_ext_windows_targets("php-ext-windows", "windows", set(), {"PHP_EXT_WINDOWS": "apcu"}, ["8.4"])
    Traceback (most recent call last):
    ...
    ValueError: apcu: no version pinned for PHP 8.4 in php-ext-windows.env
    """
    if what != "php-ext-windows" or platform not in ("all", "windows"):
        return []
    out = []
    for minor in minors:
        vs = compiler(minor)
        for group in ("main", "grpc"):
            exts = []
            for ext in pins.get("PHP_EXT_WINDOWS", "").split():
                if (ext == "grpc") != (group == "grpc") or minor in pin(pins, ext, "skip", minor).split():
                    continue
                version = pin(pins, ext, "version", minor)
                if not version:
                    raise ValueError(f"{ext}: no version pinned for PHP {minor} in php-ext-windows.env")
                if ext_file(ext, version, minor) not in published:
                    exts.append(ext)
            if exts:
                out.append({"runner": "windows-2022", "minor": minor, "compiler": vs,
                            "toolset": "14.29" if vs == "vs16" else "", "group": group, "exts": " ".join(exts)})
    return out


def php_assets(version: str) -> list:
    """The files a complete PHP release has.

    >>> php_assets("8.4.26")[:2]
    ['php-8.4.26-cli-macos-aarch64.tar.gz', 'php-8.4.26-fpm-macos-aarch64.tar.gz']
    """
    return [f"php-{version}-{sapi}-macos-{arch}.tar.gz" for arch in ARCHES for sapi in ("cli", "fpm")]


def stale(published: set, latest: dict) -> list:
    """The minors whose newest release isn't published for every Mac architecture.

    >>> have = set(php_assets("8.4.26") + php_assets("8.3.30")[:2])
    >>> stale(have, {"8.4": "8.4.26", "8.5": "8.5.11", "8.3": "8.3.30"})
    ['8.5', '8.3']
    """
    return [minor for minor, version in latest.items() if not set(php_assets(version)) <= published]


def latest_releases(minors: list) -> dict:
    """The newest release of each minor, from php.net."""
    out = {}
    for minor in minors:
        url = f"https://www.php.net/releases/index.php?json&version={minor}"
        with urllib.request.urlopen(url, timeout=30) as r:
            out[minor] = json.load(r)["version"]
    return out


def main() -> None:
    what, published, minors = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3:]
    have = set(published.read_text().split()) if published.is_file() else set()
    platform = os.environ.get("PLATFORM") or "all"
    if what == "scheduled":
        latest = latest_releases(minors)
        # The exact release, so the build is the one php.net lists.
        php = [latest[m] for m in stale(have, latest)]
    else:
        php = list(latest_releases(minors).values()) if what in ("all", "php") else []
    mac, every = runners(platform)
    if not mac:
        php = []
    here = pathlib.Path(__file__).resolve().parent
    pins = parse_env((here / "php-ext-windows.env").read_text(encoding="utf-8"))
    typesense_pins = parse_env((here / "typesense.env").read_text(encoding="utf-8"))
    windows_minors = os.environ.get("PHP_WINDOWS_MINORS", "8.0 8.1 8.2 8.3 8.4 8.5").split()
    print(f"php={json.dumps(php)}")
    print(f"ruby={str(what in ('all', 'ruby')).lower()}")
    print(f"pgvector={str(what in ('all', 'pgvector')).lower()}")
    print(f"memcached={str(what in ('all', 'memcached') and bool(mac)).lower()}")
    print(f"libwebrtc={json.dumps(libwebrtc_targets(what, platform))}")
    print(f"voice_engines={json.dumps(voice_engines_targets(what, platform))}")
    print(f"php_ext_windows={json.dumps(php_ext_windows_targets(what, platform, have, pins, windows_minors))}")
    print(f"typesense={json.dumps(typesense_versions(what, mac, typesense_pins))}")
    print(f"mac_runners={json.dumps(mac)}")
    print(f"runners={json.dumps(every)}")


if __name__ == "__main__":
    main()
