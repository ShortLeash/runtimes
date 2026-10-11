# Shared helpers for the build scripts. Source it: . "$here/lib.sh"

# DevKit runs on macOS 13 or later, so everything it downloads must too,
# whichever macOS the build machine runs (a macOS 15 runner would otherwise
# produce binaries that need macOS 15).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

# fetch_github_asset OWNER/REPO TAG ASSET DEST
# Downloads a release asset and checks it against the SHA-256 digest GitHub
# publishes for it; refuses a mismatch or an asset with no digest.
fetch_github_asset() {
  local repo="$1" tag="$2" asset="$3" dest="$4"
  local want
  want="$(curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$repo/releases/tags/$tag" |
    python3 -c "import json,sys; a=[x for x in json.load(sys.stdin)['assets'] if x['name']==sys.argv[1]]; print((a[0].get('digest') or '') if a else '')" "$asset")"
  want="${want#sha256:}"
  if [ -z "$want" ]; then
    echo "$repo $tag has no published digest for $asset" >&2
    return 1
  fi
  curl -fsSL -o "$dest" "https://github.com/$repo/releases/download/$tag/$asset"
  local got
  got="$(shasum -a 256 "$dest" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    echo "$asset: SHA-256 $got doesn't match the published $want" >&2
    return 1
  fi
}

# fetch_checked URL SHA256 DEST: downloads and checks a file's SHA-256.
fetch_checked() {
  local url="$1" want="$2" dest="$3" got
  curl -fsSL -o "$dest" "$url"
  got="$(shasum -a 256 "$dest" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    echo "$url: SHA-256 $got doesn't match $want" >&2
    return 1
  fi
}

# The Mac's architecture as DevKit names it: aarch64 or x86_64.
devkit_arch() {
  local a
  a="$(uname -m)"
  [ "$a" = arm64 ] && a=aarch64
  echo "$a"
}

# check_macos_minimum DIR: fails if any Mach-O file under DIR needs a newer
# macOS than MACOSX_DEPLOYMENT_TARGET.
check_macos_minimum() {
  local dir="$1" bad="" f minos
  while IFS= read -r f; do
    minos="$(vtool -show-build "$f" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    [ -z "$minos" ] && continue
    if [ "$(printf '%s\n%s\n' "$minos" "$MACOSX_DEPLOYMENT_TARGET" | sort -V | tail -1)" != "$MACOSX_DEPLOYMENT_TARGET" ]; then
      bad="$bad$f needs macOS $minos"$'\n'
    fi
  done < <(find "$dir" -type f -exec sh -c 'file "$1" | grep -q Mach-O && echo "$1"' _ {} \;)
  if [ -n "$bad" ]; then
    echo "Built for a newer macOS than $MACOSX_DEPLOYMENT_TARGET:" >&2
    printf '%s' "$bad" >&2
    return 1
  fi
}
