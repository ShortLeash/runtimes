#!/usr/bin/env bash
# Builds a relocatable MariaDB for one release series, for the Mac this runs
# on, with wolfSSL, zlib, PCRE2 and fmt built in (and GnuTLS with Nettle for
# its client library), and checks it serves queries and dumps from another
# folder.
#
#   scripts/mariadb.sh 11.8 out/
#
# Writes out/mariadb-<version>-macos-<arch>.tar.gz holding bin/ (mariadbd,
# mariadb, mariadb-dump, mariadb-install-db, my_print_defaults,
# mariadb-admin and the other tools), share/ (error messages, character
# sets, the system tables' SQL) and lib/plugin/. It links nothing outside
# macOS itself.
set -euo pipefail

minor="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/mariadb.env"
arch="$(shortleash_arch)"

pin="MARIADB_${minor//./_}"
version="${!pin:-}"
sha_pin="${pin}_SHA256"
sha="${!sha_pin:-}"
if [ -z "$version" ] || [ -z "$sha" ]; then
  echo "No MariaDB $minor in mariadb.env" >&2
  exit 1
fi

work="$(mktemp -d)"
cd "$work"
stage="$work/stage"
mkdir -p "$stage"

# --- Build ------------------------------------------------------------------
# The source: the pinned SHA-256, which must also be archive.mariadb.org's.
tarball="mariadb-$version.tar.gz"
base="https://archive.mariadb.org/mariadb-$version/source"
fetch_checked "$base/$tarball" "$sha" "$tarball"
published="$(curl -fsSL "$base/sha256sums.txt" |
  awk -v f="$tarball" '$2 == f || $2 == "*" f {print $1}')"
if [ "$published" != "$sha" ]; then
  echo "$tarball: archive.mariadb.org lists SHA-256 '${published:-none}', not the pinned $sha" >&2
  exit 1
fi
tar -xzf "$tarball"
mv "mariadb-$version" src

# MariaDB's CMake downloads fmt and PCRE2 while it builds, checked only with an
# MD5. Fetch the same releases here, checked against GitHub's digests, and
# point CMake at the local files with their SHA-256. A plain path (no URL
# scheme) makes CMake verify and unpack the file without its download code.
want_fmt="$(grep -oE 'fmt-[0-9.]+\.zip' src/cmake/libfmt.cmake | tail -1 | sed -E 's/^fmt-(.*)\.zip$/\1/')"
want_pcre2="$(grep -oE 'pcre2-[0-9.]+\.zip' src/cmake/pcre.cmake | tail -1 | sed -E 's/^pcre2-(.*)\.zip$/\1/')"
if [ "$want_fmt" != "$MARIADB_FMT_VERSION" ] || [ "$want_pcre2" != "$MARIADB_PCRE2_VERSION" ]; then
  echo "MariaDB now wants fmt $want_fmt / pcre2 $want_pcre2; update mariadb.env" >&2
  exit 1
fi
fmt_zip="$work/fmt-$MARIADB_FMT_VERSION.zip"
pcre2_zip="$work/pcre2-$MARIADB_PCRE2_VERSION.zip"
fetch_github_asset fmtlib/fmt "$MARIADB_FMT_VERSION" "fmt-$MARIADB_FMT_VERSION.zip" "$fmt_zip"
fetch_github_asset PCRE2Project/pcre2 "pcre2-$MARIADB_PCRE2_VERSION" "pcre2-$MARIADB_PCRE2_VERSION.zip" "$pcre2_zip"
fmt_sha="$(shasum -a 256 "$fmt_zip" | cut -d' ' -f1)"
pcre2_sha="$(shasum -a 256 "$pcre2_zip" | cut -d' ' -f1)"
# libfmt.cmake also names an older fmt for GCC before 4.9, which Apple clang
# never takes; it's pointed at the same checked file so nothing can download.
sed -i '' -E \
  -e "s|URL \"https://github\\.com/fmtlib/fmt/releases/download/[^\"]*\"|URL \"$fmt_zip\"|" \
  -e "s|URL_MD5 [0-9a-fA-F]+|URL_HASH SHA256=$fmt_sha|" src/cmake/libfmt.cmake
