# aip — AI Profile for PowerShell 7+. Dot-source this file from your profile.

if (-not (Get-Variable -Name AipProfileRoot -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AipProfileRoot = Join-Path $HOME 'agent-profiles'
}
$script:AipCommandStatus = 0

function Write-AipError {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("aip: $Message")
    $script:AipLastError = $Message
    $script:AipCommandStatus = 1
}

function Write-AipWarning {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("aip: warning: $Message")
    $script:AipLastWarning = $Message
}

function Test-AipProfileName {
    param([AllowEmptyString()][string]$Name)
    return $null -ne $Name -and [regex]::IsMatch($Name, '^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$')
}

function Test-AipOutfit {
    param([AllowEmptyString()][string]$Outfit)
    if ([string]::IsNullOrEmpty($Outfit) -or $Outfit.Length -gt 64) { return $false }
    foreach ($character in $Outfit.ToCharArray()) {
        if ([char]::IsControl($character)) { return $false }
    }
    return $true
}

function Get-AipProfilePath {
    param([Parameter(Mandatory)][string]$Name)
    return Join-Path $script:AipProfileRoot $Name
}

function Get-AipNameFile {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $null }
    $value = Get-Content -LiteralPath $LiteralPath -Raw
    $value = $value -replace '\r?\n\z', ''
    if ($value -match '[\r\n]' -or -not (Test-AipProfileName $value)) { return $null }
    return $value
}

function Test-AipProfileExists {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-AipProfileName $Name)) {
        Write-AipError "invalid profile name '$Name'"
        $script:AipCommandStatus = 2
        return $false
    }
    $profilePath = Get-AipProfilePath $Name
    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
        Write-AipError "profile '$Name' does not exist"
        $script:AipCommandStatus = 2
        return $false
    }
    if (-not (Test-Path -LiteralPath (Join-Path $profilePath '.git') -PathType Container)) {
        Write-AipError "profile '$Name' is not a Git repository; run 'aip doctor $Name'"
        $script:AipCommandStatus = 2
        return $false
    }
    return $true
}

function Find-AipProjectMarker {
    $directory = [System.IO.DirectoryInfo](Get-Location).ProviderPath
    while ($null -ne $directory) {
        $marker = Join-Path $directory.FullName '.aip-profile'
        if (Test-Path -LiteralPath $marker) {
            return [pscustomobject]@{ Path = $marker; Name = (Get-AipNameFile $marker) }
        }
        $directory = $directory.Parent
    }
    return $null
}

function Resolve-AipProfile {
    param([AllowEmptyString()][string]$ExplicitName = '')

    if ($ExplicitName) {
        if (-not (Test-AipProfileExists $ExplicitName)) { return $null }
        return [pscustomobject]@{ Name = $ExplicitName; Source = 'explicit'; Path = (Get-AipProfilePath $ExplicitName) }
    }
    if ($env:AIP_PROFILE) {
        if (-not (Test-AipProfileExists $env:AIP_PROFILE)) { return $null }
        return [pscustomobject]@{ Name = $env:AIP_PROFILE; Source = 'session'; Path = (Get-AipProfilePath $env:AIP_PROFILE) }
    }
    $project = Find-AipProjectMarker
    if ($null -ne $project) {
        if (-not $project.Name) {
            Write-AipError "invalid project marker '$($project.Path)'"
            $script:AipCommandStatus = 2
            return $null
        }
        if (-not (Test-AipProfileExists $project.Name)) { return $null }
        return [pscustomobject]@{ Name = $project.Name; Source = "project ($($project.Path))"; Path = (Get-AipProfilePath $project.Name) }
    }
    $defaultPath = Join-Path $script:AipProfileRoot '.default'
    if (Test-Path -LiteralPath $defaultPath) {
        $name = Get-AipNameFile $defaultPath
        if (-not $name) {
            Write-AipError "invalid default profile marker '$defaultPath'"
            $script:AipCommandStatus = 2
            return $null
        }
        if (-not (Test-AipProfileExists $name)) { return $null }
        return [pscustomobject]@{ Name = $name; Source = 'default'; Path = (Get-AipProfilePath $name) }
    }
    Write-AipError "no profile selected; run 'aip create NAME' then 'aip use NAME'"
    $script:AipCommandStatus = 2
    return $null
}

function Get-AipGitIgnoreLines {
    return @(
        '# aip-managed credential and runtime exclusions',
        '.env', '.env.*', '!.env.example', '*.pem', '*.key', '*.p12', '*.pfx',
        'claude/.credentials.json', 'claude/history.jsonl', 'claude/projects/', 'claude/session-env/', 'claude/shell-snapshots/', 'claude/statsig/', 'claude/todos/', 'claude/debug/', 'claude/cache/', 'claude/logs/', 'claude/file-history/',
        'codex/auth.json', 'codex/history.jsonl', 'codex/sessions/', 'codex/archived_sessions/', 'codex/log/', 'codex/logs/', 'codex/cache/', 'codex/*.db', 'codex/*.db-*', 'codex/*.sqlite', 'codex/*.sqlite-*',
        'pi/auth.json', 'pi/sessions/', 'pi/logs/', 'pi/cache/',
        'opencode/auth.json', 'opencode/sessions/', 'opencode/logs/', 'opencode/cache/'
    )
}

