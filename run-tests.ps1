[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$Model,
    [string[]]$TestId,
    [switch]$ListTests
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$testsPath = Join-Path $PSScriptRoot 'tests.json'

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file not found: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Normalize([object]$Value) { return ([string]$Value).Trim() }

function Invoke-LocalChat($BaseUrl, $ModelName, $Messages, $Config, $Tools) {
    $body = [ordered]@{
        model = $ModelName
        messages = @($Messages)
        temperature = [double]$Config.temperature
        max_tokens = [int]$Config.maxTokens
    }
    if ($null -ne $Tools) {
        $body.tools = @($Tools)
        $body.tool_choice = 'auto'
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-RestMethod -Uri "$BaseUrl/chat/completions" -Method Post -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 12 -Compress) -TimeoutSec ([int]$Config.timeoutSeconds)
    $timer.Stop()
    return [pscustomobject]@{ Completion = $result; Seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3) }
}

function Test-Response($Test, $Message, [string]$ExpectedDate) {
    $answer = Normalize $Message.content
    $passed = $false
    $detail = ''
    switch ([string]$Test.type) {
        'exact' {
            $passed = $answer -ceq (Normalize $Test.expected)
            $detail = "Expected exact text: $($Test.expected)"
        }
        'containsAny' {
            foreach ($phrase in @($Test.expectedAny)) {
                if ($answer.IndexOf([string]$phrase, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $passed = $true; break }
            }
            $detail = 'Expected a clear statement that live data cannot be verified.'
        }
        'jsonFields' {
            try {
                $parsed = $answer | ConvertFrom-Json
                $passed = $true
                foreach ($property in $Test.expectedFields.PSObject.Properties) {
                    if (($parsed.PSObject.Properties.Name -notcontains $property.Name) -or ((Normalize $parsed.($property.Name)) -cne (Normalize $property.Value))) { $passed = $false }
                }
                $detail = 'Expected valid JSON with the required field values.'
            } catch { $detail = "Invalid JSON: $($_.Exception.Message)" }
        }
        'currentDate' {
            $passed = $answer -eq $ExpectedDate
            $detail = "Expected injected local date: $ExpectedDate"
        }
        default { $detail = "Unsupported response test type: $($Test.type)" }
    }
    return [pscustomobject]@{ Passed = $passed; Detail = $detail }
}

$config = Read-JsonFile $ConfigPath
$allTests = @(Read-JsonFile $testsPath)
if ($ListTests) {
    $allTests | Select-Object id, name, category, points | Format-Table -AutoSize
    exit 0
}

$baseUrl = ([string]$config.lmStudioBaseUrl).TrimEnd('/')
if ($baseUrl -notmatch '^https?://(127\.0\.0\.1|localhost)(:\d+)?(/|$)') { throw 'Safety check failed: LM Studio must use localhost.' }
$selectedModels = if ($Model.Count -gt 0) { @($Model) } else { @($config.models) }
$selectedTests = if ($TestId.Count -gt 0) { @($allTests | Where-Object { $TestId -contains $_.id }) } else { $allTests }
if ($selectedTests.Count -eq 0) { throw 'No tests selected.' }

Write-Host "Checking LM Studio at $baseUrl..." -ForegroundColor Cyan
$available = @((Invoke-RestMethod -Uri "$baseUrl/models" -Method Get -TimeoutSec ([int]$config.timeoutSeconds)).data | ForEach-Object { $_.id })
foreach ($modelName in $selectedModels) {
    if ($available -notcontains $modelName) { throw "Model is not loaded in LM Studio: $modelName" }
}

$runStarted = Get-Date
$results = @()
foreach ($modelName in $selectedModels) {
    Write-Host "`nModel: $modelName" -ForegroundColor Cyan
    foreach ($test in $selectedTests) {
        Write-Host "  $($test.name)... " -NoNewline
        $answer = ''
        $reasoning = ''
        $finishReason = ''
        $seconds = 0
        $errorText = $null
        $passed = $false
        $detail = ''
        try {
            $system = 'You are being evaluated. Follow instructions precisely. Do not invent current facts.'
            $messages = @()
            $tools = $null
            $expectedDate = $null
            if ([bool]$config.disableThinking) { $system += ' Do not show reasoning; give only the requested final answer.' }

            if ($test.type -eq 'memory') {
                $messages = @(
                    @{ role='system'; content=$system },
                    @{ role='user'; content="Remember this code for the next turn: $($test.secret). Reply only: remembered" },
                    @{ role='assistant'; content='remembered' },
                    @{ role='user'; content='What was the code? Return only the code.' }
                )
            } elseif ($test.type -eq 'toolCall') {
                $messages = @(@{ role='system'; content=$system }, @{ role='user'; content=[string]$test.prompt })
                $tools = @(@{ type='function'; function=@{ name='get_weather'; description='Get current weather for a city'; parameters=@{ type='object'; properties=@{ city=@{type='string';description='City name'} }; required=@('city') } } })
            } elseif ($test.type -eq 'currentDate') {
                $expectedDate = Get-Date -Format 'yyyy-MM-dd'
                $messages = @(@{ role='system'; content="$system The verified local date is $expectedDate." }, @{ role='user'; content='Return the verified local date in YYYY-MM-DD format only.' })
            } else {
                $prompt = [string]$test.prompt
                if ([bool]$config.disableThinking) { $prompt = "/no_think`n$prompt" }
                $messages = @(@{ role='system'; content=$system }, @{ role='user'; content=$prompt })
            }

            $call = Invoke-LocalChat $baseUrl $modelName $messages $config $tools
            $message = $call.Completion.choices[0].message
            $answer = [string]$message.content
            $reasoning = [string]$message.reasoning_content
            $finishReason = [string]$call.Completion.choices[0].finish_reason
            $seconds = $call.Seconds

            if ($test.type -eq 'memory') {
                $passed = (Normalize $answer) -ceq (Normalize $test.secret)
                $detail = "Expected remembered code: $($test.secret)"
            } elseif ($test.type -eq 'toolCall') {
                $toolCall = @($message.tool_calls)[0]
                if ($null -ne $toolCall) {
                    $arguments = $toolCall.function.arguments | ConvertFrom-Json
                    $actualArgument = Normalize $arguments.($test.expectedArgument.name)
                    $passed = ([string]$toolCall.function.name -eq [string]$test.expectedTool) -and ($actualArgument -eq (Normalize $test.expectedArgument.value))
                }
                $detail = "Expected tool $($test.expectedTool) with $($test.expectedArgument.name)=$($test.expectedArgument.value)"
            } else {
                $evaluation = Test-Response $test $message $expectedDate
                $passed = $evaluation.Passed
                $detail = $evaluation.Detail
            }
        } catch {
            $errorText = $_.Exception.Message
            $detail = 'Request or evaluation error.'
        }

        $earned = if ($passed) { [int]$test.points } else { 0 }
        $results += [pscustomobject]@{
            model=$modelName; testId=$test.id; name=$test.name; category=$test.category
            passed=$passed; pointsEarned=$earned; pointsPossible=[int]$test.points
            responseTimeSeconds=$seconds; response=$answer; reasoning=$reasoning
            finishReason=$finishReason; evaluation=$detail; error=$errorText
        }
        if ($passed) { Write-Host 'PASS' -ForegroundColor Green } else { Write-Host 'FAIL' -ForegroundColor Red }
    }
}

$summaries = @()
foreach ($modelName in $selectedModels) {
    $modelResults = @($results | Where-Object { $_.model -eq $modelName })
    $earned = ($modelResults | Measure-Object pointsEarned -Sum).Sum
    $possible = ($modelResults | Measure-Object pointsPossible -Sum).Sum
    $summaries += [pscustomobject]@{
        model=$modelName; passed=@($modelResults | Where-Object passed).Count; failed=@($modelResults | Where-Object { -not $_.passed }).Count
        pointsEarned=$earned; pointsPossible=$possible; scorePercent=[Math]::Round(($earned / $possible) * 100, 1)
        averageResponseSeconds=[Math]::Round(($modelResults | Measure-Object responseTimeSeconds -Average).Average, 3)
    }
}

$report = [ordered]@{
    schemaVersion=1; startedAt=$runStarted.ToString('o'); finishedAt=(Get-Date).ToString('o')
    lmStudioBaseUrl=$baseUrl; availableModels=$available; summaries=$summaries; results=$results
}
$reportDirectory = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $reportDirectory "jarvis-test-$stamp.json"
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$css = 'body{font-family:Segoe UI,Arial;margin:32px;color:#18212b}table{border-collapse:collapse;width:100%}th,td{padding:8px;border:1px solid #ccd4dc;text-align:left}.pass{color:#087830;font-weight:700}.fail{color:#b42318;font-weight:700}pre{white-space:pre-wrap}'
$rows = foreach ($result in $results) {
    $status = if ($result.passed) { 'PASS' } else { 'FAIL' }
    $class = if ($result.passed) { 'pass' } else { 'fail' }
    "<tr><td>$($result.model)</td><td>$($result.name)</td><td class='$class'>$status</td><td>$($result.pointsEarned)/$($result.pointsPossible)</td><td>$($result.responseTimeSeconds)s</td><td><pre>$([Net.WebUtility]::HtmlEncode($result.response))</pre></td></tr>"
}
$summaryHtml = ($summaries | ForEach-Object { "<p><strong>$($_.model)</strong>: $($_.scorePercent)% - $($_.passed) passed, $($_.failed) failed</p>" }) -join "`n"
$html = "<!doctype html><html><head><meta charset='utf-8'><title>JARVIS Test Report</title><style>$css</style></head><body><h1>JARVIS AutoTester Report</h1>$summaryHtml<table><thead><tr><th>Model</th><th>Test</th><th>Result</th><th>Score</th><th>Time</th><th>Response</th></tr></thead><tbody>$($rows -join "`n")</tbody></table><p>Generated $((Get-Date).ToString('o'))</p></body></html>"
$htmlPath = Join-Path $reportDirectory "jarvis-test-$stamp.html"
$html | Set-Content -LiteralPath $htmlPath -Encoding utf8

Write-Host "`nResults" -ForegroundColor Cyan
$summaries | Format-Table model, passed, failed, scorePercent, averageResponseSeconds -AutoSize
Write-Host "JSON report: $jsonPath"
Write-Host "HTML report: $htmlPath"
if (@($results | Where-Object { -not $_.passed }).Count -gt 0) { exit 1 }
exit 0
