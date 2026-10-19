#!/usr/bin/env bash
# Builds PostGIS against one of the Postgres versions DevKit installs (the
# theseus-rs builds), for the Mac this runs on, without raster support (no
# GDAL), with GEOS, PROJ, json-c and protobuf-c linked in statically, and
# checks it works from another folder.
#
#   scripts/postgis.sh 18.6.0 out/
#
# Writes out/postgis-<version>-pg<major>-macos-<arch>.tar.gz holding lib/
# (postgis-3 and postgis_topology-3, .dylib from Postgres 16, .so before),
# extension/ (the postgis, postgis_topology and postgis_tiger_geocoder
# control and SQL files), proj/proj.db, which PROJ finds through PROJ_DATA,
# and doc/ with the licences of PostGIS and the libraries linked into it. The
# libraries link nothing outside macOS itself.
set -euo pipefail

pg="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/postgis.env"
arch="$(devkit_arch)"
major="${pg%%.*}"
triple="$arch-apple-darwin"

# The real path: pg_config answers with it, and the install goes under it.
work="$(cd "$(mktemp -d)" && pwd -P)"
cd "$work"
stage="$work/stage"
mkdir -p "$stage/lib" "$stage/extension" "$stage/proj" "$stage/doc"
fetch_github_asset theseus-rs/postgresql-binaries "$pg" "postgresql-$pg-$triple.tar.gz" pg.tar.gz
tar -xzf pg.tar.gz
pgroot="$work/postgresql-$pg-$triple"

# --- Build ------------------------------------------------------------------
# Everything builds with macOS's own tools on PATH, so Homebrew's and other
# prefixes' pkg-config and libraries stay out, into a private prefix of
# static libraries.
clean_path=/usr/bin:/bin:/usr/sbin:/sbin
sdk="$(xcrun --show-sdk-path)"
prefix="$work/prefix"
jobs="$(sysctl -n hw.ncpu)"
log="$work/build.log"
: >"$log"
failed() {
  tail -n 150 "$log" >&2
  echo "$1 didn't build; the log is $log" >&2
  exit 1
}
cmake_bin="$(command -v cmake || true)"
[ -n "$cmake_bin" ] || { echo "PostGIS's libraries need CMake to build; install it first" >&2; exit 1; }
# PostGIS's tarball ships no code generated from its .proto files (vector
# tiles, Geobuf), so the build needs protobuf-c's compiler, protoc-c. It only
# writes C source; the runtime library linked in is the pinned one below.
# protoc-c itself isn't pinned: it's a code generator used at build time,
# required to be the runtime's 1.5.x series, and the generated header refuses
# to compile against a runtime it doesn't support.
protoc_c="$(command -v protoc-c || true)"
[ -n "$protoc_c" ] || { echo "PostGIS needs protoc-c to build; install Homebrew's protobuf-c first" >&2; exit 1; }
protoc_c_version="$("$protoc_c" --version 2>/dev/null | awk '$1 == "protobuf-c" {print $2}')"
if [ "${protoc_c_version%.*}" != "${PROTOBUFC_VERSION%.*}" ]; then
  echo "protoc-c is ${protoc_c_version:-unknown}, not protobuf-c ${PROTOBUFC_VERSION%.*}.x like the runtime" >&2
  exit 1
fi
cmake_common=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_OSX_SYSROOT="$sdk"
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
cmake_build() { # cmake_build NAME SOURCE [OPTION...]
  local name="$1" src="$2"
  shift 2
  (
    export PATH="$clean_path"
    unset PKG_CONFIG_PATH CPATH LIBRARY_PATH
    "$cmake_bin" -S "$src" -B "$src/build" "${cmake_common[@]}" "$@" &&
      "$cmake_bin" --build "$src/build" -j"$jobs" &&
      "$cmake_bin" --install "$src/build"
  ) >>"$log" 2>&1 || failed "$name"
}