function New-AipProfileFiles {
    param([Parameter(Mandatory)][string]$ProfilePath, [Parameter(Mandatory)][string]$Outfit)

    foreach ($directory in '.aip', 'skills', 'claude', 'codex', 'pi', 'opencode') {
        New-Item -ItemType Directory -Path (Join-Path $ProfilePath $directory) -Force -ErrorAction Stop | Out-Null
    }
    $Outfit | Set-Content -LiteralPath (Join-Path $ProfilePath '.aip/outfit') -Encoding utf8NoBOM
    '# Common profile instructions' | Set-Content -LiteralPath (Join-Path $ProfilePath 'AGENTS.md') -Encoding utf8NoBOM
    @('../AGENTS.md', '', '# Claude Code instructions') | Set-Content -LiteralPath (Join-Path $ProfilePath 'claude/CLAUDE.md') -Encoding utf8NoBOM
    '# Codex instructions' | Set-Content -LiteralPath (Join-Path $ProfilePath 'codex/instructions.md') -Encoding utf8NoBOM
    '# Pi instructions' | Set-Content -LiteralPath (Join-Path $ProfilePath 'pi/APPEND_SYSTEM.md') -Encoding utf8NoBOM
    Get-AipGitIgnoreLines | Set-Content -LiteralPath (Join-Path $ProfilePath '.gitignore') -Encoding utf8NoBOM

    $links = @{
        'claude/skills' = '../skills'
        'codex/AGENTS.md' = '../AGENTS.md'
        'codex/skills' = '../skills'
        'pi/AGENTS.md' = '../AGENTS.md'
        'pi/skills' = '../skills'
        'opencode/AGENTS.md' = '../AGENTS.md'
        'opencode/skills' = '../skills'
    }
    foreach ($link in $links.GetEnumerator()) {
        New-Item -ItemType SymbolicLink -Path (Join-Path $ProfilePath $link.Key) -Target $link.Value -ErrorAction Stop | Out-Null
    }
}

function Invoke-AipCreate {
    param([object[]]$Arguments)
    if ($Arguments.Count -lt 1) {
        Write-AipError 'usage: aip create NAME [--outfit OUTFIT]'
        $script:AipCommandStatus = 2
        return
    }
    $name = [string]$Arguments[0]
    $outfit = 'plain'
    if ($Arguments.Count -eq 3 -and [string]$Arguments[1] -eq '--outfit') { $outfit = [string]$Arguments[2] }
    elseif ($Arguments.Count -ne 1) {
        Write-AipError 'usage: aip create NAME [--outfit OUTFIT]'
        $script:AipCommandStatus = 2
        return
    }
    if (-not (Test-AipProfileName $name)) {
        Write-AipError "invalid profile name '$name'"
        $script:AipCommandStatus = 2
        return
    }
    if (-not (Test-AipOutfit $outfit)) {
        Write-AipError 'outfit must be one printable, non-empty line of at most 64 characters'
        $script:AipCommandStatus = 2
        return
    }
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { Write-AipError 'Git is required'; return }
    & git var GIT_AUTHOR_IDENT *> $null
    if ($LASTEXITCODE -ne 0) { Write-AipError 'Git identity is not configured; set user.name and user.email'; return }

    New-Item -ItemType Directory -Path $script:AipProfileRoot -Force | Out-Null
    $destination = Get-AipProfilePath $name
    if (Test-Path -LiteralPath $destination) { Write-AipError "destination already exists: $destination"; return }
    $temporary = Join-Path $script:AipProfileRoot ('.aip-{0}-{1}' -f $name, [IO.Path]::GetRandomFileName())
    try {
        New-Item -ItemType Directory -Path $temporary -ErrorAction Stop | Out-Null
        New-AipProfileFiles $temporary $outfit
        & git -C $temporary init -q -b main
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
        & git -C $temporary add .aip/outfit .gitignore AGENTS.md skills claude/CLAUDE.md claude/skills codex/AGENTS.md codex/instructions.md codex/skills pi/AGENTS.md pi/APPEND_SYSTEM.md pi/skills opencode/AGENTS.md opencode/skills
        if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
        & git -C $temporary commit -q -m 'aip: create profile'
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
        Move-Item -LiteralPath $temporary -Destination $destination -ErrorAction Stop
        Write-Output "Created profile '$name' at $destination"
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        if ($_.Exception.Message -match 'symbolic|privilege') {
            Write-AipError 'could not create symbolic links; enable Windows Developer Mode and try again'
        }
        else { Write-AipError "could not create profile '$name': $($_.Exception.Message)" }
    }
}