sed -i '' -E \
  -e "s|URL \"https://github\\.com/PCRE2Project/pcre2/releases/download/[^\"]*\"|URL \"$pcre2_zip\"|" \
  -e "s|URL_MD5 [0-9a-fA-F]+|URL_HASH SHA256=$pcre2_sha|" src/cmake/pcre.cmake
if grep -rnE '(^|[[:space:](])URL +"?https?://' src/cmake/ || grep -rn 'URL_MD5' src/cmake/libfmt.cmake src/cmake/pcre.cmake; then
  echo "MariaDB's CMake still downloads something; localise it first" >&2
  exit 1
fi

# mariadb-install-db looks for my_print_defaults in an unquoted --basedir, so
# a path with a space in it (Short Leash's home has one) fails; quote it.
sed -i '' -E 's/(find_in_dirs|cannot_find_file) my_print_defaults \$basedir\/bin \$basedir\/extra/\1 my_print_defaults "$basedir\/bin" "$basedir\/extra"/' \
  src/scripts/mysql_install_db.sh
if grep -n 'my_print_defaults \$basedir' src/scripts/mysql_install_db.sh; then
  echo "mariadb-install-db's --basedir lookup changed; check it copes with spaces" >&2
  exit 1
fi

# Everything builds with macOS's own tools on PATH, so Homebrew's and other
# prefixes' pkg-config, krb5-config and libraries stay out.
clean_path=/usr/bin:/bin:/usr/sbin:/sbin
log="$work/build.log"
: >"$log"

# Connector/C, the client library, uses GnuTLS when the server has wolfSSL.
# Build it static with Nettle (mini-gmp, so no GMP) and nothing else: its own
# copies of libtasn1 and libunistring, no p11-kit, IDN or compression. The
# pinned SHA-256 is the check this build runs (mariadb.env says how the pins
# were checked against upstream's signatures).
deps="$work/deps"
# GnuTLS's configure needs pkg-config; it may only see Nettle's .pc files.
pkg_config="$(command -v pkg-config || true)"
[ -n "$pkg_config" ] || { echo "GnuTLS needs pkg-config to build; install it first" >&2; exit 1; }
fetch_checked "https://ftp.gnu.org/gnu/nettle/nettle-$MARIADB_NETTLE_VERSION.tar.gz" \
  "$MARIADB_NETTLE_SHA256" nettle.tar.gz
fetch_checked "https://www.gnupg.org/ftp/gcrypt/gnutls/v${MARIADB_GNUTLS_VERSION%.*}/gnutls-$MARIADB_GNUTLS_VERSION.tar.xz" \
  "$MARIADB_GNUTLS_SHA256" gnutls.tar.xz
tar -xzf nettle.tar.gz
tar -xJf gnutls.tar.xz
(
  export PATH="$clean_path"
  unset PKG_CONFIG_PATH
  cd "nettle-$MARIADB_NETTLE_VERSION"
  ./configure --prefix="$deps" --libdir="$deps/lib" --enable-mini-gmp --disable-shared \
    --enable-static --disable-documentation --disable-openssl &&
    make -j"$(sysctl -n hw.ncpu)" && make install
) >>"$log" 2>&1 || {
  tail -n 100 "$log" >&2
  echo "Nettle $MARIADB_NETTLE_VERSION didn't build; the log is $log" >&2
  exit 1
}
(
  export PATH="$clean_path" PKG_CONFIG="$pkg_config" PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig"
  unset PKG_CONFIG_PATH
  export NETTLE_CFLAGS="-I$deps/include" NETTLE_LIBS="-L$deps/lib -lnettle"
  export HOGWEED_CFLAGS="-I$deps/include" HOGWEED_LIBS="-L$deps/lib -lhogweed -lnettle"
  cd "gnutls-$MARIADB_GNUTLS_VERSION"
  ./configure --prefix="$deps" --libdir="$deps/lib" --with-nettle-mini \
    --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn \
    --without-zlib --without-brotli --without-zstd --without-tpm --without-tpm2 \
    --disable-doc --disable-tests --disable-tools --disable-cxx --disable-nls \
    --disable-libdane --enable-static --disable-shared &&
    make -j"$(sysctl -n hw.ncpu)" && make install
) >>"$log" 2>&1 || {
  tail -n 100 "$log" >&2
  echo "GnuTLS $MARIADB_GNUTLS_VERSION didn't build; the log is $log" >&2
  exit 1
}
# CMake's FindGnuTLS would ask pkg-config or search the system; this one names
# the static libraries and what they need from macOS.
modules="$work/cmake-modules"
mkdir -p "$modules"
cat >"$modules/FindGnuTLS.cmake" <<CMAKE
set(GNUTLS_INCLUDE_DIR "$deps/include")
set(GNUTLS_LIBRARY "$deps/lib/libgnutls.a")
set(GNUTLS_INCLUDE_DIRS "\${GNUTLS_INCLUDE_DIR}")
set(GNUTLS_LIBRARIES "$deps/lib/libgnutls.a;$deps/lib/libhogweed.a;$deps/lib/libnettle.a;-liconv;-framework Security;-framework CoreFoundation")
set(GNUTLS_VERSION "$MARIADB_GNUTLS_VERSION")
set(GNUTLS_VERSION_STRING "$MARIADB_GNUTLS_VERSION")
set(GnuTLS_VERSION "$MARIADB_GNUTLS_VERSION")
set(GNUTLS_FOUND TRUE)
set(GnuTLS_FOUND TRUE)
CMAKE

