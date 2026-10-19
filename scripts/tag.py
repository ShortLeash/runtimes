#!/usr/bin/env python3
"""Prints the release each build output belongs to, one "<tag> <file>" per line.

Usage: python3 scripts/tag.py <outputs folder>

A MariaDB or PostGIS build is released only with its sources: when
<name>-<version>-sources.tar.gz isn't among the outputs, or doesn't hold the
script that made the build (scripts/postgis-windows.sh for a Windows PostGIS,
with the libxml2 and SQLite tarballs only that build links), the build is
left out, named on stderr, and the script exits 1 after printing the rest, so
the other builds still release and the run fails. Sources files print first,
so a failed upload can't leave a build on its release without them.

A release holds one version of one thing for every platform: php-8.4.26 has
the CLI and php-fpm for both Mac architectures (so does a preview,
php-8.6.0RC3), ruby-3.4.7 has macOS and Windows, pgvector-0.8.7 has every
Postgres major on every platform, memcached-1.6.45 has both Mac
architectures, libwebrtc-0.3.49 has every Mac and Windows architecture, and
voice-engines-0.4.0-0.1.160 (named after the transcribe-cpp-sys and
llama-cpp-sys-2 crates) has both Mac architectures and Windows x64.
php-ext-redis-6.3.0 has one Windows x64 DLL for each PHP minor, built with
the compiler that minor's official PHP uses. mariadb-11.8.9 has both Mac
architectures, and postgis-3.6.4 has every Postgres major on every platform
(postgis-3.6.4-pg18-macos-aarch64.tar.gz). Both also carry the GPL sources
they were built from, as <name>-<version>-sources.tar.gz.
"""

import pathlib
import re
import sys
import tarfile

from buildinfo import parse_env

PATTERNS = [
    re.compile(r"^(?P<tag>php-\d+\.\d+\.\d+(?:(?:alpha|beta|RC)\d+)?)-(?:cli|fpm)-[a-z]+-[a-z0-9_]+\.tar\.gz$"),
    re.compile(r"^(?P<tag>ruby-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>pgvector-\d+\.\d+\.\d+)-pg\d+-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>memcached-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.tar\.gz$"),
    re.compile(r"^(?P<tag>libwebrtc-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>voice-engines-\d+\.\d+\.\d+-\d+\.\d+\.\d+)-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)$"),
    re.compile(r"^(?P<tag>php-ext-[a-z0-9_]+-\d+\.\d+\.\d+)-php\d+\.\d+-nts-vs\d+-windows-x86_64\.zip$"),
    re.compile(r"^(?P<tag>mariadb-\d+\.\d+\.\d+)-(?:macos-[a-z0-9_]+\.tar\.gz|sources\.tar\.gz)$"),
    re.compile(r"^(?P<tag>postgis-\d+\.\d+\.\d+)-(?:pg\d+-[a-z]+-[a-z0-9_]+\.(?:tar\.gz|zip)|sources\.tar\.gz)$"),
]


