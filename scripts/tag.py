#!/usr/bin/env python3
"""Prints the release each build output belongs to, one "<tag> <file>" per line.

Usage: python3 scripts/tag.py <outputs folder>

A release holds one version of one thing for every platform: php-8.4.26 has
the CLI and php-fpm for both Mac architectures, ruby-3.4.7 has macOS and
Windows, pgvector-0.8.7 has every Postgres major on every platform, memcached-1.6.45
has both Mac architectures, libwebrtc-0.3.49 has every Mac and Windows
architecture, and voice-engines-0.4.0-0.1.160 (named after the
transcribe-cpp-sys and llama-cpp-sys-2 crates) has both Mac architectures and
Windows x64. php-ext-redis-6.3.0 has one Windows x64 DLL for each PHP minor,
built with the compiler that minor's official PHP uses. typesense-30.2 has
Typesense's own build for both Mac architectures, repackaged, and the
source it was built from (typesense-30.2-sources.tar.gz).
"""

import pathlib
import re
import sys

PATTERNS = [
    re.compile(r"^(?P<tag>php-\d+\.\d+\.\d+)-(?:cli|fpm)-[a-z]+-[a-z0-9_]+\.tar\.gz$"),
    re.compile(r"^(?P<tag>ruby-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>pgvector-\d+\.\d+\.\d+)-pg\d+-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>memcached-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.tar\.gz$"),
    re.compile(r"^(?P<tag>libwebrtc-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>voice-engines-\d+\.\d+\.\d+-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>php-ext-[a-z0-9_]+-\d+\.\d+\.\d+)-php\d+\.\d+-nts-vs\d+-windows-x86_64\.zip$"),
    re.compile(r"^(?P<tag>typesense-\d+\.\d+)-(?:macos-[a-z0-9_]+\.tar\.gz|sources\.tar\.gz)$"),
]


def tag(name: str) -> str:
    """
    >>> tag("php-8.4.26-fpm-macos-x86_64.tar.gz")
    'php-8.4.26'
    >>> tag("ruby-3.4.7-windows-x86_64.zip")
    'ruby-3.4.7'
    >>> tag("pgvector-0.8.7-pg18-macos-aarch64.tar.gz")
    'pgvector-0.8.7'
    >>> tag("memcached-1.6.45-macos-x86_64.tar.gz")
    'memcached-1.6.45'
    >>> tag("libwebrtc-0.3.49-windows-aarch64.zip")
    'libwebrtc-0.3.49'
    >>> tag("voice-engines-0.4.0-0.1.160-macos-aarch64.tar.gz")
    'voice-engines-0.4.0-0.1.160'
    >>> tag("voice-engines-0.4.0-0.1.160-windows-x86_64.zip")
    'voice-engines-0.4.0-0.1.160'
    >>> tag("php-ext-pdo_sqlsrv-5.13.3-php8.4-nts-vs17-windows-x86_64.zip")
    'php-ext-pdo_sqlsrv-5.13.3'
    >>> tag("php-ext-mongodb-1.20.1-php8.0-nts-vs16-windows-x86_64.zip")
    'php-ext-mongodb-1.20.1'
    >>> tag("typesense-30.2-macos-aarch64.tar.gz")
    'typesense-30.2'
    >>> tag("typesense-29.0-sources.tar.gz")
    'typesense-29.0'
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
