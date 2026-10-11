# Builds pgvector against one of the Postgres versions DevKit installs on
# Windows (the theseus-rs builds) and checks it loads. Run from a Visual Studio
# developer shell (nmake and cl on the PATH).
#
#   pwsh scripts/pgvector.ps1 18.6.0 out
#
# Writes out/pgvector-<version>-pg<major>-windows-x86_64.zip holding
# lib/vector.dll and extension/vector.control plus its SQL files.
param([string]$Pg, [string]$Out)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Get-Content (Join-Path $here 'pgvector.env') | Where-Object { $_ -match '^[A-Z_]+=' }
$vars = @{}; foreach ($l in $envFile) { $k, $v = $l -split '=', 2; $vars[$k] = $v }
$version = $vars['PGVECTOR_VERSION']; $commit = $vars['PGVECTOR_COMMIT']
$major = $Pg.Split('.')[0]
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
Set-Location $work

# Postgres, checked against the digest GitHub publishes for it.
$asset = "postgresql-$Pg-x86_64-pc-windows-msvc.zip"
$headers = @{}; if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
$release = Invoke-RestMethod -Headers $headers "https://api.github.com/repos/theseus-rs/postgresql-binaries/releases/tags/$Pg"
$digest = ($release.assets | Where-Object name -eq $asset).digest
if (-not $digest) { throw "No published digest for $asset" }
Invoke-WebRequest -OutFile pg.zip "https://github.com/theseus-rs/postgresql-binaries/releases/download/$Pg/$asset"
$got = (Get-FileHash -Algorithm SHA256 pg.zip).Hash.ToLower()
if ("sha256:$got" -ne $digest) { throw "${asset}: SHA-256 $got doesn't match $digest" }
Expand-Archive pg.zip -DestinationPath .
$pgroot = (Get-ChildItem -Directory "postgresql-$Pg-*").FullName

git clone --quiet --depth 1 --branch "v$version" https://github.com/pgvector/pgvector.git src
if ((git -C src rev-parse HEAD) -ne $commit) { throw "pgvector v$version isn't commit $commit" }
Push-Location src
$env:PGROOT = $pgroot
nmake /NOLOGO /F Makefile.win
if ($LASTEXITCODE -ne 0) { throw "nmake failed" }
Pop-Location

$stage = Join-Path $work 'stage'
New-Item -ItemType Directory -Force -Path "$stage/lib", "$stage/extension" | Out-Null
Copy-Item src/vector.dll "$stage/lib/"
Copy-Item src/vector.control "$stage/extension/"
Copy-Item src/sql/vector--*.sql "$stage/extension/"

# It loads into that Postgres and answers a query.
Copy-Item "$stage/lib/*" "$pgroot/lib/"
Copy-Item "$stage/extension/*" "$pgroot/share/extension/"
$data = Join-Path $work 'data'
& "$pgroot/bin/initdb.exe" -D $data -U root --auth=trust | Out-Null
if ($LASTEXITCODE -ne 0) { throw "initdb failed" }
# Not piped: the server inherits pg_ctl's output, so a pipe would stay open
# while it runs and PowerShell would wait on it forever. pg.log has its output.
& "$pgroot/bin/pg_ctl.exe" -D $data -o "-p 55432" -l "$work/pg.log" -t 60 -w start
if ($LASTEXITCODE -ne 0) { Get-Content "$work/pg.log"; throw "Postgres didn't start" }
try {
  & "$pgroot/bin/psql.exe" -h 127.0.0.1 -p 55432 -U root -d postgres -v ON_ERROR_STOP=1 -Atc "CREATE EXTENSION vector; SELECT '[1,2,3]'::vector <-> '[1,2,4]';"
  if ($LASTEXITCODE -ne 0) { throw "pgvector didn't load" }
} finally {
  & "$pgroot/bin/pg_ctl.exe" -D $data -m fast stop | Out-Null
}

Compress-Archive -Path "$stage/lib", "$stage/extension" -DestinationPath "$Out/pgvector-$version-pg$major-windows-x86_64.zip" -Force
Write-Output "Built pgvector $version for Postgres $Pg on windows-x86_64"
