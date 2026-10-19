#!/usr/bin/env bash
# Builds PostGIS for Windows x64 against one of the Postgres versions DevKit
# installs there (the theseus-rs builds, compiled with MSVC), without raster
# support (no GDAL). Runs in MSYS2's UCRT64 shell: GCC whose C runtime is the
# Universal CRT the MSVC Postgres uses too.
#
#   scripts/postgis-windows.sh 18.6.0 out/ [work folder]
#
# Writes out/postgis-<version>-pg<major>-windows-x86_64.zip holding lib/
# (postgis-3.dll and postgis_topology-3.dll), extension/ (the postgis,
# postgis_topology and postgis_tiger_geocoder control and SQL files),
# proj/proj.db, which PROJ finds through PROJ_DATA, and doc/ with the
# licences of everything linked in. GEOS, PROJ, json-c, protobuf-c, libxml2
# and SQLite come from the same checked sources as on macOS (libxml2 and
# SQLite are Windows only) and, with GCC's C++ runtime and winpthreads, are
# linked into the modules statically: they import only postgres.exe and
# Windows' own DLLs, so nothing lands beside postgres.exe, whose folder
# already holds DLLs of the same names (zlib1, libiconv-2, libwinpthread-1).
#
# The work folder keeps the Postgres it was built against (pgroot/) and the
# archive's contents (stage/) for scripts/postgis-smoke.ps1, which the
# workflow runs next.
set -euo pipefail
# A failing command substitution stops the script without a word.
trap 'echo "postgis-windows.sh stopped at line $LINENO: $BASH_COMMAND" >&2' ERR

pg="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/postgis.env"
major="${pg%%.*}"
# 18.6.0 is PostgreSQL 18.6.
pgsrc_version="${pg%.0}"

# lib.sh hashes with shasum, which MSYS2's perl may not put on the PATH.
command -v shasum >/dev/null || shasum() { shift 2; sha256sum "$@"; }

work="${3:-$(mktemp -d)}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
[ -z "$(ls -A "$work")" ] || { echo "The work folder $work isn't empty" >&2; exit 1; }
cd "$work"
stage="$work/stage"
mkdir -p "$stage/lib" "$stage/extension" "$stage/proj" "$stage/doc"
prefix="$work/prefix"
mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/include"
jobs="$(nproc)"
log="$work/build.log"
: >"$log"
failed() {
  tail -n 150 "$log" >&2
  echo "$1 didn't build; the log is $log" >&2
  exit 1
}
# Native programs (CMake, pg_config) take Windows paths with forward slashes.
win() { cygpath -m "$1"; }

# --- Inputs -----------------------------------------------------------------
# The MSVC Postgres, checked against the digest GitHub publishes for it.
fetch_github_asset theseus-rs/postgresql-binaries "$pg" "postgresql-$pg-x86_64-pc-windows-msvc.zip" pg.zip
unzip -q pg.zip
mv "postgresql-$pg-x86_64-pc-windows-msvc" pgroot
pgroot="$work/pgroot"

# The same Postgres's source, checked against postgresql.org's SHA-256: its
# headers and PGXS, configured for GCC, build the modules.
pgtar="postgresql-$pgsrc_version.tar.bz2"
pgsha="$(curl -fsSL "https://ftp.postgresql.org/pub/source/v$pgsrc_version/$pgtar.sha256" | awk '{print $1}')"
[ -n "$pgsha" ] || { echo "Couldn't read postgresql.org's SHA-256 for $pgtar" >&2; exit 1; }
fetch_checked "https://ftp.postgresql.org/pub/source/v$pgsrc_version/$pgtar" "$pgsha" "$pgtar"

# PostGIS: the pinned SHA-256, which must also match download.osgeo.org's MD5.
tarball="postgis-$POSTGIS_VERSION.tar.gz"
fetch_checked "https://download.osgeo.org/postgis/source/$tarball" "$POSTGIS_SHA256" "$tarball"
published="$(curl -fsSL "https://download.osgeo.org/postgis/source/$tarball.md5" | awk '{print $1}')"
got="$(md5sum "$tarball" | cut -d' ' -f1)"
if [ "$published" != "$got" ]; then
  echo "$tarball: download.osgeo.org lists MD5 '${published:-none}', not $got" >&2
  exit 1
