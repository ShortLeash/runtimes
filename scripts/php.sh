#!/usr/bin/env bash
# Builds static PHP (CLI and php-fpm) with static-php-cli, with the extensions
# in php-extensions.txt, for the Mac this runs on: a minor version's newest
# release, or an exact release.
#
#   scripts/php.sh 8.4 out/
#   scripts/php.sh 8.4.26 out/
#
# A preview (a pre-release of a minor php.net hasn't released yet) builds
# from php.net's tarball, checked against the SHA-256 php.net publishes for
# it, and leaves out the extensions in php-extensions-preview-skip.txt:
#
#   PHP_SOURCE_URL=https://downloads.php.net/~…/php-8.6.0RC3.tar.xz \
#   PHP_SOURCE_SHA256=<64 hex> scripts/php.sh 8.6.0RC3 out/
#
# Writes out/php-<version>-cli-macos-<arch>.tar.gz and
# out/php-<version>-fpm-macos-<arch>.tar.gz, each holding its program at the top
# of the archive (the layout Short Leash's PHP installer unpacks). The CLI archive
# also holds pcov.so, for code coverage; Short Leash loads it for the CLI only
# (not a preview's while pcov is in php-extensions-preview-skip.txt).
set -euo pipefail

want="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/excimer.env"
arch="$(shortleash_arch)"
spc_version="${SPC_VERSION:-2.8.5}"

work="$(mktemp -d)"
cd "$work"