def tag(name: str) -> str:
    """
    >>> tag("php-8.4.26-fpm-macos-x86_64.tar.gz")
    'php-8.4.26'
    >>> tag("php-8.6.0RC3-cli-macos-aarch64.tar.gz")
    'php-8.6.0RC3'
    >>> tag("php-8.6.0beta2-fpm-macos-x86_64.tar.gz"), tag("php-8.6.0alpha1-cli-macos-aarch64.tar.gz")
    ('php-8.6.0beta2', 'php-8.6.0alpha1')
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
    >>> tag("mariadb-11.8.9-macos-aarch64.tar.gz")
    'mariadb-11.8.9'
    >>> tag("mariadb-10.11.19-sources.tar.gz")
    'mariadb-10.11.19'
    >>> tag("postgis-3.6.4-pg18-macos-x86_64.tar.gz")
    'postgis-3.6.4'
    >>> tag("postgis-3.6.4-pg14-windows-x86_64.zip")
    'postgis-3.6.4'
    >>> tag("postgis-3.6.4-sources.tar.gz")
    'postgis-3.6.4'
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


# Builds under the GPL (or linking LGPL code statically), whose releases must
# carry the sources they were built from.
WITH_SOURCES = ("mariadb", "postgis")


def sources_for(name: str):
    """The sources file a build's release must carry, or None.

    >>> sources_for("mariadb-11.8.9-macos-aarch64.tar.gz")
    'mariadb-11.8.9-sources.tar.gz'
    >>> sources_for("postgis-3.6.4-pg14-windows-x86_64.zip")
    'postgis-3.6.4-sources.tar.gz'
    >>> sources_for("postgis-3.6.4-sources.tar.gz") is None, sources_for("pgvector-0.8.7-pg18-macos-aarch64.tar.gz") is None
    (True, True)
    """
    release = tag(name)
    if release.split("-")[0] in WITH_SOURCES and name != f"{release}-sources.tar.gz":
        return f"{release}-sources.tar.gz"
    return None


# The script each GPL build is made by, which its sources file must hold.
BUILD_SCRIPTS = {
    ("mariadb", "macos"): "scripts/mariadb.sh",
    ("postgis", "macos"): "scripts/postgis.sh",
    ("postgis", "windows"): "scripts/postgis-windows.sh",
}


def required_members(name: str, pins: dict):
    """What a GPL build's sources file must hold, or None when no build
    script is known for it: the script that made it and, for a Windows
    PostGIS, the libxml2 and SQLite tarballs only that build links in, as
    scripts/postgis.env pins them (pins).

    >>> pins = {"LIBXML2_VERSION": "2.15.4", "SQLITE_TARBALL": "2026/sqlite-autoconf-3540100.tar.gz"}
    >>> required_members("postgis-3.6.4-pg14-windows-x86_64.zip", pins)
    ['scripts/postgis-windows.sh', 'libxml2-2.15.4.tar.xz', 'sqlite-autoconf-3540100.tar.gz']
    >>> required_members("postgis-3.6.4-pg18-macos-aarch64.tar.gz", pins), required_members("mariadb-11.8.9-macos-x86_64.tar.gz", pins)
    (['scripts/postgis.sh'], ['scripts/mariadb.sh'])
    >>> required_members("postgis-3.6.4-pg14-linux-x86_64.tar.gz", pins) is None
    True
    """
    m = re.search(r"-([a-z]+)-[a-z0-9_]+\.(?:tar\.gz|zip)$", name)
    key = (tag(name).split("-")[0], m[1] if m else "")
    script = BUILD_SCRIPTS.get(key)
    if script is None:
        return None
    if key == ("postgis", "windows"):
        return [script, f"libxml2-{pins['LIBXML2_VERSION']}.tar.xz", pins["SQLITE_TARBALL"].rsplit("/", 1)[-1]]
    return [script]


def unreleasable(name: str, present: set, listing, pins: dict) -> str:
    """Why a build can't be released, or "" when it can: its sources file
    must be among the outputs and hold what required_members names.
    listing(file) gives a sources file's members.

    >>> pins = {"LIBXML2_VERSION": "2.15.4", "SQLITE_TARBALL": "2026/sqlite-autoconf-3540100.tar.gz"}
    >>> held = {"postgis-3.6.4-sources.tar.gz": {"scripts/postgis.sh"}}
    >>> present = set(held)
    >>> unreleasable("postgis-3.6.4-pg18-macos-aarch64.tar.gz", present, held.get, pins)
    ''
    >>> unreleasable("postgis-3.6.4-pg18-windows-x86_64.zip", present, held.get, pins)
    "postgis-3.6.4-sources.tar.gz doesn't hold scripts/postgis-windows.sh, so it isn't this build's sources"
    >>> held["postgis-3.6.4-sources.tar.gz"] |= {"scripts/postgis-windows.sh", "sqlite-autoconf-3540100.tar.gz"}
    >>> unreleasable("postgis-3.6.4-pg18-windows-x86_64.zip", present, held.get, pins)
    "postgis-3.6.4-sources.tar.gz doesn't hold libxml2-2.15.4.tar.xz, so it isn't this build's sources"
    >>> held["postgis-3.6.4-sources.tar.gz"].add("libxml2-2.15.4.tar.xz")
    >>> unreleasable("postgis-3.6.4-pg18-windows-x86_64.zip", present, held.get, pins)
    ''
    >>> unreleasable("mariadb-11.8.9-macos-aarch64.tar.gz", present, held.get, pins)
    "mariadb-11.8.9-sources.tar.gz isn't among the outputs"
    >>> unreleasable("postgis-3.6.4-pg18-linux-x86_64.tar.gz", present, held.get, pins)
    'no build script is known for it'
    >>> unreleasable("ruby-3.4.7-windows-x86_64.zip", present, held.get, pins)
    ''
    """
    sources = sources_for(name)
    if sources is None:
        return ""
    if sources not in present:
        return f"{sources} isn't among the outputs"
    members = required_members(name, pins)
    if members is None:
        return "no build script is known for it"
    held = listing(sources)
    for member in members:
        if member not in held:
            return f"{sources} doesn't hold {member}, so it isn't this build's sources"
    return ""


def releases(names: list, listing, pins: dict) -> tuple:
    """Each output's release as (tag, name), and the builds withheld, with
    why (unreleasable). listing(file) gives a sources file's members.

    >>> pins = {"LIBXML2_VERSION": "2.15.4", "SQLITE_TARBALL": "2026/sqlite-autoconf-3540100.tar.gz"}
    >>> held = {"mariadb-11.8.9-sources.tar.gz": {"scripts/mariadb.sh"}, "postgis-3.6.4-sources.tar.gz": {"scripts/postgis.sh"}}
    >>> released, withheld = releases(["mariadb-11.8.9-macos-aarch64.tar.gz", "mariadb-11.8.9-sources.tar.gz",
    ...     "mariadb-10.11.19-macos-x86_64.tar.gz", "postgis-3.6.4-pg18-windows-x86_64.zip",
    ...     "postgis-3.6.4-sources.tar.gz", "ruby-3.4.7-windows-x86_64.zip"], held.get, pins)
    >>> [name for _, name in released]
    ['mariadb-11.8.9-macos-aarch64.tar.gz', 'mariadb-11.8.9-sources.tar.gz', 'postgis-3.6.4-sources.tar.gz', 'ruby-3.4.7-windows-x86_64.zip']
    >>> [name for name, _ in withheld]
    ['mariadb-10.11.19-macos-x86_64.tar.gz', 'postgis-3.6.4-pg18-windows-x86_64.zip']
    >>> releases(["postgis-3.6.4-sources.tar.gz"], held.get, pins)
    ([('postgis-3.6.4', 'postgis-3.6.4-sources.tar.gz')], [])
    >>> releases(["mariadb-11.8.9-macos-aarch64.tar.gz", "notes.txt"], held.get, pins)
    Traceback (most recent call last):
    ...
    ValueError: notes.txt: not a build output
    """
    present = set(names)
    released, withheld = [], []
    for name in names:
        why = unreleasable(name, present, listing, pins)
        if why:
            withheld.append((name, why))
        else:
            released.append((tag(name), name))
    return released, withheld


def main() -> None:
    paths = {p.name: p for p in sorted(pathlib.Path(sys.argv[1]).rglob("*")) if p.is_file()}

    def listing(name: str) -> set:
        with tarfile.open(paths[name]) as t:
            return set(t.getnames())

    pins = parse_env((pathlib.Path(__file__).resolve().parent / "postgis.env").read_text(encoding="utf-8"))
    released, withheld = releases(sorted(paths), listing, pins)
    # Sources first, so a failed upload can't leave a build without them.
    for release, name in sorted(released, key=lambda r: sources_for(r[1]) is not None):
        print(release, paths[name])
    for name, why in withheld:
        print(f"{name}: not released, {why}", file=sys.stderr)
    if withheld:
        sys.exit(1)


if __name__ == "__main__":
    main()
