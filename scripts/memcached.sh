#!/usr/bin/env bash
# Builds memcached for the Mac this runs on, with libevent linked in, and
# checks it serves a set and a get.
#
#   scripts/memcached.sh out/
#
# Writes out/memcached-<version>-macos-<arch>.tar.gz holding bin/memcached,
# which links nothing outside macOS itself.
set -euo pipefail

out="$(mkdir -p "$1" && cd "$1" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/memcached.env"
arch="$(devkit_arch)"

work="$(mktemp -d)"
cd "$work"
jobs="$(sysctl -n hw.ncpu)"

# libevent, static, into a private prefix.
fetch_github_asset libevent/libevent "release-$LIBEVENT_VERSION" "libevent-$LIBEVENT_VERSION.tar.gz" libevent.tar.gz
tar -xzf libevent.tar.gz
prefix="$work/prefix"
(
  cd "libevent-$LIBEVENT_VERSION"
  ./configure --prefix="$prefix" --disable-shared --enable-static --with-pic \
    --disable-openssl --disable-samples --disable-libevent-regress --disable-debug-mode >/dev/null
  make -j"$jobs" >/dev/null
  make install >/dev/null
)

# memcached: the pinned SHA-256, and upstream's own SHA-1.
tarball="memcached-$MEMCACHED_VERSION.tar.gz"
fetch_checked "https://www.memcached.org/files/$tarball" "$MEMCACHED_SHA256" "$tarball"
want_sha1="$(curl -fsSL "https://www.memcached.org/files/$tarball.sha1" | awk '{print $1}')"
got_sha1="$(shasum -a 1 "$tarball" | cut -d' ' -f1)"
if [ "$got_sha1" != "$want_sha1" ]; then
  echo "$tarball: SHA-1 $got_sha1 doesn't match memcached.org's $want_sha1" >&2
  exit 1
fi
tar -xzf "$tarball"
(
  cd "memcached-$MEMCACHED_VERSION"
  # macOS 27's SDK has a sandbox.h memcached can't use (memcached #1313).
  ac_cv_header_sandbox_h=no ./configure --with-libevent="$prefix" \
    --disable-docs --disable-coverage --disable-sasl --disable-tls >/dev/null
  make -j"$jobs" memcached >/dev/null
)

stage="$work/stage"
mkdir -p "$stage/bin"
cp "memcached-$MEMCACHED_VERSION/memcached" "$stage/bin/"
strip -x "$stage/bin/memcached"

# Links only macOS's own libraries.
extra="$(otool -L "$stage/bin/memcached" | tail -n +2 | awk '{print $1}' | grep -v '^/usr/lib/' || true)"
if [ -n "$extra" ]; then
  echo "memcached links libraries outside macOS:" >&2
  echo "$extra" >&2
  exit 1
fi

# It serves a set and a get on 127.0.0.1.
port=51211
"$stage/bin/memcached" -l 127.0.0.1 -p "$port" -U 0 -m 16 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
python3 - "$port" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
for _ in range(50):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        break
    except OSError:
        time.sleep(0.1)
else:
    sys.exit("memcached didn't start")
s.sendall(b"set devkit 0 0 2\r\nok\r\nget devkit\r\nversion\r\n")
time.sleep(0.3)
reply = s.recv(4096).decode()
assert "STORED" in reply and "VALUE devkit 0 2\r\nok\r\nEND" in reply and "VERSION" in reply, reply
PY

check_macos_minimum "$stage"
tar -C "$stage" -czf "$out/memcached-$MEMCACHED_VERSION-macos-$arch.tar.gz" bin
echo "Built memcached $MEMCACHED_VERSION on macos-$arch"