# PostGIS: the pinned SHA-256, which must also match download.osgeo.org's MD5.
tarball="postgis-$POSTGIS_VERSION.tar.gz"
fetch_checked "https://download.osgeo.org/postgis/source/$tarball" "$POSTGIS_SHA256" "$tarball"
published="$(curl -fsSL "https://download.osgeo.org/postgis/source/$tarball.md5" | awk '{print $1}')"
got="$(md5 -q "$tarball")"
if [ "$published" != "$got" ]; then
  echo "$tarball: download.osgeo.org lists MD5 '${published:-none}', not $got" >&2
  exit 1
fi
fetch_github_asset libgeos/geos "$GEOS_VERSION" "geos-$GEOS_VERSION.tar.bz2" geos.tar.bz2
fetch_github_asset OSGeo/PROJ "$PROJ_VERSION" "proj-$PROJ_VERSION.tar.gz" proj.tar.gz
fetch_github_asset json-c/json-c "$JSONC_TAG" "json-c-$JSONC_VERSION.tar.gz" json-c.tar.gz
fetch_checked "https://github.com/protobuf-c/protobuf-c/releases/download/v$PROTOBUFC_VERSION/protobuf-c-$PROTOBUFC_VERSION.tar.gz" \
  "$PROTOBUFC_SHA256" protobuf-c.tar.gz
for t in "$tarball" geos.tar.bz2 proj.tar.gz json-c.tar.gz protobuf-c.tar.gz; do
  tar -xf "$t"
done

cmake_build "GEOS $GEOS_VERSION" "geos-$GEOS_VERSION" -DBUILD_BENCHMARKS=OFF -DBUILD_DOCUMENTATION=OFF
# PROJ against the SDK's SQLite, with proj.db as a file (not embedded) and no
# build path baked in: PROJ finds it through PROJ_DATA, or beside the
# Postgres it runs in (share/proj).
cmake_build "PROJ $PROJ_VERSION" "proj-$PROJ_VERSION" -DENABLE_TIFF=OFF -DENABLE_CURL=OFF \
  -DBUILD_APPS=OFF -DBUILD_PROJSYNC=OFF -DEMBED_RESOURCE_FILES=OFF -DEMBED_PROJ_DATA_PATH=OFF
cmake_build "json-c $JSONC_VERSION" "json-c-$JSONC_VERSION" -DBUILD_STATIC_LIBS=ON \
  -DDISABLE_EXTRA_LIBS=ON -DBUILD_APPS=OFF
(
  export PATH="$clean_path"
  unset PKG_CONFIG_PATH CPATH LIBRARY_PATH
  cd "protobuf-c-$PROTOBUFC_VERSION"
  ./configure --prefix="$prefix" --libdir="$prefix/lib" --disable-shared --enable-static --disable-protoc &&
    make -j"$jobs" && make install
) >>"$log" 2>&1 || failed "protobuf-c $PROTOBUFC_VERSION"

# libxml2 is macOS's own; this stands in for its xml2-config.
xml2_version="$(awk -F'"' '/#define LIBXML_DOTTED_VERSION/ {print $2}' "$sdk/usr/include/libxml2/libxml/xmlversion.h")"
cat >"$work/xml2-config" <<SH
#!/bin/sh
case "\$1" in --cflags) echo "-I$sdk/usr/include/libxml2" ;; --libs) echo "-lxml2" ;; --version) echo "$xml2_version" ;; esac
SH
chmod +x "$work/xml2-config"

