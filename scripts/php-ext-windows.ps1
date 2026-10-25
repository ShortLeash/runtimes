# Builds PHP extensions for windows.php.net's official PHP (non-thread-safe,
# x64) for one PHP minor, at the pins in php-ext-windows.env, against that
# minor's devel pack, and checks each one loads into the official PHP. Sources
# are a git tag at a pinned commit, or a PECL tarball at a pinned SHA-256.
# Extensions whose own project publishes Windows DLLs (mongodb, and Microsoft's
# sqlsrv and pdo_sqlsrv) aren't built: their DLL is checked against GitHub's
# digest or a pinned SHA-256 (and Microsoft's against its Authenticode
# signature), load-tested the same way and repackaged unchanged. Run from a
# Visual Studio developer prompt whose compiler matches the minor's (cl 19.20
# to 19.29 for vs16, 19.30 to 19.49 for vs17); only building needs it.
#
#   pwsh scripts/php-ext-windows.ps1 -Minor 8.4 -Exts "apcu redis" -Out out
#
# Writes out\php-ext-<ext>-<version>-php<minor>-nts-<vs>-windows-x86_64.zip
# for each extension, holding ext\php_<ext>.dll and licenses\php_<ext>\ (the
# extension's licence and notices, and BUILDINFO.json, which records the PHP
# release, the source and how it was checked, for a build the devel pack's
# SHA-256 and the cl version, and what php -m listed). Nothing else, so the
# zips extract into one PHP folder.
param(
  [Parameter(Mandatory)][string]$Minor,
  [Parameter(Mandatory)][string]$Exts,
  [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'
# A program that exits non-zero throws, like a failed cmdlet.
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

if ($Minor -notmatch '^\d+\.\d+$') { throw "${Minor}: not a PHP minor (like 8.4)" }

$pins = @{}
foreach ($line in Get-Content (Join-Path $PSScriptRoot 'php-ext-windows.env')) {
  # The checkout may end lines with CRLF.
  if ($line -match '^([A-Z0-9_]+)=(.*)$') { $pins[$Matches[1]] = $Matches[2].Trim() }
}

# <EXT>_<KEY>_PHP<XY> when it's set and not empty, else <EXT>_<KEY>, else ""
# (the same rule as plan.py's pin).
function Pin([string]$ext, [string]$key) {
  $name = "${ext}_${key}".ToUpper()
  $over = $pins["${name}_PHP$($Minor.Replace('.', ''))"]
  if ($over) { return $over }
  if ($pins[$name]) { return $pins[$name] }
  return ''
}

# mongodb, sqlsrv and pdo_sqlsrv: their own DLLs, checked and repackaged.
function Repackaged([string]$ext) { @('dll', 'microsoft') -contains (Pin $ext 'source') }

# The Visual Studio windows.php.net builds this minor with (plan.py's compiler).
$compiler = if ([version]$Minor -le [version]'8.3') { 'vs16' } else { 'vs17' }

$known = $pins['PHP_EXT_WINDOWS'].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
$wanted = $Exts.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
if (-not $wanted) { throw 'No extensions named; pass -Exts "apcu redis"' }
foreach ($ext in $wanted) {
  if ($known -notcontains $ext) { throw "${ext}: not in PHP_EXT_WINDOWS in php-ext-windows.env" }
  if ((Pin $ext 'skip').Split(' ') -contains $Minor) { throw "${ext}: php-ext-windows.env skips PHP $Minor" }
  $need = switch (Pin $ext 'source') {
    'git' { @('repo', 'tag', 'commit') }
    'pecl' { @('sha256') }
    # The release's tag is the version; the SHA-256 is needed only where
    # GitHub publishes no digest, which shows when the release is read.
    'dll' { @('repo', 'asset') }
    'microsoft' { @('repo', 'tag', 'asset') }
    default { throw "${ext}: source '$(Pin $ext 'source')' isn't one this script knows" }
  }
  if (-not (Pin $ext 'version')) { throw "${ext}: no version pinned for PHP $Minor in php-ext-windows.env" }
  foreach ($key in $need) {
    if (-not (Pin $ext $key)) { throw "${ext}: no $key pinned for PHP $Minor in php-ext-windows.env" }
  }
}

$built = @($wanted | Where-Object { -not (Repackaged $_) })

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
Set-Location $work

function Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 $path).Hash.ToLower() }

