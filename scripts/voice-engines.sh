#!/usr/bin/env bash
# Builds Short Leash's two local AI engines for macOS, each with its own ggml:
# transcribe.cpp (speech) and llama.cpp with its common library (chat and
# summaries), at the pins in voice-engines.env. Static libraries, so Short Leash's
# helpers link them in. Apple silicon builds use Metal; Intel builds run on
# the CPU. Cross-builds x86_64 from an Apple silicon Mac (the smoke tests then
# run under Rosetta).
#
#   scripts/voice-engines.sh <aarch64|x86_64> out/
#
# Writes out/voice-engines-<transcribe-cpp-sys>-<llama-cpp-sys-2>-macos-<arch>.tar.gz:
#
#   transcribe/   the `cmake --install` prefix transcribe-cpp-sys reads from
#                 TRANSCRIBE_DIR (lib/transcribe-link.json says how to link it)
#   llama/        llama.cpp's install prefix plus common's libraries and
#                 headers, with lib/llama-link.json in the same shape
#   LICENSES/     the engines' licences and their third-party notices
#   BUILDINFO.json  pins, compiler, CMake options and smoke test results
#
# Fails unless both link from their manifests alone, transcribe a FLEURS clip
# on the CPU, and llama.cpp generates, renders a Qwen chat template with a
# tool and parses a tool call.
set -euo pipefail

arch="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
. "$here/lib.sh"
. "$here/engines.sh"
case "$arch" in
  aarch64) osx_arch=arm64 metal=ON ;;
  x86_64) osx_arch=x86_64 metal=OFF ;;
  *) echo "arch must be aarch64 or x86_64" >&2; exit 1 ;;
esac

work="${VOICE_ENGINES_WORK:-$(mktemp -d)}"
mkdir -p "$work"
fetch_transcribe "$work/transcribe.cpp"
fetch_llama "$work/llama.cpp"

name="voice-engines-$TRANSCRIBE_VERSION-$LLAMA_CPP_SYS_VERSION-macos-$arch"
pkg="$work/$name"
rm -rf "$pkg" "$work/build-$arch-transcribe" "$work/build-$arch-llama"
mkdir -p "$pkg/LICENSES"

generator=()
command -v ninja >/dev/null && generator=(-G Ninja)
common=(
  "${generator[@]}"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES="$osx_arch"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
  # Never tuned to the build machine: an M2 build would crash on an M1.
  -DGGML_NATIVE=OFF
  -DGGML_CCACHE=OFF
)
if [ "$arch" = x86_64 ]; then
  # macOS 13 runs only on Intel Macs from 2017 on, which all have AVX2, FMA,
  # F16C and BMI2; AVX-512 stays off.
  common+=(-DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON
    -DGGML_AVX512=OFF)
fi

transcribe_opts=(
  -DTRANSCRIBE_INSTALL=ON
  -DTRANSCRIBE_BUILD_TESTS=OFF
  -DTRANSCRIBE_BUILD_EXAMPLES=OFF
  -DTRANSCRIBE_BUILD_TOOLS=OFF
  -DTRANSCRIBE_BUILD_SHARED=OFF
  -DTRANSCRIBE_USE_OPENMP=OFF
  -DTRANSCRIBE_METAL="$metal"
  -DGGML_METAL_EMBED_LIBRARY="$metal"
)
cmake -S "$work/transcribe.cpp" -B "$work/build-$arch-transcribe" "${common[@]}" "${transcribe_opts[@]}" >/dev/null
cmake --build "$work/build-$arch-transcribe" --config Release -j "$(sysctl -n hw.ncpu)"
cmake --install "$work/build-$arch-transcribe" --prefix "$pkg/transcribe" >/dev/null

# llama.cpp as llama-cpp-sys-2 builds it with its common feature, without
# the network code Short Leash doesn't use: no curl, no OpenSSL, no subprocesses.
llama_opts=(
  -DBUILD_SHARED_LIBS=OFF
  -DLLAMA_BUILD_COMMON=ON
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_SERVER=OFF
  -DLLAMA_BUILD_TOOLS=OFF
  -DLLAMA_BUILD_APP=OFF
  -DLLAMA_CURL=OFF
  -DLLAMA_OPENSSL=OFF
  -DLLAMA_SUBPROCESS=OFF
  -DGGML_BLAS=OFF
  -DGGML_OPENMP=OFF
  -DGGML_METAL="$metal"
  -DGGML_METAL_EMBED_LIBRARY="$metal"
)
cmake -S "$work/llama.cpp" -B "$work/build-$arch-llama" "${common[@]}" "${llama_opts[@]}" >/dev/null
cmake --build "$work/build-$arch-llama" --config Release -j "$(sysctl -n hw.ncpu)"
cmake --install "$work/build-$arch-llama" --prefix "$pkg/llama" >/dev/null
python3 "$here/llama_manifest.py" "$work/llama.cpp" "$work/build-$arch-llama" "$pkg/llama" macos "$metal"

