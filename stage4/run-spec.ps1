[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SpecPath,
    [string]$ConfigPath,
    [string]$ApiToken
)

# Runs one Stage 4 spec file (e.g. stage4\memory-fallback.json) against the local
# Open WebUI "jarvis" model. Read-only apart from the single chat request: it never
# updates models, prompts, memories, or files outside the reports directory.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = INCOMPLETE (nothing failed, but some gate or
# postcondition could not be verified from here).

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'full-config.json' }

# Request and assertion helpers mirror run-full-tests.ps1 so results grade identically.
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file not found: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Relative-ToRoot([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return $Value }
    Join-Path $RepoRoot $Value
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
function Invoke-OpenWebUI($Config, [string]$Token, [string]$Prompt) {
    $body = [ordered]@{
        model = [string]$Config.modelId
        messages = @(@{ role='user'; content=$Prompt })
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
        Text = [string]$response.choices[0].message.content
        ToolCalls = @($response.choices[0].message.tool_calls | Where-Object { $null -ne $_ })
        Seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
    }
}
function Tool-CallName($Call) {
    if ($Call.function -and $Call.function.name) { return [string]$Call.function.name }
    if ($Call.name) { return [string]$Call.name }
    ''
}
function Evaluate($Spec, [string]$Text, [object[]]$ToolCalls) {
    $failures = @()
    foreach ($assertion in @($Spec.assertions)) {
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
            default { $failures += "Unsupported assertion type: $kind" }
        }
    }
    $failures
}

# Read-only state snapshots used to prove the run changed nothing.
function Get-StateHash([string]$BaseUrl, [hashtable]$Headers, [string]$Path, [int]$TimeoutSec) {
    try {
        $data = Invoke-RestMethod -Uri "$BaseUrl$Path" -Headers $Headers -Method Get -TimeoutSec $TimeoutSec
        $json = $data | ConvertTo-Json -Depth 50 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$json)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
        [pscustomobject]@{ Hash=$hash; Error=$null }
    } catch {
        [pscustomobject]@{ Hash=$null; Error=$_.Exception.Message }
    }
}
function Compare-State([string]$Name, $Before, $After) {
    if ($Before.Error -or $After.Error) {
        return [pscustomobject]@{ check=$Name; status='NOT VERIFIED'; detail="Snapshot failed: $(@($Before.Error, $After.Error) | Where-Object { $_ } | Select-Object -First 1)" }
    }
    if ($Before.Hash -ceq $After.Hash) {
        return [pscustomobject]@{ check=$Name; status='PASS'; detail="Unchanged (SHA-256 $($Before.Hash))" }
    }
    [pscustomobject]@{ check=$Name; status='FAIL'; detail="Changed during run: $($Before.Hash) -> $($After.Hash)" }
}

$specFile = (Resolve-Path -LiteralPath $SpecPath).Path
$spec = Read-Json $specFile
$specHash = (Get-FileHash -LiteralPath $specFile -Algorithm SHA256).Hash
$config = Read-Json $ConfigPath
Test-LocalUrl ([string]$config.openWebUIBaseUrl)
if ([string]$config.modelId -cne 'jarvis') { throw 'Safety check failed: config modelId must be exactly "jarvis".' }
if ([string]$spec.route -cne 'openwebui') { throw "Unsupported route '$($spec.route)': this runner only sends requests through Open WebUI." }
if ([string]$spec.model -cne [string]$config.modelId) { throw "Spec model '$($spec.model)' does not match config modelId '$($config.modelId)'." }
if ($null -ne $spec.fixture) { throw 'Spec fixtures are not supported by this runner yet.' }
if (-not $spec.prompt) { throw 'Spec has no prompt.' }

Write-Host "Spec: $($spec.id) - $($spec.name) [$($spec.specStatus)]" -ForegroundColor Cyan
if ($spec.specNote) { Write-Host "Note: $($spec.specNote)" }

$token = Get-Token $ApiToken
if (-not $token) { throw 'No Open WebUI API token was supplied.' }
$headers = @{ Authorization="Bearer $token" }
$baseUrl = ([string]$config.openWebUIBaseUrl).TrimEnd('/')
$timeout = [int]$config.timeoutSeconds
Write-Host "Checking Open WebUI at $baseUrl..." -ForegroundColor Cyan
$modelsResponse = Invoke-RestMethod -Uri "$baseUrl/api/models" -Headers $headers -Method Get -TimeoutSec $timeout
$exact = @(@($modelsResponse.data) | Where-Object { [string]$_.id -ceq 'jarvis' })
if ($exact.Count -ne 1) { throw "Expected exactly one Open WebUI model with exact ID 'jarvis'; found $($exact.Count)." }

