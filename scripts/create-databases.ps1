[CmdletBinding()]
param(
    [string]$PgHost = '127.0.0.1',
    [int]$Port = 5433,
    [string]$User = 'buildshield_core',
    [string]$PsqlPath,
    # Crea además las bases temporales de las pruebas de integración (<svc>_it).
    [switch]$WithTestDatabases
)
# Crea las 8 bases de BuildShield y sus roles en el clúster PostgreSQL local (sin Docker).
$ErrorActionPreference = 'Stop'

if (-not $PsqlPath) {
    $found = Get-Command psql -ErrorAction SilentlyContinue
    if ($found) { $PsqlPath = $found.Source }
    else {
        $PsqlPath = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $PsqlPath) { throw 'No se encontró psql. Indica -PsqlPath.' }

$sql = Join-Path $PSScriptRoot 'create-databases.sql'
& $PsqlPath -h $PgHost -p $Port -U $User -d postgres -v ON_ERROR_STOP=1 -f $sql
if ($LASTEXITCODE -ne 0) { throw 'No se pudieron crear las bases' }

if ($WithTestDatabases) {
    foreach ($svc in 'iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription', 'notification', 'audit') {
        $exists = & $PsqlPath -h $PgHost -p $Port -U $User -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '${svc}_it'"
        if (-not $exists) {
            & $PsqlPath -h $PgHost -p $Port -U $User -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${svc}_it"
            if ($LASTEXITCODE -ne 0) { throw "No se pudo crear ${svc}_it" }
        }
    }
}

& $PsqlPath -h $PgHost -p $Port -U $User -d postgres -Atc "SELECT datname FROM pg_database WHERE datname LIKE '%\_db' OR datname LIKE '%\_it' ORDER BY 1"
