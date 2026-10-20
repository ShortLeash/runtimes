#!/usr/bin/env bash
# Repackages Typesense's own macOS build for the Mac this runs on. Nothing is
# compiled: the binary is fetched from dl.typesense.org, checked against the
# SHA-256 pinned in scripts/typesense.env, and must link only macOS's own
# libraries and answer GET /health on 127.0.0.1.
#
#   scripts/typesense.sh 30.2 out/
#
# Writes out/typesense-<version>-macos-<arch>.tar.gz holding
# bin/typesense-server (unchanged), LICENSE (Typesense's GPL-3.0, from the
# source tarball of its tag) and NOTICE (where it came from and where its
# sources are). The sources go in the same release, from scripts/sources.sh.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: scripts/typesense.sh <version> <out folder>" >&2
  exit 2
fi
version="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/typesense.env"
arch="$(devkit_arch)"
case " $TYPESENSE_VERSIONS " in
  *" $version "*) ;;
  *) echo "Typesense $version isn't pinned in scripts/typesense.env ($TYPESENSE_VERSIONS)" >&2; exit 2 ;;
esac

# Typesense names the architectures darwin-arm64 and darwin-amd64.
upstream_arch=arm64
[ "$arch" = x86_64 ] && upstream_arch=amd64
key="TYPESENSE_${version//./_}"
upstream_arch_upper="$(echo "$upstream_arch" | tr '[:lower:]' '[:upper:]')"
sha_var="${key}_${upstream_arch_upper}_SHA256"
source_sha_var="${key}_SOURCE_SHA256"
want="${!sha_var:-}"
source_want="${!source_sha_var:-}"
if [ -z "$want" ] || [ -z "$source_want" ]; then
  echo "scripts/typesense.env has no $sha_var or $source_sha_var" >&2
  exit 1
fi

work="$(mktemp -d)"
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$work"' EXIT
cd "$work"

# The binary, against the SHA-256 from Typesense's Homebrew tap.
tarball="typesense-server-$version-darwin-$upstream_arch.tar.gz"
url="https://dl.typesense.org/releases/$version/$tarball"
fetch_checked "$url" "$want" "$tarball"
mkdir upstream
tar -C upstream -xzf "$tarball"
# Upstream's tarball also lists the binary's MD5; it must agree.
if [ -f upstream/typesense-server.md5.txt ]; then
  listed="$(awk '{print $1}' upstream/typesense-server.md5.txt)"
  if [ "$listed" != "$(md5 -q upstream/typesense-server)" ]; then
    echo "$tarball: typesense-server doesn't match the MD5 in typesense-server.md5.txt" >&2
    exit 1
  fi
fi

# The source of the tag, for its licence (and the same file the sources hold).
source_tarball="typesense-$version.tar.gz"
fetch_checked "https://github.com/typesense/typesense/archive/refs/tags/v$version.tar.gz" \
  "$source_want" "$source_tarball"

stage="$work/stage"
mkdir -p "$stage/bin"
cp upstream/typesense-server "$stage/bin/"
tar -xzOf "$source_tarball" "typesense-$version/LICENSE.txt" >"$stage/LICENSE"
grep -q "GNU GENERAL PUBLIC LICENSE" "$stage/LICENSE" && grep -q "Version 3, 29 June 2007" "$stage/LICENSE" || {
  echo "typesense-$version/LICENSE.txt isn't the GPL-3.0 text" >&2
  exit 1
}
cat >"$stage/NOTICE" <<EOF
Typesense $version for macOS ($arch)

bin/typesense-server is Typesense's own build, unchanged. Typesense
(https://typesense.org, https://github.com/typesense/typesense) is licensed
under the GNU General Public License, version 3 (LICENSE).

Downloaded from: $url
Checked against the SHA-256 Typesense publishes in its Homebrew tap
(https://github.com/typesense/homebrew-tap, Formula/typesense-server@$version.rb
at commit $TYPESENSE_TAP_COMMIT): $want

Source: https://github.com/typesense/typesense/tree/v$version
(https://github.com/typesense/typesense/archive/refs/tags/v$version.tar.gz).
The same source, with the scripts that repackaged this file, is in
typesense-$version-sources.tar.gz on the devkit-runtimes release
typesense-$version (https://github.com/frankperez87/devkit-runtimes/releases/tag/typesense-$version).
EOF

bin="$stage/bin/typesense-server"

# Links only macOS's own libraries and frameworks.
extra="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -v -E '^/usr/lib/|^/System/' || true)"
if [ -n "$extra" ]; then
  echo "typesense-server links libraries outside macOS:" >&2
  echo "$extra" >&2
  exit 1
fi

# Needs no newer macOS than Typesense's stated minimum.
MACOSX_DEPLOYMENT_TARGET="$TYPESENSE_MACOS_MINIMUM" check_macos_minimum "$stage"

# It starts with its API and its peering (Raft) service both on 127.0.0.1,
# the key from the environment, and answers GET /health. Peering otherwise
# binds the first non-loopback address, even on a single node.
read -r api_port peering_port < <(python3 -c '
import socket
socks = [socket.socket() for _ in range(2)]
for s in socks:
    s.bind(("127.0.0.1", 0))
print(*(s.getsockname()[1] for s in socks))
')
mkdir "$work/data"
TYPESENSE_API_KEY=devkit-smoke "$bin" --data-dir "$work/data" \
  --api-address 127.0.0.1 --api-port "$api_port" \
  --peering-address 127.0.0.1 --peering-port "$peering_port" >"$work/typesense.log" 2>&1 &
pid=$!
health=""
for _ in $(seq 1 120); do
  health="$(curl -fsS "http://127.0.0.1:$api_port/health" 2>/dev/null || true)"
  [ -n "$health" ] && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
if [ "$health" != '{"ok":true}' ]; then
  echo "typesense-server didn't answer GET /health with {\"ok\":true} (got '${health}'):" >&2
  tail -n 40 "$work/typesense.log" >&2
  exit 1
fi
# Both its listening sockets are on 127.0.0.1, and nothing else.
listening="$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN -F n | sed -n 's/^n//p' | sort)"
expected="$(printf '127.0.0.1:%s\n127.0.0.1:%s\n' "$api_port" "$peering_port" | sort)"
if [ "$listening" != "$expected" ]; then
  echo "typesense-server listens on:" >&2
  echo "$listening" >&2
  echo "expected only 127.0.0.1:$api_port and 127.0.0.1:$peering_port" >&2
  exit 1
fi
# The key from TYPESENSE_API_KEY is the one it accepts.
code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-TYPESENSE-API-KEY: devkit-smoke' "http://127.0.0.1:$api_port/collections")"
wrong="$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-TYPESENSE-API-KEY: wrong' "http://127.0.0.1:$api_port/collections")"
if [ "$code" != 200 ] || [ "$wrong" != 401 ]; then
  echo "GET /collections answered $code with the key and $wrong with a wrong one (expected 200 and 401)" >&2
  exit 1
fi
kill "$pid"
wait "$pid" || true
pid=""

archive="$out/typesense-$version-macos-$arch.tar.gz"
COPYFILE_DISABLE=1 tar -C "$stage" -czf "$archive" bin LICENSE NOTICE
echo "Repackaged Typesense $version for macos-$arch"