# PostGIS, with GEOS and PROJ static: libgeos_c needs libgeos and libc++, and
# PROJ needs SQLite and libc++. They go in LDFLAGS, not LIBS: configure links
# its checks with LIBS replaced, and LDFLAGS also reaches the modules' link.
# PG_SYSROOT: the Postgres build remembers its own build machine's SDK path.
# --prefix: topology links against $prefix/bin/postgres (-bundle_loader).
# MKDIR_P: configure leaves it empty, and the extensions' install needs it.
# rtpostgis.sql first, on its own: even without raster, utils/ starts two
# sub-makes in raster/rt_pg that both regenerate it through the same
# rtpostgis.sql.tmp, and under -j one can delete the file while the other
# reads it ("Unable to locate target new version number in rtpostgis.sql").
# Built up front, both find it up to date.
(
  export PATH="$clean_path"
  unset PKG_CONFIG_PATH CPATH LIBRARY_PATH
  cd "postgis-$POSTGIS_VERSION"
  ./configure --prefix="$pgroot" --with-pgconfig="$pgroot/bin/pg_config" --without-raster --without-gui \
    --without-sfcgal --without-address-standardizer --with-gettext=no \
    --with-geosconfig="$prefix/bin/geos-config" --with-projdir="$prefix" --with-jsondir="$prefix" \
    --with-protobufdir="$prefix" --with-xml2config="$work/xml2-config" PROTOCC="$protoc_c" \
    LDFLAGS="-L$prefix/lib -lgeos -lsqlite3 -lc++" &&
    make -C raster/rt_pg rtpostgis.sql PG_SYSROOT="$sdk" &&
    make -j"$jobs" PG_SYSROOT="$sdk" &&
    make install PG_SYSROOT="$sdk" DESTDIR="$work/dest" MKDIR_P="/bin/mkdir -p"
) >>"$log" 2>&1 || failed "PostGIS $POSTGIS_VERSION"

installed="$work/dest$pgroot"
for lib in postgis-3 postgis_topology-3; do
  found=""
  for f in "$installed/lib/$lib.dylib" "$installed/lib/$lib.so"; do
    [ -f "$f" ] && cp "$f" "$stage/lib/" && found=1
  done
  [ -n "$found" ] || { echo "PostGIS built no $lib library" >&2; exit 1; }
done
for ext in postgis postgis_topology postgis_tiger_geocoder; do
  [ -f "$installed/share/extension/$ext.control" ] || { echo "PostGIS installed no $ext extension" >&2; exit 1; }
  cp "$installed/share/extension/$ext.control" "$installed/share/extension/$ext--"*.sql "$stage/extension/"
done
cp "$prefix/share/proj/proj.db" "$stage/proj/"
# The licences travel with the modules, from the checked source tarballs.
# SQLite isn't among them: it's macOS's own library, not linked in.
licences=(postgis/COPYING postgis/LICENSE.TXT geos/COPYING proj/COPYING json-c/COPYING protobuf-c/LICENSE)
mkdir -p "$stage/doc"/{postgis,geos,proj,json-c,protobuf-c}
cp "postgis-$POSTGIS_VERSION/COPYING" "postgis-$POSTGIS_VERSION/LICENSE.TXT" "$stage/doc/postgis/"
cp "geos-$GEOS_VERSION/COPYING" "$stage/doc/geos/"
cp "proj-$PROJ_VERSION/COPYING" "$stage/doc/proj/"
cp "json-c-$JSONC_VERSION/COPYING" "$stage/doc/json-c/"
cp "protobuf-c-$PROTOBUFC_VERSION/LICENSE" "$stage/doc/protobuf-c/"
# On macOS, configure adds a run path to GEOS's and PROJ's build folder, which
# static libraries don't need.
for f in "$stage/lib/"*; do
  while p="$(otool -l "$f" | awk '$1 == "cmd" {c = $2} c == "LC_RPATH" && $1 == "path" {print $2; exit}')" && [ -n "$p" ]; do
    install_name_tool -delete_rpath "$p" "$f"
  done
  strip -x "$f"
done
# The smoke test must find the shipped proj.db, not the build's.
rm -rf "$prefix/share/proj"

# --- Smoke test -------------------------------------------------------------
# Copied into a folder with a space in its path, as DevKit's home has, with
# proj.db where DevKit puts it, PostGIS and its topology load, measure a
# distance, transform with PROJ's database, encode a vector tile with
# protobuf-c, and link nothing outside macOS.
moved="$work/Application Support/postgresql"
mkdir -p "$(dirname "$moved")"
cp -R "$pgroot" "$moved"
cp -R "$stage/lib/." "$moved/lib/"
cp -R "$stage/extension/." "$moved/share/extension/"
mkdir -p "$moved/share/proj"
cp -R "$stage/proj/." "$moved/share/proj/"