$modelPath = "/api/v1/models/model?id=$([Uri]::EscapeDataString([string]$config.modelId))"
$memoriesPath = '/api/v1/memories/'
$modelBefore = Get-StateHash $baseUrl $headers $modelPath $timeout
$memoriesBefore = Get-StateHash $baseUrl $headers $memoriesPath $timeout

$started = Get-Date
$text = ''; $seconds = 0; $toolCalls = @(); $errorText = $null; $failures = @()
Write-Host "  Sending prompt... " -NoNewline
try {
    $call = Invoke-OpenWebUI $config $token ([string]$spec.prompt)
    $text = $call.Text; $seconds = $call.Seconds; $toolCalls = @($call.ToolCalls)
    $failures = @(Evaluate $spec $text $toolCalls)
} catch {
    $errorText = $_.Exception.Message
    $failures = @("Request error: $errorText")
}
Write-Host "$($seconds)s"

$modelAfter = Get-StateHash $baseUrl $headers $modelPath $timeout
$memoriesAfter = Get-StateHash $baseUrl $headers $memoriesPath $timeout

$checks = @()
$checks += [pscustomobject]@{ check='assertions'; status=$(if ($failures.Count -eq 0) {'PASS'} else {'FAIL'}); detail=$(if ($failures.Count -eq 0) {"$(@($spec.assertions).Count) assertion(s) passed"} else {$failures -join '; '}) }
$memoryCheck = Compare-State 'memories-unchanged' $memoriesBefore $memoriesAfter
$modelCheck = Compare-State 'model-unchanged' $modelBefore $modelAfter
$checks += $memoryCheck
$checks += $modelCheck
foreach ($gate in @($spec.gates | Where-Object { $_ })) {
    switch ([string]$gate) {
        'no-model-or-prompt-changes' {
            $checks += [pscustomobject]@{ check="gate:$gate"; status=$modelCheck.status; detail="From model-unchanged: the jarvis model record holds its system prompt and parameters." }
        }
        'task1-still-passes' {
            $checks += [pscustomobject]@{ check="gate:$gate"; status='NOT VERIFIED'; detail='The Task 1 gate (tests/test_stage4_repository_context.py and tests/test_stage4_routing_boundary.py) lives in the JARVIS codebase, not this repo. Run it there.' }
        }
        default {
            $checks += [pscustomobject]@{ check="gate:$gate"; status='NOT VERIFIED'; detail='No automated check for this gate.' }
        }
    }
}
foreach ($postcondition in @($spec.postconditions | Where-Object { $_ })) {
    $checks += [pscustomobject]@{ check='postcondition'; status='NOT VERIFIED'; detail="$postcondition (memories and the jarvis model are checked above; files and other configuration are not)" }
}

$statuses = @($checks | ForEach-Object { $_.status })
$overall = if ($statuses -contains 'FAIL') { 'FAIL' } elseif ($statuses -contains 'NOT VERIFIED') { 'INCOMPLETE' } else { 'PASS' }

$reportsDir = Relative-ToRoot ([string]$config.reportsDirectory)
New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
$stamp = $started.ToString('yyyyMMdd-HHmmss')
$report = [ordered]@{
    specId = $spec.id; specName = $spec.name; specStatus = $spec.specStatus; specNote = $spec.specNote
    specPath = $specFile; specSha256 = $specHash
    model = [string]$config.modelId; openWebUIBaseUrl = $baseUrl
    startedAt = $started.ToString('o'); finishedAt = (Get-Date).ToString('o')
    overall = $overall; responseTimeSeconds = $seconds
    prompt = $spec.prompt; response = $text
    toolCalls = @($toolCalls | ForEach-Object { Tool-CallName $_ })
    error = $errorText; checks = $checks
}
$reportPath = Join-Path $reportsDir "Stage4-$($spec.id)-$stamp.json"
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host ''
$checks | Format-Table check,status,detail -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$color = switch ($overall) { 'PASS' {'Green'} 'FAIL' {'Red'} default {'Yellow'} }
Write-Host "Overall: $overall" -ForegroundColor $color
Write-Host "JSON report: $reportPath"
switch ($overall) { 'PASS' { exit 0 } 'FAIL' { exit 1 } default { exit 2 } }
