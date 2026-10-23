#!/usr/bin/env bash
# Builds pgvector against one of the Postgres versions Short Leash installs (the
# theseus-rs builds), for the Mac this runs on, and checks it loads.
#
#   scripts/pgvector.sh 18.6.0 out/
#
# Writes out/pgvector-<version>-pg<major>-macos-<arch>.tar.gz holding
# lib/vector.<dylib|so> and extension/vector.control plus its SQL files.
set -euo pipefail

pg="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/pgvector.env"
arch="$(shortleash_arch)"
major="${pg%%.*}"
triple="$arch-apple-darwin"

work="$(mktemp -d)"
cd "$work"
fetch_github_asset theseus-rs/postgresql-binaries "$pg" "postgresql-$pg-$triple.tar.gz" pg.tar.gz
tar -xzf pg.tar.gz
pgroot="$work/postgresql-$pg-$triple"

git clone --quiet --depth 1 --branch "v$PGVECTOR_VERSION" https://github.com/pgvector/pgvector.git src
if [ "$(git -C src rev-parse HEAD)" != "$PGVECTOR_COMMIT" ]; then
  echo "pgvector v$PGVECTOR_VERSION isn't commit $PGVECTOR_COMMIT" >&2
  exit 1
fi
# No -march=native: the library runs on other Macs than the build machine.
# PG_SYSROOT: the Postgres build remembers its own build machine's SDK path.
make -C src PG_CONFIG="$pgroot/bin/pg_config" OPTFLAGS="" PG_SYSROOT="$(xcrun --show-sdk-path)"

stage="$work/stage"
mkdir -p "$stage/lib" "$stage/extension"
for lib in src/vector.dylib src/vector.so; do
  [ -f "$lib" ] && cp "$lib" "$stage/lib/"
done
[ -n "$(ls -A "$stage/lib")" ] || { echo "pgvector built no library" >&2; exit 1; }
cp src/vector.control "$stage/extension/"
cp src/sql/vector--*.sql "$stage/extension/"

# It loads into that Postgres and answers a query.
cp "$stage/lib/"* "$pgroot/lib/"
cp "$stage/extension/"* "$pgroot/share/extension/"
data="$work/data"
"$pgroot/bin/initdb" -D "$data" -U root --auth=trust >/dev/null
port=55432
"$pgroot/bin/pg_ctl" -D "$data" -o "-p $port -k $work -c listen_addresses=''" -l "$work/pg.log" -w start >/dev/null
trap '"$pgroot/bin/pg_ctl" -D "$data" -m fast stop >/dev/null 2>&1 || true' EXIT
"$pgroot/bin/psql" -h "$work" -p "$port" -U root -d postgres -v ON_ERROR_STOP=1 -Atc \
  "CREATE EXTENSION vector; SELECT '[1,2,3]'::vector <-> '[1,2,4]';"

check_macos_minimum "$stage"
tar -C "$stage" -czf "$out/pgvector-$PGVECTOR_VERSION-pg$major-macos-$arch.tar.gz" lib extension
echo "Built pgvector $PGVECTOR_VERSION for Postgres $pg on macos-$arch"