fi
fetch_github_asset libgeos/geos "$GEOS_VERSION" "geos-$GEOS_VERSION.tar.bz2" geos.tar.bz2
fetch_github_asset OSGeo/PROJ "$PROJ_VERSION" "proj-$PROJ_VERSION.tar.gz" proj.tar.gz
fetch_github_asset json-c/json-c "$JSONC_TAG" "json-c-$JSONC_VERSION.tar.gz" json-c.tar.gz
fetch_checked "https://github.com/protobuf-c/protobuf-c/releases/download/v$PROTOBUFC_VERSION/protobuf-c-$PROTOBUFC_VERSION.tar.gz" \
  "$PROTOBUFC_SHA256" protobuf-c.tar.gz
# libxml2: the pinned SHA-256, which must also be download.gnome.org's.
xml="libxml2-$LIBXML2_VERSION.tar.xz"
xml_url="https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/$xml"
fetch_checked "$xml_url" "$LIBXML2_SHA256" "$xml"
published="$(curl -fsSL "${xml_url%.tar.xz}.sha256sum" | awk -v f="$xml" '$2 == f {print $1}')"
if [ "$published" != "$LIBXML2_SHA256" ]; then
  echo "$xml: download.gnome.org lists SHA-256 '${published:-none}', not the pinned $LIBXML2_SHA256" >&2
  exit 1
fi
fetch_checked "https://sqlite.org/$SQLITE_TARBALL" "$SQLITE_SHA256" sqlite.tar.gz
# MSYS2's tar makes a symlink as a copy of its target, so one whose target
# comes later in the tarball (json-c's tests) fails the first time and is
# copied the second.
for t in "$pgtar" "$tarball" geos.tar.bz2 proj.tar.gz json-c.tar.gz protobuf-c.tar.gz "$xml" sqlite.tar.gz; do
  tar -xf "$t" 2>/dev/null || tar -xf "$t"
done
sqlite_src="$(basename "$SQLITE_TARBALL" .tar.gz)"

# --- Toolchain --------------------------------------------------------------
# MSYS2's packages, checked by pacman against MSYS2's keyring. Of them, only
# GCC's runtime (libgcc, libstdc++), winpthreads and mingw-w64's start-up code
# end up in the modules; the build records their versions and ships their
# licences.
# protoc-c writes PostGIS's vector tile and Geobuf code from its .proto files
# at build time, like on macOS: MSYS2's protobuf-c must be the runtime's 1.5.x
# series, and nothing of it is linked (the import check proves it). It runs
# as protoc's plugin, the way protoc-c itself does.
protoc="$(command -v protoc || true)"
protoc_gen_c="$(command -v protoc-gen-c || true)"
if [ -z "$protoc" ] || [ -z "$protoc_gen_c" ]; then
  echo "PostGIS needs protoc and protoc-gen-c to build; install MSYS2's protobuf-c first" >&2
  exit 1
fi
protoc_c_version="$(pacman -Q mingw-w64-ucrt-x86_64-protobuf-c | awk '{print $2}')"
protoc_c_version="${protoc_c_version%-*}"
if [ "${protoc_c_version%.*}" != "${PROTOBUFC_VERSION%.*}" ]; then
  echo "MSYS2's protobuf-c is ${protoc_c_version:-unknown}, not ${PROTOBUFC_VERSION%.*}.x like the runtime" >&2
  exit 1
fi
protoc_c="$work/protoc-c"
cat >"$protoc_c" <<SH
#!/bin/sh
exec "$protoc" --plugin=protoc-gen-c="$(win "$protoc_gen_c")" "\$@"
SH
chmod +x "$protoc_c"
runtime_libs=()
for f in "$(gcc -print-file-name=libstdc++.a)" "$(gcc -print-libgcc-file-name)" \
  "$(gcc -print-file-name=libwinpthread.a)" "$(gcc -print-file-name=libmingwex.a)"; do
  runtime_libs+=("$(cygpath -u "$f")")
done
runtime_pkgs="$(pacman -Qqo "${runtime_libs[@]}" | sort -u)"
# shellcheck disable=SC2086 # one package per word
{
  echo "Built with $(gcc --version | head -n 1) in MSYS2 UCRT64."
  echo "Linked in statically from these MSYS2 packages:"
  pacman -Q $runtime_pkgs
} >"$stage/doc/toolchain.txt"

# Static libraries only, so nothing outside the prefix is linked. MSYS2's
# own .pc files stay out of sight.
export PKG_CONFIG_PATH="" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
cmake_common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$(win "$prefix")"
  -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$(win "$prefix")" -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