# MariaDB: wolfSSL, zlib, PCRE2 and fmt are its bundled copies, and plugins
# that need other libraries are left out. The client's line editing is macOS's
# libedit.
cmake_bin="$(command -v cmake)"
(
  export PATH="$clean_path"
  unset PKG_CONFIG_PATH
  cmake() { "$cmake_bin" "$@"; }
  cmake -S src -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" -DINSTALL_LAYOUT=STANDALONE \
    -DINSTALL_SCRIPTDIR=bin -DWITH_SSL=bundled -DWITH_ZLIB=bundled -DWITH_PCRE=bundled \
    -DWITH_LIBFMT=bundled -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_WSREP=OFF \
    -DWITH_MARIABACKUP=OFF -DPLUGIN_TOKUDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO \
    -DPLUGIN_OQGRAPH=NO -DPLUGIN_CONNECT=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_COLUMNSTORE=NO \
    -DPLUGIN_S3=NO -DPLUGIN_SPHINX=NO -DPLUGIN_AUTH_GSSAPI=NO -DPLUGIN_AUTH_PAM=NO \
    -DPLUGIN_PROVIDER_LZ4=NO -DPLUGIN_PROVIDER_LZO=NO -DPLUGIN_PROVIDER_SNAPPY=NO \
    -DPLUGIN_PROVIDER_LZMA=NO -DPLUGIN_PROVIDER_BZIP2=NO \
    -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF -DCMAKE_MODULE_PATH="$modules" \
    -DNETTLE_INCLUDE_DIR="$deps/include" -DNETTLE_LIBRARY="$deps/lib/libnettle.a" \
    -DHOGWEED_LIBRARY="$deps/lib/libhogweed.a" &&
    cmake --build build -j"$(sysctl -n hw.ncpu)" &&
    cmake --install build --prefix "$stage"
) >>"$log" 2>&1 || {
  tail -n 200 "$log" >&2
  echo "MariaDB $version didn't build; the log is $log" >&2
  exit 1
}
if grep -n 'Downloading' "$log"; then
  echo "MariaDB's build downloaded something; localise it first" >&2
  exit 1
fi