function Test-AipUnfinishedGitOperation {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $gitDirectory = Join-Path $ProfilePath '.git'
    foreach ($entry in 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_START') {
        if (Test-Path -LiteralPath (Join-Path $gitDirectory $entry)) { return $true }
    }
    return $false
}

function Invoke-AipClone {
    param([object[]]$Arguments)
    if ($Arguments.Count -ne 2) { Write-AipError 'usage: aip clone SOURCE TARGET'; $script:AipCommandStatus = 2; return }
    $sourceName = [string]$Arguments[0]
    $targetName = [string]$Arguments[1]
    if (-not (Test-AipProfileExists $sourceName)) { return }
    if (-not (Test-AipProfileName $targetName)) { Write-AipError "invalid profile name '$targetName'"; $script:AipCommandStatus = 2; return }
    $sourcePath = Get-AipProfilePath $sourceName
    if ((Get-Item -LiteralPath $sourcePath).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { Write-AipError 'source profile path must not be a symbolic link'; return }
    $targetPath = Get-AipProfilePath $targetName
    if (Test-Path -LiteralPath $targetPath) { Write-AipError "destination already exists: $targetPath"; return }
    & git var GIT_AUTHOR_IDENT *> $null
    if ($LASTEXITCODE -ne 0) { Write-AipError 'Git identity is not configured; set user.name and user.email'; return }
    Invoke-AipSyncProfile $sourcePath 'clone'
    if ($script:AipCommandStatus -ne 0) { return }

    $temporary = Join-Path $script:AipProfileRoot ('.aip-{0}-{1}' -f $targetName, [IO.Path]::GetRandomFileName())
    try {
        & git clone --no-hardlinks -q $sourcePath $temporary
        if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
        Remove-Item -LiteralPath (Join-Path $temporary '.git') -Recurse -Force -ErrorAction Stop
        & git -C $temporary init -q -b main
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
        & git -C $temporary add -A
        if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
        & git -C $temporary commit -q -m "aip: clone $sourceName"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
        Move-Item -LiteralPath $temporary -Destination $targetPath -ErrorAction Stop
        Write-Output "Cloned profile '$sourceName' to '$targetName' at $targetPath"
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        Write-AipError "could not clone profile '$sourceName': $($_.Exception.Message)"
    }
}

function Invoke-AipDelete {
    param([object[]]$Arguments)
    if ($Arguments.Count -lt 1 -or $Arguments.Count -gt 2 -or ($Arguments.Count -eq 2 -and [string]$Arguments[1] -ne '--force')) {
        Write-AipError 'usage: aip delete NAME [--force]'
        $script:AipCommandStatus = 2
        return
    }
    $name = [string]$Arguments[0]
    $force = $Arguments.Count -eq 2
    if (-not (Test-AipProfileExists $name)) { return }
    $profilePath = Get-AipProfilePath $name
    if ((Get-Item -LiteralPath $profilePath).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { Write-AipError 'profile path must not be a symbolic link'; return }
    if ($env:AIP_PROFILE -eq $name) { Write-AipError "cannot delete session profile '$name'; select another profile first"; return }
    $rootFull = [IO.Path]::GetFullPath($script:AipProfileRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $parentFull = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($profilePath)).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($rootFull -ne $parentFull) { Write-AipError 'refusing to delete a profile outside the profile root'; return }

    $risks = @()
    if (& git -C $profilePath status --porcelain) { $risks += 'uncommitted changes' }
    if (Test-AipUnfinishedGitOperation $profilePath) { $risks += 'unfinished Git operation' }
    & git -C $profilePath rev-parse --verify '@{upstream}' *> $null
    if ($LASTEXITCODE -eq 0) {
        if (& git -C $profilePath rev-list '@{upstream}..HEAD') { $risks += 'unpushed commits' }
    }
    else { $risks += 'unpushed commits (no upstream)' }
    $hasRemote = [bool](& git -C $profilePath remote)

    if (-not $force) {
        $riskText = if ($risks.Count) { ' (' + ($risks -join ', ') + ')' } else { '' }
        $answer = Read-Host "Delete profile '$name' at $profilePath$riskText? Type yes"
        if ($answer -ne 'yes') { Write-AipError 'deletion cancelled; rerun with --force for non-interactive use'; return }
    }
    $defaultPath = Join-Path $script:AipProfileRoot '.default'
    $defaultName = Get-AipNameFile $defaultPath
    Remove-Item -LiteralPath $profilePath -Recurse -Force
    if ($defaultName -eq $name) { Remove-Item -LiteralPath $defaultPath -Force }
    if ($hasRemote) { Write-Output "Deleted $profilePath; recoverable from its configured Git remote." }
    else { Write-Output "Deleted $profilePath; no configured remote is available for recovery." }
}

function Test-AipLayout {
    param([Parameter(Mandatory)][string]$ProfilePath, [switch]$Report)
    $valid = $true
    $links = [ordered]@{
        'claude/skills' = '../skills'
        'codex/AGENTS.md' = '../AGENTS.md'
        'codex/skills' = '../skills'
        'pi/AGENTS.md' = '../AGENTS.md'
        'pi/skills' = '../skills'
        'opencode/AGENTS.md' = '../AGENTS.md'
        'opencode/skills' = '../skills'
    }
    foreach ($link in $links.GetEnumerator()) {
        $literalPath = Join-Path $ProfilePath $link.Key
        $item = Get-Item -LiteralPath $literalPath -Force -ErrorAction SilentlyContinue
        $target = if ($null -ne $item) { [string]$item.Target } else { '' }
        if ($null -eq $item -or $item.LinkType -ne 'SymbolicLink' -or $target -ne $link.Value) {
            if ($Report) { Write-Output "ERROR: $($link.Key) should link to $($link.Value)" }
            $valid = $false
        }
    }
    foreach ($file in '.aip/outfit', '.gitignore', 'AGENTS.md', 'claude/CLAUDE.md', 'codex/instructions.md', 'pi/APPEND_SYSTEM.md') {
        if (-not (Test-Path -LiteralPath (Join-Path $ProfilePath $file) -PathType Leaf)) {
            if ($Report) { Write-Output "ERROR: required file is missing: $file" }
            $valid = $false
        }
    }
    return $valid
}

function Invoke-AipDoctor {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 1) { Write-AipError 'usage: aip doctor [NAME]'; $script:AipCommandStatus = 2; return }
    $explicit = if ($Arguments.Count) { [string]$Arguments[0] } else { '' }
    $profile = Resolve-AipProfile $explicit
    if ($null -eq $profile) { return }
    $errors = 0
    if ((Get-Item -LiteralPath $profile.Path).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { Write-Output 'ERROR: profile path must not be a symbolic link'; $errors++ }
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { Write-Output 'ERROR: Git was not found'; $errors++ }
    & git var GIT_AUTHOR_IDENT *> $null
    if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: configure Git user.name and user.email'; $errors++ }
    & git -C $profile.Path status --porcelain *> $null
    if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: profile Git repository is unreadable'; $errors++ }
    $layoutResult = @(Test-AipLayout $profile.Path -Report)
    if ($layoutResult.Count -gt 1) { $layoutResult[0..($layoutResult.Count - 2)] | Write-Output }
    if (-not [bool]$layoutResult[-1]) { $errors++ }
    if (-not (Test-AipTrackedPathsSafe $profile.Path)) {
        Write-Output 'ERROR: remove forbidden tracked content before using this profile'
        $errors++
    }
    $lockPath = Join-Path $profile.Path '.git/aip-sync.lock'
    if (Test-Path -LiteralPath $lockPath -PathType Container) {
        $ownerPid = 0
        $pidText = if (Test-Path -LiteralPath (Join-Path $lockPath 'pid')) { (Get-Content -LiteralPath (Join-Path $lockPath 'pid') -Raw).Trim() } else { '' }
        $ownerHost = if (Test-Path -LiteralPath (Join-Path $lockPath 'host')) { (Get-Content -LiteralPath (Join-Path $lockPath 'host') -Raw).Trim() } else { '' }
        if (-not [int]::TryParse($pidText, [ref]$ownerPid)) {
            Write-Output "WARN: sync lock owner is unknown; inspect $lockPath"
        }
        elseif ($ownerHost -eq [Environment]::MachineName -and -not (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
            Write-Output "WARN: stale sync lock found; the next sync will remove it, or inspect $lockPath"
        }
        else { Write-Output "WARN: sync lock is owned by a live or remote process; inspect $lockPath" }
    }
    if ($errors -eq 0) { Write-Output 'OK: profile layout and links' }
    foreach ($harness in 'claude', 'codex', 'pi', 'opencode') {
        if (Get-AipRealCommand $harness) { Write-Output "OK: $harness executable found" }
        else { Write-Output "WARN: $harness executable was not found; install it before using this wrapper" }
    }
    if ($errors -gt 0) { $script:AipCommandStatus = 1 }
}

function Get-AipRealCommand {
    param([Parameter(Mandatory)][string]$Name)
    if (Get-Variable -Name AipRealPath -Scope Script -ErrorAction SilentlyContinue) {
        $extensions = if ($IsWindows) { @('.exe', '.cmd', '.bat', '.com', '') } else { @('') }
        foreach ($directory in ($script:AipRealPath -split [IO.Path]::PathSeparator)) {
            foreach ($extension in $extensions) {
                $candidate = Join-Path $directory "$Name$extension"
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
        return $null
    }
    $command = Get-Command -Name $Name -CommandType Application, ExternalScript -All -ErrorAction SilentlyContinue | Select-Object -First 1
    return $command.Path
}

function Test-AipForbiddenPath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('\', '/')
    if ($relative -like '.env.example' -or $relative -like '*/.env.example') { return $false }
    switch -Wildcard ($relative) {
        '.env' { return $true }
        '.env.*' { return $true }
        '*/.env' { return $true }
        '*/.env.*' { return $true }
        '*.pem' { return $true }
        '*.key' { return $true }
        '*.p12' { return $true }
        '*.pfx' { return $true }
        'claude/.credentials.json' { return $true }
        'claude/history.jsonl' { return $true }
        'claude/projects/*' { return $true }
        'claude/session-env/*' { return $true }
        'claude/shell-snapshots/*' { return $true }
        'claude/statsig/*' { return $true }
        'claude/todos/*' { return $true }
        'claude/debug/*' { return $true }
        'claude/cache/*' { return $true }
        'claude/logs/*' { return $true }
        'claude/file-history/*' { return $true }
        'codex/auth.json' { return $true }
        'codex/history.jsonl' { return $true }
        'codex/sessions/*' { return $true }
        'codex/archived_sessions/*' { return $true }
        'codex/log/*' { return $true }
        'codex/logs/*' { return $true }
        'codex/cache/*' { return $true }
        'codex/*.db' { return $true }
        'codex/*.db-*' { return $true }
        'codex/*.sqlite' { return $true }
        'codex/*.sqlite-*' { return $true }
        'pi/auth.json' { return $true }
        'pi/sessions/*' { return $true }
        'pi/logs/*' { return $true }
        'pi/cache/*' { return $true }
        'opencode/auth.json' { return $true }
        'opencode/sessions/*' { return $true }
        'opencode/logs/*' { return $true }
        'opencode/cache/*' { return $true }
        '*/node_modules/*' { return $true }
        default { return $false }
    }
}

function Test-AipTrackedPathsSafe {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $raw = (& git -C $ProfilePath ls-files -z) -join "`n"
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not inspect tracked profile paths'; return $false }
    foreach ($relative in ($raw -split "`0")) {
        if ($relative -and (Test-AipForbiddenPath $relative)) {
            Write-AipError "forbidden credential or runtime path is tracked; inspect with 'git -C `"$ProfilePath`" ls-files' and remove it with 'git rm --cached PATH'"
            return $false
        }
    }
    return $true
}

function Remove-AipStaleLock {
    param([Parameter(Mandatory)][string]$LockPath)
    $pidPath = Join-Path $LockPath 'pid'
    $hostPath = Join-Path $LockPath 'host'
    if (-not (Test-Path -LiteralPath $pidPath) -or -not (Test-Path -LiteralPath $hostPath)) { return $false }
    $ownerPid = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$ownerPid)) { return $false }
    $ownerHost = (Get-Content -LiteralPath $hostPath -Raw).Trim()
    if ($ownerHost -ne [Environment]::MachineName) { return $false }
    if (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) { return $false }
    Remove-Item -LiteralPath $LockPath -Recurse -Force
    return $true
}

function Enter-AipSyncLock {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $attempts = if (Get-Variable -Name AipLockAttempts -Scope Script -ErrorAction SilentlyContinue) { [int]$script:AipLockAttempts } else { 100 }
    if ($attempts -lt 1) { $attempts = 1 }
    $script:AipSyncLock = Join-Path $ProfilePath '.git/aip-sync.lock'
    for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
        try {
            New-Item -ItemType Directory -Path $script:AipSyncLock -ErrorAction Stop | Out-Null
            $script:AipSyncToken = [guid]::NewGuid().ToString('N')
            $PID | Set-Content -LiteralPath (Join-Path $script:AipSyncLock 'pid') -Encoding ascii
            [Environment]::MachineName | Set-Content -LiteralPath (Join-Path $script:AipSyncLock 'host') -Encoding utf8NoBOM
            [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() | Set-Content -LiteralPath (Join-Path $script:AipSyncLock 'timestamp') -Encoding ascii
            $script:AipSyncToken | Set-Content -LiteralPath (Join-Path $script:AipSyncLock 'token') -Encoding ascii
            return $true
        }
        catch {
            if (Remove-AipStaleLock $script:AipSyncLock) { continue }
            if ($attempt + 1 -lt $attempts) { Start-Sleep -Milliseconds 100 }
        }
    }
    Write-AipError "sync is already running for $ProfilePath; inspect $($script:AipSyncLock)"
    return $false
}

function Exit-AipSyncLock {
    if (-not $script:AipSyncLock -or -not (Test-Path -LiteralPath $script:AipSyncLock)) { return }
    $tokenPath = Join-Path $script:AipSyncLock 'token'
    if ((Test-Path -LiteralPath $tokenPath) -and (Get-Content -LiteralPath $tokenPath -Raw).Trim() -eq $script:AipSyncToken) {
        Remove-Item -LiteralPath $script:AipSyncLock -Recurse -Force
    }
}

function Add-AipCheckpoint {
    param([Parameter(Mandatory)][string]$ProfilePath, [Parameter(Mandatory)][string]$Mode)
    $script:AipCheckpointCreated = $false
    if (-not (Test-AipTrackedPathsSafe $ProfilePath)) { return $false }
    & git -C $ProfilePath add -u -- .
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not stage tracked profile changes'; return $false }
    $owned = @('.aip/outfit', '.gitignore', 'AGENTS.md', 'skills', 'claude/CLAUDE.md', 'claude/skills', 'codex/AGENTS.md', 'codex/instructions.md', 'codex/skills', 'pi/AGENTS.md', 'pi/APPEND_SYSTEM.md', 'pi/skills', 'opencode/AGENTS.md', 'opencode/skills')
    & git -C $ProfilePath add -- @owned
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not stage aip-owned profile files'; return $false }
    & git -C $ProfilePath diff --cached --quiet --
    if ($LASTEXITCODE -ne 0) {
        & git -C $ProfilePath commit -q -m "aip: checkpoint ($Mode)"
        if ($LASTEXITCODE -ne 0) { Write-AipError 'could not commit the local checkpoint; check Git identity and hooks'; return $false }
        $script:AipCheckpointCreated = $true
    }
    return $true
}

function Invoke-AipSyncProfile {
    param([Parameter(Mandatory)][string]$ProfilePath, [string]$Mode = 'manual')
    $script:AipCommandStatus = 0
    $layoutResult = @(Test-AipLayout $ProfilePath)
    if (-not [bool]$layoutResult[-1]) { Write-AipError 'required profile file or link is missing or invalid'; return }
    if (-not (Enter-AipSyncLock $ProfilePath)) { return }
    try {
        $unmerged = & git -C $ProfilePath diff --name-only --diff-filter=U 2>$null
        if ((Test-AipUnfinishedGitOperation $ProfilePath) -or $unmerged) {
            Write-AipError "Git conflict or unfinished operation in $ProfilePath; run 'git -C `"$ProfilePath`" status', then resolve and continue or abort it"
            return
        }
        if (-not (Add-AipCheckpoint $ProfilePath $Mode)) { return }
        if ($script:AipCheckpointCreated) { Write-Output 'Checkpointed local profile changes.' }
        & git -C $ProfilePath rev-parse --verify '@{upstream}' *> $null
        if ($LASTEXITCODE -ne 0) { Write-Output 'Profile is local only (no upstream).'; return }

        $upstream = & git -C $ProfilePath rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
        $branch = & git -C $ProfilePath branch --show-current
        $remote = & git -C $ProfilePath config --get "branch.$branch.remote"
        $previousPrompt = $env:GIT_TERMINAL_PROMPT
        try {
            $env:GIT_TERMINAL_PROMPT = '0'
            & git -C $ProfilePath fetch --quiet $remote *> $null
            if ($LASTEXITCODE -ne 0) { Write-AipWarning 'remote sync unavailable; using the committed local profile and retrying next time'; return }
            & git -C $ProfilePath rebase $upstream *> $null
            if ($LASTEXITCODE -ne 0) {
                $unmerged = & git -C $ProfilePath diff --name-only --diff-filter=U 2>$null
                if ((Test-AipUnfinishedGitOperation $ProfilePath) -or $unmerged) {
                    Write-AipError "Git conflict in $ProfilePath; no side was chosen. Resolve files, then use 'git rebase --continue' or 'git rebase --abort'"
                }
                else { Write-AipError "local Git integration failed in $ProfilePath; inspect it with 'git status'" }
                return
            }
            & git -C $ProfilePath push --quiet *> $null
            if ($LASTEXITCODE -ne 0) { Write-AipWarning 'remote sync unavailable during push; the local checkpoint is safe and will retry next time'; return }
            Write-Output "Profile synced with $upstream."
        }
        finally {
            if ($null -eq $previousPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
            else { $env:GIT_TERMINAL_PROMPT = $previousPrompt }
        }
    }
    finally { Exit-AipSyncLock }
}

function Invoke-AipSync {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 1) { Write-AipError 'usage: aip sync [NAME]'; $script:AipCommandStatus = 2; return }
    $explicit = if ($Arguments.Count) { [string]$Arguments[0] } else { '' }
    $profile = Resolve-AipProfile $explicit
    if ($null -ne $profile) { Invoke-AipSyncProfile $profile.Path 'manual' }
}

function Invoke-AipHarness {
    param(
        [AllowEmptyString()][string]$ExplicitName,
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(ValueFromRemainingArguments)][object[]]$Arguments
    )
    $script:AipCommandStatus = 0
    $script:AipLastError = $null
    $script:AipLastWarning = $null
    if ($Harness -notin 'claude', 'codex', 'pi', 'opencode') {
        Write-AipError "unknown harness '$Harness'; expected claude, codex, pi, or opencode"
        $global:LASTEXITCODE = 2
        return
    }
    $profile = Resolve-AipProfile $ExplicitName
    if ($null -eq $profile) { $global:LASTEXITCODE = $script:AipCommandStatus; return }
    $realCommand = Get-AipRealCommand $Harness
    if (-not $realCommand) {
        Write-AipError "$Harness executable was not found in PATH"
        $global:LASTEXITCODE = 127
        return
    }
    Invoke-AipSyncProfile $profile.Path 'before'
    if ($script:AipCommandStatus -ne 0) { $global:LASTEXITCODE = $script:AipCommandStatus; return }

    $variables = @{
        claude = 'CLAUDE_CONFIG_DIR'
        codex = 'CODEX_HOME'
        pi = 'PI_CODING_AGENT_DIR'
        opencode = 'OPENCODE_CONFIG_DIR'
    }
    $variable = $variables[$Harness]
    $previous = [Environment]::GetEnvironmentVariable($variable, 'Process')
    $hadPrevious = $null -ne $previous
    $childStatus = 1
    try {
        [Environment]::SetEnvironmentVariable($variable, (Join-Path $profile.Path $Harness), 'Process')
        $nativeArguments = @($Arguments)
        if ($Harness -eq 'codex') {
            $instructions = (Get-Content -LiteralPath (Join-Path $profile.Path 'codex/instructions.md') -Raw).TrimEnd("`r", "`n")
            $nativeArguments = @('-c', "developer_instructions=$instructions") + $nativeArguments
        }
        & $realCommand @nativeArguments
        $childStatus = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    finally {
        Invoke-AipSyncProfile $profile.Path 'after'
        if ($hadPrevious) { [Environment]::SetEnvironmentVariable($variable, $previous, 'Process') }
        else { [Environment]::SetEnvironmentVariable($variable, $null, 'Process') }
        $global:LASTEXITCODE = $childStatus
    }
}

function Invoke-AipUse {
    param([object[]]$Arguments)
    if ($Arguments.Count -ne 1) { Write-AipError 'usage: aip use NAME'; $script:AipCommandStatus = 2; return }
    $name = [string]$Arguments[0]
    if (-not (Test-AipProfileExists $name)) { return }
    $env:AIP_PROFILE = $name
    Write-Output "Using profile '$name' for this PowerShell session"
}

function Invoke-AipWhich {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 1) { Write-AipError 'usage: aip which [NAME]'; $script:AipCommandStatus = 2; return }
    $explicit = if ($Arguments.Count -eq 1) { [string]$Arguments[0] } else { '' }
    $profile = Resolve-AipProfile $explicit
    if ($null -ne $profile) { Write-Output $profile.Path }
}

function Set-AipMarker {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][string]$Name)
    $temporary = "$LiteralPath.$([IO.Path]::GetRandomFileName())"
    try {
        $Name | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $LiteralPath -Force -ErrorAction Stop
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        Write-AipError "could not write marker '$LiteralPath'"
    }
}

function Invoke-AipDefault {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 1) { Write-AipError 'usage: aip default [NAME]'; $script:AipCommandStatus = 2; return }
    $marker = Join-Path $script:AipProfileRoot '.default'
    if ($Arguments.Count -eq 0) {
        $name = Get-AipNameFile $marker
        if (-not $name) { Write-AipError 'no default profile is set'; return }
        Write-Output $name
        return
    }
    $name = [string]$Arguments[0]
    if (-not (Test-AipProfileExists $name)) { return }
    Set-AipMarker $marker $name
    if ($script:AipCommandStatus -eq 0) { Write-Output "Default profile is now '$name'" }
}

function Invoke-AipLocal {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 1) { Write-AipError 'usage: aip local [NAME|--remove]'; $script:AipCommandStatus = 2; return }
    $marker = Join-Path (Get-Location).ProviderPath '.aip-profile'
    if ($Arguments.Count -eq 0) {
        $name = Get-AipNameFile $marker
        if (-not $name) { Write-AipError 'no profile marker exists in the current directory'; return }
        Write-Output $name
        return
    }
    $value = [string]$Arguments[0]
    if ($value -eq '--remove') {
        if (-not (Test-Path -LiteralPath $marker)) { Write-AipError 'no profile marker exists in the current directory'; return }
        Remove-Item -LiteralPath $marker -Force
        Write-Output "Removed $marker"
        return
    }
    if (-not (Test-AipProfileExists $value)) { return }
    Set-AipMarker $marker $value
    if ($script:AipCommandStatus -eq 0) { Write-Output "This directory now uses profile '$value'" }
}

