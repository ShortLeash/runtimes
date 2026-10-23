#!/usr/bin/env python3
"""Decides what a run of the Build workflow builds, as GitHub step outputs.

Usage: PLATFORM=<all|macos|windows> python3 scripts/plan.py <what> <published asset names file> <PHP minor>...

<what> is the workflow input (all, php, ruby, pgvector, memcached, libwebrtc,
voice-engines, php-ext-windows, mariadb or postgis), or "scheduled"
for the daily run. The daily run builds only the PHP versions whose newest
php.net release isn't on this repository's releases for both Mac
architectures yet, and nothing else. Either way it names each version's
exact release (8.4.26), looked up once here, so every runner builds the same
release rather than asking php.net itself and maybe getting another answer.
PHP_PREVIEW_MINORS (space-separated, "8.6") names minors php.net hasn't
released yet: each builds its newest pre-release (8.6.0RC3), with the
tarball's URL and php.net's SHA-256 for php.sh to check, on the same rules.
The php output is a list of {"version"} objects, previews adding "url" and
"sha256". When php.net's pre-release feed fails, the run warns and builds
no previews, so the stable releases still go out. PLATFORM limits a run by
hand to one platform's runners, so a test on a branch doesn't take every
Mac runner.
PHP_WINDOWS_MINORS (default "8.0 8.1 8.2 8.3 8.4 8.5") names the PHP minors
php-ext-windows builds extensions for, with the pins in
scripts/php-ext-windows.env. MariaDB builds for macOS only (Short Leash takes
Windows MariaDB from archive.mariadb.org), and PostGIS for macOS
(postgis) and Windows (postgis_windows), for every Postgres major. Either
also collects its GPL sources, once per run on Linux (sources).
"""

import json
import os
import pathlib
import re
import sys
import urllib.request

from buildinfo import parse_env

ARCHES = ("aarch64", "x86_64")
MAC_RUNNERS = ["macos-15", "macos-15-intel"]
WINDOWS_RUNNERS = ["windows-latest"]
# php.net's pre-releases: alpha, beta and release candidates (8.6.0RC3).
PRE_RELEASE = r"(?:alpha|beta|RC)\d+"
PRE_RELEASES = "https://www.php.net/pre-release-builds.php?format=json"
PHP_DOWNLOADS = "https://downloads.php.net/"


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
    the engines are pinned and change only with Short Leash's crates. Each Mac
    architecture builds on its own runner, so the smoke tests run natively.
    Windows uses Visual Studio 2022, whose MSVC version the build records:
    Short Leash installs at least that Visual C++ Redistributable.

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


def flags(what: str, platform: str) -> dict:
    """Whether a run builds MariaDB (macOS), PostGIS for macOS and PostGIS
    for Windows.

    >>> flags("mariadb", "all")
    {'mariadb': True, 'postgis': False, 'postgis_windows': False}
    >>> flags("all", "windows")
    {'mariadb': False, 'postgis': False, 'postgis_windows': True}
    >>> flags("postgis", "macos")["postgis_windows"]
    False
    >>> flags("scheduled", "all")
    {'mariadb': False, 'postgis': False, 'postgis_windows': False}
    """
    mac = platform in ("all", "macos")
    windows = platform in ("all", "windows")
    return {
        "mariadb": mac and what in ("all", "mariadb"),
        "postgis": mac and what in ("all", "postgis"),
        "postgis_windows": windows and what in ("all", "postgis"),
    }


def sources(built: dict) -> list:
    """The GPL sources a run collects (scripts/sources.sh), one job each, for
    the builds flags() turned on: their releases carry them.

    >>> sources(flags("all", "all"))
    ['mariadb', 'postgis']
    >>> sources(flags("postgis", "windows")), sources(flags("mariadb", "windows")), sources(flags("php", "all"))
    (['postgis'], [], [])
    """
    out = ["mariadb"] if built["mariadb"] else []
    if built["postgis"] or built["postgis_windows"]:
        out.append("postgis")
    return out


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


