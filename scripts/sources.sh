#!/usr/bin/env bash
# Collects the complete sources of the GPL builds, for their releases: every
# input the build compiles in, fetched and checked as its build script
# fetches it, and the scripts that build it.
#
#   scripts/sources.sh mariadb out/
#   scripts/sources.sh postgis out/
#
# mariadb writes out/mariadb-<version>-sources.tar.gz for each MariaDB pin in
# scripts/mariadb.env, holding MariaDB's source tarball, the fmt and PCRE2 zips
# its CMake builds in, the GnuTLS and Nettle tarballs linked into its client
# library, and scripts/lib.sh, scripts/mariadb.sh and scripts/mariadb.env.
# postgis writes out/postgis-<version>-sources.tar.gz, holding the PostGIS,
# GEOS, PROJ, json-c and protobuf-c tarballs and scripts/lib.sh,
# scripts/postgis.sh and scripts/postgis.env. Each also lists its files'
# SHA-256 in SHA256SUMS. Runs on macOS and Linux.
set -euo pipefail

if [ $# -ne 2 ] || { [ "$1" != mariadb ] && [ "$1" != postgis ]; }; then
  echo "Usage: scripts/sources.sh <mariadb|postgis> <out folder>" >&2
  exit 2
fi
what="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
md5_of() {
  if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi
}

# fetched FILE: records a checked download's SHA-256, for pack to check again.
fetched() { printf '%s %s\n' "$(sha256 "$1")" "$1" >>"$work/checked"; }
was_fetched_with() { awk -v f="$1" '$2 == f {print $1}' "$work/checked" 2>/dev/null; }

# pack NAME SCRIPT FILE...: writes out/NAME-sources.tar.gz with the files,
# each copied and checked against the SHA-256 it was fetched with, and
# scripts/lib.sh, scripts/SCRIPT.sh and scripts/SCRIPT.env.
pack() {
  local name="$1" script="$2" f got want dir="$work/pack-$1"
  shift 2
  mkdir -p "$dir/scripts"
  for f in "$@"; do
    cp "$f" "$dir/"
    got="$(sha256 "$dir/$f")"
    want="$(was_fetched_with "$f")"
    if [ -z "$want" ] || [ "$got" != "$want" ]; then
      echo "$f: SHA-256 $got isn't the ${want:-unchecked} it was fetched with" >&2
      exit 1
    fi
  done
  cp "$here/lib.sh" "$here/$script.sh" "$here/$script.env" "$dir/scripts/"
  (cd "$dir" && shasum -a 256 "$@" scripts/* >SHA256SUMS)
  # COPYFILE_DISABLE: macOS's tar would add its extended attributes.
  COPYFILE_DISABLE=1 tar -C "$dir" -czf "$out/$name-sources.tar.gz" SHA256SUMS "$@" scripts
  echo "Wrote $out/$name-sources.tar.gz"
}

mariadb() {
  . "$here/mariadb.env"
  local fmt="fmt-$MARIADB_FMT_VERSION.zip" pcre2="pcre2-$MARIADB_PCRE2_VERSION.zip"
  local gnutls="gnutls-$MARIADB_GNUTLS_VERSION.tar.xz" nettle="nettle-$MARIADB_NETTLE_VERSION.tar.gz"
  # The same checked fetches as scripts/mariadb.sh.
  fetch_github_asset fmtlib/fmt "$MARIADB_FMT_VERSION" "$fmt" "$fmt"
  fetched "$fmt"
  fetch_github_asset PCRE2Project/pcre2 "pcre2-$MARIADB_PCRE2_VERSION" "$pcre2" "$pcre2"
  fetched "$pcre2"
  fetch_checked "https://ftp.gnu.org/gnu/nettle/$nettle" "$MARIADB_NETTLE_SHA256" "$nettle"
  fetched "$nettle"
  fetch_checked "https://www.gnupg.org/ftp/gcrypt/gnutls/v${MARIADB_GNUTLS_VERSION%.*}/$gnutls" \
    "$MARIADB_GNUTLS_SHA256" "$gnutls"
  fetched "$gnutls"

  local pin version sha_pin sha tarball base published want_fmt want_pcre2
  for pin in $(grep -oE '^MARIADB_[0-9]+_[0-9]+=' "$here/mariadb.env" | tr -d =); do
    version="${!pin}"
    sha_pin="${pin}_SHA256"
    sha="${!sha_pin:-}"
    [ -n "$sha" ] || { echo "$pin has no ${pin}_SHA256 in mariadb.env" >&2; exit 1; }
    tarball="mariadb-$version.tar.gz"
    base="https://archive.mariadb.org/mariadb-$version/source"
    fetch_checked "$base/$tarball" "$sha" "$tarball"
    published="$(curl -fsSL "$base/sha256sums.txt" |
      awk -v f="$tarball" '$2 == f || $2 == "*" f {print $1}')"
    if [ "$published" != "$sha" ]; then
      echo "$tarball: archive.mariadb.org lists SHA-256 '${published:-none}', not the pinned $sha" >&2
      exit 1
    fi
    fetched "$tarball"
    # The fmt and PCRE2 this MariaDB builds in, as scripts/mariadb.sh checks.
    want_fmt="$(tar -xzOf "$tarball" "mariadb-$version/cmake/libfmt.cmake" |
      grep -oE 'fmt-[0-9.]+\.zip' | tail -1)"
    want_pcre2="$(tar -xzOf "$tarball" "mariadb-$version/cmake/pcre.cmake" |
      grep -oE 'pcre2-[0-9.]+\.zip' | tail -1)"
    if [ "$want_fmt" != "$fmt" ] || [ "$want_pcre2" != "$pcre2" ]; then
      echo "MariaDB $version wants $want_fmt and $want_pcre2; update mariadb.env" >&2
      exit 1
    fi
    pack "mariadb-$version" mariadb "$tarball" "$fmt" "$pcre2" "$gnutls" "$nettle"
    rm -f "$tarball"
  done
}

postgis() {
  . "$here/postgis.env"
  local tarball="postgis-$POSTGIS_VERSION.tar.gz" geos="geos-$GEOS_VERSION.tar.bz2"
  local proj="proj-$PROJ_VERSION.tar.gz" jsonc="json-c-$JSONC_VERSION.tar.gz"
  local protobufc="protobuf-c-$PROTOBUFC_VERSION.tar.gz" published
  # The same checked fetches as scripts/postgis.sh.
  fetch_checked "https://download.osgeo.org/postgis/source/$tarball" "$POSTGIS_SHA256" "$tarball"
  published="$(curl -fsSL "https://download.osgeo.org/postgis/source/$tarball.md5" | awk '{print $1}')"
  if [ "$published" != "$(md5_of "$tarball")" ]; then
    echo "$tarball: download.osgeo.org lists MD5 '${published:-none}', not $(md5_of "$tarball")" >&2
    exit 1
  fi
  fetched "$tarball"
  fetch_github_asset libgeos/geos "$GEOS_VERSION" "$geos" "$geos"
  fetched "$geos"
  fetch_github_asset OSGeo/PROJ "$PROJ_VERSION" "$proj" "$proj"
  fetched "$proj"
  fetch_github_asset json-c/json-c "$JSONC_TAG" "$jsonc" "$jsonc"
  fetched "$jsonc"
  fetch_checked "https://github.com/protobuf-c/protobuf-c/releases/download/v$PROTOBUFC_VERSION/$protobufc" \
    "$PROTOBUFC_SHA256" "$protobufc"
  fetched "$protobufc"
  pack "postgis-$POSTGIS_VERSION" postgis "$tarball" "$geos" "$proj" "$jsonc" "$protobufc"
}

"$what"
