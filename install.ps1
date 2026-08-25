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

$packageVersion = if ((Get-Content -LiteralPath $sourceFile -Raw) -match "(?m)^\`$script:AipVersion = '([^']*)'") { $Matches[1] } else { $null }
if (-not $packageVersion) {
    Write-Error "aip: cannot read the package version from $sourceFile"
    $global:LASTEXITCODE = 1
    return
}
$previousVersion = $null
$versionFile = Join-Path $installRoot 'VERSION'
if (Test-Path -LiteralPath $versionFile) { $previousVersion = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() }

Write-Output "aip will install: $installedFile"
Write-Output "aip will update:  $shellProfile"

# Creates the 'aip' profile (skeleton committed via aip create) and
# (re)installs the management skill, marker-managed. Never commits, syncs, or
# pushes: the skill files land untracked and the next checkpoint or 'aip sync'
# commits them. Skipped with a warning when Git or the identity is missing.
function Invoke-AipProfileSkillSetup {
    param(
        [Parameter(Mandatory)][string]$InstalledFile,
        [Parameter(Mandatory)][string]$PackageVersion,
        [Parameter(Mandatory)][string]$ScriptDirectory
    )
    # The warnings below use Write-Error so callers can capture them on the
    # error stream; keep them non-terminating under a caller's Stop preference.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
    Invoke-AipProfileSkillSetupBody -InstalledFile $InstalledFile -PackageVersion $PackageVersion -ScriptDirectory $ScriptDirectory
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

function Invoke-AipProfileSkillSetupBody {
    param(
        [Parameter(Mandatory)][string]$InstalledFile,
        [Parameter(Mandatory)][string]$PackageVersion,
        [Parameter(Mandatory)][string]$ScriptDirectory
    )
    $gitApp = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $gitApp) {
        Write-Error 'aip: warning: Git was not found, so the aip profile and management skill were not set up. Install Git and re-run the installer.'
        return
    }
    $userName = @(& git config --get user.name 2>$null)
    if ($LASTEXITCODE -ne 0) { $userName = @() }
    $userEmail = @(& git config --get user.email 2>$null)
    if ($LASTEXITCODE -ne 0) { $userEmail = @() }
    if ($userName.Count -eq 0 -or $userEmail.Count -eq 0) {
        Write-Error 'aip: warning: Git has no user.name or user.email, so the aip profile and management skill were not set up. Configure both (git config --global user.name / user.email) and re-run the installer.'
        return
    }
    $profileRoot = if ($env:_AIP_PROFILE_ROOT) { $env:_AIP_PROFILE_ROOT } else { Join-Path $HOME 'agent-profiles' }
    $skillSrc = Join-Path $ScriptDirectory 'skills/aip'
    $skillDest = Join-Path $profileRoot 'aip/skills/aip'
    $marker = Join-Path $skillDest '.aip-managed'
    if (-not (Test-Path -LiteralPath (Join-Path $profileRoot 'aip') -PathType Container)) {
        # Dot-source the installed script in this throwaway process and point it
        # at the target root before creating the profile.
        . $InstalledFile
        $script:AipProfileRoot = $profileRoot
        aip create aip *> $null
        if ($global:LASTEXITCODE -ne 0) {
            Write-Error 'aip: warning: could not create the aip profile; run: aip create aip'
            return
        }
    }
    if (Test-Path -LiteralPath $marker) {
        # Managed skill: replace the directory contents from the package (user
        # edits to a managed skill are overwritten — documented behaviour).
        Remove-Item -LiteralPath $skillDest -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif (Test-Path -LiteralPath $skillDest) {
        Write-Output "aip: note: $skillDest exists without the .aip-managed marker; leaving it untouched."
        return
    }
    if (-not (Test-Path -LiteralPath $skillSrc -PathType Container)) {
        Write-Error "aip: warning: the aip management skill is missing from the package at $skillSrc"
        return
    }
    # Copy the package directory into the (existing) skills/ parent so that
    # $skillDest is created as a plain copy of $skillSrc.
    New-Item -ItemType Directory -Path (Split-Path $skillDest) -Force | Out-Null
    Copy-Item -LiteralPath $skillSrc -Destination (Split-Path $skillDest) -Recurse -Force | Out-Null
    Set-Content -LiteralPath $marker -Value "aip $PackageVersion — installed by the aip installer; re-run the installer or aip update to refresh" -Encoding utf8NoBOM
    Write-Output 'Set up the aip profile with the aip management skill (untracked until your next aip sync). Launch a harness with it: aip manage pi'
}

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
        Set-Content -LiteralPath $versionFile -Value $packageVersion -Encoding utf8NoBOM
        Invoke-AipProfileSkillSetup -InstalledFile $installedFile -PackageVersion $packageVersion -ScriptDirectory $PSScriptRoot
        # Adopt profiles' untracked pi/settings.json (created before aip tracked them).
        $adoptCommand = ". '$($installedFile.Replace("'", "''"))'; Invoke-AipAdoptUntrackedSettings"
        & (Get-Process -Id $PID).Path -NoProfile -Command $adoptCommand
        if ($previousVersion -and $previousVersion -ne $packageVersion) {
            Write-Output "Updated aip from $previousVersion to $packageVersion. Restart PowerShell or run: $sourceLine"
        }
        elseif ($previousVersion) {
            Write-Output "aip $packageVersion is already installed. Restart PowerShell or run: $sourceLine"
        }
        else {
            Write-Output "Installed aip $packageVersion. Restart PowerShell or run: $sourceLine"
        }
        # Native git probes above clobber LASTEXITCODE; the try completing is the
        # success contract.
        $global:LASTEXITCODE = 0
}
catch {
    $global:LASTEXITCODE = 1
    throw [InvalidOperationException]::new("aip: $($_.Exception.Message)", $_.Exception)
}