def latest_preview(pre_releases: dict, minor: str) -> dict | None:
    """The newest pre-release of a minor that isn't out yet, from php.net's
    pre-release-builds.php?format=json (keyed by the coming release), as
    {"version", "url", "sha256"} for its .tar.xz, or None. It counts only
    when its key is <minor>.0, it names a version, and its .tar.xz is on
    https://downloads.php.net/ with a 64-hex SHA-256: php.sh checks the
    tarball against that SHA-256 before building it.

    >>> data = {"8.5.12": {"active": True, "release": {"version": "8.5.12RC1", "enabled": True,
    ...           "files": {"xz": {"path": "https://downloads.php.net/~a/php-8.5.12RC1.tar.xz", "sha256": "aa" * 32}}}},
    ...         "8.6.0": {"active": True, "release": {"version": "8.6.0RC3",
    ...           "files": {"xz": {"path": "https://downloads.php.net/~b/php-8.6.0RC3.tar.xz", "sha256": "bb" * 32}}}},
    ...         "reported": ["8.6.0RC3"]}
    >>> latest_preview(data, "8.6")["version"]
    '8.6.0RC3'
    >>> latest_preview(data, "8.6")["url"], latest_preview(data, "8.6")["sha256"] == "bb" * 32
    ('https://downloads.php.net/~b/php-8.6.0RC3.tar.xz', True)
    >>> latest_preview(data, "8.5") is None   # a patch RC of a released minor isn't a preview
    True
    >>> latest_preview({"8.6.0": {"active": True, "release": {"enabled": False}}}, "8.6") is None
    True
    >>> latest_preview(data, "8.7") is None
    True
    >>> import copy
    >>> off = copy.deepcopy(data); off["8.6.0"]["release"]["enabled"] = False
    >>> latest_preview(off, "8.6") is None
    True
    >>> elsewhere = copy.deepcopy(data); elsewhere["8.6.0"]["release"]["files"]["xz"]["path"] = "https://example.com/php-8.6.0RC3.tar.xz"
    >>> latest_preview(elsewhere, "8.6") is None
    True
    >>> short = copy.deepcopy(data); short["8.6.0"]["release"]["files"]["xz"]["sha256"] = "bb"
    >>> latest_preview(short, "8.6") is None
    True
    >>> odd = copy.deepcopy(data); odd["8.6.0"]["release"]["version"] = "8.6.0RC3; rm -rf /"
    >>> latest_preview(odd, "8.6") is None
    True
    """
    entry = pre_releases.get(f"{minor}.0")
    if not isinstance(entry, dict) or entry.get("active") is False:
        return None
    release = entry.get("release") or {}
    version = release.get("version") or ""
    if release.get("enabled") is False or not re.fullmatch(rf"{re.escape(minor)}\.0{PRE_RELEASE}", version):
        return None
    xz = (release.get("files") or {}).get("xz") or {}
    url, sha256 = xz.get("path") or "", xz.get("sha256") or ""
    if not url.startswith(PHP_DOWNLOADS) or not url.endswith(f"/php-{version}.tar.xz"):
        return None
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        return None
    return {"version": version, "url": url, "sha256": sha256}


def php_matrix(what: str, published: set, latest: dict, previews: dict) -> list:
    """The PHP builds a run makes, one {"version"} object each; a preview's
    also names php.net's tarball and its SHA-256 ("url", "sha256"). A
    scheduled run builds only the releases and previews not published for
    every Mac architecture yet; "all" and "php" build every one.

    >>> latest = {"8.4": "8.4.26", "8.5": "8.5.11"}
    >>> previews = {"8.6": {"version": "8.6.0RC3", "url": "https://downloads.php.net/~b/php-8.6.0RC3.tar.xz", "sha256": "bb" * 32}}
    >>> [p["version"] for p in php_matrix("php", set(), latest, previews)]
    ['8.4.26', '8.5.11', '8.6.0RC3']
    >>> php_matrix("all", set(), latest, {})
    [{'version': '8.4.26'}, {'version': '8.5.11'}]
    >>> php_matrix("scheduled", set(php_assets("8.4.26") + php_assets("8.5.11")), latest, previews) == [previews["8.6"]]
    True
    >>> php_matrix("scheduled", set(php_assets("8.4.26") + php_assets("8.6.0RC3")), latest, previews)
    [{'version': '8.5.11'}]
    >>> php_matrix("ruby", set(), latest, previews)
    []
    """
    if what == "scheduled":
        php = [{"version": latest[m]} for m in stale(published, latest)]
        php += [previews[m] for m in stale(published, {m: p["version"] for m, p in previews.items()})]
        return php
    if what in ("all", "php"):
        return [{"version": v} for v in latest.values()] + list(previews.values())
    return []


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
    >>> stale(have | set(php_assets("8.6.0RC2")), {"8.4": "8.4.26", "8.6": "8.6.0RC3"})
    ['8.6']
    >>> stale(set(php_assets("8.6.0RC3")), {"8.6": "8.6.0RC3"})
    []
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


