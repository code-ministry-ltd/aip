$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$requiredVersion = (Get-Content (Join-Path $PSScriptRoot 'Pester.version') -Raw).Trim()
$installed = Get-Module Pester -ListAvailable |
    Where-Object Version -EQ ([version]$requiredVersion) |
    Select-Object -First 1

if (-not $installed) {
    Write-Error "Pester $requiredVersion is required. Install it with: Install-Module Pester -RequiredVersion $requiredVersion -Scope CurrentUser"
}

Import-Module Pester -RequiredVersion $requiredVersion -Force

$resultsDirectory = Join-Path $repositoryRoot 'test-results'
New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'powershell'
$configuration.Run.Exit = $true
if ($env:AIP_PESTER_FILTER) { $configuration.Filter.FullName = $env:AIP_PESTER_FILTER }
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.TestResult.OutputPath = Join-Path $resultsDirectory 'pester.xml'

Invoke-Pester -Configuration $configuration