function Write-BuildInfo([string]$path, $info) {
  $info | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8NoBOM $path
}

# 1. The PHP release and its devel pack, checked against releases.json.
$base = 'https://windows.php.net/downloads/releases'
$releases = Invoke-RestMethod "$base/releases.json"
$entry = $releases.PSObject.Properties[$Minor]
if (-not $entry) { throw "PHP $Minor isn't in releases.json" }
$build = $entry.Value.PSObject.Properties["nts-$compiler-x64"]
if (-not $build) { throw "PHP $Minor has no nts-$compiler-x64 build in releases.json" }
$full = $entry.Value.version
$build = $build.Value

function Fetch-Php([string]$what) {
  $item = $build.$what
  $file = Join-Path $work $item.path
  Invoke-WebRequest -OutFile $file "$base/$($item.path)"
  $got = Sha256 $file
  if ($got -ne $item.sha256.ToLower()) { throw "$($item.path): SHA-256 $got doesn't match $($item.sha256) from releases.json" }
  return $item
}
$phpZip = Fetch-Php 'zip'
Expand-Archive (Join-Path $work $phpZip.path) -DestinationPath "$work\php"
$phpDir = "$work\php"
if (-not (Test-Path "$phpDir\php.exe")) { throw "$($phpZip.path) has no php.exe" }

# Only a build needs the devel pack, the compiler (2) and the PHP SDK (3); a
# run that only repackages skips them.
if ($built) {
  $develPack = Fetch-Php 'devel_pack'
  Expand-Archive (Join-Path $work $develPack.path) -DestinationPath "$work\devel"
  $phpize = (Get-ChildItem -Recurse -Filter phpize.bat "$work\devel" | Select-Object -First 1)
  if (-not $phpize) { throw "$($develPack.path) has no phpize.bat" }
  $phpize = $phpize.FullName

  # 2. The compiler matches the one this PHP was built with.
  if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'cl.exe is not on PATH; run from a Visual Studio developer prompt' }
  # cl prints its banner (with the version) to stderr and its usage to stdout.
  $clBanner = (& cl.exe 2>&1 | ForEach-Object { $_.ToString() } | Where-Object { $_ -match 'Compiler Version' } | Select-Object -First 1)
  if ($clBanner -notmatch 'Version (\d+)\.(\d+)\.(\d+)') { throw "Can't read the cl version from: $clBanner" }
  $cl = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
  $clMinor = [int]$Matches[2]
  $range = if ($compiler -eq 'vs16') { 20..29 } else { 30..49 }
  if ($Matches[1] -ne '19' -or $range -notcontains $clMinor) { throw "cl $cl doesn't build $compiler extensions" }

  # 3. The PHP SDK: configure.bat needs its bison, re2c and sed, and checks its
  # version with phpsdk_version.
  $sdkTag = $pins['PHP_SDK_TAG']; $sdkCommit = $pins['PHP_SDK_COMMIT']
  git clone --quiet --depth 1 --branch $sdkTag https://github.com/php/php-sdk-binary-tools.git sdk
  if ((git -C sdk rev-parse HEAD) -ne $sdkCommit) { throw "php-sdk-binary-tools $sdkTag isn't commit $sdkCommit" }
  $sdk = "$work\sdk"
}

