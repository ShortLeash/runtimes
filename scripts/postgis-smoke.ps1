# Checks a Windows PostGIS build (scripts/postgis-windows.sh) in the MSVC
# Postgres Short Leash installs (the theseus-rs build it was built against). Run
# from a Visual Studio developer shell (dumpbin on the PATH).
#
#   pwsh scripts/postgis-smoke.ps1 <Postgres folder> <stage folder>
#
# The stage is what the archive holds: lib/ (postgis-3.dll and
# postgis_topology-3.dll), extension/, proj/proj.db, doc/, and bin/ if the
# modules need DLLs of their own. Copied into a folder with a space in its
# path, as Short Leash's home can have, with proj.db where Short Leash puts it and
# PROJ_DATA pointing at it, PostGIS and its topology load, measure a
# distance, transform with the shipped proj.db, encode a vector tile and a
# FlatGeobuf, report the pinned GEOS, PROJ, libxml2, json-c and protobuf-c,
# survive an error raised inside the module, and import nothing but
# postgres.exe, Windows' own DLLs and bin/.
param([string]$PgRoot, [string]$Stage)
$ErrorActionPreference = 'Stop'
# A program that exits non-zero throws, like a failed cmdlet.
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

foreach ($f in 'lib/postgis-3.dll', 'lib/postgis_topology-3.dll', 'extension/postgis.control',
  'extension/postgis_topology.control', 'extension/postgis_tiger_geocoder.control', 'proj/proj.db') {
  if (-not (Test-Path -LiteralPath (Join-Path $Stage $f))) { throw "The stage has no $f" }
}
if (-not (Test-Path -LiteralPath (Join-Path $PgRoot 'bin/postgres.exe'))) { throw "$PgRoot has no bin/postgres.exe" }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pins = @{}
foreach ($l in Get-Content (Join-Path $here 'postgis.env') | Where-Object { $_ -match '^[A-Z0-9_]+=' }) {
  $k, $v = $l -split '=', 2; $pins[$k] = $v
}

