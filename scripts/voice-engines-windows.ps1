# Builds Short Leash's two local AI engines for Windows x64, each with its own
# ggml: transcribe.cpp (speech) and llama.cpp with its common library, at the
# pins in voice-engines.env. DLLs with the dynamic C runtime (/MD), and ggml's
# backends as loadable modules: CPU variants for each instruction set, picked
# at run time, plus Vulkan. Uses the installed Visual Studio 2022 (run it from
# a developer prompt, so cl.exe is on PATH) and installs the Vulkan SDK.
#
#   pwsh scripts/voice-engines-windows.ps1 x86_64 out
#
# Writes out\voice-engines-<transcribe-cpp-sys>-<llama-cpp-sys-2>-windows-x86_64.zip
# with transcribe\ and llama\ (install prefixes with lib\transcribe-link.json
# and lib\llama-link.json; DLLs in bin\), LICENSES\ and BUILDINFO.json, which
# records the MSVC version: Short Leash installs at least that Visual C++
# Redistributable. Fails unless every DLL uses the dynamic C runtime, both
# engines link from their manifests alone and pass the CPU smoke tests.
param([Parameter(Mandatory)][string]$Arch, [Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($Arch -ne 'x86_64') { throw 'Windows builds are x86_64 only' }

$pins = @{}
foreach ($line in Get-Content (Join-Path $PSScriptRoot 'voice-engines.env')) {
  # The checkout may end lines with CRLF.
  if ($line -match '^([A-Z0-9_]+)=(.*)$') { $pins[$Matches[1]] = $Matches[2].Trim() }
}
$repo = Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
# A short root: ggml's Vulkan shader build has deep paths.
$work = if ($env:VOICE_ENGINES_WORK) { $env:VOICE_ENGINES_WORK } else { Join-Path ([IO.Path]::GetTempPath()) 've' }
New-Item -ItemType Directory -Force $work | Out-Null

function Run([string]$exe, [string[]]$argv) {
  & $exe @argv
  if ($LASTEXITCODE -ne 0) { throw "${exe} failed with exit code $LASTEXITCODE" }
}

function Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 $path).Hash.ToLower() }

function Fetch-Checked([string]$url, [string]$sha, [string]$dest) {
  if (-not ((Test-Path $dest) -and ((Sha256 $dest) -eq $sha))) {
    Invoke-WebRequest -UseBasicParsing $url -OutFile $dest
  }
  $got = Sha256 $dest
  if ($got -ne $sha) { throw "${url}: SHA-256 $got doesn't match $sha" }
}

function Fetch-HF([string]$repoId, [string]$commit, [string]$file, [string]$sha, [string]$dest) {
  Fetch-Checked "https://huggingface.co/$repoId/resolve/$commit/$file" $sha $dest
}

# A shallow checkout of exactly one commit; git checks every object's hash.
function Fetch-Commit([string]$url, [string]$commit, [string]$dir) {
  if (-not (Test-Path "$dir\.git")) {
    Run git @('init', '-q', $dir)
    # Byte for byte: the runner's git would otherwise convert line endings.
    Run git @('-C', $dir, 'config', 'core.autocrlf', 'false')
    Run git @('-C', $dir, 'fetch', '-q', '--depth', '1', $url, $commit)
    Run git @('-C', $dir, '-c', 'advice.detachedHead=false', 'checkout', '-q', 'FETCH_HEAD')
  }
  $head = (& git -C $dir rev-parse HEAD).Trim()
  if ($head -ne $commit) { throw "$dir is at $head, not $commit" }
}

function Fetch-Crate([string]$name, [string]$version, [string]$sha) {
  $crates = Join-Path $work 'crates'
  New-Item -ItemType Directory -Force $crates | Out-Null
  $dir = Join-Path $crates "$name-$version"
  if (-not (Test-Path $dir)) {
    $file = Join-Path $crates "$name-$version.crate"
    Fetch-Checked "https://static.crates.io/crates/$name/$name-$version.crate" $sha $file
    Run tar @('-C', $crates, '-xzf', $file)
  }
  return $dir
}

