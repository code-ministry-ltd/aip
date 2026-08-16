$global:LASTEXITCODE = 0

if ($PSVersionTable.PSVersion -lt [version]'7.3') {
    $global:LASTEXITCODE = 1
    throw 'aip: PowerShell 7.3 or later is required'
}

$sourceFile = Join-Path $PSScriptRoot 'aip.ps1'
$installRoot = if ($env:_AIP_INSTALL_ROOT) {
    $env:_AIP_INSTALL_ROOT
}
elseif ($IsWindows) {
    Join-Path $env:LOCALAPPDATA 'aip'
}
else {
    Join-Path $HOME '.local/share/aip'
}
$shellProfile = if ($env:_AIP_SHELL_PROFILE) { $env:_AIP_SHELL_PROFILE } else { $PROFILE.CurrentUserAllHosts }
$installedFile = Join-Path $installRoot 'aip.ps1'

Write-Output "aip will install: $installedFile"
Write-Output "aip will update:  $shellProfile"

try {
    New-Item -ItemType Directory -Path $installRoot -Force -ErrorAction Stop | Out-Null
    $profileParent = Split-Path -Parent $shellProfile
    if ($profileParent) { New-Item -ItemType Directory -Path $profileParent -Force -ErrorAction Stop | Out-Null }
    Copy-Item -LiteralPath $sourceFile -Destination $installedFile -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $shellProfile)) { New-Item -ItemType File -Path $shellProfile -ErrorAction Stop | Out-Null }

    $quotedSource = $installedFile.Replace("'", "''")
    $sourceLine = ". '$quotedSource'"
    $profileContent = Get-Content -LiteralPath $shellProfile -Raw
    if ($profileContent -match '(?m)^# >>> aip >>>\r?$') {
        if ($profileContent -notmatch "(?m)^$([regex]::Escape($sourceLine))\r?$" -or $profileContent -notmatch '(?m)^# <<< aip <<<\r?$') {
            throw 'an existing aip profile block is not recognised; remove it manually and retry'
        }
    }
    else {
        $prefix = if ($profileContent.Length -gt 0) { [Environment]::NewLine } else { '' }
        $block = @('# >>> aip >>>', $sourceLine, '# <<< aip <<<') -join [Environment]::NewLine
        Add-Content -LiteralPath $shellProfile -Value "$prefix$block" -Encoding utf8NoBOM -ErrorAction Stop
    }
    Write-Output "Installed aip. Restart PowerShell or run: $sourceLine"
}
catch {
    $global:LASTEXITCODE = 1
    throw [InvalidOperationException]::new("aip: $($_.Exception.Message)", $_.Exception)
}