IFS=. read -r major minor _ <<<"$want"
php_minor=$((major * 100 + minor))
preview=false
[[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+(alpha|beta|RC)[0-9]+$ ]] && preview=true
source_args=(--with-php="$want")
if [ -n "${PHP_SOURCE_URL:-}" ]; then
  # Only php.net's own downloads, checked against the SHA-256 it publishes.
  case "$PHP_SOURCE_URL" in
    https://downloads.php.net/*/php-"$want".tar.xz) ;;
    *) echo "PHP_SOURCE_URL isn't php-$want.tar.xz on https://downloads.php.net/: $PHP_SOURCE_URL" >&2; exit 1 ;;
  esac
  if ! [[ "${PHP_SOURCE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "PHP_SOURCE_SHA256 must be php.net's SHA-256 for php-$want.tar.xz (64 hex characters)" >&2
    exit 1
  fi
  src="$work/php-$want.tar.xz"
  curl -fsSL --proto =https --retry 3 -o "$src" "$PHP_SOURCE_URL"
  if [ "$(shasum -a 256 "$src" | cut -d' ' -f1)" != "$PHP_SOURCE_SHA256" ]; then
    echo "php-$want.tar.xz doesn't match php.net's SHA-256" >&2
    exit 1
  fi
  # static-php-cli takes only x.y or x.y.z, and the checked file from here.
  source_args=(--with-php="$major.$minor" -U "php-src:file://$src")
elif $preview; then
  echo "PHP $want is a preview: set PHP_SOURCE_URL and PHP_SOURCE_SHA256 to php.net's tarball and its SHA-256" >&2
  exit 1
fi

fetch_github_asset crazywhalecc/static-php-cli "$spc_version" "spc-macos-${arch}.tar.gz" spc.tar.gz
tar -xzf spc.tar.gz
chmod +x spc

# One extension list, comma-joined: lines may or may not end in a comma.
exts="$(grep -v '^#' "$here/php-extensions.txt" | tr -d ' ' | { grep -v '^$' || true; } |
  paste -sd, - | sed 's/,,*/,/g; s/,$//')"
# Built as shared extensions (static-php-cli builds pcov no other way).
shared="pcov"
if $preview; then
  # Extensions that don't build against the preview yet stay out of it.
  skip="$(sed 's/#.*//' "$here/php-extensions-preview-skip.txt" | tr -d ' \t' | { grep -v '^$' || true; })"
  for e in $skip; do
    exts="$(tr ',' '\n' <<<"$exts" | { grep -vx "$e" || true; } | paste -sd, -)"
    if [ "$e" = pcov ]; then shared=""; fi
  done
  # static-php-cli patches the PHP source with phpmicro's patches for the
  # PHP minor, and with 8.0's for a minor it doesn't know yet, which don't
  # apply to a preview. Micro isn't built here: keep only the macOS iconv
  # fix, the one 8.5 builds get too (cli_checks is for micro alone).
  export SPC_MICRO_PATCHES=macos_iconv_84
fi
# PHP 8.4 moved imap to PECL, and that copy doesn't build on macOS.
if [ "$php_minor" -ge 804 ]; then
  exts="$(tr ',' '\n' <<<"$exts" | { grep -vx imap || true; } | paste -sd, -)"
fi
./spc doctor --auto-fix
# swoole 6.2.3 doesn't compile on macOS (sw_usleep undeclared); stay on 6.2.2
# until a release does.
swoole_tag="${SWOOLE_TAG:-v6.2.2}"
custom=(-U "swoole:https://github.com/swoole/swoole-src/archive/refs/tags/$swoole_tag.tar.gz")
# Excimer from the commit excimer.env pins, not PECL's newest (see there).
if tr ',' '\n' <<<"$exts" | grep -qx excimer; then
  git init -q excimer-git
  git -C excimer-git fetch -q --depth 1 "https://github.com/$EXCIMER_REPO.git" "$EXCIMER_COMMIT"
  git -C excimer-git checkout -q FETCH_HEAD
  if [ "$(git -C excimer-git rev-parse HEAD)" != "$EXCIMER_COMMIT" ]; then
    echo "$EXCIMER_REPO didn't give commit $EXCIMER_COMMIT" >&2
    exit 1
  fi
  git -C excimer-git archive --format=tar.gz --prefix="excimer-$EXCIMER_VERSION/" -o "$work/excimer.tgz" HEAD
  custom+=(-U "ext-excimer:file://$work/excimer.tgz")
fi
./spc download "${source_args[@]}" --for-extensions="$exts${shared:+,$shared}" --prefer-pre-built --retry=3 \
  "${custom[@]}"
# curl asks the system's resolver, not c-ares (see the patch).
build_args=(--with-added-patch="$here/spc-patches/curl-system-resolver.php")
[ "$php_minor" -lt 803 ] && build_args+=(--with-added-patch="$here/spc-patches/c17.php")
if [ -n "$shared" ]; then build_args+=(--build-shared="$shared"); fi
# libavif gives gd imageavif() (imagick reads AVIF on its own).
./spc build "$exts" --build-cli --build-fpm --with-libs=libavif \
  ${build_args[@]+"${build_args[@]}"}

php="buildroot/bin/php"
fpm="buildroot/bin/php-fpm"
version="$("$php" -r 'echo PHP_VERSION;')"
# Every listed extension must have made it in.
missing="$("$php" -r '
  $want = array_filter(explode(",", $argv[1]));
  $have = array_map("strtolower", get_loaded_extensions());
  $alias = ["opcache" => "zend opcache"];
  // Parts of an extension PHP never lists on their own: check a function.
  $probe = ["mbregex" => "mb_split"];
  foreach ($want as $e) {
    $ok = isset($probe[$e]) ? function_exists($probe[$e]) : in_array($alias[$e] ?? $e, $have, true);
    if (!$ok) echo "$e ";
  }
' "$exts")"
if ! "$php" -r 'exit(function_exists("imageavif") ? 0 : 1);'; then
  missing="$missing gd-avif"
fi
# curl must resolve through the system (so /etc/resolver applies), still
# asynchronously: its threaded resolver, not c-ares.
if ! "$php" -n -r '$v = curl_version(); exit(empty($v["ares"]) && ($v["features"] & CURL_VERSION_ASYNCHDNS) ? 0 : 1);'; then
  echo "PHP's curl doesn't use the system's resolver: $("$php" -n -r '$a = curl_version()["ares"] ?? ""; echo $a !== "" ? "it uses c-ares $a" : "it has no asynchronous DNS";')" >&2
  exit 1
fi
# Excimer is the pinned one, and its profiler takes samples.
if tr ',' '\n' <<<"$exts" | grep -qx excimer && ! "$php" -r '
  if (phpversion("excimer") !== $argv[1]) { exit(1); }
  $p = new ExcimerProfiler();
  $p->setPeriod(0.001);
  $p->start();
  for ($t = hrtime(true); hrtime(true) - $t < 100e6;) {}
  $p->stop();
  exit(count($p->getLog()) > 0 ? 0 : 1);
' "$EXCIMER_VERSION"; then
  missing="$missing excimer-$EXCIMER_VERSION-sampling"
fi
pcov="buildroot/modules/pcov.so"
cli_files=(php)
if [ -n "$shared" ]; then
  if ! [ -f "$pcov" ] || ! "$php" -n -d extension="$PWD/$pcov" -r 'exit(extension_loaded("pcov") ? 0 : 1);'; then
    missing="$missing pcov"
  fi
  cli_files+=(pcov.so)
fi
if [ -n "$missing" ]; then
  echo "PHP $version is missing extensions: $missing" >&2
  exit 1
fi
if [ "$version" != "$want" ] && [[ "$want" == *.*.* ]]; then
  echo "Built PHP $version, not $want" >&2
  exit 1
fi
if [ -n "$shared" ]; then cp "$pcov" "$(dirname "$php")/pcov.so"; fi

check_macos_minimum "$(dirname "$php")"
tar -C "$(dirname "$php")" -czf "$out/php-${version}-cli-macos-${arch}.tar.gz" "${cli_files[@]}"
tar -C "$(dirname "$fpm")" -czf "$out/php-${version}-fpm-macos-${arch}.tar.gz" php-fpm
echo "Built PHP $version for macos-$arch"