# Keep what Short Leash runs: no tests, benchmarks, manuals, headers, static
# libraries or packaging files.
rm -rf "$stage"/{mysql-test,mariadb-test,sql-bench,man,include,support-files,docs}
rm -f "$stage"/lib/*.a
for t in mariadb-test mariadb-test-embedded mariadb-client-test mariadb-client-test-embedded \
  mysqltest mysqltest_embedded mysql_client_test mysql_client_test_embedded; do
  rm -f "$stage/bin/$t"
done
find "$stage" -type f -exec sh -c 'file "$1" | grep -q Mach-O && echo "$1"' _ {} \; |
  while read -r f; do strip -x "$f"; done
# The licences and notices of everything built in travel with the programs:
# MariaDB's, Connector/C's, wolfSSL's (with its exception for MariaDB),
# GnuTLS's, Nettle's, and fmt's and PCRE2's from the checked zips (MariaDB's
# THIRDPARTY has neither). share/doc/COPYING is the GPL-2.0 text that
# Nettle's and GnuTLS's included unistring are used under.
doc="$stage/share/doc"
mkdir -p "$doc"/{connector-c,wolfssl,gnutls,nettle,fmt,pcre2}
cp src/COPYING src/THIRDPARTY "$doc/"
cp src/libmariadb/COPYING.LIB "$doc/connector-c/"
cp src/extra/wolfssl/wolfssl/{COPYING,LICENSING} "$doc/wolfssl/"
cp "gnutls-$MARIADB_GNUTLS_VERSION/COPYING.LESSERv2" "$doc/gnutls/"
cp "nettle-$MARIADB_NETTLE_VERSION"/{COPYINGv2,COPYINGv3,COPYING.LESSERv3} "$doc/nettle/"
unzip -p "$fmt_zip" "fmt-$MARIADB_FMT_VERSION/LICENSE" >"$doc/fmt/LICENSE"
unzip -p "$pcre2_zip" "pcre2-$MARIADB_PCRE2_VERSION/LICENCE.md" >"$doc/pcre2/LICENCE.md"
notices=(COPYING THIRDPARTY connector-c/COPYING.LIB wolfssl/COPYING wolfssl/LICENSING
  gnutls/COPYING.LESSERv2 nettle/COPYINGv2 nettle/COPYINGv3 nettle/COPYING.LESSERv3
  fmt/LICENSE pcre2/LICENCE.md)
grep -q 'MariaDB Server' "$doc/wolfssl/LICENSING" && grep -q 'GPLv2' "$doc/wolfssl/LICENSING" ||
  { echo "wolfSSL's LICENSING no longer names MariaDB Server's GPLv2 exception" >&2; exit 1; }
grep -q 'Permission is hereby granted' "$doc/fmt/LICENSE" || { echo "fmt's LICENSE isn't its MIT licence" >&2; exit 1; }
grep -q 'BSD' "$doc/pcre2/LICENCE.md" || { echo "PCRE2's LICENCE.md isn't its BSD licence" >&2; exit 1; }
for p in mariadbd mariadb mariadb-dump mariadb-install-db my_print_defaults mariadb-admin; do
  [ -e "$stage/bin/$p" ] || { echo "The build has no bin/$p" >&2; exit 1; }
done

# --- Smoke test -------------------------------------------------------------
# Copied into a folder with a space in its path, as Short Leash's home has, it
# initialises a data folder, serves a query over TCP on 127.0.0.1 only, dumps
# and restores a database, logs a user in with a password, and links nothing
# outside macOS.
moved="$work/Application Support/mariadb"
mkdir -p "$(dirname "$moved")"
cp -R "$stage" "$moved"
data="$work/Application Support/data"
port=53306
sock="$work/m.sock"

"$moved/bin/mariadb-install-db" --no-defaults --basedir="$moved" --datadir="$data" \
  --auth-root-authentication-method=normal --skip-test-db >"$work/install-db.log" 2>&1 || {
  cat "$work/install-db.log" >&2
  echo "mariadb-install-db failed" >&2
  exit 1
}

"$moved/bin/mariadbd" --no-defaults --basedir="$moved" --datadir="$data" \
  --port="$port" --bind-address=127.0.0.1 --socket="$sock" \
  --pid-file="$work/mariadbd.pid" --log-error="$work/mariadbd.log" &
pid=$!
trap 'kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true' EXIT

# root has no password, so the client can't check the server's certificate
# against one; say so rather than have it warn on every call.
root=(--no-defaults --protocol=TCP -h 127.0.0.1 -P "$port" -u root --disable-ssl-verify-server-cert)
sql() {
  "$moved/bin/mariadb" "${root[@]}" -N -B "$@"
}
for _ in $(seq 1 120); do
  "$moved/bin/mariadb-admin" "${root[@]}" ping >/dev/null 2>&1 && break
  kill -0 "$pid" 2>/dev/null || { cat "$work/mariadbd.log" >&2; echo "mariadbd exited" >&2; exit 1; }
  sleep 0.5
done

# root gets in over TCP with no password, and it's this version.
got="$(sql -e 'SELECT VERSION()')"
case "$got" in
  "$version-MariaDB"*) ;;
  *) echo "SELECT VERSION() answered '$got', not $version-MariaDB" >&2; exit 1 ;;
esac

# A dump restores into another database.
sql -e 'CREATE DATABASE shop; CREATE TABLE shop.items (id INT PRIMARY KEY, name VARCHAR(20));
  INSERT INTO shop.items VALUES (1, "tea"), (2, "cake");'
"$moved/bin/mariadb-dump" "${root[@]}" --single-transaction --routines --triggers --events --hex-blob --no-tablespaces shop >"$work/shop.sql"
sql -e 'CREATE DATABASE shop2'
sql shop2 <"$work/shop.sql"
count="$(sql -e 'SELECT COUNT(*) FROM shop2.items')"
[ "$count" = 2 ] || { echo "The restored dump has $count rows, not 2" >&2; exit 1; }

# A user with a password logs in (the client hashes it with GnuTLS's Nettle),
# over TLS when the server offers it (11.4 and later make their own
# certificate).
sql -e "CREATE USER app@'%' IDENTIFIED BY 'shortleash-smoke'; GRANT SELECT ON shop2.* TO app@'%';"
app=(--no-defaults --protocol=TCP -h 127.0.0.1 -P "$port" -u app --password=shortleash-smoke -N -B)
count="$("$moved/bin/mariadb" "${app[@]}" -e 'SELECT COUNT(*) FROM shop2.items')"
[ "$count" = 2 ] || { echo "A user with a password couldn't read the restored table" >&2; exit 1; }
if [ "$(sql -e 'SELECT @@have_ssl')" = YES ]; then
  cipher="$("$moved/bin/mariadb" "${app[@]}" --ssl -e "SHOW SESSION STATUS LIKE 'Ssl_cipher'" | cut -f2)"
  [ -n "$cipher" ] || { echo "The client didn't use TLS though the server offers it" >&2; exit 1; }
fi

# It listens on 127.0.0.1 only.
listening="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN)"
if ! grep -q "127.0.0.1:$port" <<<"$listening" || grep -q "\*:$port" <<<"$listening"; then
  echo "mariadbd isn't listening on 127.0.0.1:$port only:" >&2
  echo "$listening" >&2
  exit 1
fi

# Relocatable: nothing links outside macOS, every @rpath library is in the
# archive, and no run path points outside it.
bad="$(find "$stage" -type f -exec sh -c 'file "$1" | grep -q Mach-O && echo "$1"' _ {} \; |
  while read -r f; do
    otool -L "$f" | tail -n +2 | awk '{print $1}' |
      { grep -vE '^(/usr/lib/|/System/Library/|@loader_path/|@rpath/)' || true; } | sed "s|^|$f: |"
    otool -L "$f" | tail -n +2 | awk '{print $1}' | { grep '^@rpath/' || true; } |
      while read -r lib; do
        [ -n "$(find "$stage" -name "${lib#@rpath/}" -print -quit)" ] || echo "$f: $lib isn't in the archive"
      done
    otool -l "$f" | awk '$1 == "cmd" {c = $2} c == "LC_RPATH" && $1 == "path" {print $2}' |
      { grep -vE '^@(loader|executable)_path(/|$)' || true; } | sed "s|^|$f: run path |"
  done)"
if [ -n "$bad" ]; then
  echo "MariaDB $version links outside macOS:" >&2
  echo "$bad" >&2
  exit 1
fi

check_macos_minimum "$stage"

archive="$out/mariadb-$version-macos-$arch.tar.gz"
tar -C "$stage" -czf "$archive" bin share lib
# The archive carries every licence and notice.
listing="$(tar -tzf "$archive")"
for f in "${notices[@]}"; do
  grep -qx "share/doc/$f" <<<"$listing" || { rm -f "$archive"; echo "The archive has no share/doc/$f" >&2; exit 1; }
done
echo "Built MariaDB $version on macos-$arch"
