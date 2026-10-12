<#
.SYNOPSIS
  Runs "mvn verify" in one or more BuildShield repositories with temporary files outside C:.

.DESCRIPTION
  The integration tests start an embedded Kafka broker that preallocates 1 GB log segments in java.io.tmpdir
  and does not delete them. On Windows java.io.tmpdir comes from TMP, so this script points TMP and TEMP to
  <drive of the repositories>\tmp\buildshield-test and removes the broker folders it left when the run ends.
  Requirements: the same as each repository (PostgreSQL on 127.0.0.1:5433, JDK 21). Compatible with PowerShell 5.1.

.EXAMPLE
  .\scripts\mvn-verify.ps1 -Repos buildshield-inventory-service
  .\scripts\mvn-verify.ps1 -Repos buildshield-audit-service,buildshield-notification-service -MavenArgs '-Dbuildshield.test.external-database=true'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Repos,
    # Folder that contains the buildshield-* repositories (by default, the parent of this repo).
    [string]$ReposRoot,
    [string[]]$MavenArgs = @()
)
$ErrorActionPreference = 'Stop'

$PlatformRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReposRoot) { $ReposRoot = Split-Path -Parent $PlatformRoot }
$ReposRoot = (Resolve-Path $ReposRoot).Path

$TempDir = Join-Path (Split-Path -Qualifier $ReposRoot) 'tmp\buildshield-test'
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
$env:TMP = $TempDir
$env:TEMP = $TempDir

$failed = @()
foreach ($repo in $Repos) {
    $repoDir = Join-Path $ReposRoot $repo
    if (-not (Test-Path $repoDir)) { throw "Repository not found: $repoDir" }
    $mvn = Join-Path $repoDir 'mvnw.cmd'
    if (-not (Test-Path $mvn)) {
        $cmd = Get-Command mvn -ErrorAction SilentlyContinue
        $mvn = if ($cmd) { $cmd.Source } else { 'C:\apache-maven-3.9.9\bin\mvn.cmd' }
    }
    Write-Host "[verify] $repo (TMP=$TempDir)"
    Push-Location $repoDir
    try {
        & $mvn -B verify @MavenArgs
        if ($LASTEXITCODE -ne 0) { $failed += $repo }
    } finally {
        Pop-Location
    }
}

# Embedded Kafka leaves kafka-* folders behind; they are only test data.
Get-ChildItem $TempDir -Directory -Filter 'kafka*' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

if ($failed.Count -gt 0) {
    Write-Host "[verify] failed: $($failed -join ', ')"
    exit 1
}
Write-Host '[verify] all green'