data="$work/data"
"$moved/bin/initdb" -D "$data" -U root --auth=trust >/dev/null
port=55433
PROJ_DATA="$moved/share/proj" PROJ_NETWORK=OFF \
  "$moved/bin/pg_ctl" -D "$data" -o "-p $port -k $work -c listen_addresses=''" -l "$work/pg.log" -w start >/dev/null
trap '"$moved/bin/pg_ctl" -D "$data" -m fast stop >/dev/null 2>&1 || true' EXIT
sql() {
  PGOPTIONS="-c client_min_messages=warning" "$moved/bin/psql" -h "$work" -p "$port" -U root -d postgres -v ON_ERROR_STOP=1 -Atc "$1"
}

# London to Paris on the spheroid is about 343.9 km.
distance="$(sql "CREATE EXTENSION postgis; CREATE EXTENSION postgis_topology; SELECT round(ST_Distance('SRID=4326;POINT(-0.1278 51.5074)'::geography, 'SRID=4326;POINT(2.3522 48.8566)'::geography));" | tail -n 1)"
distance="${distance%%.*}"
if ! [[ "$distance" =~ ^[0-9]+$ ]] || [ "$distance" -lt 343000 ] || [ "$distance" -gt 345000 ]; then
  echo "ST_Distance from London to Paris answered '$distance', not 343000 to 345000 metres" >&2
  exit 1
fi
sql "CREATE EXTENSION postgis_tiger_geocoder CASCADE" >/dev/null

got="$(sql "SELECT ST_AsText(ST_Transform(ST_SetSRID(ST_MakePoint(0,0),4326),3857))")"
[ "$got" = "POINT(0 0)" ] || { echo "ST_Transform to EPSG:3857 answered '$got', not POINT(0 0)" >&2; exit 1; }
# PROJ reads the shipped proj.db (the build's own copy is gone by now).
codes="$(sql "SELECT count(*) FROM postgis_srs_codes('EPSG')")"
[ "$codes" -gt 1000 ] || { echo "PROJ's database lists $codes EPSG codes" >&2; exit 1; }

got="$(sql "SELECT length(ST_AsMVT(q)) > 0 FROM (SELECT 1 AS id, ST_AsMVTGeom(ST_MakePoint(0,0), ST_MakeEnvelope(-1,-1,1,1)) AS geom) q")"
[ "$got" = t ] || { echo "ST_AsMVT answered '$got', not t" >&2; exit 1; }

full="$(sql "SELECT postgis_full_version()")"
for want in "POSTGIS=\"$POSTGIS_VERSION" 'GEOS="' 'PROJ="' 'PROTOBUF="' "DATABASE_PATH=$moved/share/proj/proj.db"; do
  [[ "$full" == *"$want"* ]] || { echo "postgis_full_version() has no $want: $full" >&2; exit 1; }
done
[[ "$full" != *"need upgrade"* ]] || { echo "postgis_full_version() asks for an upgrade: $full" >&2; exit 1; }

# Relocatable: nothing links outside macOS (macOS's own libsqlite3, libxml2
# and libc++ are fine; Postgres's symbols resolve through -bundle_loader),
# every @rpath library is in the archive, and no run path points outside it.
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
  echo "PostGIS $POSTGIS_VERSION links outside macOS:" >&2
  echo "$bad" >&2
  exit 1
fi

check_macos_minimum "$stage"

archive="$out/postgis-$POSTGIS_VERSION-pg$major-macos-$arch.tar.gz"
tar -C "$stage" -czf "$archive" lib extension proj doc
# The archive carries every licence, and PostGIS's is the GPL.
listing="$(tar -tzf "$archive")"
for f in "${licences[@]}"; do
  grep -qx "doc/$f" <<<"$listing" || { echo "The archive has no doc/$f" >&2; exit 1; }
done
grep -q 'GNU GENERAL PUBLIC LICENSE' "$stage/doc/postgis/COPYING" || { echo "doc/postgis/COPYING isn't the GPL" >&2; exit 1; }
grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' "$stage/doc/geos/COPYING" || { echo "doc/geos/COPYING isn't the LGPL" >&2; exit 1; }
echo "Built PostGIS $POSTGIS_VERSION for Postgres $pg on macos-$arch"
