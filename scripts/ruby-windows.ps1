# Repackages RubyInstaller's Ruby for one minor version as a zip DevKit can
# unpack (RubyInstaller publishes .7z archives and installers only). The .7z
# is checked against the digest GitHub publishes for it.
#
#   pwsh scripts/ruby-windows.ps1 3.4 out
#
# Writes out/ruby-<version>-windows-x86_64.zip holding a ruby/ folder.
param([string]$Minor, [string]$Out)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$headers = @{}; if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }

# The newest RubyInstaller release of the minor (tags look like RubyInstaller-3.4.7-1).
$releases = Invoke-RestMethod -Headers $headers "https://api.github.com/repos/oneclick/rubyinstaller2/releases?per_page=100"
$release = $releases |
  Where-Object { -not $_.prerelease -and $_.tag_name -match "^RubyInstaller-$([regex]::Escape($Minor))\.(\d+)-(\d+)$" } |
  Sort-Object { [int]($_.tag_name -replace '^RubyInstaller-\d+\.\d+\.(\d+)-\d+$', '$1') } -Descending |
  Select-Object -First 1
if (-not $release) { throw "No RubyInstaller release for Ruby $Minor" }
$version = $release.tag_name -replace '^RubyInstaller-(\d+\.\d+\.\d+)-\d+$', '$1'
$assetName = ($release.tag_name -replace '^RubyInstaller-', 'rubyinstaller-').ToLower() + '-x64.7z'
$asset = $release.assets | Where-Object name -eq $assetName
if (-not $asset -or -not $asset.digest) { throw "No checked $assetName in $($release.tag_name)" }

$work = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
Set-Location $work
Invoke-WebRequest -OutFile ruby.7z $asset.browser_download_url
$got = (Get-FileHash -Algorithm SHA256 ruby.7z).Hash.ToLower()
if ("sha256:$got" -ne $asset.digest) { throw "${assetName}: SHA-256 $got doesn't match $($asset.digest)" }
7z x ruby.7z -oextracted | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z couldn't unpack $assetName" }
$top = Get-ChildItem -Directory extracted | Select-Object -First 1
Rename-Item $top.FullName 'ruby'

# It runs, with OpenSSL and psych.
& extracted/ruby/bin/ruby.exe -ropenssl -rpsych -e 'puts "#{RUBY_VERSION} #{OpenSSL::OPENSSL_LIBRARY_VERSION}"'
if ($LASTEXITCODE -ne 0) { throw "Ruby $version doesn't run" }

Compress-Archive -Path extracted/ruby -DestinationPath "$Out/ruby-$version-windows-x86_64.zip" -Force
Write-Output "Repackaged Ruby $version for windows-x86_64"