# Licences: the engines' own, and the notices of what they vendor.
cp "$work/transcribe.cpp/LICENSE" "$pkg/LICENSES/transcribe.cpp-LICENSE.txt"
cp "$work/transcribe.cpp/THIRD-PARTY-LICENSES.md" "$pkg/LICENSES/transcribe.cpp-THIRD-PARTY-LICENSES.md"
cp "$work/llama.cpp/LICENSE" "$pkg/LICENSES/llama.cpp-LICENSE.txt"
cp "$work/llama.cpp/licenses/LICENSE-jsonhpp" "$pkg/LICENSES/llama.cpp-nlohmann-json-LICENSE.txt"
cp "$work/llama.cpp/vendor/cpp-httplib/LICENSE" "$pkg/LICENSES/llama.cpp-cpp-httplib-LICENSE.txt"

# Static archives aren't Mach-O files, so check_macos_minimum skips them:
# check each one's architecture and every object's minimum macOS here.
for a in "$pkg"/*/lib/*.a; do
  [ "$(lipo -archs "$a")" = "$osx_arch" ] || { echo "$a is $(lipo -archs "$a"), not $osx_arch" >&2; exit 1; }
  newest="$(otool -l "$a" | awk '/ minos / {print $2}' | sort -V | tail -1)"
  if [ -z "$newest" ] || [ "$(printf '%s\n%s\n' "$newest" "$MACOSX_DEPLOYMENT_TARGET" | sort -V | tail -1)" != "$MACOSX_DEPLOYMENT_TARGET" ]; then
    echo "$a needs macOS ${newest:-unknown}, newer than $MACOSX_DEPLOYMENT_TARGET" >&2
    exit 1
  fi
done

# Smoke tests on the CPU, linked from the manifests alone.
fixtures="$work/smoke-fixtures"
mkdir -p "$fixtures"
fetch_hf "$TRANSCRIBE_SMOKE_REPO" "$TRANSCRIBE_SMOKE_COMMIT" "$TRANSCRIBE_SMOKE_FILE" "$TRANSCRIBE_SMOKE_SHA256" "$fixtures/$TRANSCRIBE_SMOKE_FILE"
fetch_hf "$LLAMA_SMOKE_REPO" "$LLAMA_SMOKE_COMMIT" "$LLAMA_SMOKE_FILE" "$LLAMA_SMOKE_SHA256" "$fixtures/$LLAMA_SMOKE_FILE"
run_prefix=()
[ "$arch" != "$(devkit_arch)" ] && run_prefix=(arch "-$osx_arch")
python3 "$here/engine_smoke.py" \
  --pkg "$pkg" \
  --dr-wav "$work/transcribe.cpp/examples/common" \
  --cc "cc -arch $osx_arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
  --cxx "c++ -arch $osx_arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
  --run-prefix "${run_prefix[*]:-}" \
  --transcribe-model "$fixtures/$TRANSCRIBE_SMOKE_FILE" \
  --llama-model "$fixtures/$LLAMA_SMOKE_FILE" \
  --template "$repo/models/templates/qwen3.5.jinja" \
  --fixtures "$repo/models/fixtures" \
  --results "$work/smoke-$arch.json"

python3 "$here/buildinfo.py" "$pkg/BUILDINFO.json" \
  platform="macos-$arch" \
  macos_minimum="$MACOSX_DEPLOYMENT_TARGET" \
  compiler="$(cc --version | head -1)" \
  xcode="$(xcodebuild -version 2>/dev/null | head -1 || echo unknown)" \
  cmake="$(cmake --version | head -1)" \
  transcribe_options="${common[*]} ${transcribe_opts[*]}" \
  llama_options="${common[*]} ${llama_opts[*]}" \
  smoke=@"$work/smoke-$arch.json"

tar -C "$work" -czf "$out/$name.tar.gz" "$name"
ls -lh "$out"