function Get-AipOutfit {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $outfitPath = Join-Path $ProfilePath '.aip/outfit'
    if (-not (Test-Path -LiteralPath $outfitPath -PathType Leaf)) { return 'invalid outfit' }
    $outfit = (Get-Content -LiteralPath $outfitPath -Raw).TrimEnd("`r", "`n")
    if (-not (Test-AipOutfit $outfit)) { return 'invalid outfit' }
    return $outfit
}

function Invoke-AipOutfit {
    param([object[]]$Arguments)
    if ($Arguments.Count -ne 2) { Write-AipError 'usage: aip outfit NAME OUTFIT'; $script:AipCommandStatus = 2; return }
    $name = [string]$Arguments[0]
    $outfit = [string]$Arguments[1]
    if (-not (Test-AipProfileExists $name)) { return }
    if (-not (Test-AipOutfit $outfit)) { Write-AipError 'outfit must be one printable, non-empty line of at most 64 characters'; $script:AipCommandStatus = 2; return }
    $outfit | Set-Content -LiteralPath (Join-Path (Get-AipProfilePath $name) '.aip/outfit') -Encoding utf8NoBOM
    Write-Output "Profile '$name' now wears $outfit"
}

function Get-AipGitSummary {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $changes = & git -C $ProfilePath status --porcelain 2>$null
    $state = if ($changes) { 'changes' } else { 'clean' }
    & git -C $ProfilePath rev-parse --verify '@{upstream}' *> $null
    if ($LASTEXITCODE -eq 0) { $upstream = & git -C $ProfilePath rev-parse --abbrev-ref '@{upstream}' 2>$null }
    else { $upstream = 'local only' }
    return "$state, $upstream"
}