cmake_build() { # cmake_build NAME SOURCE [OPTION...]
  local name="$1" src="$2"
  shift 2
  {
    cmake -S "$src" -B "$src/build" "${cmake_common[@]}" "$@" &&
      cmake --build "$src/build" -j"$jobs" &&
      cmake --install "$src/build"
  } >>"$log" 2>&1 || failed "$name"
}

# --- Libraries --------------------------------------------------------------
# SQLite, and the sqlite3 program PROJ's build writes proj.db with.
(
  cd "$sqlite_src"
  gcc -O2 -DSQLITE_THREADSAFE=1 -c sqlite3.c -o sqlite3.o &&
    ar rcs "$prefix/lib/libsqlite3.a" sqlite3.o &&
    cp sqlite3.h sqlite3ext.h "$prefix/include/" &&
    gcc -O2 shell.c sqlite3.o -o "$prefix/bin/sqlite3.exe"
) >>"$log" 2>&1 || failed "SQLite $SQLITE_VERSION"
cmake_build "GEOS $GEOS_VERSION" "geos-$GEOS_VERSION" -DBUILD_BENCHMARKS=OFF -DBUILD_DOCUMENTATION=OFF
# PROJ with proj.db as a file (not embedded) and no build path baked in: PROJ
# finds it through PROJ_DATA, or in share/proj beside the module's folder.
cmake_build "PROJ $PROJ_VERSION" "proj-$PROJ_VERSION" -DENABLE_TIFF=OFF -DENABLE_CURL=OFF \
  -DBUILD_APPS=OFF -DBUILD_PROJSYNC=OFF -DEMBED_RESOURCE_FILES=OFF -DEMBED_PROJ_DATA_PATH=OFF \
  -DNLOHMANN_JSON_ORIGIN=internal -DSQLite3_INCLUDE_DIR="$(win "$prefix/include")" -DSQLite3_LIBRARY="$(win "$prefix/lib/libsqlite3.a")" \
  -DEXE_SQLITE3="$(win "$prefix/bin/sqlite3.exe")"
cmake_build "json-c $JSONC_VERSION" "json-c-$JSONC_VERSION" -DBUILD_STATIC_LIBS=ON \
  -DDISABLE_EXTRA_LIBS=ON -DBUILD_APPS=OFF
(
  cd "protobuf-c-$PROTOBUFC_VERSION"
  ./configure --prefix="$prefix" --libdir="$prefix/lib" --disable-shared --enable-static --disable-protoc &&
    make -j"$jobs" && make install
) >>"$log" 2>&1 || failed "protobuf-c $PROTOBUFC_VERSION"
# libxml2 with only what PostGIS reads GML and KML with: UTF-8 and Latin-1
# built in (no iconv), no zlib, no HTTP.
cmake_build "libxml2 $LIBXML2_VERSION" "libxml2-$LIBXML2_VERSION" -DLIBXML2_WITH_ICONV=OFF \
  -DLIBXML2_WITH_ZLIB=OFF -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_TESTS=OFF \
  -DLIBXML2_WITH_MODULES=OFF -DLIBXML2_WITH_DOCS=OFF
# PostGIS asks xml2-config for libxml2's flags; static on Windows needs
# LIBXML_STATIC, or its headers ask for a DLL.
xml2_version="$(awk -F'"' '/#define LIBXML_DOTTED_VERSION/ {print $2}' "$prefix/include/libxml2/libxml/xmlversion.h")"
[ "$xml2_version" = "$LIBXML2_VERSION" ] || { echo "libxml2's headers say ${xml2_version:-nothing}, not $LIBXML2_VERSION" >&2; exit 1; }
cat >"$work/xml2-config" <<SH
#!/bin/sh
case "\$1" in --cflags) echo "-I$prefix/include/libxml2 -DLIBXML_STATIC" ;; --libs) echo "-L$prefix/lib -lxml2 -lbcrypt" ;; --version) echo "$xml2_version" ;; esac
SH
chmod +x "$work/xml2-config"

# --- Postgres's headers, PGXS and libpq, configured for GCC -----------------
# Only what building a module needs; the server itself isn't built. libpq is
# there because PostGIS's configure links a test program against it.
pgmingw="$work/pgsql"
(
  cd "postgresql-$pgsrc_version"
  ./configure --prefix="$pgmingw" --without-readline --without-zlib --without-icu --without-openssl &&
    make -C src/backend generated-headers &&
    make -C src/include install &&
    make -C src/interfaces/libpq install &&
    make -C src/bin/pg_config install &&
    make -C src/makefiles install &&
    make -C config install &&
    make -C src install-local
) >>"$log" 2>&1 || failed "Postgres $pgsrc_version's headers"
pg_config="$pgmingw/bin/pg_config.exe"
includedir_server="$("$pg_config" --includedir-server)"

