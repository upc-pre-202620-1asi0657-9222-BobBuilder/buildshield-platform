<#
.SYNOPSIS
  Starts BuildShield locally without Docker: dev-kafka, the 8 microservices and the API gateway.

.DESCRIPTION
  Each process runs in the background as "java -jar" with the given Spring profile (local by default)
  and the environment variables of the contract (wiki/informe-tf/plan-microservicios.md):
  DB_HOST, DB_PORT, DB_NAME=<svc>_db, DB_USER/DB_PASSWORD=<svc>_service, KAFKA_BOOTSTRAP_SERVERS,
  SERVER_PORT, BUILDSHIELD_JWT_PUBLIC_KEY (all) and BUILDSHIELD_JWT_PRIVATE_KEY (iam only).
  Logs go to logs\<svc>.log (stderr to logs\<svc>.err.log) and PIDs to logs\run-all.pids.
  Services whose repository or jar does not exist yet are skipped with a warning.
  Ports already listening are skipped too (assumed to be running).
  Requirements: PostgreSQL cluster on 127.0.0.1:5433 with the 8 databases (scripts\create-databases.ps1),
  JWT keys in ~\.buildshield\jwt-private.pem and jwt-public.pem, JDK 21. Compatible with PowerShell 5.1.

.EXAMPLE
  .\scripts\run-all.ps1
  .\scripts\run-all.ps1 -Build
  .\scripts\run-all.ps1 -ReposRoot E:\obsidian\funda\repos -Only iam,organization -NoKafka
#>
[CmdletBinding()]
param(
    # Folder that contains the buildshield-* repositories (by default, the parent of this repo).
    [string]$ReposRoot,
    # Runs "mvn package -DskipTests" in every existing repository before starting.
    [switch]$Build,
    [string]$SpringProfile = 'local',
    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 5433,
    [string]$KafkaBootstrapServers = 'localhost:9092',
    [string]$KeysDir = (Join-Path $HOME '.buildshield'),
    # Only these services (names: kafka, iam, organization, ..., gateway). Empty = all.
    [string[]]$Only = @(),
    [switch]$NoKafka,
    [int]$HealthTimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'

$PlatformRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReposRoot) { $ReposRoot = Split-Path -Parent $PlatformRoot }
$ReposRoot = (Resolve-Path $ReposRoot).Path
$LogDir = Join-Path $PlatformRoot 'logs'
$PidFile = Join-Path $LogDir 'run-all.pids'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Temporary files (Kafka segments, Tomcat, uploads) go next to the repositories instead of %TEMP% on C:.
# Child processes inherit TMP/TEMP, so java.io.tmpdir follows them.
$TempDir = Join-Path (Split-Path -Qualifier $ReposRoot) 'tmp\buildshield'
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
$env:TMP = $TempDir
$env:TEMP = $TempDir

# name, repository folder, port, database (empty = none)
$Services = @(
    @{ Name = 'kafka';        Repo = 'buildshield-platform\dev-kafka';    Port = 9092; Db = '' },
    @{ Name = 'iam';          Repo = 'buildshield-iam-service';           Port = 8081; Db = 'iam_db' },
    @{ Name = 'organization'; Repo = 'buildshield-organization-service';  Port = 8082; Db = 'organization_db' },
    @{ Name = 'inventory';    Repo = 'buildshield-inventory-service';     Port = 8083; Db = 'inventory_db' },
    @{ Name = 'ordering';     Repo = 'buildshield-ordering-service';      Port = 8084; Db = 'ordering_db' },
    @{ Name = 'discrepancy';  Repo = 'buildshield-discrepancy-service';   Port = 8085; Db = 'discrepancy_db' },
    @{ Name = 'subscription'; Repo = 'buildshield-subscription-service';  Port = 8086; Db = 'subscription_db' },
    @{ Name = 'notification'; Repo = 'buildshield-notification-service';  Port = 8087; Db = 'notification_db' },
    @{ Name = 'audit';        Repo = 'buildshield-audit-service';         Port = 8088; Db = 'audit_db' },
    @{ Name = 'gateway';      Repo = 'buildshield-api-gateway';           Port = 8080; Db = '' }
)
if ($NoKafka) { $Services = @($Services | Where-Object { $_.Name -ne 'kafka' }) }
if ($Only.Count -gt 0) { $Services = @($Services | Where-Object { $Only -contains $_.Name }) }

function Find-Java {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        return (Join-Path $env:JAVA_HOME 'bin\java.exe')
    }
    $jdk = Get-ChildItem 'C:\Program Files\Java\jdk-21*\bin\java.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($jdk) { return $jdk.FullName }
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Java 21 not found. Set JAVA_HOME.'
}

function Find-Maven([string]$repoDir) {
    $wrapper = Join-Path $repoDir 'mvnw.cmd'
    if (Test-Path $wrapper) { return $wrapper }
    $cmd = Get-Command mvn -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (Test-Path 'C:\apache-maven-3.9.9\bin\mvn.cmd') { return 'C:\apache-maven-3.9.9\bin\mvn.cmd' }
    throw 'Maven not found.'
}

function Find-Jar([string]$repoDir) {
    $target = Join-Path $repoDir 'target'
    if (-not (Test-Path $target)) { return $null }
    $jar = Get-ChildItem $target -Filter '*.jar' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*-sources.jar' -and $_.Name -notlike '*-javadoc.jar' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($jar) { return $jar.FullName }
    return $null
}

