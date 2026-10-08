<#
.SYNOPSIS
  Stops what scripts\run-all.ps1 started.

.DESCRIPTION
  First by the PIDs in logs\run-all.pids. Then, as a fallback, any java process still listening on the
  BuildShield ports (8080 to 8088 and 9092). Compatible with PowerShell 5.1.

.EXAMPLE
  .\scripts\stop-all.ps1
  .\scripts\stop-all.ps1 -NoPortFallback
#>
[CmdletBinding()]
param(
    # Do not look for java processes by port, only use the PID file.
    [switch]$NoPortFallback
)
$ErrorActionPreference = 'Stop'

$PlatformRoot = Split-Path -Parent $PSScriptRoot
$PidFile = Join-Path (Join-Path $PlatformRoot 'logs') 'run-all.pids'
$Ports = 8080, 8081, 8082, 8083, 8084, 8085, 8086, 8087, 8088, 9092

$stopped = 0
if (Test-Path $PidFile) {
    foreach ($line in Get-Content $PidFile) {
        $parts = $line -split ','
        if ($parts.Count -ne 3) { continue }
        $process = Get-Process -Id ([int]$parts[1]) -ErrorAction SilentlyContinue
        if ($process -and $process.ProcessName -like 'java*') {
            Stop-Process -Id $process.Id -Force
            Write-Host "[$($parts[0])] stopped (pid $($process.Id))"
            $stopped++
        }
    }
    Remove-Item $PidFile -Force
} else {
    Write-Host 'No PID file (logs\run-all.pids).'
}

if (-not $NoPortFallback) {
    foreach ($port in $Ports) {
        $owners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique)
        foreach ($owner in $owners) {
            $process = Get-Process -Id $owner -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -like 'java*') {
                Stop-Process -Id $process.Id -Force
                Write-Host "[port $port] stopped java (pid $($process.Id))"
                $stopped++
            } elseif ($process) {
                Write-Warning "[port $port] used by $($process.ProcessName) (pid $owner), not java: left running."
            }
        }
    }
}

Write-Host "Stopped processes: $stopped"
