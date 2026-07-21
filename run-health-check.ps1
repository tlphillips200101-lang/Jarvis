[CmdletBinding()]
param(
    [string]$OpenWebUIUrl = 'http://127.0.0.1:8080',
    [string]$LmStudioUrl = 'http://127.0.0.1:1234/v1',
    [string]$DataDirectory = 'C:\JARVIS-Restore\data'
)

$ErrorActionPreference = 'Stop'

function Test-HttpEndpoint([string]$Name, [string]$Url) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
        $timer.Stop()
        return [pscustomobject]@{ name=$Name; status='healthy'; detail="HTTP $($response.StatusCode)"; responseTimeMs=[Math]::Round($timer.Elapsed.TotalMilliseconds) }
    } catch {
        $timer.Stop()
        return [pscustomobject]@{ name=$Name; status='unhealthy'; detail=$_.Exception.Message; responseTimeMs=[Math]::Round($timer.Elapsed.TotalMilliseconds) }
    }
}

$checks = @(
    Test-HttpEndpoint 'Open WebUI' "$($OpenWebUIUrl.TrimEnd('/'))/health"
    Test-HttpEndpoint 'LM Studio' "$($LmStudioUrl.TrimEnd('/'))/models"
)

$databasePath = Join-Path $DataDirectory 'webui.db'
$checks += [pscustomobject]@{
    name='JARVIS data store'
    status=if (Test-Path -LiteralPath $databasePath -PathType Leaf) { 'healthy' } else { 'unhealthy' }
    detail=if (Test-Path -LiteralPath $databasePath -PathType Leaf) { "Found $databasePath" } else { "Missing $databasePath" }
    responseTimeMs=$null
}

$libraryPath = Join-Path $DataDirectory 'vector_db'
$checks += [pscustomobject]@{
    name='JARVIS Library index'
    status=if (Test-Path -LiteralPath $libraryPath -PathType Container) { 'healthy' } else { 'unhealthy' }
    detail=if (Test-Path -LiteralPath $libraryPath -PathType Container) { "Found $libraryPath" } else { "Missing $libraryPath" }
    responseTimeMs=$null
}

$report = [ordered]@{
    checkedAt=(Get-Date).ToString('o')
    overallStatus=if ($checks.status -contains 'unhealthy') { 'unhealthy' } else { 'healthy' }
    checks=$checks
}

$reportsDirectory = Join-Path $PSScriptRoot 'Tests'
New-Item -ItemType Directory -Force -Path $reportsDirectory | Out-Null
$reportPath = Join-Path $reportsDirectory "JARVIS-Health-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8

$checks | Format-Table name, status, detail, responseTimeMs -AutoSize
Write-Host "Health report: $reportPath"
if ($report.overallStatus -eq 'unhealthy') { exit 1 }