# Each extension's source in src-<ext>: a git tag at its pinned commit, or a
# PECL tarball at its pinned SHA-256 (PECL publishes no checksum); or, for one
# that's repackaged, its DLL (see Fetch-Dll). Then the patches <EXT>_PATCHES
# names from scripts\php-ext-patches, if any, and the notices <EXT>_NOTICES
# names into notices-<ext>, each at its pinned SHA-256.
function Pecl-Url([string]$ext) { "https://pecl.php.net/get/$ext-$(Pin $ext 'version').tgz" }
# <EXT>_NOTICE_<NAME> for each name in <EXT>_NOTICES: <file> <URL> <SHA-256>.
function Notices([string]$ext) {
  foreach ($name in (Pin $ext 'notices').Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) {
    $spec = @((Pin $ext "notice_$name").Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    if ($spec.Count -ne 3) { throw "${ext}: $("${ext}_notice_$name".ToUpper()) in php-ext-windows.env needs <file> <URL> <SHA-256>" }
    [ordered]@{ file = $spec[0]; url = $spec[1]; sha256 = $spec[2].ToLower() }
  }
}
$gh = @{}; if ($env:GITHUB_TOKEN) { $gh['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
# A repackaged extension's DLL, from its project's GitHub release: the asset
# (<EXT>_ASSET, with {version}, {minor} and {compiler} filled in) is checked
# against GitHub's digest, or the pinned <EXT>_SHA256 for releases older than
# GitHub's digests, and unpacked into pkg-<ext>. mongodb's zip holds one DLL,
# named after the asset, and its LICENSE. Microsoft's holds a DLL per PHP
# version, thread model and architecture, and must be signed by Microsoft.
function Fetch-Dll([string]$ext) {
  $repo = Pin $ext 'repo'; $version = Pin $ext 'version'
  $kind = Pin $ext 'source'
  $tag = if ($kind -eq 'dll') { $version } else { Pin $ext 'tag' }
  $asset = (Pin $ext 'asset').Replace('{version}', $version).Replace('{minor}', $Minor).Replace('{compiler}', $compiler)
  $release = Invoke-RestMethod -Headers $gh "https://api.github.com/repos/$repo/releases/tags/$tag"
  $item = @($release.assets | Where-Object name -eq $asset)
  if ($item.Count -ne 1) { throw "${ext}: $repo's release $tag has no $asset" }
  $item = $item[0]
  $digest = if ($item.PSObject.Properties['digest']) { $item.digest } else { $null }
  $pinned = (Pin $ext 'sha256').ToLower()
  if (-not $digest -and -not $pinned) { throw "${asset}: no published digest and no pinned SHA-256" }
  if ($digest -and $digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "${asset}: GitHub's digest $digest isn't a SHA-256" }
  $zip = Join-Path $work "$ext-$asset"
  Invoke-WebRequest -OutFile $zip $item.browser_download_url
  $got = Sha256 $zip
  if ($digest -and "sha256:$got" -ne $digest) { throw "${asset}: SHA-256 $got doesn't match $digest from GitHub" }
  if ($pinned -and $got -ne $pinned) { throw "${asset}: SHA-256 $got, not the pinned $pinned" }
  $pkg = "$work\pkg-$ext"
  Expand-Archive $zip -DestinationPath $pkg

  if ($kind -eq 'dll') {
    $dlls = @(Get-ChildItem -Recurse -File -Filter "php_$ext*.dll" $pkg | Where-Object Extension -eq '.dll')
    $licence = "$pkg\LICENSE"
    if (-not (Test-Path $licence)) { throw "${ext}: $asset has no LICENSE" }
  } else {
    # The x64, non-thread-safe DLL for this minor: php_<ext>_<XY>_nts_x64.dll,
    # or <arch>\php_<ext>_<XY>_nts.dll in the older layout with a folder per
    # architecture. Microsoft's zips carry no licence; its notice brings it.
    $dlls = @(Get-ChildItem -Recurse -File -Filter "php_${ext}_$($Minor.Replace('.', ''))_nts*.dll" $pkg |
      Where-Object { $rel = $_.FullName.Substring($pkg.Length); $_.Extension -eq '.dll' -and $rel -match 'x64' -and $rel -notmatch 'x86' })
    $licence = $null
  }
  if ($dlls.Count -ne 1) { throw "${ext}: $asset holds $($dlls.Count) DLLs for PHP $Minor x64 non-thread-safe, not one" }
  $dll = $dlls[0]
  $source = [ordered]@{
    repo = "https://github.com/$repo"; tag = $tag; asset = $asset; url = $item.browser_download_url
    sha256 = $got; checked_against = if ($digest) { 'GitHub digest' } else { 'pinned SHA-256' }
    file = $dll.FullName.Substring($pkg.Length + 1)
  }
  if ($kind -eq 'microsoft') {
    $sig = Get-AuthenticodeSignature -FilePath $dll.FullName
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
      throw "$($dll.Name) isn't validly signed by Microsoft ($($sig.Status))"
    }
    $source.signer = [ordered]@{ subject = $sig.SignerCertificate.Subject; thumbprint = $sig.SignerCertificate.Thumbprint }
  }
  [ordered]@{ dll = $dll.FullName; licence = $licence; source = $source }
}
$repack = @{}
foreach ($ext in $wanted) {
  if (Repackaged $ext) {
    $repack[$ext] = Fetch-Dll $ext
  } elseif ((Pin $ext 'source') -eq 'pecl') {
    $version = Pin $ext 'version'; $want = (Pin $ext 'sha256').ToLower()
    $tgz = Join-Path $work "$ext-$version.tgz"
    Invoke-WebRequest -OutFile $tgz (Pecl-Url $ext)
    $got = Sha256 $tgz
    if ($got -ne $want) { throw "${ext}: $ext-$version.tgz has SHA-256 $got, not the pinned $want" }
    New-Item -ItemType Directory -Path "$work\pecl-$ext" | Out-Null
    tar -xzf $tgz -C "$work\pecl-$ext"
    if (-not (Test-Path "$work\pecl-$ext\$ext-$version\config.w32")) { throw "${ext}: $ext-$version.tgz has no $ext-$version\config.w32" }
    Move-Item "$work\pecl-$ext\$ext-$version" "$work\src-$ext"
  } else {
    $repo = Pin $ext 'repo'; $tag = Pin $ext 'tag'; $commit = Pin $ext 'commit'
    git clone --quiet --depth 1 --branch $tag "https://github.com/$repo.git" "src-$ext"
    if ((git -C "src-$ext" rev-parse HEAD) -ne $commit) { throw "${ext}: $repo $tag isn't commit $commit" }
  }
  foreach ($patch in (Pin $ext 'patches').Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) {
    $file = Join-Path $PSScriptRoot "php-ext-patches\$patch"
    if (-not (Test-Path $file)) { throw "${ext}: no $patch in scripts\php-ext-patches" }
    git -C "$work\src-$ext" apply --verbose $file
  }
  foreach ($notice in (Notices $ext)) {
    $dest = Join-Path "$work\notices-$ext" $notice.file
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Invoke-WebRequest -OutFile $dest $notice.url
    $got = Sha256 $dest
    if ($got -ne $notice.sha256) { throw "${ext}: $($notice.url) has SHA-256 $got, not the pinned $($notice.sha256)" }
  }
}

# 4. Build each extension in its own checkout, with the SDK's tools on PATH
# the way phpsdk_setvars.bat puts them there.
$pathBefore = $env:PATH
$clBefore = $env:CL
if ($built) {
  $env:PHP_SDK_ROOT_PATH = $sdk
  $env:PHP_SDK_BIN_PATH = "$sdk\bin"
  $env:PHP_SDK_MSYS2_PATH = "$sdk\msys2\usr\bin"
  $env:PHP_SDK_PHP_CMD = "$sdk\bin\php\do_php.bat"
  $env:PATH = "$sdk\bin;$sdk\msys2\usr\bin;$pathBefore"
}
try {
  foreach ($ext in $built) {
    $sub = Pin $ext 'subdir'
    $dir = if ($sub) { "$work\src-$ext\$sub" } else { "$work\src-$ext" }
    Push-Location $dir
    try {
      & $phpize
      $configure = @((Pin $ext 'configure').Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) + '--enable-debug-pack=no'
      & .\configure.bat @configure | Tee-Object -Variable configured
      # configure.bat only warns about an option it doesn't know, and then
      # builds nothing for it.
      if (@($configured) -match 'invalid, and therefore ignored') { throw "${ext}: configure.bat doesn't know $($configure -join ' ')" }
      # Make the folder of every object the Makefile builds. config.w32 can
      # leave some out: grpc's drops each one with "grpc" in its name and makes
      # them where php-src's own tree would have them, not where phpize builds.
      Select-String -Path Makefile -Pattern '\$\(BUILD_DIR\)\\(\S+)\\[^\\\s]+\.obj' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
        ForEach-Object { New-Item -ItemType Directory -Force -Path "$dir\x64\Release\$_" | Out-Null }
      # configure.bat writes the objects link reads on one line, and link
      # stops at a line of 131071 characters (grpc has about 1,500 objects,
      # each with its full path). Put one on each line.
      Get-ChildItem "$dir\x64\Release\resp\*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
        $objs = [regex]::Matches((Get-Content -Raw $_.FullName), '"[^"]*"|\S+') | ForEach-Object { $_.Value }
        Set-Content -Encoding ascii $_.FullName $objs
      }
      # <EXT>_CL: compiler options the extension needs that its config.w32
      # doesn't pass; cl reads them from the CL variable.
      $env:CL = "$clBefore $(Pin $ext 'cl')".Trim()
      nmake /NOLOGO
    } finally { Pop-Location; $env:CL = $clBefore }
    if (-not (Test-Path "$dir\x64\Release\php_$ext.dll")) {
      $found = (Get-ChildItem -Recurse -Filter 'php_*.dll' $dir | ForEach-Object { $_.FullName }) -join ', '
      throw "${ext}: nmake made no x64\Release\php_$ext.dll (found: $found)"
    }
  }
} finally {
  $env:PATH = $pathBefore
}

foreach ($ext in $wanted) {
  $version = Pin $ext 'version'
  $sub = Pin $ext 'subdir'
  $src = "$work\src-$ext"
  $dir = if ($sub) { "$src\$sub" } else { $src }
  $stage = "$work\stage-$ext"
  New-Item -ItemType Directory -Force -Path "$stage\ext", "$stage\licenses\php_$ext" | Out-Null
  # A repackaged DLL is renamed to php_<ext>.dll and otherwise unchanged, so a
  # signature inside it stays valid.
  $dll = if (Repackaged $ext) { $repack[$ext].dll } else { "$dir\x64\Release\php_$ext.dll" }
  Copy-Item $dll "$stage\ext\php_$ext.dll"

  # 5. It loads into the official PHP, with nothing on PATH but that PHP and
  # Windows' own DLLs.
  $env:PATH = "$phpDir;$env:SystemRoot\System32"
  try {
    $modules = @(& "$phpDir\php.exe" -n -d "extension_dir=$stage\ext" -d "extension=$ext" -m 2>&1 | ForEach-Object { $_.ToString().Trim() })
    if ($modules -notcontains $ext) {
      throw "php_$ext.dll doesn't load into PHP ${full}: $(($modules | Where-Object { $_ -match 'Warning|Error|Unable' }) -join ' ')"
    }
    if ($ext -eq 'pcov') {
      try {
        & "$phpDir\php.exe" -n -d "extension_dir=$stage\ext" -d "extension=$ext" -r "exit(function_exists('pcov\\start') ? 0 : 1);"
      } catch {
        throw "php_$ext.dll doesn't load into PHP ${full}: pcov\start isn't defined"
      }
    }
    if ($ext -eq 'excimer') {
      # Its timer works: 100 ms of work at 1 ms makes about 100 events
      # (fewer samples, each counting the periods it covers, where Windows
      # has no high-resolution timer).
      $sampling = '$p = new ExcimerProfiler(); $p->setPeriod(0.001); $p->start(); for ($t = hrtime(true); hrtime(true) - $t < 100e6;) {} $p->stop(); exit($p->getLog()->getEventCount() >= 50 ? 0 : 1);'
      try {
        & "$phpDir\php.exe" -n -d "extension_dir=$stage\ext" -d "extension=$ext" -r $sampling
      } catch {
        throw "php_$ext.dll loads into PHP ${full}, but its profiler took too few samples"
      }
    }
  } finally {
    $env:PATH = $pathBefore
  }
  Write-Output "php_$ext.dll loads into PHP $full (php -m lists $ext)"

  # 6. The licence, the notices <EXT>_NOTICES names and BUILDINFO.json beside
  # the DLL. A built extension's licence comes from its source, mongodb's from
  # its zip, and Microsoft's from its notice (its zips carry none).
  $licence = if (Repackaged $ext) { $repack[$ext].licence } else {
    @('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING') |
      ForEach-Object { "$dir\$_"; "$src\$_" } | Where-Object { Test-Path $_ } | Select-Object -First 1
  }
  if ($licence) { Copy-Item $licence "$stage\licenses\php_$ext\LICENSE" }
  $notices = @(Notices $ext)
  if ($notices) { Copy-Item -Recurse "$work\notices-$ext\*" "$stage\licenses\php_$ext\" }
  foreach ($notice in $notices) {
    if (-not (Test-Path "$stage\licenses\php_$ext\$($notice.file)")) { throw "${ext}: the zip would lack $($notice.file)" }
  }
  if (-not (Test-Path "$stage\licenses\php_$ext\LICENSE")) { throw "${ext}: no LICENSE or COPYING in its source, and no notice named LICENSE" }
  $info = [ordered]@{ extension = $ext; version = $version }
  $info.source = if (Repackaged $ext) { $repack[$ext].source } elseif ((Pin $ext 'source') -eq 'pecl') {
    [ordered]@{ url = (Pecl-Url $ext); sha256 = (Pin $ext 'sha256').ToLower(); subdir = $sub }
  } else {
    [ordered]@{ repo = "https://github.com/$(Pin $ext 'repo')"; tag = (Pin $ext 'tag'); commit = (Pin $ext 'commit'); subdir = $sub }
  }
  $info.php = [ordered]@{ version = $full; build = "nts-$compiler-x64"; zip = $phpZip.path; zip_sha256 = $phpZip.sha256.ToLower() }
  if (-not (Repackaged $ext)) {
    $info.devel_pack = [ordered]@{ file = $develPack.path; sha256 = $develPack.sha256.ToLower() }
    $info.php_sdk = [ordered]@{ tag = $sdkTag; commit = $sdkCommit }
    $info.cl = $cl
    $info.configure = (Pin $ext 'configure')
    $info.cl_options = (Pin $ext 'cl')
    $info.patches = @((Pin $ext 'patches').Split(' ', [StringSplitOptions]::RemoveEmptyEntries) |
      ForEach-Object { [ordered]@{ file = $_; sha256 = (Sha256 (Join-Path $PSScriptRoot "php-ext-patches\$_")) } })
  }
  $info.notices = $notices
  $info.php_m = @($modules | Where-Object { $_ })
  Write-BuildInfo "$stage\licenses\php_$ext\BUILDINFO.json" $info

  $file = "php-ext-$ext-$version-php$Minor-nts-$compiler-windows-x86_64.zip"
  Compress-Archive -Path "$stage\ext", "$stage\licenses" -DestinationPath "$Out\$file" -Force
  $done = if (Repackaged $ext) { 'Repackaged' } else { 'Built' }
  Write-Output "$done $file"
}