# The engines, each checked against the crate Short Leash links it through (as
# scripts/engines.sh does on macOS).
$transcribe = Join-Path $work 'transcribe.cpp'
Fetch-Commit 'https://github.com/handy-computer/transcribe.cpp.git' $pins['TRANSCRIBE_COMMIT'] $transcribe
$tcrate = Fetch-Crate 'transcribe-cpp-sys' $pins['TRANSCRIBE_VERSION'] $pins['TRANSCRIBE_CPP_SYS_SHA256']
$packaged = (Get-Content (Join-Path $tcrate '.cargo_vcs_info.json') -Raw | ConvertFrom-Json).git.sha1
if ($packaged -ne $pins['TRANSCRIBE_COMMIT']) { throw "transcribe-cpp-sys was packaged from $packaged, not $($pins['TRANSCRIBE_COMMIT'])" }
if ((Sha256 "$tcrate\include\transcribe.abihash") -ne (Sha256 "$transcribe\include\transcribe.abihash")) {
  throw 'transcribe-cpp-sys has another ABI hash than transcribe.cpp'
}
$llama = Join-Path $work 'llama.cpp'
Fetch-Commit 'https://github.com/ggml-org/llama.cpp.git' $pins['LLAMA_COMMIT'] $llama
$lcrate = Fetch-Crate 'llama-cpp-sys-2' $pins['LLAMA_CPP_SYS_VERSION'] $pins['LLAMA_CPP_SYS_SHA256']
$vendored = Join-Path $lcrate 'llama.cpp'
# Every file the crate vendors must have the git blob hash the commit lists
# (hashed as bytes, so line endings in the checkout don't matter).
$tree = @{}
foreach ($line in (& git -C $llama ls-tree -r HEAD)) {
  if ($line -match '^\d+ blob ([0-9a-f]{40})\t(.+)$') { $tree[$Matches[2]] = $Matches[1] }
}
$n = 0
foreach ($f in Get-ChildItem -Recurse -File $vendored) {
  $n++
  $rel = $f.FullName.Substring($vendored.Length + 1) -replace '\\', '/'
  $blob = (& git hash-object --no-filters $f.FullName).Trim()
  if ($tree[$rel] -ne $blob) { throw "llama-cpp-sys-2's $rel differs from llama.cpp $($pins['LLAMA_COMMIT'])" }
}
if ($n -lt 100) { throw 'llama-cpp-sys-2 has no llama.cpp sources' }

# The Vulkan SDK: the pinned SHA-256, which must also be the one LunarG
# publishes, and LunarG's signature.
$vk = $pins['VULKAN_SDK_VERSION']
$vkExe = Join-Path $work "vulkansdk-windows-X64-$vk.exe"
$published = (Invoke-RestMethod "https://vulkan.lunarg.com/sdk/sha/$vk/windows/vulkansdk-windows-X64-$vk.exe.json").sha
if ($published -ne $pins['VULKAN_SDK_SHA256']) { throw "LunarG lists $published for the Vulkan SDK $vk, not the pinned $($pins['VULKAN_SDK_SHA256'])" }
Fetch-Checked "https://sdk.lunarg.com/sdk/download/$vk/windows/vulkansdk-windows-X64-$vk.exe" $pins['VULKAN_SDK_SHA256'] $vkExe
$sig = Get-AuthenticodeSignature $vkExe
if ($sig.Status -ne 'Valid') { throw "The Vulkan SDK installer's signature is $($sig.Status)" }
$vkRoot = "C:\VulkanSDK\$vk"
if (-not (Test-Path "$vkRoot\Bin\glslc.exe")) {
  Run $vkExe @('--root', $vkRoot, '--accept-licenses', '--default-answer', '--confirm-command', 'install')
}
$env:VULKAN_SDK = $vkRoot
$env:PATH = "$vkRoot\Bin;$env:PATH"
$glslc = (& glslc --version | Select-Object -First 1)