function Invoke-AipStatus {
    $profile = Resolve-AipProfile
    if ($null -eq $profile) { return }
    Write-Output "🐵 $($profile.Name) — $(Get-AipOutfit $profile.Path)"
    Write-Output "Selected by: $($profile.Source)"
    Write-Output "Path: $($profile.Path)"
    Write-Output "Git: $(Get-AipGitSummary $profile.Path)"
    $availability = foreach ($harness in 'claude', 'codex', 'pi', 'opencode') {
        "$harness=$(if (Get-AipRealCommand $harness) { 'available' } else { 'missing' })"
    }
    Write-Output "Harnesses: $($availability -join ' ')"
}

function Invoke-AipList {
    param([object[]]$Arguments)
    if ($Arguments.Count -ne 0) { Write-AipError 'usage: aip list'; $script:AipCommandStatus = 2; return }
    $defaultName = Get-AipNameFile (Join-Path $script:AipProfileRoot '.default')
    $project = Find-AipProjectMarker
    $profiles = @(Get-ChildItem -LiteralPath $script:AipProfileRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        Test-AipProfileName $_.Name -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container)
    } | Sort-Object Name)
    if ($profiles.Count -eq 0) { Write-Output 'No profiles. Create one with: aip create NAME'; return }
    foreach ($profile in $profiles) {
        $tags = @()
        if ($env:AIP_PROFILE -eq $profile.Name) { $tags += '[session]' }
        if ($null -ne $project -and $project.Name -eq $profile.Name) { $tags += '[project]' }
        if ($defaultName -eq $profile.Name) { $tags += '[default]' }
        $suffix = if ($tags.Count) { ' ' + ($tags -join ' ') } else { '' }
        Write-Output "$($profile.Name) — $(Get-AipOutfit $profile.FullName)$suffix"
    }
}