function Test-Port([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(500)) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-Health([int]$port) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$port/actuator/health" -UseBasicParsing -TimeoutSec 3
        return ($response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

$java = Find-Java
$publicKeyFile = Join-Path $KeysDir 'jwt-public.pem'
$privateKeyFile = Join-Path $KeysDir 'jwt-private.pem'
if (-not (Test-Path $publicKeyFile) -or -not (Test-Path $privateKeyFile)) {
    throw "JWT keys not found in $KeysDir (jwt-public.pem, jwt-private.pem)."
}
$publicKey = [System.IO.File]::ReadAllText($publicKeyFile)
$privateKey = [System.IO.File]::ReadAllText($privateKeyFile)

if ($Build) {
    foreach ($svc in $Services) {
        $repoDir = Join-Path $ReposRoot $svc.Repo
        if (-not (Test-Path (Join-Path $repoDir 'pom.xml'))) { continue }
        Write-Host "[build] $($svc.Name): mvn package -DskipTests"
        $mvn = Find-Maven $repoDir
        Push-Location $repoDir
        try {
            & $mvn -B -q package -DskipTests
            if ($LASTEXITCODE -ne 0) { Write-Warning "[build] $($svc.Name) failed (exit $LASTEXITCODE); its previous jar, if any, is used." }
        } finally {
            Pop-Location
        }
    }
}

# Keep the PIDs of a previous run that are still alive.
$pids = @()
if (Test-Path $PidFile) {
    foreach ($line in Get-Content $PidFile) {
        $parts = $line -split ','
        if ($parts.Count -eq 3 -and (Get-Process -Id ([int]$parts[1]) -ErrorAction SilentlyContinue)) { $pids += $line }
    }
}

# Variables that are set per process and cleaned afterwards.
$varNames = 'DB_HOST', 'DB_PORT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD', 'KAFKA_BOOTSTRAP_SERVERS', 'SERVER_PORT',
    'KAFKA_PORT', 'BUILDSHIELD_JWT_PUBLIC_KEY', 'BUILDSHIELD_JWT_PRIVATE_KEY', 'SPRING_PROFILES_ACTIVE'
$saved = @{}
foreach ($name in $varNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

$started = @()
try {
    foreach ($svc in $Services) {
        $repoDir = Join-Path $ReposRoot $svc.Repo
        if (-not (Test-Path $repoDir)) {
            Write-Warning "[$($svc.Name)] repository $($svc.Repo) does not exist yet: skipped."
            continue
        }
        $jar = Find-Jar $repoDir
        if (-not $jar) {
            Write-Warning "[$($svc.Name)] no jar in $($svc.Repo)\target (use -Build): skipped."
            continue
        }
        if (Test-Port $svc.Port) {
            Write-Warning "[$($svc.Name)] port $($svc.Port) is already in use: assumed running, skipped."
            continue
        }

        foreach ($name in $varNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        $env:KAFKA_BOOTSTRAP_SERVERS = $KafkaBootstrapServers
        $env:SPRING_PROFILES_ACTIVE = $SpringProfile
        if ($svc.Name -eq 'kafka') {
            $env:KAFKA_PORT = "$($svc.Port)"
        } else {
            $env:SERVER_PORT = "$($svc.Port)"
            $env:BUILDSHIELD_JWT_PUBLIC_KEY = $publicKey
        }
        if ($svc.Name -eq 'iam') { $env:BUILDSHIELD_JWT_PRIVATE_KEY = $privateKey }
        if ($svc.Db) {
            $role = "$($svc.Name)_service"
            $env:DB_HOST = $DbHost
            $env:DB_PORT = "$DbPort"
            $env:DB_NAME = $svc.Db
            $env:DB_USER = $role
            $env:DB_PASSWORD = $role
        }

        $log = Join-Path $LogDir "$($svc.Name).log"
        $err = Join-Path $LogDir "$($svc.Name).err.log"
        $process = Start-Process -FilePath $java -ArgumentList @('-jar', "`"$jar`"", "--spring.profiles.active=$SpringProfile") `
            -WorkingDirectory $repoDir -RedirectStandardOutput $log -RedirectStandardError $err `
            -WindowStyle Hidden -PassThru
        $pids += "$($svc.Name),$($process.Id),$($svc.Port)"
        Set-Content -Path $PidFile -Value $pids -Encoding ASCII
        $started += @{ Name = $svc.Name; Port = $svc.Port; Process = $process }
        Write-Host "[$($svc.Name)] started (pid $($process.Id), port $($svc.Port)), log: logs\$($svc.Name).log"

        # Services need Kafka up before they start publishing: wait for the broker first.
        if ($svc.Name -eq 'kafka') {
            $deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-Port $svc.Port) -and (Get-Date) -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 500 }
            if (Test-Port $svc.Port) { Write-Host "[kafka] listening on $($svc.Port)" }
            else { Write-Warning '[kafka] did not open its port in 60 s; see logs\kafka.log' }
        }
    }
} finally {
    foreach ($name in $varNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}

# Wait for /actuator/health of every HTTP process started.
$pending = @($started | Where-Object { $_.Name -ne 'kafka' })
$deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $still = @()
    foreach ($svc in $pending) {
        if ($svc.Process.HasExited) {
            Write-Warning "[$($svc.Name)] exited with code $($svc.Process.ExitCode); see logs\$($svc.Name).log"
        } elseif (Test-Health $svc.Port) {
            Write-Host "[$($svc.Name)] UP on http://localhost:$($svc.Port)"
        } else {
            $still += $svc
        }
    }
    $pending = $still
    if ($pending.Count -gt 0) { Start-Sleep -Seconds 2 }
}
foreach ($svc in $pending) { Write-Warning "[$($svc.Name)] not healthy after $HealthTimeoutSeconds s; see logs\$($svc.Name).log" }

Write-Host "PIDs in $PidFile. Stop everything with .\scripts\stop-all.ps1"