# The modules load into the MSVC build, so its ABI must be what these headers
# describe: sizes, alignments and block sizes the same in both pg_config.h.
abi() { # abi FILE: the defines a module's structs depend on, sorted
  grep -E '^#define (ALIGNOF_[A-Z0-9_]+|SIZEOF_[A-Z0-9_]+|MAXIMUM_ALIGNOF|BLCKSZ|XLOG_BLCKSZ|RELSEG_SIZE|USE_FLOAT8_BYVAL|FLOAT8PASSBYVAL|PG_VERSION_NUM) ' "$1" |
    grep -v INT128 | tr -d '\r' | awk '{print $2, $3}' | sort
}
msvc_abi="$(abi "$pgroot/include/server/pg_config.h")"
[ -n "$msvc_abi" ] || { echo "The MSVC Postgres's pg_config.h has none of the defines checked" >&2; exit 1; }
gcc_abi="$(abi "$includedir_server/pg_config.h")"
missing="$(comm -23 <(echo "$msvc_abi") <(echo "$gcc_abi"))"
if [ -n "$missing" ]; then
  echo "Postgres $pgsrc_version configured for GCC differs from the MSVC build in:" >&2
  echo "$missing" >&2
  exit 1
fi

# c.h gives GCC on Windows its own setjmp (a 5-word buffer), but the MSVC
# server longjmps with the C runtime's: a module's PG_TRY would hand it a
# buffer it can't read. The modules use the C runtime's setjmp instead, as
# the server does. (PostGIS 3.6 has no PG_TRY; this keeps it safe if it adds
# one.)
c_h="$includedir_server/c.h"
perl -0pi -e 's/#ifdef __MINGW64__\ntypedef intptr_t sigjmp_buf\[5\];/#if 0 \/* DevKit: the MSVC server longjmps with the C runtime *\/\ntypedef intptr_t sigjmp_buf[5];/' "$c_h"
grep -q 'DevKit: the MSVC server longjmps' "$c_h" || { echo "Couldn't switch c.h to the C runtime's setjmp" >&2; exit 1; }

# The import library modules link postgres.exe's exports through.
(
  cd "$work"
  gendef - "$pgroot/bin/postgres.exe" >postgres.def &&
    dlltool -d postgres.def -D postgres.exe -l "$("$pg_config" --libdir)/libpostgres.a"
) >>"$log" 2>&1 || failed "postgres.exe's import library"

# --- PostGIS ------------------------------------------------------------------
# GNU ld links static libraries in order, so each library's own needs follow
# it: libgeos_c needs libgeos and the C++ runtime (and its threads), libproj
# SQLite, the C++ runtime and Windows' shell32 and ole32. configure links its
# GEOS check with what geos-config --clibs says, and takes PROJ's flags as
# given (PROJ_CFLAGS, PROJ_LIBS); both also reach the modules' link.
# -static links GCC's runtime and winpthreads in, so the modules import no
# MinGW DLL. MKDIR_P: configure leaves it empty, and the extensions' install
# needs it. rtpostgis.sql first, on its own: under -j two sub-makes
# regenerate it through the same temporary file (as in postgis.sh).
cat >"$work/geos-config" <<SH
#!/bin/sh
case "\$1" in --clibs) echo "\$("$prefix/bin/geos-config" --clibs) -lgeos -lstdc++ -lpthread" ;; *) exec "$prefix/bin/geos-config" "\$@" ;; esac
SH
chmod +x "$work/geos-config"
(
  cd "postgis-$POSTGIS_VERSION"
  ./configure --with-pgconfig="$pg_config" --without-raster --without-gui \
    --without-sfcgal --without-address-standardizer --with-gettext=no \
    --with-geosconfig="$work/geos-config" --with-jsondir="$prefix" \
    --with-protobufdir="$prefix" --with-xml2config="$work/xml2-config" PROTOCC="$protoc_c" \
    PROJ_CFLAGS="-I$prefix/include" PROJ_LIBS="-L$prefix/lib -lproj -lsqlite3 -lstdc++ -lpthread -lshell32 -lole32" \
    LDFLAGS="-L$prefix/lib -static" &&
    make -C raster/rt_pg rtpostgis.sql &&
    make -j"$jobs" &&
    make install MKDIR_P="mkdir -p"
) >>"$log" 2>&1 || { tail -n 60 "postgis-$POSTGIS_VERSION/config.log" >&2 || true; failed "PostGIS $POSTGIS_VERSION"; }

