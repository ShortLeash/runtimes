#!/usr/bin/env python3
"""Decides what a run of the Build workflow builds, as GitHub step outputs.

Usage: python3 scripts/plan.py <what> <published asset names file> <PHP minor>...

<what> is the workflow input (all, php, ruby or pgvector), or "scheduled"
for the daily run. The daily run builds only the PHP versions whose newest
php.net release isn't on this repository's releases for both Mac
architectures yet, and nothing else; it names the exact release (8.4.26)
where a run by hand names the minor.
"""

import json
import pathlib
import sys
import urllib.request

ARCHES = ("aarch64", "x86_64")


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
        php = minors if what in ("all", "php") else []
    print(f"php={json.dumps(php)}")
    print(f"ruby={str(what in ('all', 'ruby')).lower()}")
    print(f"pgvector={str(what in ('all', 'pgvector')).lower()}")


if __name__ == "__main__":
    main()