# --- Imports ----------------------------------------------------------------
# Every DLL a module imports is postgres.exe, a DLL in bin/, or Windows' own:
# the Universal C Runtime (the one the MSVC Postgres uses) and system DLLs.
# MinGW's runtime DLLs (libstdc++, libgcc_s, libwinpthread) and msvcrt.dll
# must not appear: they're linked in statically, and a second C runtime
# would split the process's heap, errno and FILE handles.
$system = '^(api-ms-win-crt-[a-z0-9-]+|kernel32|advapi32|user32|shell32|ole32|oleaut32|ws2_32|bcrypt|crypt32|secur32|shlwapi|userenv|ntdll)\.dll$'
$own = @()
if (Test-Path -LiteralPath (Join-Path $Stage 'bin')) {
  $own = @(Get-ChildItem -LiteralPath (Join-Path $Stage 'bin') -Filter *.dll | ForEach-Object { $_.Name.ToLower() })
}
$bad = @()
foreach ($dll in Get-ChildItem -LiteralPath $Stage -Recurse -Filter *.dll) {
  $deps = @(& dumpbin /NOLOGO /DEPENDENTS $dll.FullName | ForEach-Object { if ($_ -match '^\s+(\S+\.(dll|exe))\s*$') { $Matches[1] } })
  if (-not $deps) { throw "dumpbin listed no imports for $($dll.Name)" }
  Write-Output "$($dll.Name) imports $($deps -join ', ')"
  foreach ($d in $deps) {
    $name = $d.ToLower()
    if ($name -ne 'postgres.exe' -and $name -notmatch $system -and $own -notcontains $name) {
      $bad += "$($dll.Name) imports $d"
    }
  }
}
if ($bad) { throw "PostGIS imports DLLs that are neither Windows' nor in bin/:`n$($bad -join "`n")" }

# --- In Postgres --------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
$moved = Join-Path $work 'Application Support\postgresql'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $moved) | Out-Null
Copy-Item -Recurse -LiteralPath $PgRoot -Destination $moved
Copy-Item -Path (Join-Path $Stage 'lib\*') -Destination (Join-Path $moved 'lib')
Copy-Item -Path (Join-Path $Stage 'extension\*') -Destination (Join-Path $moved 'share\extension')
$projData = Join-Path $moved 'share\proj'
New-Item -ItemType Directory -Force -Path $projData | Out-Null
Copy-Item -Path (Join-Path $Stage 'proj\*') -Destination $projData
# Short Leash copies bin/ next to postgres.exe: Windows looks for a module's DLLs
# in the program's folder.
if ($own) { Copy-Item -Path (Join-Path $Stage 'bin\*') -Destination (Join-Path $moved 'bin') }

$env:PROJ_DATA = $projData
$env:PROJ_NETWORK = 'OFF'
$env:PGOPTIONS = '-c client_min_messages=warning'
$port = 55433
$data = Join-Path $work 'data'
& (Join-Path $moved 'bin\initdb.exe') -D $data -U root --auth=trust | Out-Null
function Sql([string]$Query) {
  & (Join-Path $moved 'bin\psql.exe') -w -h 127.0.0.1 -p $port -U root -d postgres -v ON_ERROR_STOP=1 -Atc $Query
}
# Started inside the try, so the server is stopped even when the start times
# out: a server left running keeps the step's output open and the job hangs.
try {
  # Not piped: the server inherits pg_ctl's output, so a pipe would stay open
  # while it runs and PowerShell would wait on it forever. pg.log has its output.
  try {
    & (Join-Path $moved 'bin\pg_ctl.exe') -D $data -o "-p $port -c listen_addresses=127.0.0.1" -l "$work\pg.log" -t 60 -w start
  } catch {
    Get-Content "$work\pg.log" -ErrorAction SilentlyContinue
    throw "Postgres didn't start"
  }

  # London to Paris on the spheroid is about 343.9 km.
  $distance = Sql "CREATE EXTENSION postgis; CREATE EXTENSION postgis_topology; SELECT round(ST_Distance('SRID=4326;POINT(-0.1278 51.5074)'::geography, 'SRID=4326;POINT(2.3522 48.8566)'::geography));" |
    Select-Object -Last 1
  if (-not ("$distance" -match '^\d+$') -or [int]$distance -lt 343000 -or [int]$distance -gt 345000) {
    throw "ST_Distance from London to Paris answered '$distance', not 343000 to 345000 metres"
  }
  Sql 'CREATE EXTENSION postgis_tiger_geocoder CASCADE' | Out-Null

  $got = Sql 'SELECT ST_AsText(ST_Transform(ST_SetSRID(ST_MakePoint(0,0),4326),3857))'
  if ($got -ne 'POINT(0 0)') { throw "ST_Transform to EPSG:3857 answered '$got', not POINT(0 0)" }
  $codes = Sql "SELECT count(*) FROM postgis_srs_codes('EPSG')"
  if ([int]$codes -le 1000) { throw "PROJ's database lists $codes EPSG codes" }
  # GEOS: a bow tie isn't valid, and a point buffered by 1 is a 32-sided
  # polygon of area 3.1214.
  $got = Sql "SELECT ST_IsValid('POLYGON((0 0,1 1,1 0,0 1,0 0))'::geometry), round(ST_Area(ST_Buffer('POINT(0 0)'::geometry, 1))::numeric, 2)"
  if ($got -ne 'f|3.12') { throw "GEOS answered '$got', not f|3.12" }
  $got = Sql 'SELECT length(ST_AsMVT(q)) > 0 FROM (SELECT 1 AS id, ST_AsMVTGeom(ST_MakePoint(0,0), ST_MakeEnvelope(-1,-1,1,1)) AS geom) q'
  if ($got -ne 't') { throw "ST_AsMVT answered '$got', not t" }
  # FlatGeobuf is PostGIS's C++ code, with the C++ runtime linked in.
  $got = Sql 'SELECT length(ST_AsFlatGeobuf(q)) > 0 FROM (SELECT ST_MakePoint(0,0) AS geom) q'
  if ($got -ne 't') { throw "ST_AsFlatGeobuf answered '$got', not t" }

  # An error raised inside the module unwinds through it back to Postgres
  # (built with another compiler), and the same session carries on.
  # psql reports the error and exits non-zero; its stderr is read, not thrown.
  $PSNativeCommandUseErrorActionPreference = $false
  $ErrorActionPreference = 'Continue'
  $out = & (Join-Path $moved 'bin\psql.exe') -w -h 127.0.0.1 -p $port -U root -d postgres -At `
    -c "SELECT ST_GeomFromText('POINT(1)')" -c 'SELECT ST_AsText(ST_MakePoint(1, 2))' 2>&1
  $ErrorActionPreference = 'Stop'
  $PSNativeCommandUseErrorActionPreference = $true
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($text -notmatch 'parse error' -or $text -notmatch '(?m)^POINT\(1 2\)$') {
    throw "An invalid geometry didn't raise PostGIS's error and leave the session working:`n$text"
  }
  $log = Get-Content -Raw "$work\pg.log"
  if ($log -match 'terminated by exception|was terminated by|server process .* exited') {
    throw "A Postgres process crashed:`n$log"
  }

  $full = Sql 'SELECT postgis_full_version()'
  foreach ($want in "POSTGIS=`"$($pins['POSTGIS_VERSION'])", "GEOS=`"$($pins['GEOS_VERSION'])-", "PROJ=`"$($pins['PROJ_VERSION'])",
    "LIBXML=`"$($pins['LIBXML2_VERSION'])`"", "LIBJSON=`"$($pins['JSONC_VERSION'])`"", "LIBPROTOBUF=`"$($pins['PROTOBUFC_VERSION'])`"") {
    if (-not $full.Contains($want)) { throw "postgis_full_version() has no $want`: $full" }
  }
  if ($full.Contains('need upgrade')) { throw "postgis_full_version() asks for an upgrade: $full" }
  # PROJ reads the shipped proj.db, found through PROJ_DATA.
  $db = (Join-Path $projData 'proj.db').Replace('\', '/')
  if (-not $full.Replace('\', '/').Contains("DATABASE_PATH=$db")) { throw "PROJ doesn't use $db`: $full" }
} finally {
  # Fails when the server never started; that's fine here.
  try { & (Join-Path $moved 'bin\pg_ctl.exe') -D $data -m fast stop | Out-Null } catch { }
}
Write-Output $full
Write-Output "PostGIS $($pins['POSTGIS_VERSION']) works in $(& (Join-Path $PgRoot 'bin\postgres.exe') --version)"