pkglibdir="$(cygpath -u "$("$pg_config" --pkglibdir)")"
extdir="$(cygpath -u "$("$pg_config" --sharedir)")/extension"
for lib in postgis-3 postgis_topology-3; do
  [ -f "$pkglibdir/$lib.dll" ] || { echo "PostGIS built no $lib.dll" >&2; exit 1; }
  cp "$pkglibdir/$lib.dll" "$stage/lib/"
  strip --strip-unneeded "$stage/lib/$lib.dll"
done
for ext in postgis postgis_topology postgis_tiger_geocoder; do
  [ -f "$extdir/$ext.control" ] || { echo "PostGIS installed no $ext extension" >&2; exit 1; }
  cp "$extdir/$ext.control" "$extdir/$ext--"*.sql "$stage/extension/"
done
cp "$prefix/share/proj/proj.db" "$stage/proj/"

# --- Licences -------------------------------------------------------------------
# From the checked source tarballs, and, for GCC's runtime, winpthreads and
# mingw-w64's start-up code, from their MSYS2 packages.
licences=(postgis/COPYING postgis/LICENSE.TXT geos/COPYING proj/COPYING json-c/COPYING protobuf-c/LICENSE
  libxml2/Copyright sqlite/NOTICE toolchain.txt)
mkdir -p "$stage/doc"/{postgis,geos,proj,json-c,protobuf-c,libxml2,sqlite,mingw-w64}
cp "postgis-$POSTGIS_VERSION/COPYING" "postgis-$POSTGIS_VERSION/LICENSE.TXT" "$stage/doc/postgis/"
cp "geos-$GEOS_VERSION/COPYING" "$stage/doc/geos/"
cp "proj-$PROJ_VERSION/COPYING" "$stage/doc/proj/"
cp "json-c-$JSONC_VERSION/COPYING" "$stage/doc/json-c/"
cp "protobuf-c-$PROTOBUFC_VERSION/LICENSE" "$stage/doc/protobuf-c/"
cp "libxml2-$LIBXML2_VERSION/Copyright" "$stage/doc/libxml2/"
# SQLite has no licence file: it's in the public domain, as its source says.
{
  echo "SQLite $SQLITE_VERSION is in the public domain. From its source:"
  sed -n '2,10p' "$sqlite_src/sqlite3.h"
} >"$stage/doc/sqlite/NOTICE"
grep -q 'disclaims copyright' "$stage/doc/sqlite/NOTICE" || { echo "SQLite's header has no public domain notice" >&2; exit 1; }
# shellcheck disable=SC2086 # one package per word
for p in $runtime_pkgs; do
  pacman -Qql "$p" | grep '/share/licenses/.*[^/]$' | while read -r f; do
    mkdir -p "$stage/doc/mingw-w64/${p#mingw-w64-ucrt-x86_64-}"
    cp "$f" "$stage/doc/mingw-w64/${p#mingw-w64-ucrt-x86_64-}/"
  done
done
# GCC's runtime exception, mingw-w64's notices for programs linked with its
# runtime, and winpthreads' licence.
for want in 'GCC RUNTIME LIBRARY EXCEPTION' 'statically linked against the MinGW-w64 runtime' 'Lockless Inc'; do
  grep -rqs "$want" "$stage/doc/mingw-w64" ||
    { echo "No MSYS2 licence says '$want':" >&2; find "$stage/doc/mingw-w64" >&2; exit 1; }
done

archive="$out/postgis-$POSTGIS_VERSION-pg$major-windows-x86_64.zip"
rm -f "$archive"
(cd "$stage" && zip -qr "$archive" lib extension proj doc)
# The archive carries every licence, and PostGIS's is the GPL.
listing="$(unzip -Z1 "$archive")"
for f in "${licences[@]}"; do
  grep -qx "doc/$f" <<<"$listing" || { echo "The archive has no doc/$f" >&2; exit 1; }
done
grep -q 'GNU GENERAL PUBLIC LICENSE' "$stage/doc/postgis/COPYING" || { echo "doc/postgis/COPYING isn't the GPL" >&2; exit 1; }
grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' "$stage/doc/geos/COPYING" || { echo "doc/geos/COPYING isn't the LGPL" >&2; exit 1; }
echo "Built PostGIS $POSTGIS_VERSION for Postgres $pg on windows-x86_64; scripts/postgis-smoke.ps1 checks it"
