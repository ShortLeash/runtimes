#!/usr/bin/env bash
# Collects the sources of the GPL builds, for their releases: every input,
# fetched and checked as its build script fetches it, and the scripts that
# make the build.
#
#   scripts/sources.sh typesense out/
#
# typesense writes out/typesense-<version>-sources.tar.gz for each version in
# scripts/typesense.env, holding GitHub's tarball of Typesense's tag (the
# source Typesense builds its binaries from) and scripts/lib.sh,
# scripts/typesense.sh and scripts/typesense.env, which fetch, check and
# repackage the binary. Each also lists its files' SHA-256 in SHA256SUMS.
# Runs on macOS and Linux.
set -euo pipefail

if [ $# -ne 2 ] || [ "$1" != typesense ]; then
  echo "Usage: scripts/sources.sh typesense <out folder>" >&2
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

# fetched FILE: records a checked download's SHA-256, for pack to check again.
fetched() { printf '%s %s\n' "$(sha256 "$1")" "$1" >>"$work/checked"; }
was_fetched_with() { awk -v f="$1" '$2 == f {print $1}' "$work/checked" 2>/dev/null; }

# pack NAME SCRIPT FILE...: writes out/NAME-sources.tar.gz with the files,
# each copied and checked against the SHA-256 it was fetched with, and
# scripts/lib.sh, scripts/SCRIPT.sh, scripts/SCRIPT.env and any other build
# scripts named in $more_scripts.
more_scripts=""
pack() {
  local name="$1" script="$2" f got want listing dir="$work/pack-$1" scripts
  shift 2
  scripts="lib.sh $script.sh $script.env $more_scripts"
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
  # shellcheck disable=SC2086 # one script per word
  for f in $scripts; do cp "$here/$f" "$dir/scripts/"; done
  (cd "$dir" && shasum -a 256 "$@" scripts/* >SHA256SUMS)
  # COPYFILE_DISABLE: macOS's tar would add its extended attributes.
  COPYFILE_DISABLE=1 tar -C "$dir" -czf "$out/$name-sources.tar.gz" SHA256SUMS "$@" scripts
  rm -rf "$dir"
  # The tarball lists every input and script.
  listing="$(tar -tzf "$out/$name-sources.tar.gz")"
  for f in SHA256SUMS "$@"; do
    grep -qxF "$f" <<<"$listing" || { echo "$name-sources.tar.gz has no $f" >&2; exit 1; }
  done
  # shellcheck disable=SC2086 # one script per word
  for f in $scripts; do
    grep -qxF "scripts/$f" <<<"$listing" || { echo "$name-sources.tar.gz has no scripts/$f" >&2; exit 1; }
  done
  echo "Wrote $out/$name-sources.tar.gz"
}

typesense() {
  . "$here/typesense.env"
  local version sha_var tarball
  for version in $TYPESENSE_VERSIONS; do
    sha_var="TYPESENSE_${version//./_}_SOURCE_SHA256"
    if [ -z "${!sha_var:-}" ]; then
      echo "scripts/typesense.env has no $sha_var" >&2
      exit 1
    fi
    # The same checked fetch as scripts/typesense.sh.
    tarball="typesense-$version.tar.gz"
    fetch_checked "https://github.com/typesense/typesense/archive/refs/tags/v$version.tar.gz" \
      "${!sha_var}" "$tarball"
    fetched "$tarball"
    pack "typesense-$version" typesense "$tarball"
  done
}

"$what"
