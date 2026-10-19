# Builds PHP extensions for windows.php.net's official PHP (non-thread-safe,
# x64) for one PHP minor, at the pins in php-ext-windows.env, against that
# minor's devel pack, and checks each one loads into the official PHP. Sources
# are a git tag at a pinned commit, or a PECL tarball at a pinned SHA-256. Run
# from a Visual Studio developer prompt whose compiler matches the minor's
# (cl 19.20 to 19.29 for vs16, 19.30 to 19.49 for vs17).
#
#   pwsh scripts/php-ext-windows.ps1 -Minor 8.4 -Exts "apcu redis" -Out out
#
# Writes out\php-ext-<ext>-<version>-php<minor>-nts-<vs>-windows-x86_64.zip
# for each extension, holding ext\php_<ext>.dll and licenses\php_<ext>\ (the
# extension's licence and BUILDINFO.json, which records the PHP release, the
# devel pack's SHA-256, the source and its commit, the cl version and what
# php -m listed). Nothing else, so the zips extract into one PHP folder.
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

# The Visual Studio windows.php.net builds this minor with (plan.py's compiler).
$compiler = if ([version]$Minor -le [version]'8.3') { 'vs16' } else { 'vs17' }

$known = $pins['PHP_EXT_WINDOWS'].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
$wanted = $Exts.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
if (-not $wanted) { throw 'No extensions named; pass -Exts "apcu redis"' }
foreach ($ext in $wanted) {
  if ($known -notcontains $ext) { throw "${ext}: not in PHP_EXT_WINDOWS in php-ext-windows.env" }
  if ((Pin $ext 'skip').Split(' ') -contains $Minor) { throw "${ext}: php-ext-windows.env skips PHP $Minor" }
  if (@('git', 'pecl') -notcontains (Pin $ext 'source')) { throw "${ext}: source '$(Pin $ext 'source')' isn't one this script builds" }
  if (-not (Pin $ext 'version')) { throw "${ext}: no version pinned for PHP $Minor in php-ext-windows.env" }
  $need = if ((Pin $ext 'source') -eq 'git') { @('repo', 'tag', 'commit') } else { @('sha256') }
  foreach ($key in $need) {
    if (-not (Pin $ext $key)) { throw "${ext}: no $key pinned for PHP $Minor in php-ext-windows.env" }
  }
}

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
$develPack = Fetch-Php 'devel_pack'
$phpZip = Fetch-Php 'zip'
Expand-Archive (Join-Path $work $develPack.path) -DestinationPath "$work\devel"
Expand-Archive (Join-Path $work $phpZip.path) -DestinationPath "$work\php"
$phpize = (Get-ChildItem -Recurse -Filter phpize.bat "$work\devel" | Select-Object -First 1)
if (-not $phpize) { throw "$($develPack.path) has no phpize.bat" }
$phpize = $phpize.FullName
$phpDir = "$work\php"
if (-not (Test-Path "$phpDir\php.exe")) { throw "$($phpZip.path) has no php.exe" }

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

# Each extension's source in src-<ext>: a git tag at its pinned commit, or a
# PECL tarball at its pinned SHA-256 (PECL publishes no checksum).
function Pecl-Url([string]$ext) { "https://pecl.php.net/get/$ext-$(Pin $ext 'version').tgz" }
foreach ($ext in $wanted) {
  if ((Pin $ext 'source') -eq 'pecl') {
    $version = Pin $ext 'version'; $want = (Pin $ext 'sha256').ToLower()
    $tgz = Join-Path $work "$ext-$version.tgz"
    Invoke-WebRequest -OutFile $tgz (Pecl-Url $ext)
    $got = Sha256 $tgz
    if ($got -ne $want) { throw "${ext}: $ext-$version.tgz has SHA-256 $got, not the pinned $want" }
    New-Item -ItemType Directory -Path "$work\pecl-$ext" | Out-Null
    tar -xzf $tgz -C "$work\pecl-$ext"
    if (-not (Test-Path "$work\pecl-$ext\$ext-$version\config.w32")) { throw "${ext}: $ext-$version.tgz has no $ext-$version\config.w32" }
    Move-Item "$work\pecl-$ext\$ext-$version" "$work\src-$ext"
    continue
  }
  $repo = Pin $ext 'repo'; $tag = Pin $ext 'tag'; $commit = Pin $ext 'commit'
  git clone --quiet --depth 1 --branch $tag "https://github.com/$repo.git" "src-$ext"
  if ((git -C "src-$ext" rev-parse HEAD) -ne $commit) { throw "${ext}: $repo $tag isn't commit $commit" }
}

# 4. Build each extension in its own checkout, with the SDK's tools on PATH
# the way phpsdk_setvars.bat puts them there.
$pathBefore = $env:PATH
$env:PHP_SDK_ROOT_PATH = $sdk
$env:PHP_SDK_BIN_PATH = "$sdk\bin"
$env:PHP_SDK_MSYS2_PATH = "$sdk\msys2\usr\bin"
$env:PHP_SDK_PHP_CMD = "$sdk\bin\php\do_php.bat"
$env:PATH = "$sdk\bin;$sdk\msys2\usr\bin;$pathBefore"
try {
  foreach ($ext in $wanted) {
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
      # <EXT>_CL: compiler options the extension needs that its config.w32
      # doesn't pass; cl reads them from the CL variable.
      $env:CL = Pin $ext 'cl'
      nmake /NOLOGO
    } finally { Pop-Location; Remove-Item Env:CL -ErrorAction SilentlyContinue }
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
  Copy-Item "$dir\x64\Release\php_$ext.dll" "$stage\ext\"

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
  } finally {
    $env:PATH = $pathBefore
  }
  Write-Output "php_$ext.dll loads into PHP $full (php -m lists $ext)"

  # 6. The licence and BUILDINFO.json beside the DLL.
  $licence = @('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING') |
    ForEach-Object { "$dir\$_"; "$src\$_" } | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $licence) { throw "${ext}: no LICENSE or COPYING in its source" }
  Copy-Item $licence "$stage\licenses\php_$ext\LICENSE"
  $source = if ((Pin $ext 'source') -eq 'pecl') {
    [ordered]@{ url = (Pecl-Url $ext); sha256 = (Pin $ext 'sha256').ToLower(); subdir = $sub }
  } else {
    [ordered]@{ repo = "https://github.com/$(Pin $ext 'repo')"; tag = (Pin $ext 'tag'); commit = (Pin $ext 'commit'); subdir = $sub }
  }
  Write-BuildInfo "$stage\licenses\php_$ext\BUILDINFO.json" ([ordered]@{
    extension = $ext
    version = $version
    source = $source
    php = [ordered]@{ version = $full; build = "nts-$compiler-x64"; zip = $phpZip.path; zip_sha256 = $phpZip.sha256.ToLower() }
    devel_pack = [ordered]@{ file = $develPack.path; sha256 = $develPack.sha256.ToLower() }
    php_sdk = [ordered]@{ tag = $sdkTag; commit = $sdkCommit }
    cl = $cl
    configure = (Pin $ext 'configure')
    cl_options = (Pin $ext 'cl')
    php_m = @($modules | Where-Object { $_ })
  })

  $file = "php-ext-$ext-$version-php$Minor-nts-$compiler-windows-x86_64.zip"
  Compress-Archive -Path "$stage\ext", "$stage\licenses" -DestinationPath "$Out\$file" -Force
  Write-Output "Built $file"
}
