# The pinned engine sources, shared by voice-engines.sh and models.sh.
# Source it after lib.sh: . "$here/engines.sh"
#
#   fetch_transcribe DIR   transcribe.cpp at TRANSCRIBE_COMMIT
#   fetch_llama DIR        llama.cpp at LLAMA_COMMIT
#
# Each checks the source against the crate DevKit links it through, so an
# engine pin can't drift from the crate pin.
. "$(dirname "${BASH_SOURCE[0]}")/voice-engines.env"

# fetch_commit URL COMMIT DIR: a shallow checkout of exactly COMMIT. Git
# checks every object against its hash, so the files are the commit's.
fetch_commit() {
  local url="$1" commit="$2" dir="$3"
  if [ ! -d "$dir/.git" ]; then
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]; then
    echo "$dir is at $(git -C "$dir" rev-parse HEAD), not $commit" >&2
    return 1
  fi
}

# fetch_crate NAME VERSION SHA256 DIR: a crate from crates.io, checked by its
# SHA-256, unpacked into DIR/NAME-VERSION.
fetch_crate() {
  local name="$1" version="$2" sha="$3" dir="$4"
  mkdir -p "$dir"
  if [ ! -d "$dir/$name-$version" ]; then
    fetch_checked "https://static.crates.io/crates/$name/$name-$version.crate" "$sha" "$dir/$name-$version.crate"
    tar -C "$dir" -xzf "$dir/$name-$version.crate"
  fi
}

fetch_transcribe() {
  local dir="$1" crates
  fetch_commit https://github.com/handy-computer/transcribe.cpp.git "$TRANSCRIBE_COMMIT" "$dir"
  # The crate records the commit it was packaged from, and its bindings are
  # pinned to the library's ABI hash.
  crates="$(dirname "$dir")/crates"
  fetch_crate transcribe-cpp-sys "$TRANSCRIBE_VERSION" "$TRANSCRIBE_CPP_SYS_SHA256" "$crates"
  local crate="$crates/transcribe-cpp-sys-$TRANSCRIBE_VERSION" packaged
  packaged="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["git"]["sha1"])' "$crate/.cargo_vcs_info.json")"
  if [ "$packaged" != "$TRANSCRIBE_COMMIT" ]; then
    echo "transcribe-cpp-sys $TRANSCRIBE_VERSION was packaged from $packaged, not $TRANSCRIBE_COMMIT" >&2
    return 1
  fi
  cmp -s "$crate/include/transcribe.abihash" "$dir/include/transcribe.abihash" || {
    echo "transcribe-cpp-sys $TRANSCRIBE_VERSION has another ABI hash than transcribe.cpp $TRANSCRIBE_COMMIT" >&2
    return 1
  }
  local header
  header="$(awk '/#define TRANSCRIBE_VERSION_(MAJOR|MINOR|PATCH) / {printf "%s%s", sep, $3; sep="."}' "$dir/include/transcribe.h")"
  if [ "$header" != "$TRANSCRIBE_VERSION" ]; then
    echo "transcribe.cpp $TRANSCRIBE_COMMIT is version $header, not $TRANSCRIBE_VERSION" >&2
    return 1
  fi
}

fetch_llama() {
  local dir="$1" crates
  fetch_commit https://github.com/ggml-org/llama.cpp.git "$LLAMA_COMMIT" "$dir"
  # The crate vendors llama.cpp as a submodule; every file it ships must be
  # the commit's.
  crates="$(dirname "$dir")/crates"
  fetch_crate llama-cpp-sys-2 "$LLAMA_CPP_SYS_VERSION" "$LLAMA_CPP_SYS_SHA256" "$crates"
  local vendored="$crates/llama-cpp-sys-2-$LLAMA_CPP_SYS_VERSION/llama.cpp" f bad=0 n=0
  while IFS= read -r -d '' f; do
    n=$((n + 1))
    if ! cmp -s "$vendored/$f" "$dir/$f"; then
      echo "llama-cpp-sys-2 $LLAMA_CPP_SYS_VERSION's $f differs from llama.cpp $LLAMA_COMMIT" >&2
      bad=1
    fi
  done < <(cd "$vendored" && find . -type f -print0)
  [ "$bad" = 0 ] || return 1
  [ "$n" -gt 100 ] || { echo "llama-cpp-sys-2 $LLAMA_CPP_SYS_VERSION has no llama.cpp sources" >&2; return 1; }
}
