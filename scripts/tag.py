#!/usr/bin/env python3
"""Prints the release each build output belongs to, one "<tag> <file>" per line.

Usage: python3 scripts/tag.py <outputs folder>

A release holds one version of one thing for every platform: php-8.4.26 has
the CLI and php-fpm for both Mac architectures, ruby-3.4.7 has macOS and
Windows, pgvector-0.8.7 has every Postgres major on every platform.
"""

import pathlib
import re
import sys

PATTERNS = [
    re.compile(r"^(?P<tag>php-\d+\.\d+\.\d+)-(?:cli|fpm)-[a-z]+-[a-z0-9_]+\.tar\.gz$"),
    re.compile(r"^(?P<tag>ruby-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>pgvector-\d+\.\d+\.\d+)-pg\d+-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
]


def tag(name: str) -> str:
    """
    >>> tag("php-8.4.26-fpm-macos-x86_64.tar.gz")
    'php-8.4.26'
    >>> tag("ruby-3.4.7-windows-x86_64.zip")
    'ruby-3.4.7'
    >>> tag("pgvector-0.8.7-pg18-macos-aarch64.tar.gz")
    'pgvector-0.8.7'
    >>> tag("notes.txt")
    Traceback (most recent call last):
    ...
    ValueError: notes.txt: not a build output
    """
    for pattern in PATTERNS:
        m = pattern.match(name)
        if m:
            return m["tag"]
    raise ValueError(f"{name}: not a build output")


def main() -> None:
    for path in sorted(p for p in pathlib.Path(sys.argv[1]).rglob("*") if p.is_file()):
        print(tag(path.name), path)


if __name__ == "__main__":
    main()
