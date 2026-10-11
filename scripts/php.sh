#!/usr/bin/env bash
# Builds static PHP (CLI and php-fpm) with static-php-cli, with the extensions
# in php-extensions.txt, for the Mac this runs on: a minor version's newest
# release, or an exact release.
#
#   scripts/php.sh 8.4 out/
#   scripts/php.sh 8.4.26 out/
#
# Writes out/php-<version>-cli-macos-<arch>.tar.gz and
# out/php-<version>-fpm-macos-<arch>.tar.gz, each holding one program at the top
# of the archive (the layout DevKit's PHP installer unpacks).
set -euo pipefail

want="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
arch="$(devkit_arch)"
spc_version="${SPC_VERSION:-2.8.5}"

work="$(mktemp -d)"
cd "$work"
fetch_github_asset crazywhalecc/static-php-cli "$spc_version" "spc-macos-${arch}.tar.gz" spc.tar.gz
tar -xzf spc.tar.gz
chmod +x spc

# One extension list, comma-joined: lines may or may not end in a comma.
exts="$(grep -v '^#' "$here/php-extensions.txt" | tr -d ' ' | { grep -v '^$' || true; } |
  paste -sd, - | sed 's/,,*/,/g; s/,$//')"
IFS=. read -r major minor _ <<<"$want"
php_minor=$((major * 100 + minor))
# PHP 8.4 moved imap to PECL, and that copy doesn't build on macOS.
if [ "$php_minor" -ge 804 ]; then
  exts="$(tr ',' '\n' <<<"$exts" | { grep -vx imap || true; } | paste -sd, -)"
fi
./spc doctor --auto-fix
# swoole 6.2.3 doesn't compile on macOS (sw_usleep undeclared); stay on 6.2.2
# until a release does.
swoole_tag="${SWOOLE_TAG:-v6.2.2}"
./spc download --with-php="$want" --for-extensions="$exts" --prefer-pre-built --retry=3 \
  -U "swoole:https://github.com/swoole/swoole-src/archive/refs/tags/$swoole_tag.tar.gz"
patches=()
[ "$php_minor" -lt 803 ] && patches+=(--with-added-patch="$here/spc-patches/c17.php")
./spc build "$exts" --build-cli --build-fpm ${patches[@]+"${patches[@]}"}

php="buildroot/bin/php"
fpm="buildroot/bin/php-fpm"
version="$("$php" -r 'echo PHP_VERSION;')"
# Every listed extension must have made it in.
missing="$("$php" -r '
  $want = array_filter(explode(",", $argv[1]));
  $have = array_map("strtolower", get_loaded_extensions());
  $alias = ["opcache" => "zend opcache"];
  foreach ($want as $e) { if (!in_array($alias[$e] ?? $e, $have, true)) echo "$e "; }
' "$exts")"
if [ -n "$missing" ]; then
  echo "PHP $version is missing extensions: $missing" >&2
  exit 1
fi

check_macos_minimum "$(dirname "$php")"
tar -C "$(dirname "$php")" -czf "$out/php-${version}-cli-macos-${arch}.tar.gz" php
tar -C "$(dirname "$fpm")" -czf "$out/php-${version}-fpm-macos-${arch}.tar.gz" php-fpm
echo "Built PHP $version for macos-$arch"