function Invoke-AipRun {
    param([object[]]$Arguments)
    if ($Arguments.Count -lt 1) { Write-AipError 'usage: aip run [NAME] HARNESS [ARGS...]'; $script:AipCommandStatus = 2; return }
    $harnesses = @('claude', 'codex', 'pi', 'opencode')
    if ([string]$Arguments[0] -in $harnesses) {
        $explicit = ''
        $harness = [string]$Arguments[0]
        $rest = @($Arguments | Select-Object -Skip 1)
    }
    elseif ($Arguments.Count -ge 2) {
        $explicit = [string]$Arguments[0]
        $harness = [string]$Arguments[1]
        $rest = @($Arguments | Select-Object -Skip 2)
    }
    else { Write-AipError "unknown harness '$($Arguments[0])'; expected claude, codex, pi, or opencode"; $script:AipCommandStatus = 2; return }
    Invoke-AipHarness $explicit $harness @rest
    $script:AipCommandStatus = $global:LASTEXITCODE
}

function aip {
    $script:AipCommandStatus = 0
    $script:AipLastError = $null
    $script:AipLastWarning = $null
    $arguments = @($args)
    if ($arguments.Count -eq 0) { Invoke-AipStatus }
    else {
        $command = ([string]$arguments[0]).ToLowerInvariant()
        $rest = @($arguments | Select-Object -Skip 1)
        switch ($command) {
            'create' { Invoke-AipCreate $rest }
            'clone' { Invoke-AipClone $rest }
            'default' { Invoke-AipDefault $rest }
            'delete' { Invoke-AipDelete $rest }
            'doctor' { Invoke-AipDoctor $rest }
            'list' { Invoke-AipList $rest }
            'local' { Invoke-AipLocal $rest }
            'outfit' { Invoke-AipOutfit $rest }
            'run' { Invoke-AipRun $rest }
            'sync' { Invoke-AipSync $rest }
            'use' { Invoke-AipUse $rest }
            'which' { Invoke-AipWhich $rest }
            default { Write-AipError "unknown command '$command'"; $script:AipCommandStatus = 2 }
        }
    }
    $global:LASTEXITCODE = $script:AipCommandStatus
}

function claude { Invoke-AipHarness '' 'claude' @args }
function codex { Invoke-AipHarness '' 'codex' @args }
function pi { Invoke-AipHarness '' 'pi' @args }
function opencode { Invoke-AipHarness '' 'opencode' @args }
