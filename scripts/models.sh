#!/usr/bin/env bash
# Converts, vets and tests the models in models/catalogue.json, on the CPU of
# the machine it runs on (Linux in CI, or a Mac).
#
#   scripts/models.sh tools <dir>              the CPU tools: transcribe-cli,
#                                              transcribe-quantize, llama-server
#   scripts/models.sh <id> <out> [tools dir]   one model: <out>/<id>.result.json,
#                                              <id>.NOTICE.txt and, for speech
#                                              models, the converted GGUFs
#   scripts/models.sh catalogue <results> <out> <tag>
#                                              the released catalogue.json
#   scripts/models.sh all <out> [tag]          everything, in order
#
# The tools come from transcribe.cpp and llama.cpp at the engine pins in
# voice-engines.env, so the converter, the quantizer and the tests are the
# engines DevKit ships. Speech models are converted with transcribe.cpp's
# converter from upstream files pinned by commit and SHA-256, in transcribe.cpp's
# locked Python environments (uv checks every package against uv.lock).
# Hugging Face GGUFs (the Qwen models) are only checked and tested, never
# changed. MODELS_WORK picks the scratch folder; it needs room for the
# largest model plus about 15 GB of Python packages.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/engines.sh"
# uv runs transcribe.cpp's locked converter environments; this release's
# GitHub digest is checked.
UV_VERSION=0.12.22

work="${MODELS_WORK:-$(mktemp -d)}"
mkdir -p "$work"
jobs="$(getconf _NPROCESSORS_ONLN)"

build_tools() {
  local dest="$1"
  mkdir -p "$dest"
  fetch_transcribe "$work/transcribe.cpp"
  fetch_llama "$work/llama.cpp"
  # Static and CPU only; these run in CI and never ship. Not tuned to the
  # build machine: CI builds them once for runners with other CPUs.
  local common=(-DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_CCACHE=OFF -DBUILD_SHARED_LIBS=OFF)
  cmake -S "$work/transcribe.cpp" -B "$work/tools-transcribe" "${common[@]}" \
    -DTRANSCRIBE_BUILD_TOOLS=ON -DTRANSCRIBE_BUILD_EXAMPLES=ON -DTRANSCRIBE_BUILD_TESTS=OFF \
    -DTRANSCRIBE_BUILD_SHARED=OFF -DTRANSCRIBE_METAL=OFF -DTRANSCRIBE_VULKAN=OFF -DTRANSCRIBE_USE_OPENMP=OFF >/dev/null
  cmake --build "$work/tools-transcribe" -j "$jobs" --target transcribe-quantize transcribe-cli
  cmake -S "$work/llama.cpp" -B "$work/tools-llama" "${common[@]}" \
    -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_OPENMP=OFF -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF >/dev/null
  cmake --build "$work/tools-llama" -j "$jobs" --target llama-server
  cp "$work/tools-transcribe/bin/transcribe-cli" "$work/tools-transcribe/bin/transcribe-quantize" \
    "$work/tools-llama/bin/llama-server" "$dest/"
  printf 'transcribe %s\nllama %s\n' "$TRANSCRIBE_COMMIT" "$LLAMA_COMMIT" > "$dest/PINS"
}

# The tools in DIR, built for these pins (rebuilt when the pins move).
ensure_tools() {
  local dir="$1"
  if [ ! -x "$dir/llama-server" ] || ! grep -q "$LLAMA_COMMIT" "$dir/PINS" 2>/dev/null ||
    ! grep -q "$TRANSCRIBE_COMMIT" "$dir/PINS" 2>/dev/null; then
    build_tools "$dir"
  fi
}

ensure_uv() {
  local target
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) target=aarch64-apple-darwin ;;
    Darwin-x86_64) target=x86_64-apple-darwin ;;
    Linux-x86_64) target=x86_64-unknown-linux-gnu ;;
    Linux-aarch64) target=aarch64-unknown-linux-gnu ;;
    *) echo "no uv build for $(uname -s) $(uname -m)" >&2; return 1 ;;
  esac
  if [ ! -x "$work/uv/uv" ] || [ "$("$work/uv/uv" --version | awk '{print $2}')" != "$UV_VERSION" ]; then
    mkdir -p "$work/uv"
    fetch_github_asset astral-sh/uv "$UV_VERSION" "uv-$target.tar.gz" "$work/uv.tar.gz"
    tar -C "$work/uv" --strip-components 1 -xzf "$work/uv.tar.gz"
  fi
  export PATH="$work/uv:$PATH"
  # The same Python everywhere (uv's own builds, which it checks), with
  # packages and Pythons kept in the scratch folder.
  export UV_PYTHON_PREFERENCE=only-managed UV_PYTHON=3.12
  export UV_CACHE_DIR="$work/uv-cache" UV_PYTHON_INSTALL_DIR="$work/uv-python"
}

one() {
  local id="$1" out="$2" tools="${3:-$work/tools}" kind
  kind="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(next(m["kind"] for k in ("speech","chat") for m in c[k] if m["id"]==sys.argv[2]))' "$here/../models/catalogue.json" "$id")"
  ensure_tools "$tools"
  if [ "$kind" = chat ]; then
    python3 "$here/models.py" chat "$id" --tools "$tools" --work "$work/models" --out "$out"
  else
    fetch_transcribe "$work/transcribe.cpp"
    ensure_uv
    python3 "$here/models.py" speech "$id" --tools "$tools" --transcribe "$work/transcribe.cpp" \
      --work "$work/models" --out "$out"
  fi
}

python3 -m doctest "$here/models.py" "$here/speech_check.py"
case "${1:-}" in
  tools)
    build_tools "$2" ;;
  catalogue)
    python3 "$here/models.py" catalogue --results "$2" --out "$3" --tag "$4" ;;
  all)
    out="$(mkdir -p "$2" && cd "$2" && pwd)"
    for id in $(python3 "$here/models.py" ids | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))'); do
      one "$id" "$out"
    done
    python3 "$here/models.py" catalogue --results "$out" --out "$out" --tag "${3:-models-$(date -u +%Y-%m-%d)}" ;;
  "")
    echo "usage: scripts/models.sh <tools|catalogue|all|model id> ..." >&2; exit 2 ;;
  *)
    out="$(mkdir -p "$2" && cd "$2" && pwd)"
    one "$1" "$out" "${3:-}" ;;
esac
