# Builds libwebrtc for Windows the way the webrtc-sys crate's own recipe does,
# without H.264: no OpenH264 and no FFmpeg. AV1 (libaom, dav1d) and VP8/VP9
# (libvpx) stay. Cross-builds arm64 from an x64 machine.
#
#   pwsh scripts/libwebrtc-windows.ps1 <x86_64|aarch64> out
#
# Writes out\libwebrtc-<crate version>-windows-<arch>.zip with lib\webrtc.lib,
# include\, webrtc.ninja, desktop_capture.ninja, args.gn and LICENSE.md: the
# layout webrtc-sys reads from LK_CUSTOM_WEBRTC. Uses the installed Visual
# Studio 2022 and needs about 40 GB of disk; LIBWEBRTC_WORK picks where.
param([Parameter(Mandatory)][string]$Arch, [Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$cpu = switch ($Arch) { 'x86_64' { 'x64' } 'aarch64' { 'arm64' } default { throw 'Arch must be x86_64 or aarch64' } }
$env_ = @{}
foreach ($line in Get-Content (Join-Path $PSScriptRoot 'libwebrtc.env')) {
  # Keys have digits (WEBRTC_SYS_SHA256); the checkout may end lines with CRLF.
  if ($line -match '^([A-Z0-9_]+)=(.*)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
foreach ($k in 'WEBRTC_SYS_VERSION', 'WEBRTC_SYS_SHA256', 'WEBRTC_COMMIT', 'DEPOT_TOOLS_COMMIT') {
  if (-not $env_[$k]) { throw "libwebrtc.env has no $k" }
}
$version = $env_['WEBRTC_SYS_VERSION']
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$work = if ($env:LIBWEBRTC_WORK) { $env:LIBWEBRTC_WORK } else { Join-Path ([IO.Path]::GetTempPath()) "libwebrtc-$cpu" }
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

function Run([string]$exe, [string[]]$argv) {
  & $exe @argv
  if ($LASTEXITCODE -ne 0) { throw "${exe} failed with exit code $LASTEXITCODE" }
}

# The recipe and patches, from the crate DevKit links, checked by SHA-256.
$crate = "webrtc-sys-$version.crate"
if (-not (Test-Path $crate)) {
  Invoke-WebRequest -UseBasicParsing "https://static.crates.io/crates/webrtc-sys/$crate" -OutFile $crate
}
$got = (Get-FileHash -Algorithm SHA256 $crate).Hash.ToLower()
if ($got -ne $env_['WEBRTC_SYS_SHA256']) { throw "${crate}: SHA-256 $got doesn't match $($env_['WEBRTC_SYS_SHA256'])" }
Run tar @('-xzf', $crate, "webrtc-sys-$version/libwebrtc")
$recipe = Join-Path $work "webrtc-sys-$version\libwebrtc"

# depot_tools at the pinned commit, using the installed Visual Studio.
if (-not (Test-Path 'depot_tools\.git')) {
  Run git @('init', '-q', 'depot_tools')
  Run git @('-C', 'depot_tools', 'fetch', '-q', '--depth', '1', 'https://chromium.googlesource.com/chromium/tools/depot_tools.git', $env_['DEPOT_TOOLS_COMMIT'])
  Run git @('-C', 'depot_tools', 'checkout', '-q', 'FETCH_HEAD')
}
$env:PATH = (Join-Path $work 'depot_tools') + ';' + $env:PATH
$env:DEPOT_TOOLS_UPDATE = '0'
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:GYP_MSVS_VERSION = '2022'
if (-not (Test-Path 'depot_tools\python3_bin_reldir.txt')) { Run cmd @('/c', (Join-Path $work 'depot_tools\bootstrap\win_tools.bat')) }
if (-not (Test-Path 'depot_tools\python3_bin_reldir.txt')) { throw "depot_tools didn't bootstrap" }

@"
solutions = [
  {
    "name": 'src',
    "url": 'https://github.com/webrtc-sdk/webrtc.git@$($env_['WEBRTC_COMMIT'])',
    "custom_deps": {},
    "deps_file": "DEPS",
    "managed": False,
  },
]
"@ | Set-Content -Encoding ascii .gclient
$head = if (Test-Path 'src\.git') { (& git -C src rev-parse HEAD) } else { '' }
if ($head -ne $env_['WEBRTC_COMMIT']) { Run gclient.bat @('sync', '-D', '--no-history') }

# The recipe's Windows patches. A patch that's already applied is skipped; one
# that neither applies nor is applied stops the build.
Push-Location src
foreach ($p in 'add_licenses', 'add_deps', 'ssl_verify_callback_with_native_handle', 'external_audio_source') {
  $patch = Join-Path $recipe "patches\$p.patch"
  & git apply --reverse --check --ignore-space-change --ignore-whitespace $patch 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Output "Patch already applied: $p"; continue }
  Run git @('apply', '-v', '--ignore-space-change', '--ignore-whitespace', '--whitespace=nowarn', $patch)
}
Copy-Item .vpython3 ..\ -Force
Pop-Location

# The recipe's Windows arguments, with H.264 off and Chromium branding.
$build = "src\out-$cpu"
$gnArgs = "is_debug=false is_clang=true target_cpu=`"$cpu`" use_custom_libcxx=false rtc_libvpx_build_vp9=true enable_libaom=true rtc_include_tests=false rtc_build_examples=false rtc_build_tools=false is_component_build=false rtc_enable_protobuf=false rtc_use_h264=false proprietary_codecs=false ffmpeg_branding=`"Chromium`" symbol_level=0 enable_iterator_debugging=false"
# Written to args.gn, not passed as --args: gn.bat goes through cmd, which
# strips the quotes gn needs around strings.
New-Item -ItemType Directory -Force $build | Out-Null
Set-Content -Path (Join-Path $build 'args.gn') -Value ($gnArgs -replace ' (?=[a-z_]+=)', "`n") -Encoding ascii
Run gn.bat @('gen', $build, '--root=src')
Run ninja.exe @('-C', $build, ':default')

$name = "libwebrtc-$version-windows-$Arch"
$pkg = Join-Path $work $name
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force (Join-Path $pkg 'lib') | Out-Null
Copy-Item "$build\obj\webrtc.lib" (Join-Path $pkg 'lib')
Run python3 @('src\tools_webrtc\libs\generate_licenses.py', '--target', ':default', $build, $build)
Copy-Item "$build\obj\webrtc.ninja", "$build\obj\modules\desktop_capture\desktop_capture.ninja", "$build\args.gn", "$build\LICENSE.md" $pkg
Push-Location src
Get-ChildItem -Recurse -File -Include *.h, *.inc | ForEach-Object {
  $rel = $_.FullName.Substring((Get-Location).Path.Length + 1)
  $dest = Join-Path (Join-Path $pkg 'include') $rel
  New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
  Copy-Item $_.FullName $dest
}
Pop-Location

# What DevKit relies on: no FFmpeg or OpenH264 in the library or its licences.
$nm = 'src\third_party\llvm-build\Release+Asserts\bin\llvm-nm.exe'
$bad = & $nm -g --defined-only (Join-Path $pkg 'lib\webrtc.lib') 2>$null | Select-String -Pattern ' (avcodec_|av_malloc|ff_h264|WelsCreateSVCEncoder)' | Select-Object -First 1
if ($bad) { throw "webrtc.lib contains FFmpeg or OpenH264 code: $bad" }
if (Select-String -Path (Join-Path $pkg 'LICENSE.md') -Pattern '^# (ffmpeg|openh264)$' -Quiet) { throw 'LICENSE.md lists FFmpeg or OpenH264' }
if (-not (Select-String -Path (Join-Path $pkg 'args.gn') -Pattern 'rtc_use_h264 = false' -Quiet)) { throw 'args.gn lost rtc_use_h264 = false' }

Push-Location $work
Run tar.exe @('-a', '-c', '-f', (Join-Path $Out "$name.zip"), $name)
Pop-Location
Get-ChildItem $Out
