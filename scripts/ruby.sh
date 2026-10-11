#!/usr/bin/env bash
# Builds a relocatable Ruby for one minor version, for the Mac this runs on:
# the newest patch release from ruby-lang.org, with OpenSSL and libyaml built
# in statically, so the folder works wherever DevKit unpacks it.
#
#   scripts/ruby.sh 3.4 out/
#
# Writes out/ruby-<version>-macos-<arch>.tar.gz holding a ruby/ folder
# (bin, lib, include). Fails unless the build, moved to another path, loads
# openssl and psych and links nothing outside the system's libraries.
set -euo pipefail

minor="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
arch="$(devkit_arch)"
openssl_tag="${OPENSSL_TAG:-openssl-3.5.9}"
libyaml_version=0.2.5
# yaml/libyaml publishes no digest; this is the SHA-256 of its 0.2.5 release
# on GitHub and on pyyaml.org (they match).
libyaml_sha256=c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4
jobs="$(sysctl -n hw.ncpu)"

work="$(mktemp -d)"
deps="$work/deps"
cd "$work"

# Ruby: the newest patch of the minor, with ruby-lang.org's SHA-256.
read -r version url sha256 < <(curl -fsSL https://cache.ruby-lang.org/pub/ruby/index.txt |
  awk -v m="$minor" -F'\t' '$1 ~ "^ruby-" m "\\.[0-9]+$" && $2 ~ /\.tar\.gz$/ {print substr($1, 6), $2, $4}' |
  sort -t. -k3,3n | tail -1)
[ -n "${version:-}" ] || { echo "No Ruby $minor release on ruby-lang.org" >&2; exit 1; }
fetch_checked "$url" "$sha256" ruby.tar.gz

fetch_github_asset openssl/openssl "$openssl_tag" "$openssl_tag.tar.gz" openssl.tar.gz
fetch_checked "https://github.com/yaml/libyaml/releases/download/$libyaml_version/yaml-$libyaml_version.tar.gz" \
  "$libyaml_sha256" yaml.tar.gz

tar -xzf openssl.tar.gz
(cd "$openssl_tag" && ./Configure "darwin64-$( [ "$arch" = aarch64 ] && echo arm64 || echo x86_64 )-cc" \
  no-shared no-tests --prefix="$deps" --libdir=lib && make -j"$jobs" && make install_sw)

tar -xzf yaml.tar.gz
(cd "yaml-$libyaml_version" && ./configure --prefix="$deps" --disable-shared --enable-static && make -j"$jobs" && make install)

prefix="$work/ruby"
tar -xzf ruby.tar.gz
# Ruby 4.0's psych asks pkg-config first and then ignores --with-libyaml-dir, so
# pkg-config may only see our own deps, not Homebrew's (during make too, when
# the extensions configure).
(cd "ruby-$version" &&
  export PKG_CONFIG_PATH="$deps/lib/pkgconfig" PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" &&
  ./configure --prefix="$prefix" --enable-load-relative --disable-install-doc \
    --with-openssl-dir="$deps" --with-libyaml-dir="$deps" --without-gmp &&
  make -j"$jobs" && make install)

# Relocatable: nothing may link outside the system's own libraries.
bad="$(find "$prefix" -type f \( -perm -u+x -o -name '*.bundle' -o -name '*.dylib' \) -print0 |
  xargs -0 file | grep Mach-O | cut -d: -f1 |
  while read -r f; do otool -L "$f" | tail -n +2 | awk '{print $1}' |
    { grep -vE '^(/usr/lib/|/System/|@rpath/|@loader_path/|@executable_path/)' || true; } | sed "s|^|$f: |"; done)"
if [ -n "$bad" ]; then
  echo "Ruby $version links outside the system:" >&2
  echo "$bad" >&2
  exit 1
fi

# Moved somewhere else, it still works.
moved="$work/moved/elsewhere/ruby"
mkdir -p "$(dirname "$moved")"
cp -R "$prefix" "$moved"
"$moved/bin/ruby" -ropenssl -rpsych -rzlib -rfiddle -e 'puts "#{RUBY_VERSION} #{OpenSSL::OPENSSL_LIBRARY_VERSION} libyaml #{Psych::LIBYAML_VERSION}"'
"$moved/bin/gem" --version >/dev/null
"$moved/bin/bundle" --version >/dev/null

check_macos_minimum "$prefix"
tar -C "$work" -czf "$out/ruby-${version}-macos-${arch}.tar.gz" ruby
echo "Built Ruby $version for macos-$arch"
