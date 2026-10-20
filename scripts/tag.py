#!/usr/bin/env python3
"""Prints the release each build output belongs to, one "<tag> <file>" per line.

Usage: python3 scripts/tag.py <outputs folder>

A Typesense build is released only with its sources: when
<name>-<version>-sources.tar.gz isn't among the outputs, or doesn't hold the
source tarball and the script that made the build (scripts/typesense.sh),
the build is left out, named on stderr, and the script exits 1 after
printing the rest, so the other builds still release and the run fails.
Sources files print first, so a failed upload can't leave a build on its
release without them.

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
import tarfile

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


# Builds under the GPL whose releases must carry the sources they were
# built from.
WITH_SOURCES = ("typesense",)


def sources_for(name: str):
    """The sources file a build's release must carry, or None.

    >>> sources_for("typesense-30.2-macos-aarch64.tar.gz")
    'typesense-30.2-sources.tar.gz'
    >>> sources_for("typesense-30.2-sources.tar.gz") is None, sources_for("memcached-1.6.45-macos-x86_64.tar.gz") is None
    (True, True)
    """
    release = tag(name)
    if release.split("-")[0] in WITH_SOURCES and name != f"{release}-sources.tar.gz":
        return f"{release}-sources.tar.gz"
    return None


# The script each GPL build is made by, which its sources file must hold.
BUILD_SCRIPTS = {
    ("typesense", "macos"): "scripts/typesense.sh",
}


def required_members(name: str):
    """What a GPL build's sources file must hold, or None when no build
    script is known for it: the script that made it and, for Typesense, the
    source tarball of its tag.

    >>> required_members("typesense-30.2-macos-x86_64.tar.gz")
    ['scripts/typesense.sh', 'typesense-30.2.tar.gz']
    """
    m = re.search(r"-([a-z]+)-[a-z0-9_]+\.(?:tar\.gz|zip)$", name)
    release = tag(name)
    script = BUILD_SCRIPTS.get((release.split("-")[0], m[1] if m else ""))
    if script is None:
        return None
    return [script, f"{release}.tar.gz"]


def unreleasable(name: str, present: set, listing) -> str:
    """Why a build can't be released, or "" when it can: its sources file
    must be among the outputs and hold what required_members names.
    listing(file) gives a sources file's members.

    >>> held = {"typesense-30.2-sources.tar.gz": {"scripts/typesense.sh"}}
    >>> present = set(held)
    >>> unreleasable("typesense-30.2-macos-aarch64.tar.gz", present, held.get)
    "typesense-30.2-sources.tar.gz doesn't hold typesense-30.2.tar.gz, so it isn't this build's sources"
    >>> held["typesense-30.2-sources.tar.gz"].add("typesense-30.2.tar.gz")
    >>> unreleasable("typesense-30.2-macos-aarch64.tar.gz", present, held.get)
    ''
    >>> unreleasable("typesense-29.0-macos-aarch64.tar.gz", present, held.get)
    "typesense-29.0-sources.tar.gz isn't among the outputs"
    >>> unreleasable("ruby-3.4.7-windows-x86_64.zip", present, held.get)
    ''
    """
    sources = sources_for(name)
    if sources is None:
        return ""
    if sources not in present:
        return f"{sources} isn't among the outputs"
    members = required_members(name)
    if members is None:
        return "no build script is known for it"
    held = listing(sources)
    for member in members:
        if member not in held:
            return f"{sources} doesn't hold {member}, so it isn't this build's sources"
    return ""


def releases(names: list, listing) -> tuple:
    """Each output's release as (tag, name), and the builds withheld, with
    why (unreleasable). listing(file) gives a sources file's members.

    >>> held = {"typesense-30.2-sources.tar.gz": {"scripts/typesense.sh", "typesense-30.2.tar.gz"}}
    >>> released, withheld = releases(["typesense-30.2-macos-aarch64.tar.gz", "typesense-30.2-sources.tar.gz",
    ...     "typesense-29.0-macos-x86_64.tar.gz", "ruby-3.4.7-windows-x86_64.zip"], held.get)
    >>> [name for _, name in released]
    ['typesense-30.2-macos-aarch64.tar.gz', 'typesense-30.2-sources.tar.gz', 'ruby-3.4.7-windows-x86_64.zip']
    >>> withheld
    [('typesense-29.0-macos-x86_64.tar.gz', "typesense-29.0-sources.tar.gz isn't among the outputs")]
    >>> releases(["typesense-30.2-sources.tar.gz"], held.get)
    ([('typesense-30.2', 'typesense-30.2-sources.tar.gz')], [])
    >>> releases(["typesense-30.2-macos-aarch64.tar.gz", "notes.txt"], held.get)
    Traceback (most recent call last):
    ...
    ValueError: notes.txt: not a build output
    """
    present = set(names)
    released, withheld = [], []
    for name in names:
        why = unreleasable(name, present, listing)
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

    released, withheld = releases(sorted(paths), listing)
    # Sources first, so a failed upload can't leave a build without them.
    for release, name in sorted(released, key=lambda r: sources_for(r[1]) is not None):
        print(release, paths[name])
    for name, why in withheld:
        print(f"{name}: not released, {why}", file=sys.stderr)
    if withheld:
        sys.exit(1)


if __name__ == "__main__":
    main()
