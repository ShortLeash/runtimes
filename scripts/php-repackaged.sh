#!/usr/bin/env bash
# Releases static-php-cli's own build of a PHP release that's past its end of
# life, unchanged, for the Mac this runs on. PHP 8.0 and 8.1 get no more
# releases, so there's nothing new to build: Short Leash serves the programs
# people already run from its own downloads instead.
#
#   scripts/php-repackaged.sh 8.1.34 out/
#
# dl.static-php.dev publishes no checksums, so each archive is checked against
# the SHA-256 pinned in php-repackaged.env. It must then hold only its program
# (php or php-fpm) at the top of the archive, the layout Short Leash's PHP
# installer unpacks, and that program must run and say it's this release.
#
# Writes out/php-<version>-cli-macos-<arch>.tar.gz and
# out/php-<version>-fpm-macos-<arch>.tar.gz, byte for byte upstream's.
set -euo pipefail

version="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
arch="$(shortleash_arch)"

# A pin from php-repackaged.env, or nothing. The file is read, never sourced:
# PHP_REPACKAGED holds a space.
pinned() {
  sed -n "s/^$1=//p" "$here/php-repackaged.env" | head -1
}

if ! tr ' ' '\n' <<<"$(pinned PHP_REPACKAGED)" | grep -qxF "$version"; then
  echo "PHP $version isn't in PHP_REPACKAGED (scripts/php-repackaged.env)" >&2
  exit 1
fi
from="$(pinned PHP_REPACKAGED_FROM)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for sapi in cli fpm; do
  file="php-$version-$sapi-macos-$arch.tar.gz"
  pin="PHP_$(tr '.' '_' <<<"$version")_$(tr '[:lower:]' '[:upper:]' <<<"${sapi}_${arch}")_SHA256"
  want="$(pinned "$pin")"
  if ! [[ "$want" =~ ^[0-9a-f]{64}$ ]]; then
    echo "$file has no SHA-256 pinned ($pin in scripts/php-repackaged.env)" >&2
    exit 1
  fi
  fetch_checked "$from/$file" "$want" "$work/$file"

  program=php
  [ "$sapi" = fpm ] && program=php-fpm
  holds="$(tar -tzf "$work/$file")"
  if [ "$holds" != "$program" ]; then
    echo "$file must hold only $program, and holds: $holds" >&2
    exit 1
  fi
  mkdir "$work/$sapi"
  tar -xzf "$work/$file" -C "$work/$sapi"
  if ! [ -f "$work/$sapi/$program" ] || [ -L "$work/$sapi/$program" ]; then
    echo "$file's $program isn't a plain file" >&2
    exit 1
  fi
done

got="$("$work/cli/php" -n -r 'echo PHP_VERSION;')"
if [ "$got" != "$version" ]; then
  echo "php-$version-cli-macos-$arch.tar.gz is PHP $got, not $version" >&2
  exit 1
fi
got="$("$work/fpm/php-fpm" -n -v | head -1)"
if [[ "$got" != "PHP $version (fpm-fcgi)"* ]]; then
  echo "php-$version-fpm-macos-$arch.tar.gz says: $got" >&2
  exit 1
fi

for sapi in cli fpm; do
  cp "$work/php-$version-$sapi-macos-$arch.tar.gz" "$out/"
done
echo "Repackaged PHP $version for macos-$arch"