def fetch_pre_releases():
    """php.net's pre-release feed, parsed."""
    with urllib.request.urlopen(PRE_RELEASES, timeout=30) as r:
        return json.load(r)


def latest_previews(minors: list, fetch=fetch_pre_releases) -> dict:
    """The newest pre-release of each preview minor that has one, from php.net.
    Best effort: when the feed can't be fetched or read, it warns on stderr
    and returns no previews, so the stable releases still build.

    >>> import sys; sys.stderr = sys.stdout
    >>> feed = {"8.6.0": {"active": True, "release": {"version": "8.6.0RC3",
    ...     "files": {"xz": {"path": "https://downloads.php.net/~b/php-8.6.0RC3.tar.xz", "sha256": "bb" * 32}}}}}
    >>> list(latest_previews(["8.6", "8.7"], lambda: feed))
    ['8.6']
    >>> def down():
    ...     raise OSError("HTTP Error 503: Service Unavailable")
    >>> latest_previews(["8.6"], down)
    ::warning::No PHP previews this run: php.net's pre-release feed failed (HTTP Error 503: Service Unavailable)
    {}
    >>> latest_previews(["8.6"], lambda: json.loads("<html>"))
    ::warning::No PHP previews this run: php.net's pre-release feed failed (Expecting value: line 1 column 1 (char 0))
    {}
    >>> latest_previews(["8.6"], lambda: ["not", "a", "dict"])
    ::warning::No PHP previews this run: php.net's pre-release feed failed (not a JSON object)
    {}
    >>> latest_previews(["8.6"], lambda: {"8.6.0": {"release": ["odd"]}})
    ::warning::No PHP previews this run: php.net's pre-release feed failed ('list' object has no attribute 'get')
    {}
    >>> sys.stderr = sys.__stderr__
    """
    try:
        data = fetch()
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
        return {m: p for m in minors if (p := latest_preview(data, m)) is not None}
    except (OSError, ValueError, TypeError, AttributeError) as e:
        print(f"::warning::No PHP previews this run: php.net's pre-release feed failed ({e})", file=sys.stderr)
        return {}


def main() -> None:
    what, published, minors = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3:]
    have = set(published.read_text().split()) if published.is_file() else set()
    platform = os.environ.get("PLATFORM") or "all"
    mac, every = runners(platform)
    # The exact release, so every runner builds the one php.net lists.
    builds_php = bool(mac) and what in ("scheduled", "all", "php")
    latest = latest_releases(minors) if builds_php else {}
    preview_minors = os.environ.get("PHP_PREVIEW_MINORS", "").split()
    previews = latest_previews(preview_minors) if builds_php and preview_minors else {}
    php = php_matrix(what, have, latest, previews)
    pins = parse_env((pathlib.Path(__file__).resolve().parent / "php-ext-windows.env").read_text(encoding="utf-8"))
    windows_minors = os.environ.get("PHP_WINDOWS_MINORS", "8.0 8.1 8.2 8.3 8.4 8.5").split()
    print(f"php={json.dumps(php)}")
    print(f"ruby={str(what in ('all', 'ruby')).lower()}")
    print(f"pgvector={str(what in ('all', 'pgvector')).lower()}")
    print(f"memcached={str(what in ('all', 'memcached') and bool(mac)).lower()}")
    print(f"libwebrtc={json.dumps(libwebrtc_targets(what, platform))}")
    print(f"voice_engines={json.dumps(voice_engines_targets(what, platform))}")
    print(f"php_ext_windows={json.dumps(php_ext_windows_targets(what, platform, have, pins, windows_minors))}")
    built = flags(what, platform)
    for key, value in built.items():
        print(f"{key}={str(value).lower()}")
    print(f"sources={json.dumps(sources(built))}")
    print(f"mac_runners={json.dumps(mac)}")
    print(f"runners={json.dumps(every)}")


if __name__ == "__main__":
    main()
