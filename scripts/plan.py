#!/usr/bin/env python3
"""Decides what a run of the Build workflow builds, as GitHub step outputs.

Usage: PLATFORM=<all|macos|windows> python3 scripts/plan.py <what> <published asset names file> <PHP minor>...

<what> is the workflow input (all, php, ruby, pgvector, memcached or libwebrtc), or "scheduled"
for the daily run. The daily run builds only the PHP versions whose newest
php.net release isn't on this repository's releases for both Mac
architectures yet, and nothing else. Either way it names each version's
exact release (8.4.26), looked up once here, so every runner builds the same
release rather than asking php.net itself and maybe getting another answer. PLATFORM limits a run by hand to one
platform's runners, so a test on a branch doesn't take every Mac runner.
"""

import json
import os
import pathlib
import sys
import urllib.request

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

    >>> [t["arch"] for t in libwebrtc_targets("libwebrtc", "all")]
    ['aarch64', 'x86_64', 'x86_64', 'aarch64']
    >>> libwebrtc_targets("libwebrtc", "windows")[0]
    {'runner': 'windows-latest', 'os': 'windows', 'arch': 'x86_64'}
    >>> libwebrtc_targets("all", "all")
    []
    """
    if what != "libwebrtc":
        return []
    out = []
    if platform in ("all", "macos"):
        out += [{"runner": "macos-15", "os": "macos", "arch": a} for a in ("aarch64", "x86_64")]
    if platform in ("all", "windows"):
        out += [{"runner": "windows-latest", "os": "windows", "arch": a} for a in ("x86_64", "aarch64")]
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
    if what == "scheduled":
        have = set(published.read_text().split()) if published.is_file() else set()
        latest = latest_releases(minors)
        # The exact release, so the build is the one php.net lists.
        php = [latest[m] for m in stale(have, latest)]
    else:
        php = list(latest_releases(minors).values()) if what in ("all", "php") else []
    mac, every = runners(os.environ.get("PLATFORM") or "all")
    if not mac:
        php = []
    print(f"php={json.dumps(php)}")
    print(f"ruby={str(what in ('all', 'ruby')).lower()}")
    print(f"pgvector={str(what in ('all', 'pgvector')).lower()}")
    print(f"memcached={str(what in ('all', 'memcached') and bool(mac)).lower()}")
    print(f"libwebrtc={json.dumps(libwebrtc_targets(what, os.environ.get('PLATFORM') or 'all'))}")
    print(f"mac_runners={json.dumps(mac)}")
    print(f"runners={json.dumps(every)}")


if __name__ == "__main__":
    main()
