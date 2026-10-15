#!/usr/bin/env bash
# Builds libwebrtc for macOS the way the webrtc-sys crate's own recipe does,
# without H.264: no OpenH264 and no FFmpeg. AV1 (libaom, dav1d) and VP8/VP9
# (libvpx) stay. Cross-builds x86_64 from an Apple silicon Mac.
#
#   scripts/libwebrtc.sh <aarch64|x86_64> out/
#
# Writes out/libwebrtc-<crate version>-macos-<arch>.tar.gz with lib/libwebrtc.a,
# include/, webrtc.ninja, desktop_capture.ninja, args.gn and LICENSE.md: the
# layout webrtc-sys reads from LK_CUSTOM_WEBRTC. Needs about 30 GB of disk.
set -euo pipefail

arch="$1"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/libwebrtc.env"
case "$arch" in
  aarch64) cpu=arm64 ;;
  x86_64) cpu=x64 ;;
  *) echo "arch must be aarch64 or x86_64" >&2; exit 1 ;;
esac

work="${LIBWEBRTC_WORK:-$(mktemp -d)}"
mkdir -p "$work"
cd "$work"

# The recipe and patches, from the crate DevKit links.
crate="webrtc-sys-$WEBRTC_SYS_VERSION.crate"
fetch_checked "https://static.crates.io/crates/webrtc-sys/$crate" "$WEBRTC_SYS_SHA256" "$crate"
tar -xzf "$crate" "webrtc-sys-$WEBRTC_SYS_VERSION/libwebrtc"
recipe="$work/webrtc-sys-$WEBRTC_SYS_VERSION/libwebrtc"

# depot_tools at the pinned commit. With updates off it never bootstraps its
# own Python, which gn needs, so bootstrap once by hand, by absolute path:
# the CIPD client it fetches finds its pinned digests relative to $0.
if [ ! -d depot_tools/.git ]; then
  git init -q depot_tools
  git -C depot_tools fetch -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_COMMIT"
  git -C depot_tools checkout -q FETCH_HEAD
fi
export PATH="$work/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
[ -e depot_tools/python3_bin_reldir.txt ] || "$work/depot_tools/ensure_bootstrap" || true
[ -e depot_tools/python3_bin_reldir.txt ] || { echo "depot_tools didn't bootstrap" >&2; exit 1; }

cat > .gclient <<GCLIENT
solutions = [
  {
    "name": 'src',
    "url": 'https://github.com/webrtc-sdk/webrtc.git@$WEBRTC_COMMIT',
    "custom_deps": {},
    "deps_file": "DEPS",
    "managed": False,
  },
]
GCLIENT
if [ ! -e src/.git ] || [ "$(git -C src rev-parse HEAD)" != "$WEBRTC_COMMIT" ]; then
  gclient sync -D --no-history
fi

# Build stamps come from build/util/LASTCHANGE.committime, which
# lastchange.py leaves at 0 for a commit without a Gerrit Change-Id. Use the
# commit's own date, so the build is the same wherever it runs.
git -C src log -1 --format=%ct HEAD | tr -d '\n' > src/build/util/LASTCHANGE.committime

. "$recipe/apply_patch.sh"
cd src
for p in add_licenses fix_license_json_parsing ssl_verify_callback_with_native_handle add_deps external_audio_source; do
  apply_patch "$recipe/patches/$p.patch"
done
cd ..

build="$work/src/out-$cpu"
# The recipe's macOS arguments, with H.264 off and Chromium branding. H.265
# stays on: the Objective-C codec list needs its classes, and on macOS it's
# VideoToolbox, not FFmpeg.
gn gen "$build" --root=src --args="is_debug=false
  enable_dsyms=false
  target_os=\"mac\"
  target_cpu=\"$cpu\"
  mac_deployment_target=\"$MACOSX_DEPLOYMENT_TARGET\"
  mac_min_system_version=\"$MACOSX_DEPLOYMENT_TARGET\"
  treat_warnings_as_errors=false
  rtc_enable_protobuf=false
  rtc_include_tests=false
  rtc_build_examples=false
  rtc_build_tools=false
  rtc_libvpx_build_vp9=true
  enable_libaom=true
  is_component_build=false
  enable_stripping=true
  rtc_enable_symbol_export=true
  rtc_enable_objc_symbol_export=false
  rtc_include_dav1d_in_internal_decoder_factory=true
  rtc_use_h264=false
  rtc_use_h265=true
  proprietary_codecs=false
  ffmpeg_branding=\"Chromium\"
  use_custom_libcxx=false
  use_clang_modules=false
  clang_use_chrome_plugins=false
  use_rtti=true
  use_lld=false
  rtc_include_internal_audio_device=true"

ninja -C "$build" :default \
  api/audio_codecs:builtin_audio_decoder_factory \
  api/task_queue:default_task_queue_factory \
  sdk:native_api \
  sdk:default_codec_factory_objc \
  pc:peer_connection \
  sdk:videocapture_objc \
  sdk:mac_framework_objc \
  desktop_capture_objc \
  modules/audio_device:audio_device

pkg="$work/libwebrtc-$WEBRTC_SYS_VERSION-macos-$arch"
rm -rf "$pkg" && mkdir -p "$pkg/lib"
find "$build/obj" -name '*.o' -not -path '*/third_party/nasm/*' -print0 | xargs -0 ar -rc "$pkg/lib/libwebrtc.a"
vpython3 src/tools_webrtc/libs/generate_licenses.py --target :webrtc "$build" "$build"
cp "$build/obj/webrtc.ninja" "$build/args.gn" "$build/LICENSE.md" "$pkg/"
cp "$build/obj/modules/desktop_capture/desktop_capture.ninja" "$pkg/"
mkdir -p "$pkg/include"
(cd src && find . \( -name '*.h' -o -name '*.inc' \) -print0 | rsync -a --from0 --files-from=- ./ "$pkg/include/")
[ -f "$pkg/include/api/rtc_error.h" ] || { echo "the headers weren't copied" >&2; exit 1; }

# What DevKit relies on: no FFmpeg or OpenH264 in the library or its licences.
nm_bin="src/third_party/llvm-build/Release+Asserts/bin/llvm-nm"
if "$nm_bin" -g --defined-only "$pkg/lib/libwebrtc.a" 2>/dev/null | grep -Eq ' (_avcodec_|_av_malloc|_ff_h264|_WelsCreateSVCEncoder)'; then
  echo "libwebrtc.a contains FFmpeg or OpenH264 code" >&2
  exit 1
fi
if grep -Eq '^# (ffmpeg|openh264)$' "$pkg/LICENSE.md"; then
  echo "LICENSE.md lists FFmpeg or OpenH264" >&2
  exit 1
fi
grep -q 'rtc_use_h264 = false' "$pkg/args.gn"

tar -C "$work" -czf "$out/libwebrtc-$WEBRTC_SYS_VERSION-macos-$arch.tar.gz" "libwebrtc-$WEBRTC_SYS_VERSION-macos-$arch"
ls -lh "$out"
