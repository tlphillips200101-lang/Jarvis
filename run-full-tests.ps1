[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$ApiToken,
    [string[]]$TestId,
    [switch]$NoOpenReport,
    [switch]$AcceptBaseline,
    [switch]$ListTests
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'full-config.json' }

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file not found: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Safe-Html([object]$Value) { [Net.WebUtility]::HtmlEncode([string]$Value) }
function Relative-ToRoot([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return $Value }
    Join-Path $PSScriptRoot $Value
}
function Get-Token([string]$Provided) {
    if ($Provided) { return $Provided.Trim() }
    if ($env:OPENWEBUI_API_TOKEN) { return $env:OPENWEBUI_API_TOKEN.Trim() }
    $secure = Read-Host 'Paste the Open WebUI API token' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Test-LocalUrl([string]$Url) {
    $uri = [Uri]$Url
    if ($uri.Scheme -notin @('http','https') -or $uri.Host -notin @('127.0.0.1','localhost')) {
        throw 'Safety check failed: Open WebUI must use localhost.'
    }
}
function Invoke-OpenWebUI($Config, [string]$Token, [string]$Prompt, [string]$ImagePath) {
    $content = if ($ImagePath) {
        $ext = [IO.Path]::GetExtension($ImagePath).TrimStart('.').ToLowerInvariant()
        if ($ext -eq 'jpg') { $ext = 'jpeg' }
        $bytes = [IO.File]::ReadAllBytes($ImagePath)
        @(
            @{ type='text'; text=$Prompt },
            @{ type='image_url'; image_url=@{ url="data:image/$ext;base64,$([Convert]::ToBase64String($bytes))" } }
        )
    } else { $Prompt }
    $body = [ordered]@{
        model = [string]$Config.modelId
        messages = @(@{ role='user'; content=$content })
        temperature = [double]$Config.temperature
        max_tokens = [int]$Config.maxTokens
        stream = $false
    }
    $headers = @{ Authorization="Bearer $Token" }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Uri "$(([string]$Config.openWebUIBaseUrl).TrimEnd('/'))/api/chat/completions" -Method Post -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 15 -Compress) -TimeoutSec ([int]$Config.timeoutSeconds)
    } finally { $timer.Stop() }
    [pscustomobject]@{
        Response = $response
        Text = [string]$response.choices[0].message.content
        ToolCalls = @($response.choices[0].message.tool_calls)
        SourceEvidence = @(
            @($response.citations)
            @($response.sources)
            @($response.choices[0].message.citations)
            @($response.choices[0].message.sources)
            @($response.choices[0].message.context)
        ) | Where-Object { $null -ne $_ }
        Seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
    }
}
function Tool-CallName($Call) {
    if ($Call.function -and $Call.function.name) { return [string]$Call.function.name }
    if ($Call.name) { return [string]$Call.name }
    ''
}
function Evaluate($Test, [string]$Text, [object[]]$ToolCalls, [object[]]$SourceEvidence) {
    $failures = @()
    foreach ($assertion in @($Test.assertions)) {
        $kind = [string]$assertion.type
        switch ($kind) {
            'exact' {
                if ($Text.Trim() -cne ([string]$assertion.value).Trim()) { $failures += "Expected exact value: $($assertion.value)" }
            }
            'contains' {
                foreach ($value in @($assertion.values)) {
                    if ($Text.IndexOf([string]$value, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $failures += "Missing required text: $value" }
                }
            }
            'containsAny' {
                $found = $false
                foreach ($value in @($assertion.values)) { if ($Text.IndexOf([string]$value, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found = $true } }
                if (-not $found) { $failures += "Expected one of: $(@($assertion.values) -join ', ')" }
            }
            'notContains' {
                foreach ($value in @($assertion.values)) {
                    if ($Text.IndexOf([string]$value, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $failures += "Unexpected text: $value" }
                }
            }
            'regex' {
                if ($Text -notmatch [string]$assertion.value) { $failures += "Did not match pattern: $($assertion.value)" }
            }
            'toolCalls' {
                $actualNames = @($ToolCalls | ForEach-Object { Tool-CallName $_ } | Where-Object { $_ })
                foreach ($value in @($assertion.values)) {
                    if ($actualNames -notcontains [string]$value) { $failures += "Missing structured tool call: $value (observed: $($actualNames -join ', '))" }
                }
            }
            'sourceEvidence' {
                if (@($SourceEvidence).Count -eq 0) { $failures += 'No structured citation or source evidence was returned.' }
            }
            default { $failures += "Unsupported assertion type: $kind" }
        }
    }
    [pscustomobject]@{ Passed=($failures.Count -eq 0); Detail=($failures -join '; ') }
}

$config = Read-Json $ConfigPath
Test-LocalUrl ([string]$config.openWebUIBaseUrl)
if ([string]$config.modelId -cne 'jarvis') { throw 'Safety check failed: config modelId must be exactly "jarvis".' }

$tests = Read-Json (Join-Path $PSScriptRoot 'full-tests.json')
$visionManifestPath = Relative-ToRoot ([string]$config.visionManifest)
$visionManifest = Read-Json $visionManifestPath
foreach ($vision in $visionManifest.tests) {
    $imagePath = Join-Path (Split-Path -Parent $visionManifestPath) ([string]$vision.image)
    $tests += [pscustomobject]@{
        id=[string]$vision.id; group='VISION'; name=[string]$vision.name; prompt=[string]$vision.prompt
        assertions=$vision.assertions; critical=[bool]$vision.critical; imagePath=$imagePath
    }
}
if ($TestId.Count -gt 0) { $tests = @($tests | Where-Object { $TestId -contains $_.id }) }
if ($ListTests) { $tests | Select-Object id,group,name,critical | Format-Table -AutoSize; exit 0 }
if ($tests.Count -eq 0) { throw 'No tests selected. Add Vision tests to the manifest or check -TestId values.' }

$token = Get-Token $ApiToken
if (-not $token) { throw 'No Open WebUI API token was supplied.' }
$headers = @{ Authorization="Bearer $token" }
$baseUrl = ([string]$config.openWebUIBaseUrl).TrimEnd('/')
Write-Host "Checking Open WebUI at $baseUrl..." -ForegroundColor Cyan
$modelsResponse = Invoke-RestMethod -Uri "$baseUrl/api/models" -Headers $headers -Method Get -TimeoutSec ([int]$config.timeoutSeconds)
$models = @($modelsResponse.data)
$exact = @($models | Where-Object { [string]$_.id -ceq 'jarvis' })
if ($exact.Count -ne 1) {
    $ids = @($models | ForEach-Object { [string]$_.id }) -join ', '
    throw "Expected exactly one Open WebUI model with exact ID 'jarvis'; found $($exact.Count). Available IDs: $ids"
}

$started = Get-Date
$results = @()
foreach ($test in $tests) {
    Write-Host "  [$($test.group)] $($test.name)... " -NoNewline
    $text = ''; $seconds = 0; $errorText = $null; $passed = $false; $detail = ''; $toolCalls = @(); $sourceEvidence = @()
    try {
        if ($test.imagePath -and -not (Test-Path -LiteralPath $test.imagePath -PathType Leaf)) { throw "Vision image not found: $($test.imagePath)" }
        $call = Invoke-OpenWebUI $config $token ([string]$test.prompt) ([string]$test.imagePath)
        $text = $call.Text; $seconds = $call.Seconds; $toolCalls = @($call.ToolCalls); $sourceEvidence = @($call.SourceEvidence)
        $evaluation = Evaluate $test $text $toolCalls $sourceEvidence
        $passed = $evaluation.Passed; $detail = $evaluation.Detail
    } catch {
        $errorText = $_.Exception.Message; $detail = 'Request or evaluation error.'
    }
    $slow = $seconds -gt [double]$config.slowResponseSeconds
    $results += [pscustomobject]@{
        id=$test.id; group=$test.group; name=$test.name; critical=[bool]$test.critical
        passed=$passed; responseTimeSeconds=$seconds; slow=$slow; prompt=$test.prompt
        imagePath=[string]$test.imagePath; response=$text; toolCalls=$toolCalls; sourceEvidence=$sourceEvidence; evaluation=$detail; error=$errorText
    }
    if ($passed) { Write-Host 'PASS' -ForegroundColor Green } else { Write-Host 'FAIL' -ForegroundColor Red }
}

$reportsDir = Relative-ToRoot ([string]$config.reportsDirectory)
New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
$baselinePath = Relative-ToRoot ([string]$config.baselineFile)
$baseline = $null
if (Test-Path -LiteralPath $baselinePath -PathType Leaf) { $baseline = Read-Json $baselinePath }
$baselineMap = @{}
if ($baseline) { foreach ($item in @($baseline.results)) { $baselineMap[[string]$item.id] = [bool]$item.passed } }
foreach ($result in $results) {
    if (-not $baselineMap.ContainsKey([string]$result.id)) { $state = 'NEW' }
    elseif ($baselineMap[[string]$result.id] -and -not $result.passed) { $state = 'REGRESSED' }
    elseif (-not $baselineMap[[string]$result.id] -and $result.passed) { $state = 'FIXED' }
    elseif ($result.passed) { $state = 'UNCHANGED PASS' } else { $state = 'UNCHANGED FAIL' }
    $result | Add-Member -NotePropertyName regressionState -NotePropertyValue $state
}

$groups = @('TOOLS','LIBRARY','VISION')
$groupSummaries = foreach ($group in $groups) {
    $items = @($results | Where-Object group -eq $group)
    $passedCount = @($items | Where-Object passed).Count
    [pscustomobject]@{ group=$group; total=$items.Count; passed=$passedCount; failed=($items.Count-$passedCount); scorePercent=$(if ($items.Count) {[Math]::Round(100*$passedCount/$items.Count,1)} else {$null}); averageSeconds=$(if ($items.Count) {[Math]::Round(($items|Measure-Object responseTimeSeconds -Average).Average,3)} else {$null}) }
}
$passedTotal = @($results | Where-Object passed).Count
$summary = [pscustomobject]@{
    total=$results.Count; passed=$passedTotal; failed=($results.Count-$passedTotal)
    scorePercent=[Math]::Round(100*$passedTotal/$results.Count,1)
    criticalFailures=@($results | Where-Object { $_.critical -and -not $_.passed }).Count
    regressions=@($results | Where-Object regressionState -eq 'REGRESSED').Count
    fixed=@($results | Where-Object regressionState -eq 'FIXED').Count
    averageResponseSeconds=[Math]::Round(($results|Measure-Object responseTimeSeconds -Average).Average,3)
}
$report = [ordered]@{ schemaVersion=1; modelId='jarvis'; openWebUIBaseUrl=$baseUrl; startedAt=$started.ToString('o'); finishedAt=(Get-Date).ToString('o'); summary=$summary; groupSummaries=$groupSummaries; results=$results }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $reportsDir "JARVIS-Full-Test-$stamp.json"
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
if ($AcceptBaseline) { $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $baselinePath -Encoding UTF8 }

$cards = ($groupSummaries | ForEach-Object { "<div class='card'><h3>$($_.group)</h3><b>$(if ($null -eq $_.scorePercent) {'Not configured'} else {"$($_.scorePercent)%"})</b><p>$($_.passed) passed / $($_.failed) failed<br>Avg: $($_.averageSeconds)s</p></div>" }) -join ''
$rows = foreach ($r in $results) {
    $statusClass = if ($r.passed) {'pass'} else {'fail'}
    "<tr><td>$(Safe-Html $r.group)</td><td>$(Safe-Html $r.name)</td><td class='$statusClass'>$(if($r.passed){'PASS'}else{'FAIL'})</td><td>$(Safe-Html $r.regressionState)</td><td>$($r.responseTimeSeconds)s$(if($r.slow){' SLOW'})</td><td><details><summary>Details</summary><b>Evaluation</b><pre>$(Safe-Html $r.evaluation)</pre><b>Response</b><pre>$(Safe-Html $r.response)</pre><b>Error</b><pre>$(Safe-Html $r.error)</pre></details></td></tr>"
}
$css = 'body{font-family:Segoe UI,Arial;margin:28px;color:#15202b;background:#f6f8fa}.cards{display:flex;gap:14px;flex-wrap:wrap}.card{background:white;border:1px solid #d0d7de;border-radius:10px;padding:16px;min-width:180px}.card b{font-size:28px}table{width:100%;border-collapse:collapse;background:white;margin-top:20px}th,td{border:1px solid #d0d7de;padding:9px;vertical-align:top}th{background:#eef2f6}.pass{color:#087830;font-weight:700}.fail{color:#b42318;font-weight:700}pre{white-space:pre-wrap;max-width:760px}code{background:#eef2f6;padding:2px 5px}'
$htmlPath = Join-Path $reportsDir "JARVIS-Full-Test-$stamp.html"
$html = "<!doctype html><html><head><meta charset='utf-8'><title>JARVIS Full Regression</title><style>$css</style></head><body><h1>JARVIS Full Regression Test</h1><p>Exact Open WebUI model: <code>jarvis</code> | $($summary.scorePercent)% | $($summary.passed) passed, $($summary.failed) failed | $($summary.regressions) regressions, $($summary.fixed) fixed | Avg $($summary.averageResponseSeconds)s</p><div class='cards'>$cards</div><table><thead><tr><th>Group</th><th>Test</th><th>Status</th><th>Regression</th><th>Time</th><th>Evidence</th></tr></thead><tbody>$($rows -join '')</tbody></table><p>Generated $((Get-Date).ToString('o'))</p></body></html>"
$html | Set-Content -LiteralPath $htmlPath -Encoding UTF8

Write-Host "`nPass/fail summary" -ForegroundColor Cyan
$groupSummaries | Format-Table group,total,passed,failed,scorePercent,averageSeconds -AutoSize
Write-Host "Overall: $($summary.scorePercent)% | Critical failures: $($summary.criticalFailures) | Regressions: $($summary.regressions) | Fixed: $($summary.fixed)"
Write-Host "JSON report: $jsonPath"
Write-Host "HTML dashboard: $htmlPath"
if ($AcceptBaseline) { Write-Host "Accepted baseline: $baselinePath" -ForegroundColor Yellow }
if (-not $NoOpenReport) { Start-Process -FilePath $htmlPath }
if ($summary.failed -gt 0) { exit 1 }
exit 0
