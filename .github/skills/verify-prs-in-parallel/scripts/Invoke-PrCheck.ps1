#requires -Version 5.1
<#
.SYNOPSIS
    Installs, builds, serves and smoke-tests one omni-tools worktree.

.DESCRIPTION
    Runs the full `npm install` -> `npm run build` -> `npm run serve` -> browser check
    pipeline against a single git worktree, on its own port, and writes both a human
    readable `verify.log` and a machine readable `result.json` into that worktree.

    Designed to be launched once per pull request, in parallel, by the
    `verify-prs-in-parallel` skill. Never returns before the preview server it started
    has been stopped, including the child `node` process that `npm.cmd` spawns.

.PARAMETER Dir
    Worktree to test. Must already exist.

.PARAMETER Port
    Port for `vite preview`. Must be unique across concurrently running instances.

.PARAMETER Label
    Name used in the result file, e.g. a PR number. Defaults to the worktree folder name.

.PARAMETER CheckScript
    Node script run against the preview server. Defaults to Test-HomePage.mjs next to
    this file. It is copied into the worktree before running so that its `import` of
    `@playwright/test` resolves against that worktree's node_modules.

.PARAMETER RequiredText
    Strings that must appear on the served page. Passed through to the check script.

.PARAMETER SkipInstall
    Reuse the existing node_modules instead of running `npm install`.

.EXAMPLE
    .\Invoke-PrCheck.ps1 -Dir G:\Code\omni-wt\pr-216 -Port 4216 -Label 216
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [Parameter(Mandatory = $true)][int]$Port,
    [string]$Label,
    [string]$CheckScript,
    [string[]]$RequiredText = @(),
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $Dir)) { throw "Worktree not found: $Dir" }
$Dir = (Resolve-Path $Dir).Path
if (-not $Label) { $Label = Split-Path $Dir -Leaf }
if (-not $CheckScript) { $CheckScript = Join-Path $PSScriptRoot 'Test-HomePage.mjs' }

$log = Join-Path $Dir 'verify.log'
$resultFile = Join-Path $Dir 'result.json'
foreach ($f in @($log, $resultFile)) { if (Test-Path $f) { Remove-Item $f -Force } }

$result = [ordered]@{
    label = $Label; port = $Port; dir = $Dir
    install = 'skipped'; build = 'skipped'; serve = 'skipped'; check = 'skipped'
    result = 'FAIL'; failedStage = $null; errors = @()
}

function Write-Log { param([string]$Message) Add-Content -Path $log -Value $Message }

# npm.cmd is a shim; killing it orphans the real node process, which then keeps a lock on
# node_modules and makes `git worktree remove` fail. Walk the tree and kill children first.
function Stop-Tree {
    param([int]$ProcessId)
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Tree -ProcessId $_.ProcessId }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Complete-Run {
    param([string]$Stage)
    if ($Stage) { $result.failedStage = $Stage } else { $result.result = 'PASS' }
    Write-Log "RESULT=$($result.result)$(if ($Stage) { " (failed at $Stage)" })"
    $result | ConvertTo-Json -Depth 4 | Set-Content -Path $resultFile -Encoding UTF8
    exit $(if ($result.result -eq 'PASS') { 0 } else { 1 })
}

Push-Location $Dir
try {
    if ($SkipInstall) {
        Write-Log '=== npm install (skipped) ==='
    }
    else {
        Write-Log '=== npm install ==='
        $out = & npm install --no-audit --no-fund 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Log $out
        Write-Log "INSTALL_EXIT=$code"
        $result.install = "exit $code"
        if ($code -ne 0) {
            # Pull the npm error lines out so the caller does not have to read the log.
            $result.errors += ($out -split "`r?`n" | Where-Object { $_ -match 'npm error' } | Select-Object -First 5)
            Complete-Run -Stage 'install'
        }
    }

    Write-Log '=== npm run build ==='
    $out = & npm run build 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Log $out
    Write-Log "BUILD_EXIT=$code"
    $result.build = "exit $code"
    if ($code -ne 0) {
        $result.errors += ($out -split "`r?`n" | Where-Object { $_ -match 'error|Error' } | Select-Object -First 8)
        Complete-Run -Stage 'build'
    }

    Write-Log "=== npm run serve (port $Port) ==="
    $serveOut = Join-Path $Dir 'serve.out.log'
    $serveErr = Join-Path $Dir 'serve.err.log'
    $proc = Start-Process -FilePath 'npm.cmd' `
        -ArgumentList @('run', 'serve', '--', '--port', "$Port", '--strictPort') `
        -WorkingDirectory $Dir -NoNewWindow -PassThru `
        -RedirectStandardOutput $serveOut -RedirectStandardError $serveErr

    $url = "http://localhost:$Port/"
    $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        Start-Sleep -Seconds 2
        if ($proc.HasExited) { break }
        try {
            if ((Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) { $ready = $true }
        }
        catch { }
    }

    try {
        if (-not $ready) {
            $result.serve = 'not ready'
            Write-Log (Get-Content $serveOut -Raw -ErrorAction SilentlyContinue)
            Write-Log (Get-Content $serveErr -Raw -ErrorAction SilentlyContinue)
            $result.errors += "Preview server never answered on $url"
            Complete-Run -Stage 'serve'
        }
        $result.serve = 'ready'

        Write-Log '=== homepage check ==='
        $localCheck = Join-Path $Dir '.pr-check.mjs'
        Copy-Item $CheckScript $localCheck -Force
        $out = & node $localCheck $url @RequiredText 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Log $out
        $result.check = "exit $code"
        if ($code -ne 0) {
            $result.errors += ($out -split "`r?`n" | Where-Object { $_ -match '^\s+- ' } | Select-Object -First 8)
            Complete-Run -Stage 'check'
        }
    }
    finally {
        if ($proc -and -not $proc.HasExited) { Stop-Tree -ProcessId $proc.Id }
        Remove-Item (Join-Path $Dir '.pr-check.mjs') -Force -ErrorAction SilentlyContinue
    }

    Complete-Run
}
finally {
    Pop-Location
}