# The compiler Short Leash's Redistributable pin follows.
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'cl.exe is not on PATH; run from a Visual Studio developer prompt' }
# cl prints its banner (with the version) to stderr and its usage to stdout.
$clBanner = (& cl.exe 2>&1 | ForEach-Object { $_.ToString() } | Where-Object { $_ -match 'Compiler Version' } | Select-Object -First 1)
if ($clBanner -notmatch 'Version (\d+\.\d+\.\d+)') { throw "Can't read the MSVC version from: $clBanner" }
$msvc = @{ compiler = $Matches[1]; toolset = $env:VCToolsVersion; redist = $env:VCToolsRedistDir; banner = $clBanner }

$name = "voice-engines-$($pins['TRANSCRIBE_VERSION'])-$($pins['LLAMA_CPP_SYS_VERSION'])-windows-$Arch"
$pkg = Join-Path $work $name
foreach ($d in $pkg, "$work\b-t", "$work\b-l") { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
New-Item -ItemType Directory -Force "$pkg\LICENSES" | Out-Null

$generator = if (Get-Command ninja -ErrorAction SilentlyContinue) { @('-G', 'Ninja') } else { @('-G', 'Visual Studio 17 2022', '-A', 'x64') }
$common = $generator + @(
  '-DCMAKE_BUILD_TYPE=Release',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL',
  '-DGGML_NATIVE=OFF',
  '-DGGML_CCACHE=OFF',
  # One CPU module per instruction-set level, chosen at run time.
  '-DGGML_CPU_ALL_VARIANTS=ON'
)
$transcribeOpts = @(
  '-DTRANSCRIBE_INSTALL=ON',
  '-DTRANSCRIBE_BUILD_TESTS=OFF',
  '-DTRANSCRIBE_BUILD_EXAMPLES=OFF',
  '-DTRANSCRIBE_BUILD_TOOLS=OFF',
  '-DTRANSCRIBE_BUILD_SHARED=ON',
  '-DTRANSCRIBE_GGML_BACKEND_DL=ON',
  '-DTRANSCRIBE_X86_CONSERVATIVE=ON',
  '-DTRANSCRIBE_VULKAN=ON',
  '-DTRANSCRIBE_USE_OPENMP=OFF',
  '-DTRANSCRIBE_USE_SYSTEM_BLAS=OFF'
)
Run cmake (@('-S', $transcribe, '-B', "$work\b-t") + $common + $transcribeOpts)
Run cmake @('--build', "$work\b-t", '--config', 'Release', '--parallel')
Run cmake @('--install', "$work\b-t", '--config', 'Release', '--prefix', "$pkg\transcribe")

# llama.cpp as llama-cpp-sys-2 builds it with its common feature, without
# the network code Short Leash doesn't use.
$llamaOpts = @(
  '-DBUILD_SHARED_LIBS=ON',
  '-DGGML_BACKEND_DL=ON',
  '-DGGML_VULKAN=ON',
  '-DLLAMA_BUILD_COMMON=ON',
  '-DLLAMA_BUILD_TESTS=OFF',
  '-DLLAMA_BUILD_EXAMPLES=OFF',
  '-DLLAMA_BUILD_SERVER=OFF',
  '-DLLAMA_BUILD_TOOLS=OFF',
  '-DLLAMA_BUILD_APP=OFF',
  '-DLLAMA_CURL=OFF',
  '-DLLAMA_OPENSSL=OFF',
  '-DLLAMA_SUBPROCESS=OFF',
  '-DGGML_OPENMP=OFF'
)
Run cmake (@('-S', $llama, '-B', "$work\b-l") + $common + $llamaOpts)
Run cmake @('--build', "$work\b-l", '--config', 'Release', '--parallel')
Run cmake @('--install', "$work\b-l", '--config', 'Release', '--prefix', "$pkg\llama")
Run python @("$PSScriptRoot\llama_manifest.py", $llama, "$work\b-l", "$pkg\llama", 'windows', 'OFF', '--shared')

Copy-Item "$transcribe\LICENSE" "$pkg\LICENSES\transcribe.cpp-LICENSE.txt"
Copy-Item "$transcribe\THIRD-PARTY-LICENSES.md" "$pkg\LICENSES\transcribe.cpp-THIRD-PARTY-LICENSES.md"
Copy-Item "$llama\LICENSE" "$pkg\LICENSES\llama.cpp-LICENSE.txt"
Copy-Item "$llama\licenses\LICENSE-jsonhpp" "$pkg\LICENSES\llama.cpp-nlohmann-json-LICENSE.txt"
Copy-Item "$llama\vendor\cpp-httplib\LICENSE" "$pkg\LICENSES\llama.cpp-cpp-httplib-LICENSE.txt"

# Every DLL uses the dynamic C runtime, and the Vulkan backends exist and
# load Vulkan through the system's loader only.
$dlls = Get-ChildItem -Recurse -File -Filter *.dll $pkg
if ($dlls.Count -lt 4) { throw "Only $($dlls.Count) DLLs were installed" }
foreach ($dll in $dlls) {
  $deps = (& dumpbin /nologo /dependents $dll.FullName) -join "`n"
  if ($deps -notmatch 'VCRUNTIME140\.dll') { throw "$($dll.Name) doesn't use the dynamic C runtime" }
}
foreach ($engine in 'transcribe', 'llama') {
  $vkDll = Get-ChildItem -Recurse -File -Filter 'ggml-vulkan.dll' "$pkg\$engine" | Select-Object -First 1
  if (-not $vkDll) { throw "$engine has no Vulkan backend" }
  if (((& dumpbin /nologo /dependents $vkDll.FullName) -join "`n") -notmatch 'vulkan-1\.dll') { throw "$engine's Vulkan backend doesn't use vulkan-1.dll" }
  $cpuVariants = @(Get-ChildItem -Recurse -File -Filter 'ggml-cpu-*.dll' "$pkg\$engine").Count
  if ($cpuVariants -lt 2) { throw "$engine has $cpuVariants CPU variants" }
}

# Smoke tests on the CPU, linked from the manifests alone.
$fixtures = Join-Path $work 'smoke-fixtures'
New-Item -ItemType Directory -Force $fixtures | Out-Null
Fetch-HF $pins['TRANSCRIBE_SMOKE_REPO'] $pins['TRANSCRIBE_SMOKE_COMMIT'] $pins['TRANSCRIBE_SMOKE_FILE'] $pins['TRANSCRIBE_SMOKE_SHA256'] "$fixtures\$($pins['TRANSCRIBE_SMOKE_FILE'])"
Fetch-HF $pins['LLAMA_SMOKE_REPO'] $pins['LLAMA_SMOKE_COMMIT'] $pins['LLAMA_SMOKE_FILE'] $pins['LLAMA_SMOKE_SHA256'] "$fixtures\$($pins['LLAMA_SMOKE_FILE'])"
# Hosted runners have no GPU; layers that hook Vulkan stay out either way.
$env:VK_LOADER_LAYERS_DISABLE = '~implicit~'
Run python @("$PSScriptRoot\engine_smoke.py", '--msvc',
  '--pkg', $pkg,
  '--dr-wav', "$transcribe\examples\common",
  '--transcribe-model', "$fixtures\$($pins['TRANSCRIBE_SMOKE_FILE'])",
  '--llama-model', "$fixtures\$($pins['LLAMA_SMOKE_FILE'])",
  '--template', "$repo\models\templates\qwen3.5.jinja",
  '--fixtures', "$repo\models\fixtures",
  '--results', "$work\smoke\windows.json")

$msvc | ConvertTo-Json | Set-Content -Encoding utf8 "$work\msvc.json"
Run python @("$PSScriptRoot\buildinfo.py", "$pkg\BUILDINFO.json",
  "platform=windows-$Arch",
  "msvc=@$work\msvc.json",
  "vulkan_sdk=$vk",
  "glslc=$glslc",
  "cmake=$((& cmake --version | Select-Object -First 1))",
  "transcribe_options=$(($common + $transcribeOpts) -join ' ')",
  "llama_options=$(($common + $llamaOpts) -join ' ')",
  "smoke=@$work\smoke\windows.json")

Push-Location $work
Run tar.exe @('-a', '-c', '-f', (Join-Path $Out "$name.zip"), $name)
Pop-Location
Get-ChildItem $Out
