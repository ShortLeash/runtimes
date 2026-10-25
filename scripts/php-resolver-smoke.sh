#!/usr/bin/env bash
# Checks that a PHP build's curl resolves names the way macOS does, through
# the per-domain resolvers in /etc/resolver (how Short Leash serves .test), by
# fetching a page from a name only such a resolver knows.
#
#   scripts/php-resolver-smoke.sh out/php-8.4.26-cli-macos-arm64.tar.gz
#   scripts/php-resolver-smoke.sh /path/to/php
#
# Without /etc/resolver/$RESOLVER_SMOKE_TLD it answers that domain from a
# small DNS server of its own, set up with sudo and removed afterwards (as on
# CI). With one already there (RESOLVER_SMOKE_TLD=test on a Mac running Short
# Leash), it uses that resolver as it is.
set -euo pipefail

archive="$1"
tld="${RESOLVER_SMOKE_TLD:-shortleash-smoke}"
work="$(mktemp -d)"
resolver="/etc/resolver/$tld"
pids=()
ours=false
cleanup() {
  if [ ${#pids[@]} -gt 0 ]; then kill "${pids[@]}" 2>/dev/null || true; fi
  if $ours; then sudo rm -f "$resolver"; fi
  rm -rf "$work"
}
trap cleanup EXIT

if [[ "$archive" == *.tar.gz ]]; then
  tar -xzf "$archive" -C "$work" php
  php="$work/php"
else
  php="$archive"
fi

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

if [ ! -e "$resolver" ]; then
  dns_port="$(free_port)"
  # Answers every A question with 127.0.0.1, and every other one with no
  # records.
  python3 -c '
import socket, struct, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", int(sys.argv[1])))
while True:
    q, addr = s.recvfrom(512)
    end = 12
    while q[end]:
        end += q[end] + 1
    question = q[12:end + 5]
    qtype = struct.unpack(">H", q[end + 1:end + 3])[0]
    answer = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 5, 4) + socket.inet_aton("127.0.0.1") if qtype == 1 else b""
    flags = 0x8180 | (q[2] & 1) << 8
    s.sendto(q[:2] + struct.pack(">HHHHH", flags, 1, 1 if answer else 0, 0, 0) + question + answer, addr)
' "$dns_port" &
  pids+=($!)
  ours=true
  printf 'nameserver 127.0.0.1\nport %s\n' "$dns_port" | sudo tee "$resolver" >/dev/null
fi

http_port="$(free_port)"
mkdir "$work/www" && echo ok > "$work/www/index.html"
python3 -m http.server --bind 127.0.0.1 --directory "$work/www" "$http_port" >/dev/null 2>&1 &
pids+=($!)

url="http://site.$tld:$http_port/"
# macOS takes a moment to pick up a new resolver file.
for _ in $(seq 1 20); do
  if "$php" -n -r '
    $c = curl_init($argv[1]);
    curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 5]);
    exit(trim((string) curl_exec($c)) === "ok" ? 0 : 1);
  ' "$url"; then
    echo "PHP's curl fetched $url through $resolver"
    exit 0
  fi
  sleep 1
done
echo "PHP's curl couldn't fetch $url through $resolver:" >&2
"$php" -n -r '
  echo "  gethostbyname: ", gethostbyname(parse_url($argv[1], PHP_URL_HOST)), "\n";
  $c = curl_init($argv[1]);
  curl_setopt($c, CURLOPT_RETURNTRANSFER, true);
  curl_exec($c);
  echo "  curl: ", curl_error($c), "\n";
' "$url" >&2
exit 1
