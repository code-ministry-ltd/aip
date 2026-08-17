# aip — AI Profile for PowerShell 7.3+. Dot-source this file from your profile.

if ($PSVersionTable.PSVersion -lt [version]'7.3') { throw 'aip requires PowerShell 7.3 or later' }

if (-not (Get-Variable -Name AipProfileRoot -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AipProfileRoot = Join-Path $HOME 'agent-profiles'
}
$script:AipCommandStatus = 0
$script:AipVersion = '0.2.0'

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

function Invoke-AipWithoutGitRouting {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $names = @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_COMMON_DIR')
    $previous = @{}
    foreach ($name in $names) {
        $environmentPath = "Env:$name"
        $existing = Get-Item -LiteralPath $environmentPath -ErrorAction SilentlyContinue
        $previous[$name] = if ($null -eq $existing) { $null } else { [string]$existing.Value }
        Remove-Item -LiteralPath $environmentPath -ErrorAction SilentlyContinue
    }
    try { & $Action }
    finally {
        foreach ($name in $names) {
            $environmentPath = "Env:$name"
            if ($null -eq $previous[$name]) { Remove-Item -LiteralPath $environmentPath -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath $environmentPath -Value $previous[$name] }
        }
    }
}

function Get-AipGitApplication {
    $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Path
}

function Invoke-AipGit {
    $application = Get-AipGitApplication
    if (-not $application) { $global:LASTEXITCODE = 127; return }
    & $application @args
}

function Get-AipFileLinkCount {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if ($IsWindows) {
        $fsutil = Join-Path $env:SystemRoot 'System32/fsutil.exe'
        $links = & $fsutil hardlink list $LiteralPath 2>$null
        if ($LASTEXITCODE -ne 0) { throw "could not inspect hard links for $LiteralPath" }
        return @($links | Where-Object { $_ }).Count
    }
    $stat = (Get-Command stat -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    $count = & $stat -c '%h' $LiteralPath 2>$null
    if ($LASTEXITCODE -ne 0) { $count = & $stat -f '%l' $LiteralPath 2>$null }
    if ($LASTEXITCODE -ne 0) { throw "could not inspect hard links for $LiteralPath" }
    return [int]$count
}

function Get-AipSshTransport {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $effective = $env:GIT_SSH_COMMAND
    if (-not $effective) {
        $configured = Invoke-AipGit -C $ProfilePath config --get core.sshCommand 2>$null
        if ($LASTEXITCODE -eq 0) { $effective = [string]$configured }
    }
    if (-not $effective -and $env:GIT_SSH) { $effective = '"' + $env:GIT_SSH + '"' }
    if (-not $effective) { $effective = 'ssh' }
    if ($effective -notmatch '^\s*("[^"]+"|''[^'']+''|\S+)(.*)$') { return $null }
    $commandPrefix = $Matches[1]
    $commandRemainder = $Matches[2]
    $executable = $commandPrefix
    if (($executable.StartsWith('"') -and $executable.EndsWith('"')) -or ($executable.StartsWith("'") -and $executable.EndsWith("'"))) {
        $executable = $executable.Substring(1, $executable.Length - 2)
    }

    $variant = $env:GIT_SSH_VARIANT
    if (-not $variant) {
        $configuredVariant = Invoke-AipGit -C $ProfilePath config --get ssh.variant 2>$null
        if ($LASTEXITCODE -eq 0) { $variant = [string]$configuredVariant }
    }
    if (-not $variant -or $variant -ieq 'auto') {
        switch -Regex ([IO.Path]::GetFileName($executable).ToLowerInvariant()) {
            '^tortoiseplink(?:\.exe)?$' { $variant = 'tortoiseplink'; break }
            '^(?:plink|putty)(?:\.exe)?$' { $variant = 'plink'; break }
            default { $variant = 'ssh' }
        }
    }
    switch ($variant.ToLowerInvariant()) {
        { $_ -in 'plink', 'putty', 'tortoiseplink' } { $effective = "$commandPrefix -batch$commandRemainder"; break }
        'ssh' { $effective = "$commandPrefix -o BatchMode=yes$commandRemainder" }
        default { return $null }
    }
    return [pscustomobject]@{ Command = $effective; Variant = $variant }
}

function Test-AipGitMutationState {
    param([Parameter(Mandatory)][string]$ProfilePath, [switch]$Report)
    if (-not (Test-AipGitContainment $ProfilePath)) {
        if ($Report) { Write-AipError $script:AipGitContainmentError }
        return $false
    }
    foreach ($relative in 'FETCH_HEAD', 'ORIG_HEAD', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_START', 'index') {
        $path = Join-Path $ProfilePath ".git/$relative"
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))) {
            if ($Report) { Write-AipError "Git metadata path must be an ordinary file before remote sync: $path" }
            return $false
        }
    }
    $ownedLock = [IO.Path]::GetFullPath((Join-Path $ProfilePath '.git/aip-sync.lock'))
    $lockFile = Get-ChildItem -LiteralPath (Join-Path $ProfilePath '.git') -Force -Recurse -Filter '*.lock' -ErrorAction SilentlyContinue |
        Where-Object { [IO.Path]::GetFullPath($_.FullName) -ne $ownedLock } | Select-Object -First 1
    if ($null -ne $lockFile) {
        if ($Report) { Write-AipError "local Git operation is blocked by an existing lock file; inspect: $($lockFile.FullName)" }
        return $false
    }
    foreach ($path in (Join-Path $ProfilePath '.git'), (Join-Path $ProfilePath '.git/objects'), (Join-Path $ProfilePath '.git/refs')) {
        try {
            $probe = Join-Path $path ".aip-write-probe-$PID-$([guid]::NewGuid().ToString('N'))"
            [IO.File]::WriteAllBytes($probe, [byte[]]@())
            Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        }
        catch {
            if ($Report) { Write-AipError "Git metadata is not writable for remote sync: $path" }
            return $false
        }
    }
    Invoke-AipGit -C $ProfilePath status --porcelain *> $null
    if ($LASTEXITCODE -ne 0) {
        if ($Report) { Write-AipError "local Git repository became unreadable during remote sync: $ProfilePath" }
        return $false
    }
    Invoke-AipGit -C $ProfilePath fsck --connectivity-only --no-dangling *> $null
    if ($LASTEXITCODE -ne 0) {
        if ($Report) { Write-AipError "local Git repository failed its integrity check during remote sync: $ProfilePath" }
        return $false
    }
    return $true
}

function Test-AipGitContainment {
    param([Parameter(Mandatory)][string]$ProfilePath, [switch]$Report)
    $script:AipGitContainmentError = $null
    $top = Invoke-AipGit -C $ProfilePath rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { $script:AipGitContainmentError = "Git repository is unreadable: $ProfilePath"; if ($Report) { Write-AipError $script:AipGitContainmentError }; return $false }
    $gitDirectory = Invoke-AipGit -C $ProfilePath rev-parse --absolute-git-dir 2>$null
    if ($LASTEXITCODE -ne 0) { $script:AipGitContainmentError = "Git repository is unreadable: $ProfilePath"; if ($Report) { Write-AipError $script:AipGitContainmentError }; return $false }
    $commonDirectory = Invoke-AipGit -C $ProfilePath rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0) { $script:AipGitContainmentError = "Git repository is unreadable: $ProfilePath"; if ($Report) { Write-AipError $script:AipGitContainmentError }; return $false }
    $expectedTop = [IO.Path]::GetFullPath($ProfilePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $expectedGit = [IO.Path]::GetFullPath((Join-Path $ProfilePath '.git')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $actualTop = [IO.Path]::GetFullPath([string]$top).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $actualGit = [IO.Path]::GetFullPath([string]$gitDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $actualCommon = if ([IO.Path]::IsPathRooted([string]$commonDirectory)) {
        [IO.Path]::GetFullPath([string]$commonDirectory)
    }
    else { [IO.Path]::GetFullPath((Join-Path $ProfilePath ([string]$commonDirectory))) }
    $actualCommon = $actualCommon.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($actualTop -ne $expectedTop -or $actualGit -ne $expectedGit -or $actualCommon -ne $expectedGit) {
        $script:AipGitContainmentError = 'Git repository routing escapes the profiles repository; remove core.worktree or external Git routing'
        if ($Report) { Write-AipError $script:AipGitContainmentError }
        return $false
    }
    $linkedMetadata = Get-ChildItem -LiteralPath (Join-Path $ProfilePath '.git') -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) } | Select-Object -First 1
    if ($null -ne $linkedMetadata) {
        $script:AipGitContainmentError = "Git metadata contains a symbolic link or reparse point; remove or repair: $($linkedMetadata.FullName)"
        if ($Report) { Write-AipError $script:AipGitContainmentError }
        return $false
    }
    try {
        $objectsPrefix = [IO.Path]::GetFullPath((Join-Path $ProfilePath '.git/objects')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $hardlinkedMetadata = Get-ChildItem -LiteralPath (Join-Path $ProfilePath '.git') -Force -Recurse -File -ErrorAction Stop |
            Where-Object { -not $_.FullName.StartsWith($objectsPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Get-AipFileLinkCount $_.FullName) -gt 1 } |
            Select-Object -First 1
    }
    catch {
        $script:AipGitContainmentError = "Git metadata hard links could not be inspected: $(Join-Path $ProfilePath '.git')"
        if ($Report) { Write-AipError $script:AipGitContainmentError }
        return $false
    }
    if ($null -ne $hardlinkedMetadata) {
        $script:AipGitContainmentError = "Git metadata contains a hard-linked mutable file; replace it with an independent copy: $($hardlinkedMetadata.FullName)"
        if ($Report) { Write-AipError $script:AipGitContainmentError }
        return $false
    }
    foreach ($alternate in '.git/objects/info/alternates', '.git/objects/info/http-alternates') {
        $alternatePath = Join-Path $ProfilePath $alternate
        if ($null -ne (Get-Item -LiteralPath $alternatePath -Force -ErrorAction SilentlyContinue)) {
            $script:AipGitContainmentError = "Git object alternates escape the profiles repository; remove: $alternatePath"
            if ($Report) { Write-AipError $script:AipGitContainmentError }
            return $false
        }
    }
    return $true
}

function Test-AipProfileName {
    param([AllowEmptyString()][string]$Name)
    if ($null -eq $Name -or -not [regex]::IsMatch($Name, '^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$')) { return $false }
    return $Name -notmatch '^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$'
}

function Test-AipOutfit {
    param([AllowEmptyString()][string]$Outfit)
    if ([string]::IsNullOrEmpty($Outfit)) { return $false }
    $scalarCount = 0
    $characters = $Outfit.ToCharArray()
    for ($index = 0; $index -lt $characters.Length; $index++) {
        $character = $characters[$index]
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $characters.Length -or -not [char]::IsLowSurrogate($characters[$index + 1])) { return $false }
            $index++
        }
        elseif ([char]::IsLowSurrogate($character)) { return $false }
        $scalarCount++
        if ($scalarCount -gt 64) { return $false }
        if ([char]::IsControl($character)) { return $false }
    }
    return $true
}

function Test-AipUtf8TextFile {
    param([Parameter(Mandatory)][string]$LiteralPath)
    try {
        $bytes = [IO.File]::ReadAllBytes($LiteralPath)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return $text.IndexOf([char]0) -lt 0
    }
    catch { return $false }
}

function Set-AipUtf8LfFile {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    [IO.File]::WriteAllText($LiteralPath, (($Lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-AipUtf8TextFile {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

function ConvertFrom-AipOutfitText {
    param([AllowEmptyString()][string]$Text)
    if ($Text.EndsWith("`n")) {
        $Text = $Text.Substring(0, $Text.Length - 1)
        if ($Text.EndsWith("`r")) { $Text = $Text.Substring(0, $Text.Length - 1) }
    }
    if ($Text.Contains("`n") -or $Text.Contains("`r")) { return $null }
    return $Text
}

function Export-AipGitBlob {
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$ObjectSpec,
        [Parameter(Mandatory)][string]$Destination
    )
    $application = Get-AipGitApplication
    if (-not $application) { return $false }
    $process = [Diagnostics.Process]::new()
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $application
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $ProfilePath, 'cat-file', 'blob', $ObjectSpec)) { [void]$start.ArgumentList.Add($argument) }
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { return $false }
        $destinationStream = [IO.File]::Create($Destination)
        try { $process.StandardOutput.BaseStream.CopyTo($destinationStream) }
        finally { $destinationStream.Dispose() }
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return $process.ExitCode -eq 0
    }
    catch { return $false }
    finally { $process.Dispose() }
}

function ConvertTo-AipTomlString {
    param([AllowEmptyString()][string]$Value)
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $characters = $Value.ToCharArray()
    for ($index = 0; $index -lt $characters.Length; $index++) {
        $character = $characters[$index]
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $characters.Length -or -not [char]::IsLowSurrogate($characters[$index + 1])) {
                throw 'Codex instructions contain an invalid Unicode surrogate'
            }
            [void]$builder.Append($character)
            $index++
            [void]$builder.Append($characters[$index])
            continue
        }
        if ([char]::IsLowSurrogate($character)) { throw 'Codex instructions contain an invalid Unicode surrogate' }
        $code = [int]$character
        switch ($code) {
            8 { [void]$builder.Append('\b') }
            9 { [void]$builder.Append('\t') }
            10 { [void]$builder.Append('\n') }
            12 { [void]$builder.Append('\f') }
            13 { [void]$builder.Append('\r') }
            34 { [void]$builder.Append('\"') }
            92 { [void]$builder.Append('\\') }
            default {
                if ($code -lt 32 -or $code -eq 127) { throw 'Codex instructions contain a control character that TOML cannot represent safely' }
                [void]$builder.Append($character)
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-AipProfilePath {
    param([Parameter(Mandatory)][string]$Name)
    return Join-Path $script:AipProfileRoot $Name
}

function Test-AipRootRepo {
    $rootItem = Get-Item -LiteralPath $script:AipProfileRoot -Force -ErrorAction SilentlyContinue
    $gitItem = if ($null -ne $rootItem) { Get-Item -LiteralPath (Join-Path $script:AipProfileRoot '.git') -Force -ErrorAction SilentlyContinue } else { $null }
    if ($null -eq $rootItem -or $null -eq $gitItem -or -not $gitItem.PSIsContainer -or $gitItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        Write-AipError "profiles directory is not a Git repository: $script:AipProfileRoot; run 'aip create NAME' or 'aip doctor'"
        $script:AipCommandStatus = 2
        return $false
    }
    return $true
}

function Get-AipProfileNames {
    $rootItem = Get-Item -LiteralPath $script:AipProfileRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem -or $rootItem -isnot [IO.DirectoryInfo]) { return @() }
    if ($rootItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        $rootItem = $rootItem.ResolveLinkTarget($true)
        if ($null -eq $rootItem -or $rootItem -isnot [IO.DirectoryInfo]) { return @() }
    }
    return @(Get-ChildItem -LiteralPath $rootItem.FullName -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.PSIsContainer -and $null -eq $_.LinkType -and -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -and
            (Test-AipProfileName $_.Name) -and
            ($null -ne (Get-Item -LiteralPath (Join-Path $_.FullName '.aip/outfit') -Force -ErrorAction SilentlyContinue))
    } | Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-AipRootGitIgnoreLines {
    return @('# aip-managed root exclusions', '.default', '.aip-*/')
}

function Invoke-AipEnsureRootRepo {
    $root = $script:AipProfileRoot
    try { New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null }
    catch { Write-AipError "could not create the profiles directory: $($_.Exception.Message)"; $script:AipCommandStatus = 1; return $false }
    $gitItem = Get-Item -LiteralPath (Join-Path $root '.git') -Force -ErrorAction SilentlyContinue
    if ($null -ne $gitItem -and $gitItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        Write-AipError "profiles repository metadata must not be a symbolic link or reparse point: $(Join-Path $root '.git')"
        $script:AipCommandStatus = 1
        return $false
    }
    if ($null -eq $gitItem) {
        Invoke-AipGit -C $root init -q -b main
        if ($LASTEXITCODE -ne 0) { Write-AipError 'could not initialise the profiles repository'; $script:AipCommandStatus = 1; return $false }
        Invoke-AipGit -C $root config core.symlinks true
        if ($LASTEXITCODE -ne 0) { Write-AipError 'could not configure symbolic-link checkout'; $script:AipCommandStatus = 1; return $false }
        Invoke-AipGit -C $root config core.longpaths true
        if ($LASTEXITCODE -ne 0) { Write-AipError 'could not configure long-path support'; $script:AipCommandStatus = 1; return $false }
    }
    Invoke-AipGit -C $root var GIT_AUTHOR_IDENT *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-AipError "configure Git identity with 'git config --global user.name NAME' and 'git config --global user.email EMAIL'"
        $script:AipCommandStatus = 1
        return $false
    }
    $gitignorePath = Join-Path $root '.gitignore'
    if ($null -eq (Get-Item -LiteralPath $gitignorePath -Force -ErrorAction SilentlyContinue)) {
        Set-AipUtf8LfFile $gitignorePath @(Get-AipRootGitIgnoreLines)
    }
    return $true
}

function Get-AipNameFile {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { return $null }
    if (-not (Test-AipUtf8TextFile $LiteralPath)) { return $null }
    $value = Get-AipUtf8TextFile $LiteralPath
    $value = $value -replace '\r?\n\z', ''
    if ($value -match '[\r\n]' -or -not (Test-AipProfileName $value)) { return $null }
    return $value
}

function Test-AipProfileExists {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if (-not (Test-AipProfileName $Name)) {
        Write-AipError "invalid profile name '$Name'"
        $script:AipCommandStatus = 2
        return $false
    }
    $profilePath = Get-AipProfilePath $Name
    $profileItem = Get-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
    if ($null -eq $profileItem -or -not $profileItem.PSIsContainer) {
        Write-AipError "profile '$Name' does not exist"
        $script:AipCommandStatus = 2
        return $false
    }
    if ($profileItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        Write-AipError "profile '$Name' path must not be a symbolic link or reparse point"
        $script:AipCommandStatus = 2
        return $false
    }
    return Test-AipRootRepo
}

function Find-AipProjectMarker {
    $directory = [System.IO.DirectoryInfo](Get-Location).ProviderPath
    while ($null -ne $directory) {
        $marker = Join-Path $directory.FullName '.aip-profile'
        if ($null -ne (Get-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ Path = $marker; Name = (Get-AipNameFile $marker) }
        }
        $directory = $directory.Parent
    }
    return $null
}

function Resolve-AipProfile {
    param([AllowEmptyString()][string]$ExplicitName = '', [bool]$ExplicitNameSupplied = $false)

    if ($ExplicitNameSupplied) {
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
    if ($null -ne (Get-Item -LiteralPath $defaultPath -Force -ErrorAction SilentlyContinue)) {
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
        '.netrc', '.npmrc', '.pypirc', 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'node_modules/',
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
    Set-AipUtf8LfFile (Join-Path $ProfilePath '.aip/outfit') @($Outfit)
    New-Item -ItemType File -Path (Join-Path $ProfilePath 'skills/.gitkeep') -ErrorAction Stop | Out-Null
    Set-AipUtf8LfFile (Join-Path $ProfilePath 'AGENTS.md') @('# Common profile instructions')
    Set-AipUtf8LfFile (Join-Path $ProfilePath 'claude/CLAUDE.md') @('@../AGENTS.md', '', '# Claude Code instructions')
    Set-AipUtf8LfFile (Join-Path $ProfilePath 'codex/instructions.md') @('# Codex instructions')
    Set-AipUtf8LfFile (Join-Path $ProfilePath 'pi/APPEND_SYSTEM.md') @('# Pi instructions')
    Set-AipUtf8LfFile (Join-Path $ProfilePath '.gitignore') @(Get-AipGitIgnoreLines)

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

function Get-AipTemporaryName {
    return [IO.Path]::GetRandomFileName()
}

function New-AipOwnedTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Prefix)
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidate = Join-Path $script:AipProfileRoot ('.aip-{0}-{1}' -f $Prefix, (Get-AipTemporaryName))
        try {
            New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
            return $candidate
        }
        catch {
            if ($null -eq (Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue)) { throw }
        }
    }
    throw 'could not allocate a unique temporary profile directory'
}

function Test-AipPathEntry {
    param([Parameter(Mandatory)][string]$LiteralPath)
    return $null -ne (Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue)
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
    if (-not (Get-AipGitApplication)) { Write-AipError 'Git is required'; return }
    $destination = Get-AipProfilePath $name
    if (Test-AipPathEntry $destination) { Write-AipError "destination already exists: $destination"; return }
    if (-not (Invoke-AipEnsureRootRepo)) { return }
    if (-not (Test-AipGitContainment $script:AipProfileRoot -Report)) { return }
    $temporary = $null
    try {
        $temporary = New-AipOwnedTemporaryDirectory $name
        New-AipProfileFiles $temporary $outfit
        [IO.Directory]::Move($temporary, $destination)
        $temporary = $null
    }
    catch {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        if ($_.Exception.Message -match 'symbolic|privilege') {
            Write-AipError 'could not create symbolic links; enable Windows Developer Mode and try again'
        }
        else { Write-AipError "could not create profile '$name': $($_.Exception.Message)" }
        return
    }
    Invoke-AipGit -C $script:AipProfileRoot add .gitignore $name
    if ($LASTEXITCODE -ne 0) { Write-AipError "could not commit profile '$name'; check Git identity and hooks"; return }
    Invoke-AipGit -C $script:AipProfileRoot diff --cached --quiet --
    if ($LASTEXITCODE -ne 0) {
        Invoke-AipGit -C $script:AipProfileRoot commit -q -m 'aip: create profile'
        if ($LASTEXITCODE -ne 0) { Write-AipError "could not commit profile '$name'; check Git identity and hooks"; return }
    }
    Write-Output "Created profile '$name' at $destination"
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
    if (-not (Test-AipGitContainment $script:AipProfileRoot -Report)) { return }
    $targetPath = Get-AipProfilePath $targetName
    if (Test-AipPathEntry $targetPath) { Write-AipError "destination already exists: $targetPath"; return }
    # Capture the source profile's committed executable paths before the sync
    # checkpoint can re-stage files from disk (where the executable bit may
    # differ, and never exists on platforms without file modes such as Windows).
    $executablePaths = [System.Collections.Generic.List[string]]::new()
    $sourceListing = [string](Invoke-AipGit -C $script:AipProfileRoot ls-files -s -z -- (Join-Path $sourceName ''))
    if ($LASTEXITCODE -ne 0) { Write-AipError "could not clone profile '$sourceName'"; return }
    foreach ($record in @($sourceListing -split "`0")) {
        if ($record -eq '') { continue }
        $tabIndex = $record.IndexOf([char]9)
        if ($tabIndex -lt 0 -or -not $record.Substring(0, $tabIndex).StartsWith('100755')) { continue }
        $executablePaths.Add($record.Substring($tabIndex + 1))
    }
    Invoke-AipSync 'clone'
    if ($script:AipCommandStatus -ne 0) { return }

    $temporary = $null
    $tarball = [IO.Path]::GetTempFileName()
    try {
        $temporary = New-AipOwnedTemporaryDirectory $targetName
        Invoke-AipGit -C $script:AipProfileRoot archive -o $tarball HEAD $sourceName
        if ($LASTEXITCODE -ne 0) { throw 'could not archive the tracked source profile' }
        & tar -xf $tarball --strip-components=1 -C $temporary
        if ($LASTEXITCODE -ne 0) { throw 'could not extract the archived profile' }
        $layoutResult = @(Test-AipLayout $temporary)
        if (-not [bool]$layoutResult[-1]) { throw 'cloned profile layout is invalid' }
        [IO.Directory]::Move($temporary, $targetPath)
        $temporary = $null
    }
    catch {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        Remove-Item -LiteralPath $tarball -Force -ErrorAction SilentlyContinue
        Write-AipError "could not clone profile '$sourceName': $($_.Exception.Message)"
        return
    }
    Remove-Item -LiteralPath $tarball -Force -ErrorAction SilentlyContinue
    Invoke-AipGit -C $script:AipProfileRoot add $targetName
    if ($LASTEXITCODE -ne 0) { Write-AipError "could not commit clone of profile '$sourceName'; check Git identity and hooks"; return }
    # Executable bits do not survive tar extraction on platforms without file modes
    # (e.g. Windows); restore them from the source profile's committed modes.
    foreach ($trackedPath in $executablePaths) {
        Invoke-AipGit -C $script:AipProfileRoot update-index --add --chmod=+x -- (Join-Path $targetName $trackedPath.Substring($sourceName.Length + 1))
        if ($LASTEXITCODE -ne 0) { Write-AipError "could not commit clone of profile '$sourceName'; check Git identity and hooks"; return }
    }
    Invoke-AipGit -C $script:AipProfileRoot diff --cached --quiet --
    if ($LASTEXITCODE -ne 0) {
        Invoke-AipGit -C $script:AipProfileRoot commit -q -m "aip: clone $sourceName"
        if ($LASTEXITCODE -ne 0) { Write-AipError "could not commit clone of profile '$sourceName'; check Git identity and hooks"; return }
    }
    Write-Output "Cloned profile '$sourceName' to '$targetName' at $targetPath"
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
    if (-not (Test-AipGitContainment $script:AipProfileRoot -Report)) { return }
    if ($env:AIP_PROFILE -eq $name) { Write-AipError "cannot delete session profile '$name'; select another profile first"; return }
    $rootFull = [IO.Path]::GetFullPath($script:AipProfileRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $parentFull = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($profilePath)).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($rootFull -ne $parentFull) { Write-AipError 'refusing to delete a profile outside the profile root'; return }

    $risks = @()
    $changes = Invoke-AipGit -C $script:AipProfileRoot status --porcelain -- $name 2>$null
    if ($LASTEXITCODE -ne 0) { $risks += 'working-tree state could not be inspected' }
    elseif ($changes) { $risks += 'uncommitted changes' }
    if (Test-AipUnfinishedGitOperation $script:AipProfileRoot) { $risks += 'unfinished Git operation' }
    Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify '@{upstream}' *> $null
    $fullyRecoverable = $false
    if ($LASTEXITCODE -eq 0) {
        $unpushed = Invoke-AipGit -C $script:AipProfileRoot rev-list --branches --not --remotes 2>$null
        if ($LASTEXITCODE -ne 0) { $risks += 'commit reachability could not be inspected' }
        elseif ($unpushed) { $risks += 'unpushed commits on local branches' }
        Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify refs/stash *> $null
        if ($LASTEXITCODE -eq 0) { $risks += 'stashed changes' }
        $tags = Invoke-AipGit -C $script:AipProfileRoot for-each-ref '--format=%(refname)' refs/tags 2>$null
        if ($LASTEXITCODE -ne 0) { $risks += 'tags could not be inspected' }
        elseif ($tags) { $risks += 'local tags' }
        if ($risks.Count -eq 0) { $fullyRecoverable = $true }
    }
    else { $risks += 'unpushed commits (no upstream)' }

    if (-not $force) {
        $riskText = if ($risks.Count) { ' (' + ($risks -join ', ') + ')' } else { '' }
        if ([Console]::IsInputRedirected) {
            Write-AipError "deletion requires confirmation$riskText; rerun with --force for non-interactive use"
            return
        }
        try { $answer = Read-Host "Delete profile '$name' at $profilePath$riskText? Type yes" }
        catch {
            Write-AipError "deletion requires confirmation$riskText; rerun with --force for non-interactive use"
            return
        }
        if ($answer -ne 'yes') { Write-AipError 'deletion cancelled; rerun with --force for non-interactive use'; return }
    }
    $defaultPath = Join-Path $script:AipProfileRoot '.default'
    $defaultName = Get-AipNameFile $defaultPath
    try {
        Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction Stop
        if (Test-AipPathEntry $profilePath) { throw 'the profile path still exists after deletion' }
        if ($defaultName -eq $name) { Remove-Item -LiteralPath $defaultPath -Force -ErrorAction Stop }
    }
    catch {
        Write-AipError "could not completely delete profile '$name': $($_.Exception.Message)"
        return
    }
    try {
        Invoke-AipGit -C $script:AipProfileRoot add -u -- $name 2>$null
        if ($LASTEXITCODE -eq 0) {
            Invoke-AipGit -C $script:AipProfileRoot diff --cached --quiet -- 2>$null
            if ($LASTEXITCODE -ne 0) {
                Invoke-AipGit -C $script:AipProfileRoot commit -q -m "aip: delete profile $name" 2>$null
                if ($LASTEXITCODE -ne 0) { Write-AipError 'deletion is complete, but its commit failed; check the profiles repository and commit the removal manually'; $script:AipCommandStatus = 0 }
            }
        }
        else { Write-AipError 'deletion is complete, but the profiles repository could not stage the removal; inspect it and commit manually'; $script:AipCommandStatus = 0 }
    }
    catch {
        Write-AipError 'deletion is complete, but the profiles repository could not stage the removal; inspect it and commit manually'
        $script:AipCommandStatus = 0
    }
    if ($fullyRecoverable) { Write-Output "Deleted $profilePath; its committed content is recoverable from the configured Git upstream." }
    else { Write-Output "Deleted $profilePath; no complete remote recovery is available; local or unpushed changes were removed." }
}

function Test-AipProfileReparsePoints {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $script:AipProfileBoundaryError = $null
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in 'claude/skills', 'codex/AGENTS.md', 'codex/skills', 'pi/AGENTS.md', 'pi/skills', 'opencode/AGENTS.md', 'opencode/skills') { [void]$required.Add($relative) }
    $gitPath = [IO.Path]::GetFullPath((Join-Path $ProfilePath '.git'))
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($ProfilePath)
    try {
        while ($pending.Count) {
            $directory = $pending.Pop()
            foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
                if ([IO.Path]::GetFullPath($item.FullName) -eq $gitPath) { continue }
                $relative = [IO.Path]::GetRelativePath($ProfilePath, $item.FullName).Replace('\', '/')
                if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
                    if ($item.LinkType -ne 'SymbolicLink' -or -not $required.Contains($relative)) {
                        $script:AipProfileBoundaryError = "profile contains an unsupported symbolic link, junction, or mount that could escape its boundary: $relative"
                        return $false
                    }
                    continue
                }
                if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            }
        }
    }
    catch {
        $script:AipProfileBoundaryError = "profile paths could not be inspected safely: $($_.Exception.Message)"
        return $false
    }
    return $true
}

function Test-AipLayout {
    param([Parameter(Mandatory)][string]$ProfilePath, [switch]$Report, [switch]$IgnoreOutfitContent)
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
        # On Windows, .Target reports relative links with backslashes; normalize
        # to the forward-slash form aip stores and validates.
        $target = if ($null -ne $item) { ([string]$item.Target).Replace('\', '/') } else { '' }
        if ($null -eq $item -or $item.LinkType -ne 'SymbolicLink' -or $target -ne $link.Value) {
            if ($Report) { Write-Output "ERROR: $($link.Key) should link to $($link.Value)" }
            if ($Report) { Write-Output "FIX: enable Windows Developer Mode, remove the broken item, then run New-Item -ItemType SymbolicLink -Path '$literalPath' -Target '$($link.Value)'" }
            $valid = $false
        }
    }
    if (-not (Test-AipProfileReparsePoints $ProfilePath)) {
        if ($Report) { Write-Output "ERROR: $script:AipProfileBoundaryError" }
        $valid = $false
    }
    $profileItem = Get-Item -LiteralPath $ProfilePath -Force -ErrorAction SilentlyContinue
    if ($null -eq $profileItem -or -not $profileItem.PSIsContainer -or $profileItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        if ($Report) { Write-Output 'ERROR: profile path must be an ordinary directory' }
        $valid = $false
    }
    foreach ($directory in '.aip', 'skills', 'claude', 'codex', 'pi', 'opencode') {
        $item = Get-Item -LiteralPath (Join-Path $ProfilePath $directory) -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or -not $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            if ($Report) { Write-Output "ERROR: required directory is missing or linked: $directory" }
            $valid = $false
        }
    }
    foreach ($file in '.aip/outfit', '.gitignore', 'AGENTS.md', 'skills/.gitkeep', 'claude/CLAUDE.md', 'codex/instructions.md', 'pi/APPEND_SYSTEM.md') {
        $item = Get-Item -LiteralPath (Join-Path $ProfilePath $file) -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            if ($Report) { Write-Output "ERROR: required file is missing or linked: $file" }
            $valid = $false
        }
    }
    foreach ($file in '.aip/outfit', '.gitignore', 'AGENTS.md', 'skills/.gitkeep', 'claude/CLAUDE.md', 'codex/instructions.md', 'pi/APPEND_SYSTEM.md') {
        if ($IgnoreOutfitContent -and $file -eq '.aip/outfit') { continue }
        if (-not (Test-AipUtf8TextFile (Join-Path $ProfilePath $file))) {
            if ($Report) { Write-Output "ERROR: required profile text is not valid NUL-free UTF-8: $file" }
            $valid = $false
        }
    }
    $placeholderPath = Join-Path $ProfilePath 'skills/.gitkeep'
    if ((Get-Item -LiteralPath $placeholderPath -Force -ErrorAction SilentlyContinue).Length -ne 0) {
        if ($Report) { Write-Output 'ERROR: skills/.gitkeep placeholder must be empty' }
        $valid = $false
    }
    if (-not $IgnoreOutfitContent) {
        $outfit = if (Test-AipUtf8TextFile (Join-Path $ProfilePath '.aip/outfit')) {
            ConvertFrom-AipOutfitText (Get-AipUtf8TextFile (Join-Path $ProfilePath '.aip/outfit'))
        }
        else { $null }
        if (-not (Test-AipOutfit $outfit)) {
            if ($Report) { Write-Output 'ERROR: profile outfit is empty, invalid, or longer than 64 characters' }
            $valid = $false
        }
    }
    $claudeInstructions = Join-Path $ProfilePath 'claude/CLAUDE.md'
    if ((Get-Content -LiteralPath $claudeInstructions -TotalCount 1 -ErrorAction SilentlyContinue) -ne '@../AGENTS.md') {
        if ($Report) { Write-Output 'ERROR: claude/CLAUDE.md must begin with @../AGENTS.md' }
        $valid = $false
    }
    return $valid
}

function Add-AipSkillsPlaceholder {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $profileItem = Get-Item -LiteralPath $ProfilePath -Force -ErrorAction SilentlyContinue
    $skillsItem = Get-Item -LiteralPath (Join-Path $ProfilePath 'skills') -Force -ErrorAction SilentlyContinue
    foreach ($item in $profileItem, $skillsItem) {
        if ($null -eq $item -or -not $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            Write-AipError 'profile and skills paths must be ordinary directories'
            return $false
        }
    }
    $placeholderPath = Join-Path $ProfilePath 'skills/.gitkeep'
    $placeholder = Get-Item -LiteralPath $placeholderPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $placeholder) {
        if ($placeholder.PSIsContainer -or $placeholder.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            Write-AipError 'skills/.gitkeep must be an ordinary file'
            return $false
        }
    }
    else {
        New-Item -ItemType File -Path $placeholderPath -ErrorAction Stop | Out-Null
    }
    return $true
}

function Resolve-AipDoctorProfile {
    param([AllowEmptyString()][string]$ExplicitName = '', [bool]$ExplicitNameSupplied = $false)
    if ($ExplicitNameSupplied) { $name = $ExplicitName }
    elseif ($env:AIP_PROFILE) { $name = $env:AIP_PROFILE }
    else {
        $project = Find-AipProjectMarker
        if ($null -ne $project) {
            if (-not $project.Name) { Write-AipError "invalid project marker '$($project.Path)'"; $script:AipCommandStatus = 2; return $null }
            $name = $project.Name
        }
        else {
            $defaultPath = Join-Path $script:AipProfileRoot '.default'
            $name = Get-AipNameFile $defaultPath
            if (-not $name) { Write-AipError "no profile selected; run 'aip create NAME' then 'aip use NAME'"; $script:AipCommandStatus = 2; return $null }
        }
    }
    if (-not (Test-AipProfileName $name)) { Write-AipError "invalid profile name '$name'"; $script:AipCommandStatus = 2; return $null }
    $path = Get-AipProfilePath $name
    if ($null -eq (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) { Write-AipError "profile '$name' does not exist"; $script:AipCommandStatus = 2; return $null }
    return [pscustomobject]@{ Name = $name; Path = $path }
}

function Invoke-AipDoctor {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 1) { Write-AipError 'usage: aip doctor [NAME]'; $script:AipCommandStatus = 2; return }
    $explicit = if ($Arguments.Count) { [string]$Arguments[0] } else { '' }
    $profile = Resolve-AipDoctorProfile $explicit ($Arguments.Count -eq 1)
    if ($null -eq $profile) { return }
    $errors = 0
    $repoOk = $true
    $profileItem = Get-Item -LiteralPath $profile.Path -Force
    $safeProfile = $profileItem.PSIsContainer -and -not $profileItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
    if (-not $safeProfile) { Write-Output 'ERROR: profile path must be an ordinary directory'; $errors++ }

    $rootGitItem = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot '.git') -Force -ErrorAction SilentlyContinue
    $rootExists = $null -ne (Get-Item -LiteralPath $script:AipProfileRoot -Force -ErrorAction SilentlyContinue)
    $repoReadable = $rootExists -and $null -ne $rootGitItem -and $rootGitItem.PSIsContainer -and -not $rootGitItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
    if (-not $repoReadable) {
        Write-Output "ERROR: profiles repository metadata is missing or linked: $(Join-Path $script:AipProfileRoot '.git')"
        Write-Output 'FIX: restore an ordinary .git directory at the profiles root'
        $errors++
        $repoOk = $false
    }
    $gitAvailable = $null -ne (Get-AipGitApplication)
    if (-not $gitAvailable) {
        Write-Output 'ERROR: Git was not found'
        $errors++
        $repoOk = $false
    }
    elseif ($repoReadable) {
        if (-not (Test-AipGitContainment $script:AipProfileRoot)) {
            Write-Output "ERROR: $script:AipGitContainmentError"
            $errors++
            $repoReadable = $false
            $repoOk = $false
        }
    }
    if ($gitAvailable -and $repoReadable) {
        Invoke-AipGit -C $script:AipProfileRoot var GIT_AUTHOR_IDENT *> $null
        if ($LASTEXITCODE -ne 0) { Write-Output "ERROR: configure Git identity with 'git config --global user.name NAME' and 'git config --global user.email EMAIL'"; $errors++; $repoOk = $false }
        Invoke-AipGit -C $script:AipProfileRoot status --porcelain *> $null
        if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: profiles Git repository is unreadable'; $errors++; $repoOk = $false }
        $symlinkMode = Invoke-AipGit -C $script:AipProfileRoot config --bool core.symlinks 2>$null
        if ($LASTEXITCODE -eq 0 -and $symlinkMode -eq 'false') {
            Write-Output 'ERROR: Git symbolic-link checkout is disabled'
            Write-Output "FIX: git -C '$($script:AipProfileRoot)' config core.symlinks true, then re-clone the profiles repository"
            $errors++
            $repoOk = $false
        }
        $branch = Invoke-AipGit -C $script:AipProfileRoot branch --show-current 2>$null
        if ($LASTEXITCODE -eq 0 -and $branch) {
            $configuredRemote = Invoke-AipGit -C $script:AipProfileRoot config --get "branch.$branch.remote" 2>$null
            if ($LASTEXITCODE -ne 0) { $configuredRemote = '' }
            $configuredMerge = Invoke-AipGit -C $script:AipProfileRoot config --get "branch.$branch.merge" 2>$null
            if ($LASTEXITCODE -ne 0) { $configuredMerge = '' }
            if (($configuredRemote -or $configuredMerge)) {
                Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify '@{upstream}' *> $null
                if ($LASTEXITCODE -ne 0) {
                    Write-Output 'ERROR: the configured Git upstream cannot be resolved'
                    Write-Output "FIX: repair or fetch the configured remote branch, or run 'git -C `"$($script:AipProfileRoot)`" branch --unset-upstream'"
                    $errors++
                    $repoOk = $false
                }
            }
        }
    }

    foreach ($name in (@(Get-AipProfileNames) + @($profile.Name)) | Where-Object { $_ } | Select-Object -Unique) {
        $profilePath = Get-AipProfilePath $name
        $item = Get-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or -not $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { continue }
        $layoutResult = @(Test-AipLayout $profilePath -Report)
        if ($layoutResult.Count -gt 1) { $layoutResult[0..($layoutResult.Count - 2)] | Write-Output }
        if (-not [bool]$layoutResult[-1]) { $errors++ }
        else { Write-Output "OK: profile layout and links ($name)" }
    }

    if ($gitAvailable -and $repoReadable) {
        if (-not (Test-AipTrackedPathsSafe $script:AipProfileRoot)) {
            Write-Output 'ERROR: tracked profile path validation failed; see the diagnostic above'
            $errors++
        }
        $unmerged = Invoke-AipGit -C $script:AipProfileRoot diff --name-only --diff-filter=U 2>$null
        if ((Test-AipUnfinishedGitOperation $script:AipProfileRoot) -or $unmerged) {
            Write-Output "ERROR: Git conflict or unfinished operation; run 'git -C `"$($script:AipProfileRoot)`" status', resolve files, then use 'git rebase --continue' or 'git rebase --abort'"
            $errors++
        }
    }
    $lockPath = Join-Path $script:AipProfileRoot '.git/aip-sync.lock'
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
    if ($repoOk) { Write-Output 'OK: profiles repository' }
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
    $relative = $RelativePath.Replace('\', '/').ToLowerInvariant()
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
        '.netrc' { return $true }
        '*/.netrc' { return $true }
        '.npmrc' { return $true }
        '*/.npmrc' { return $true }
        '.pypirc' { return $true }
        '*/.pypirc' { return $true }
        'id_rsa' { return $true }
        '*/id_rsa' { return $true }
        'id_dsa' { return $true }
        '*/id_dsa' { return $true }
        'id_ecdsa' { return $true }
        '*/id_ecdsa' { return $true }
        'id_ed25519' { return $true }
        '*/id_ed25519' { return $true }
        'claude/.credentials.json' { return $true }
        'claude/history.jsonl' { return $true }
        'claude/projects' { return $true }
        'claude/projects/*' { return $true }
        'claude/session-env' { return $true }
        'claude/session-env/*' { return $true }
        'claude/shell-snapshots' { return $true }
        'claude/shell-snapshots/*' { return $true }
        'claude/statsig' { return $true }
        'claude/statsig/*' { return $true }
        'claude/todos' { return $true }
        'claude/todos/*' { return $true }
        'claude/debug' { return $true }
        'claude/debug/*' { return $true }
        'claude/cache' { return $true }
        'claude/cache/*' { return $true }
        'claude/logs' { return $true }
        'claude/logs/*' { return $true }
        'claude/file-history' { return $true }
        'claude/file-history/*' { return $true }
        'codex/auth.json' { return $true }
        'codex/history.jsonl' { return $true }
        'codex/sessions' { return $true }
        'codex/sessions/*' { return $true }
        'codex/archived_sessions' { return $true }
        'codex/archived_sessions/*' { return $true }
        'codex/log' { return $true }
        'codex/log/*' { return $true }
        'codex/logs' { return $true }
        'codex/logs/*' { return $true }
        'codex/cache' { return $true }
        'codex/cache/*' { return $true }
        'codex/*.db' { return $true }
        'codex/*.db-*' { return $true }
        'codex/*.sqlite' { return $true }
        'codex/*.sqlite-*' { return $true }
        'pi/auth.json' { return $true }
        'pi/sessions' { return $true }
        'pi/sessions/*' { return $true }
        'pi/logs' { return $true }
        'pi/logs/*' { return $true }
        'pi/cache' { return $true }
        'pi/cache/*' { return $true }
        'opencode/auth.json' { return $true }
        'opencode/sessions' { return $true }
        'opencode/sessions/*' { return $true }
        'opencode/logs' { return $true }
        'opencode/logs/*' { return $true }
        'opencode/cache' { return $true }
        'opencode/cache/*' { return $true }
        'node_modules' { return $true }
        'node_modules/*' { return $true }
        '*/node_modules' { return $true }
        '*/node_modules/*' { return $true }
        default { return $false }
    }
}

function Test-AipPortablePaths {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelativePaths, [Parameter(Mandatory)][string]$Context)
    $spellings = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $RelativePaths) {
        if ([string]::IsNullOrEmpty($relative)) { continue }
        $prefix = ''
        if ($relative.Contains('\')) {
            Write-AipError "$Context contains a path that is not portable to Windows: $relative"
            return $false
        }
        foreach ($component in $relative.Split('/')) {
            $invalidCharacter = $false
            foreach ($character in $component.ToCharArray()) {
                $code = [int]$character
                if ($code -lt 32 -or $code -gt 126 -or '<>:"\|?*'.Contains($character)) { $invalidCharacter = $true; break }
            }
            $baseName = ($component -split '\.', 2)[0]
            if ([string]::IsNullOrEmpty($component) -or $invalidCharacter -or $component -ieq '.git' -or $component.EndsWith('.') -or $component.EndsWith(' ') -or
                $baseName -match '^(?:con|prn|aux|nul|com[1-9]|lpt[1-9]|conin\$|conout\$)$') {
                Write-AipError "$Context contains a path that is not portable to Windows: $relative"
                return $false
            }
            $prefix = if ($prefix) { "$prefix/$component" } else { $component }
            $existing = ''
            if ($spellings.TryGetValue($prefix, [ref]$existing)) {
                if ($existing -cne $prefix) {
                    Write-AipError "$Context contains case-colliding paths that are not portable to Windows: $existing and $prefix"
                    return $false
                }
            }
            else { $spellings[$prefix] = $prefix }
        }
    }
    return $true
}

function Get-AipTrackedProfilePrefixes {
    param([Parameter(Mandatory)][string[]]$Paths)
    $prefixes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in $Paths) {
        if ([string]::IsNullOrEmpty($relative)) { continue }
        $normalized = [string]$relative.Replace('\', '/')
        if ($normalized -like '*/.aip/outfit') { [void]$prefixes.Add($normalized.Split('/')[0]) }
    }
    return @($prefixes)
}

function Test-AipPathUnderProfile {
    param([Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][string[]]$ProfilePrefixes)
    $normalized = [string]$RelativePath.Replace('\', '/')
    $first = $normalized.Split('/')[0]
    if ($normalized -eq $first) { return $false }
    return @($ProfilePrefixes) -contains $first
}

function Test-AipTrackedPathsSafe {
    param([Parameter(Mandatory)][string]$Root)
    $raw = (Invoke-AipGit -C $Root ls-files -z) -join "`n"
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not inspect tracked profile paths'; return $false }
    $paths = @($raw -split "`0" | Where-Object { $_ })
    if (-not (Test-AipPortablePaths $paths 'tracked profile')) { return $false }
    $prefixes = Get-AipTrackedProfilePrefixes $paths
    foreach ($relative in $paths) {
        if ([string]::IsNullOrEmpty($relative)) { continue }
        $check = [string]$relative.Replace('\', '/')
        if (Test-AipPathUnderProfile $check $prefixes) { $check = $check.Substring($check.IndexOf('/') + 1) }
        if (Test-AipForbiddenPath $check) {
            Write-AipError "forbidden credential or runtime path is tracked; inspect with 'git -C `"$Root`" ls-files' and remove it with 'git rm --cached PATH'"
            return $false
        }
    }
    $requiredLinks = @('claude/skills', 'codex/AGENTS.md', 'codex/skills', 'pi/AGENTS.md', 'pi/skills', 'opencode/AGENTS.md', 'opencode/skills')
    $stagedEntries = @(Invoke-AipGit -C $Root ls-files --stage)
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not inspect tracked profile modes'; return $false }
    foreach ($entry in $stagedEntries) {
        if ([string]$entry -match '^120000 [0-9a-f]+ \d+\t(.+)$') {
            $relative = ([string]$Matches[1]).Replace('\', '/')
            if (-not (Test-AipPathUnderProfile $relative $prefixes) -or
                $relative.Substring($relative.IndexOf('/') + 1) -cnotin $requiredLinks) {
                Write-AipError "tracked profile contains an unsupported symbolic link: $relative"
                return $false
            }
        }
    }
    return $true
}

function Test-AipUntrackedSkillsSafe {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($name in (Get-AipProfileNames)) {
        $raw = (Invoke-AipGit -C $Root ls-files --others --exclude-standard -z -- "$($name)/skills") -join "`n"
        if ($LASTEXITCODE -ne 0) { Write-AipError 'could not inspect untracked skill paths'; return $false }
        $paths = @($raw -split "`0" | Where-Object { $_ })
        if (-not (Test-AipPortablePaths $paths 'shared skills')) { return $false }
        foreach ($relative in $paths) {
            if ([string]::IsNullOrEmpty($relative)) { continue }
            $normalized = [string]$relative.Replace('\', '/')
            if (Test-AipForbiddenPath $normalized.Substring($normalized.IndexOf('/') + 1)) {
                Write-AipError 'forbidden credential path exists under skills/; remove or ignore it before syncing'
                return $false
            }
        }
    }
    return $true
}

function Test-AipSkillRepositoriesSafe {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($name in (Get-AipProfileNames)) {
        $profilePath = Get-AipProfilePath $name
        if (-not (Test-AipSkillsMountsSafe $profilePath)) { return $false }
        $nestedGit = Get-ChildItem -LiteralPath (Join-Path $profilePath 'skills') -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq '.git' } | Select-Object -First 1
        if ($null -ne $nestedGit) {
            Write-AipError 'nested Git repositories under skills/ are not supported; remove the nested .git directory and sync the skill files directly'
            return $false
        }
    }
    $staged = (Invoke-AipGit -C $Root ls-files --stage) -join "`n"
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not inspect profile gitlinks'; return $false }
    if ($staged -match '(?m)^160000 ') {
        Write-AipError 'Git submodules are not supported in profiles; remove the gitlink and sync ordinary files directly'
        return $false
    }
    return $true
}

function Test-AipLinkedProfiles {
    $rootItem = Get-Item -LiteralPath $script:AipProfileRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem -or $rootItem -isnot [IO.DirectoryInfo]) { return $true }
    if ($rootItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        $rootItem = $rootItem.ResolveLinkTarget($true)
        if ($null -eq $rootItem -or $rootItem -isnot [IO.DirectoryInfo]) { return $true }
    }
    foreach ($item in (Get-ChildItem -LiteralPath $rootItem.FullName -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -and (Test-AipProfileName $_.Name)
    })) {
        $targetIsProfile = $false
        try {
            $resolved = $item.ResolveLinkTarget($true)
            if ($null -ne $resolved -and (Test-Path -LiteralPath (Join-Path $resolved.FullName '.aip/outfit'))) { $targetIsProfile = $true }
        }
        catch { $targetIsProfile = $false }
        if ($targetIsProfile) {
            Write-AipError "profile '$($item.Name)' path must not be a symbolic link or reparse point"
            return $false
        }
    }
    return $true
}

function Test-AipSkillsMountsSafe {
    param([Parameter(Mandatory)][string]$ProfilePath)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push((Join-Path $ProfilePath 'skills'))
    while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            if (-not $item.PSIsContainer) { continue }
            if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
                if ($item.LinkType -ne 'SymbolicLink') {
                    Write-AipError "shared skills contain a junction or mounted directory that cannot be staged safely: $($item.FullName)"
                    return $false
                }
                continue
            }
            $pending.Push($item.FullName)
        }
    }
    return $true
}

function Test-AipGitTree {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Tree)
    $remoteTree = (Invoke-AipGit -C $Root ls-tree -r $Tree) -join "`n"
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not inspect remote gitlinks'; return $false }
    if ($remoteTree -match '(?m)^160000 ') {
        Write-AipError 'remote profile contains an unsupported Git submodule'
        return $false
    }
    $prefixes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in @($remoteTree -split "`n")) {
        if ([string]$line -match '^100644 \S+ \S+\t(.+)$' -and ([string]$Matches[1]).Replace('\', '/') -like '*/.aip/outfit') {
            [void]$prefixes.Add(([string]$Matches[1]).Replace('\', '/').Split('/')[0])
        }
    }
    $profilePrefixList = @($prefixes)
    $requiredLinks = @('claude/skills', 'codex/AGENTS.md', 'codex/skills', 'pi/AGENTS.md', 'pi/skills', 'opencode/AGENTS.md', 'opencode/skills')
    foreach ($entry in @($remoteTree -split "`n")) {
        if ($entry -match '^120000 (?:blob )?[0-9a-f]+\t(.+)$') {
            $relative = ([string]$Matches[1]).Replace('\', '/')
            if (-not (Test-AipPathUnderProfile $relative $profilePrefixList) -or
                $relative.Substring($relative.IndexOf('/') + 1) -cnotin $requiredLinks) {
                Write-AipError "remote profile contains an unsupported symbolic link: $relative"
                return $false
            }
        }
    }
    $raw = (Invoke-AipGit -C $Root ls-tree -rz --name-only $Tree) -join "`n"
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not inspect the fetched profile tree'; return $false }
    $paths = @($raw -split "`0" | Where-Object { $_ })
    if (-not (Test-AipPortablePaths $paths 'remote profile')) { return $false }
    foreach ($relative in $paths) {
        if ([string]::IsNullOrEmpty($relative)) { continue }
        $check = [string]$relative.Replace('\', '/')
        if (Test-AipPathUnderProfile $check $profilePrefixList) { $check = $check.Substring($check.IndexOf('/') + 1) }
        if (Test-AipForbiddenPath $check) {
            Write-AipError 'remote profile contains a forbidden credential or runtime path; remove it from the remote history before syncing'
            return $false
        }
    }
    $links = [ordered]@{
        'claude/skills' = '../skills'
        'codex/AGENTS.md' = '../AGENTS.md'
        'codex/skills' = '../skills'
        'pi/AGENTS.md' = '../AGENTS.md'
        'pi/skills' = '../skills'
        'opencode/AGENTS.md' = '../AGENTS.md'
        'opencode/skills' = '../skills'
    }
    $requiredFiles = @('.aip/outfit', '.gitignore', 'AGENTS.md', 'skills/.gitkeep', 'claude/CLAUDE.md', 'codex/instructions.md', 'pi/APPEND_SYSTEM.md')
    foreach ($prefix in $profilePrefixList) {
        foreach ($link in $links.GetEnumerator()) {
            $entry = Invoke-AipGit -C $Root ls-tree $Tree -- "$($prefix)/$($link.Key)"
            if ($LASTEXITCODE -ne 0) { return $false }
            $mode = if ($entry) { ([string]$entry -split ' ')[0] } else { '' }
            $target = Invoke-AipGit -C $Root show "$Tree`:$($prefix)/$($link.Key)" 2>$null
            if ($LASTEXITCODE -ne 0 -or $mode -ne '120000' -or [string]$target -ne $link.Value) {
                Write-AipError "remote profile has an invalid required link: $($prefix)/$($link.Key) should link to $($link.Value)"
                return $false
            }
        }
        foreach ($file in $requiredFiles) {
            $entry = Invoke-AipGit -C $Root ls-tree $Tree -- "$($prefix)/$file"
            $mode = if ($LASTEXITCODE -eq 0 -and $entry) { ([string]$entry -split ' ')[0] } else { '' }
            if ($mode -notin '100644', '100755') { Write-AipError "remote profile is missing a regular required file: $($prefix)/$file"; return $false }
        }
        $temporary = [IO.Path]::GetTempFileName()
        try {
            foreach ($file in $requiredFiles) {
                if (-not (Export-AipGitBlob $Root "$Tree`:$($prefix)/$file" $temporary) -or -not (Test-AipUtf8TextFile $temporary)) {
                    Write-AipError "remote profile contains a required text file that is not valid NUL-free UTF-8: $($prefix)/$file"
                    return $false
                }
                $text = Get-AipUtf8TextFile $temporary
                if ($file -eq 'skills/.gitkeep' -and $text.Length -ne 0) {
                    Write-AipError 'remote profile skills/.gitkeep placeholder must be empty'
                    return $false
                }
                elseif ($file -eq '.aip/outfit') {
                    $outfit = ConvertFrom-AipOutfitText $text
                    if (-not (Test-AipOutfit $outfit)) {
                        Write-AipError 'remote profile contains an invalid outfit'
                        return $false
                    }
                }
                elseif ($file -eq 'claude/CLAUDE.md') {
                    $firstLine = ($text -split "`n", 2)[0].TrimEnd("`r")
                    if ($firstLine -cne '@../AGENTS.md') {
                        Write-AipError 'remote profile has an invalid Claude import; claude/CLAUDE.md must begin with @../AGENTS.md'
                        return $false
                    }
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        $skillsType = Invoke-AipGit -C $Root cat-file -t "$Tree`:$($prefix)/skills" 2>$null
        if ($LASTEXITCODE -ne 0 -or $skillsType -ne 'tree') { Write-AipError 'remote profile is missing required skills directory'; return $false }
    }
    $gitignoreEntry = Invoke-AipGit -C $Root ls-tree $Tree -- .gitignore
    $gitignoreMode = if ($LASTEXITCODE -eq 0 -and $gitignoreEntry) { ([string]$gitignoreEntry -split ' ')[0] } else { '' }
    if ($gitignoreMode -notin '100644', '100755') {
        Write-AipError 'remote profiles repository is missing the root .gitignore'
        return $false
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
        $acquired = $false
        try {
            New-Item -ItemType Directory -Path $script:AipSyncLock -ErrorAction Stop | Out-Null
            $acquired = $true
        }
        catch {
            if (Remove-AipStaleLock $script:AipSyncLock) { continue }
            if ($attempt + 1 -lt $attempts) { Start-Sleep -Milliseconds 100 }
            continue
        }
        try {
            $script:AipSyncToken = [guid]::NewGuid().ToString('N')
            $PID | Set-Content -LiteralPath (Join-Path $script:AipSyncLock 'pid') -Encoding ascii -ErrorAction Stop
            [Environment]::MachineName | Set-Content -LiteralPath (Join-Path $script:AipSyncLock 'host') -Encoding utf8NoBOM -ErrorAction Stop
            [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() | Set-Content -LiteralPath (Join-Path $script:AipSyncLock 'timestamp') -Encoding ascii -ErrorAction Stop
            $script:AipSyncToken | Set-Content -LiteralPath (Join-Path $script:AipSyncLock 'token') -Encoding ascii -ErrorAction Stop
            return $true
        }
        catch {
            if ($acquired) { Remove-Item -LiteralPath $script:AipSyncLock -Recurse -Force -ErrorAction SilentlyContinue }
            $script:AipSyncToken = $null
            Write-AipError 'could not record sync-lock ownership; the incomplete lock was removed'
            return $false
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
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Mode)
    $script:AipCheckpointCreated = $false
    if (-not (Test-AipLinkedProfiles)) { return $false }
    if (-not (Test-AipTrackedPathsSafe $Root)) { return $false }
    if (-not (Test-AipSkillRepositoriesSafe $Root)) { return $false }
    if (-not (Test-AipUntrackedSkillsSafe $Root)) { return $false }
    Invoke-AipGit -C $Root add -u -- .
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not stage tracked profile changes'; return $false }
    Invoke-AipGit -C $Root add .gitignore
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not stage the root Git exclusions'; return $false }
    $owned = @('.aip/outfit', '.gitignore', 'AGENTS.md', 'skills', 'claude/CLAUDE.md', 'claude/skills', 'codex/AGENTS.md', 'codex/instructions.md', 'codex/skills', 'pi/AGENTS.md', 'pi/APPEND_SYSTEM.md', 'pi/skills', 'opencode/AGENTS.md', 'opencode/skills')
    foreach ($name in (Get-AipProfileNames)) {
        Invoke-AipGit -C $Root add -- @($owned | ForEach-Object { "$($name)/$_" })
        if ($LASTEXITCODE -ne 0) { Write-AipError 'could not stage aip-owned profile files'; return $false }
    }
    Invoke-AipGit -C $Root diff --cached --quiet --
    if ($LASTEXITCODE -ne 0) {
        Invoke-AipGit -C $Root commit -q -m "aip: checkpoint ($Mode)"
        if ($LASTEXITCODE -ne 0) { Write-AipError 'could not commit the local checkpoint; check Git identity and hooks'; return $false }
        $script:AipCheckpointCreated = $true
    }
    return $true
}

function Test-AipRebasePreservesUntracked {
    param([Parameter(Mandatory)][string]$ProfilePath, [Parameter(Mandatory)][string]$UpstreamCommit)
    $remoteRaw = (Invoke-AipGit -C $ProfilePath diff --name-only --diff-filter=ACMRT -z HEAD $UpstreamCommit) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-AipError 'could not inspect remote paths before integrating the remote profile'
        return $false
    }
    $untrackedRaw = (Invoke-AipGit -C $ProfilePath ls-files --others --exclude-standard -z) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-AipError 'could not inspect local untracked paths before integrating the remote profile'
        return $false
    }
    $ignoredRaw = (Invoke-AipGit -C $ProfilePath ls-files --others --ignored --exclude-standard -z) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-AipError 'could not inspect local ignored paths before integrating the remote profile'
        return $false
    }
    $remotePaths = @($remoteRaw -split "`0" | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('/') })
    $localPaths = @(($untrackedRaw + "`0" + $ignoredRaw) -split "`0" | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('/') })
    foreach ($remotePath in $remotePaths) {
        foreach ($localPath in $localPaths) {
            if ($remotePath.Equals($localPath, [StringComparison]::OrdinalIgnoreCase) -or
                $remotePath.StartsWith("$localPath/", [StringComparison]::OrdinalIgnoreCase) -or
                $localPath.StartsWith("$remotePath/", [StringComparison]::OrdinalIgnoreCase)) {
                Write-AipError "remote integration would overwrite or replace untracked or ignored local profile state; inspect with 'git -C `"$ProfilePath`" status --ignored --untracked-files=all' and move or deliberately track the conflicting path"
                return $false
            }
        }
    }
    return $true
}

function Invoke-AipSyncCore {
    param([string]$Mode = 'manual')
    $script:AipCommandStatus = 0
    if (-not (Test-AipRootRepo)) { return }
    if (-not (Test-AipGitContainment $script:AipProfileRoot -Report)) { return }
    if (-not (Enter-AipSyncLock $script:AipProfileRoot)) { return }
    try {
        $unmerged = Invoke-AipGit -C $script:AipProfileRoot diff --name-only --diff-filter=U 2>$null
        if ((Test-AipUnfinishedGitOperation $script:AipProfileRoot) -or $unmerged) {
            Write-AipError "Git conflict or unfinished operation in $script:AipProfileRoot; run 'git -C `"$script:AipProfileRoot`" status', then resolve and continue or abort it"
            return
        }
        foreach ($name in (Get-AipProfileNames)) {
            $profilePath = Get-AipProfilePath $name
            if (-not (Add-AipSkillsPlaceholder $profilePath)) { return }
            $layoutResult = @(Test-AipLayout $profilePath)
            if (-not [bool]$layoutResult[-1]) {
                if (-not $script:AipLastError) {
                    if ($script:AipProfileBoundaryError) { Write-AipError $script:AipProfileBoundaryError }
                    else { Write-AipError 'required profile file or link is missing or invalid' }
                }
                return
            }
        }
        if (-not (Add-AipCheckpoint $script:AipProfileRoot $Mode)) { return }
        if ($script:AipCheckpointCreated) { Write-Output 'Checkpointed local profile changes.' }
        Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify '@{upstream}' *> $null
        if ($LASTEXITCODE -ne 0) { Write-Output 'Profiles are local only (no upstream).'; return }

        $upstream = Invoke-AipGit -C $script:AipProfileRoot rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
        $branch = Invoke-AipGit -C $script:AipProfileRoot branch --show-current
        $remote = Invoke-AipGit -C $script:AipProfileRoot config --get "branch.$branch.remote"
        $mergeRef = Invoke-AipGit -C $script:AipProfileRoot config --get "branch.$branch.merge"
        if (-not $remote) { Write-AipError 'configured upstream remote is invalid'; return }
        if ($LASTEXITCODE -ne 0 -or $mergeRef -notlike 'refs/heads/*') { Write-AipError 'configured upstream branch is invalid'; return }
        $previousPrompt = $env:GIT_TERMINAL_PROMPT
        $previousCredentialManager = $env:GCM_INTERACTIVE
        $previousSshCommand = $env:GIT_SSH_COMMAND
        $previousSshVariant = $env:GIT_SSH_VARIANT
        try {
            if (-not (Test-AipGitMutationState $script:AipProfileRoot -Report)) { return }
            $transport = Get-AipSshTransport $script:AipProfileRoot
            if ($null -eq $transport) {
                Write-AipWarning 'remote sync unavailable because the configured SSH variant cannot be made non-interactive; using the committed local profiles'
                return
            }
            $env:GIT_TERMINAL_PROMPT = '0'
            $env:GCM_INTERACTIVE = 'never'
            $env:GIT_SSH_COMMAND = $transport.Command
            $env:GIT_SSH_VARIANT = $transport.Variant
            Invoke-AipGit -C $script:AipProfileRoot fetch --quiet $remote *> $null
            if ($LASTEXITCODE -ne 0) {
                if (-not (Test-AipGitMutationState $script:AipProfileRoot -Report)) { return }
                Write-AipWarning 'remote sync unavailable; using the committed local profiles and retrying next time'
                return
            }
            $upstreamCommit = Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify "$upstream^{commit}"
            if ($LASTEXITCODE -ne 0) { Write-AipError 'could not resolve the fetched upstream commit'; return }
            if (-not (Test-AipGitTree $script:AipProfileRoot $upstreamCommit)) { return }
            if (-not (Test-AipRebasePreservesUntracked $script:AipProfileRoot $upstreamCommit)) { return }
            Invoke-AipGit -C $script:AipProfileRoot rebase $upstreamCommit *> $null
            if ($LASTEXITCODE -ne 0) {
                $unmerged = Invoke-AipGit -C $script:AipProfileRoot diff --name-only --diff-filter=U 2>$null
                if ((Test-AipUnfinishedGitOperation $script:AipProfileRoot) -or $unmerged) {
                    Write-AipError "Git conflict in $script:AipProfileRoot; no side was chosen. Resolve files, then use 'git rebase --continue' or 'git rebase --abort'"
                }
                else { Write-AipError "local Git integration failed in $script:AipProfileRoot; inspect it with 'git status'" }
                return
            }
            foreach ($name in (Get-AipProfileNames)) {
                $layoutResult = @(Test-AipLayout (Get-AipProfilePath $name))
                if (-not [bool]$layoutResult[-1]) {
                    if (-not $script:AipLastError) {
                        if ($script:AipProfileBoundaryError) { Write-AipError $script:AipProfileBoundaryError }
                        else { Write-AipError 'required profile file or link is missing or invalid' }
                    }
                    return
                }
            }
            if (-not (Test-AipTrackedPathsSafe $script:AipProfileRoot)) { return }
            if (-not (Test-AipUntrackedSkillsSafe $script:AipProfileRoot)) { return }
            if (-not (Test-AipSkillRepositoriesSafe $script:AipProfileRoot)) { return }
            if (-not (Test-AipGitMutationState $script:AipProfileRoot -Report)) { return }
            Invoke-AipGit -C $script:AipProfileRoot push --quiet $remote "HEAD`:$mergeRef" *> $null
            if ($LASTEXITCODE -ne 0) {
                if (-not (Test-AipGitMutationState $script:AipProfileRoot -Report)) { return }
                Write-AipWarning 'remote sync unavailable during push; the local checkpoint is safe and will retry next time'
                return
            }
            Write-Output "Profiles synced with $upstream."
        }
        finally {
            if ($null -eq $previousPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
            else { $env:GIT_TERMINAL_PROMPT = $previousPrompt }
            if ($null -eq $previousCredentialManager) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue }
            else { $env:GCM_INTERACTIVE = $previousCredentialManager }
            if ($null -eq $previousSshCommand) { Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue }
            else { $env:GIT_SSH_COMMAND = $previousSshCommand }
            if ($null -eq $previousSshVariant) { Remove-Item Env:GIT_SSH_VARIANT -ErrorAction SilentlyContinue }
            else { $env:GIT_SSH_VARIANT = $previousSshVariant }
        }
    }
    finally { Exit-AipSyncLock }
}

function Invoke-AipSync {
    param([string]$Mode = 'manual')
    Invoke-AipWithoutGitRouting { Invoke-AipSyncCore $Mode }
}

function Invoke-AipSyncCommand {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 1) { Write-AipError 'usage: aip sync'; $script:AipCommandStatus = 2; return }
    if ($Arguments.Count -eq 1) {
        Write-AipError "unexpected argument '$($Arguments[0])'; aip sync syncs every profile in the profiles repository"
        $script:AipCommandStatus = 2
        return
    }
    Invoke-AipSync 'manual'
}

function Invoke-AipHarness {
    param(
        [Parameter(Mandatory)][bool]$ExplicitNameSupplied,
        [AllowEmptyString()][string]$ExplicitName,
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(ValueFromRemainingArguments)][object[]]$Arguments
    )
    $script:AipCommandStatus = 0
    $script:AipLastError = $null
    $script:AipLastWarning = $null
    if ($Harness -cnotin 'claude', 'codex', 'pi', 'opencode') {
        Write-AipError "unknown harness '$Harness'; expected claude, codex, pi, or opencode"
        $global:LASTEXITCODE = 2
        return
    }
    $profile = Resolve-AipProfile $ExplicitName $ExplicitNameSupplied
    if ($null -eq $profile) { $global:LASTEXITCODE = $script:AipCommandStatus; return }
    $realCommand = Get-AipRealCommand $Harness
    if (-not $realCommand) {
        Write-AipError "$Harness executable was not found in PATH"
        $global:LASTEXITCODE = 127
        return
    }
    Invoke-AipSync 'before'
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
    $hadArgumentPassing = Test-Path Variable:PSNativeCommandArgumentPassing
    $previousArgumentPassing = $PSNativeCommandArgumentPassing
    $childStatus = $null
    $childStarted = $false
    try {
        [Environment]::SetEnvironmentVariable($variable, (Join-Path $profile.Path $Harness), 'Process')
        $PSNativeCommandArgumentPassing = 'Standard'
        $nativeArguments = @($Arguments)
        if ($Harness -eq 'codex') {
            $instructionPath = Join-Path $profile.Path 'codex/instructions.md'
            if (-not (Test-AipUtf8TextFile $instructionPath)) { throw 'Codex instructions must be valid NUL-free UTF-8' }
            $instructions = (Get-AipUtf8TextFile $instructionPath).TrimEnd("`r", "`n")
            $tomlInstructions = ConvertTo-AipTomlString $instructions
            $nativeArguments = @('-c', "developer_instructions=$tomlInstructions") + $nativeArguments
        }
        $childStarted = $true
        $global:LASTEXITCODE = 0
        & $realCommand @nativeArguments
        $childStatus = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    catch {
        $childStatus = if ($childStarted -and $null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            $LASTEXITCODE
        }
        elseif ($_ -is [System.Management.Automation.PipelineStoppedException]) {
            130
        }
        else {
            1
        }
        if ($_ -isnot [System.Management.Automation.PipelineStoppedException]) {
            Write-AipError "could not run ${Harness}: $($_.Exception.Message)"
        }
    }
    finally {
        if ($null -eq $childStatus) {
            $childStatus = if ($childStarted -and $null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } elseif ($childStarted) { 130 } else { 1 }
        }
        try {
            Invoke-AipSync 'after'
        }
        catch {
            Write-AipWarning "after-run sync failed during cleanup: $($_.Exception.Message)"
        }
        finally {
            if ($hadPrevious) { [Environment]::SetEnvironmentVariable($variable, $previous, 'Process') }
            else { [Environment]::SetEnvironmentVariable($variable, $null, 'Process') }
            if ($hadArgumentPassing) { $PSNativeCommandArgumentPassing = $previousArgumentPassing }
            else { Remove-Variable -Name PSNativeCommandArgumentPassing -Scope Local -ErrorAction SilentlyContinue }
            if ($IsWindows -and ($childStatus -eq 3221225786 -or $childStatus -eq -1073741510)) {
                # Native Ctrl-C terminates children with STATUS_CONTROL_C_EXIT (0xC000013A,
                # signed or unsigned); report the conventional 130 instead.
                $childStatus = 130
            }
            $global:LASTEXITCODE = $childStatus
        }
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

function Invoke-AipUpdate {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 0) { Write-AipError 'usage: aip update'; $script:AipCommandStatus = 2; return }
    if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { Write-AipError 'update requires Node.js (npx) on PATH'; $script:AipCommandStatus = 1; return }
    & npx --yes '@code-ministry/aip' update
    $script:AipCommandStatus = $LASTEXITCODE
}

function Invoke-AipVersion {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 0) { Write-AipError 'usage: aip version'; $script:AipCommandStatus = 2; return }
    Write-Output "aip $($script:AipVersion)"
}

function Invoke-AipWhich {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 1) { Write-AipError 'usage: aip which [NAME]'; $script:AipCommandStatus = 2; return }
    $explicit = if ($Arguments.Count -eq 1) { [string]$Arguments[0] } else { '' }
    $profile = Resolve-AipProfile $explicit ($Arguments.Count -eq 1)
    if ($null -ne $profile) { Write-Output $profile.Path }
}

function Set-AipMarker {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][string]$Name)
    $existing = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing -and ($existing.PSIsContainer -or $existing.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))) {
        Write-AipError "marker path is not a regular file: $LiteralPath"
        return
    }
    $temporary = "$LiteralPath.$([IO.Path]::GetRandomFileName())"
    try {
        $Name | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $LiteralPath -Force -ErrorAction Stop
        if ((Get-AipNameFile $LiteralPath) -ne $Name) { throw 'marker verification failed' }
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
        $markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        if ($null -eq $markerItem) { Write-AipError 'no profile marker exists in the current directory'; return }
        if ($markerItem.PSIsContainer -and -not $markerItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            Write-AipError "marker path is a directory and was not removed: $marker"
            return
        }
        Remove-Item -LiteralPath $marker -Force -ErrorAction Stop
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
    $outfitDirectory = Get-Item -LiteralPath (Join-Path $ProfilePath '.aip') -Force -ErrorAction SilentlyContinue
    $outfitItem = Get-Item -LiteralPath $outfitPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $outfitDirectory -or -not $outfitDirectory.PSIsContainer -or $outfitDirectory.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or
        $null -eq $outfitItem -or $outfitItem.PSIsContainer -or $outfitItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { return 'invalid outfit' }
    if (-not (Test-AipUtf8TextFile $outfitPath)) { return 'invalid outfit' }
    $outfit = ConvertFrom-AipOutfitText (Get-AipUtf8TextFile $outfitPath)
    if (-not (Test-AipOutfit $outfit)) { return 'invalid outfit' }
    return $outfit
}

function Invoke-AipOutfit {
    param([object[]]$Arguments)
    if ($Arguments.Count -ne 2) { Write-AipError 'usage: aip outfit NAME OUTFIT'; $script:AipCommandStatus = 2; return }
    $name = [string]$Arguments[0]
    $outfit = [string]$Arguments[1]
    if (-not (Test-AipProfileExists $name)) { return }
    $profilePath = Get-AipProfilePath $name
    $layoutResult = @(Test-AipLayout $profilePath -IgnoreOutfitContent)
    if (-not [bool]$layoutResult[-1]) { Write-AipError "profile '$name' has an invalid layout; run 'aip doctor $name'"; return }
    if (-not (Test-AipOutfit $outfit)) { Write-AipError 'outfit must be one printable, non-empty line of at most 64 characters'; $script:AipCommandStatus = 2; return }
    $outfitPath = Join-Path $profilePath '.aip/outfit'
    $temporary = "$outfitPath.$([IO.Path]::GetRandomFileName())"
    try {
        Set-AipUtf8LfFile $temporary @($outfit)
        [IO.File]::Move($temporary, $outfitPath, $true)
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Write-AipError "could not update outfit for profile '$name': $($_.Exception.Message)"
        return
    }
    Write-Output "Profile '$name' now wears $outfit"
}

function Get-AipGitSummary {
    if (-not (Test-AipGitContainment $script:AipProfileRoot)) { return 'unreadable; run aip doctor' }
    $changes = Invoke-AipGit -C $script:AipProfileRoot status --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) { return 'unreadable; run aip doctor' }
    $state = if ($changes) { 'changes' } else { 'clean' }
    $unmerged = Invoke-AipGit -C $script:AipProfileRoot diff --name-only --diff-filter=U 2>$null
    if ((Test-AipUnfinishedGitOperation $script:AipProfileRoot) -or $unmerged) { return "$state, conflict or unfinished Git operation" }
    Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify '@{upstream}' *> $null
    if ($LASTEXITCODE -ne 0) {
        $branch = Invoke-AipGit -C $script:AipProfileRoot branch --show-current 2>$null
        if ($LASTEXITCODE -ne 0) { return 'unreadable; run aip doctor' }
        $configuredRemote = Invoke-AipGit -C $script:AipProfileRoot config --get "branch.$branch.remote" 2>$null
        $configuredMerge = Invoke-AipGit -C $script:AipProfileRoot config --get "branch.$branch.merge" 2>$null
        if ($configuredRemote -or $configuredMerge) { return 'unreadable; run aip doctor' }
        return "$state, local only"
    }
    $upstream = Invoke-AipGit -C $script:AipProfileRoot rev-parse --abbrev-ref '@{upstream}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $upstream) { return 'unreadable; run aip doctor' }
    $countText = Invoke-AipGit -C $script:AipProfileRoot rev-list --left-right --count 'HEAD...@{upstream}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]$countText -notmatch '^\d+\s+\d+$') { return 'unreadable; run aip doctor' }
    $counts = ([string]$countText -split '\s+')
    $ahead = [int]$counts[0]
    $behind = [int]$counts[1]
    if ($ahead -eq 0 -and $behind -eq 0) { return "$state, synced with $upstream" }
    if ($behind -eq 0) { return "$state, pending push ($ahead ahead of $upstream)" }
    if ($ahead -eq 0) { return "$state, pending pull ($behind behind $upstream)" }
    return "$state, diverged ($ahead ahead, $behind behind $upstream)"
}

function Invoke-AipStatus {
    $profile = Resolve-AipProfile
    if ($null -eq $profile) { return }
    Write-Output "🐵 $($profile.Name) — $(Get-AipOutfit $profile.Path)"
    Write-Output "Selected by: $($profile.Source)"
    Write-Output "Path: $($profile.Path)"
    Write-Output "Git: $(Get-AipGitSummary)"
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
    $rootItem = Get-Item -LiteralPath $script:AipProfileRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem -or $rootItem -isnot [IO.DirectoryInfo]) { Write-Output 'No profiles. Create one with: aip create NAME'; return }
    if ($rootItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        $rootItem = $rootItem.ResolveLinkTarget($true)
        if ($null -eq $rootItem -or $rootItem -isnot [IO.DirectoryInfo]) { Write-Output 'No profiles. Create one with: aip create NAME'; return }
    }
    $profiles = @(Get-ChildItem -LiteralPath $rootItem.FullName -Directory -ErrorAction SilentlyContinue | Where-Object {
        (Test-AipProfileName $_.Name) -and $null -eq $_.LinkType -and -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -and
            ($null -ne (Get-Item -LiteralPath (Join-Path $_.FullName '.aip/outfit') -Force -ErrorAction SilentlyContinue))
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
    $first = [string]$Arguments[0]
    $explicitHarnessProfile = $Arguments.Count -ge 2 -and $first -cin $harnesses -and [string]$Arguments[1] -cin $harnesses -and
        (Test-AipPathEntry (Get-AipProfilePath $first))
    if ($explicitHarnessProfile) {
        $explicitSupplied = $true
        $explicit = $first
        $harness = [string]$Arguments[1]
        $rest = @($Arguments | Select-Object -Skip 2)
    }
    elseif ($first -cin $harnesses) {
        $explicitSupplied = $false
        $explicit = ''
        $harness = $first
        $rest = @($Arguments | Select-Object -Skip 1)
    }
    elseif ($Arguments.Count -ge 2) {
        $explicitSupplied = $true
        $explicit = [string]$Arguments[0]
        $harness = [string]$Arguments[1]
        $rest = @($Arguments | Select-Object -Skip 2)
    }
    else { Write-AipError "unknown harness '$($Arguments[0])'; expected claude, codex, pi, or opencode"; $script:AipCommandStatus = 2; return }
    Invoke-AipHarness $explicitSupplied $explicit $harness @rest
    $script:AipCommandStatus = $global:LASTEXITCODE
}

function Invoke-AipRemoteShow {
    $root = $script:AipProfileRoot
    $url = @()
    $rootGit = Join-Path $root '.git'
    if ((Test-Path -LiteralPath $rootGit -PathType Container) -and
        $null -ne (Get-Item -LiteralPath $rootGit -Force -ErrorAction SilentlyContinue) -and
        -not ((Get-Item -LiteralPath $rootGit -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))) {
        $url = @(Invoke-AipGit -C $root remote get-url origin 2>$null)
        if ($LASTEXITCODE -ne 0) { $url = @() }
    }
    if ($url.Count -eq 1 -and "$url[0]".Trim().Length -gt 0) { Write-Output $url[0] }
    else { Write-Output 'no remote is configured' }
}

function Invoke-AipRemoteRemove {
    $root = $script:AipProfileRoot
    $url = @()
    $rootGit = Join-Path $root '.git'
    if ((Test-Path -LiteralPath $rootGit -PathType Container) -and
        $null -ne (Get-Item -LiteralPath $rootGit -Force -ErrorAction SilentlyContinue) -and
        -not ((Get-Item -LiteralPath $rootGit -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))) {
        $url = @(Invoke-AipGit -C $root remote get-url origin 2>$null)
        if ($LASTEXITCODE -ne 0) { $url = @() }
    }
    if ($url.Count -eq 0 -or "$url[0]".Trim().Length -eq 0) { Write-Output 'no remote is configured'; return }
    $null = Invoke-AipGit -C $root remote remove origin
    if ($LASTEXITCODE -ne 0) {
        Write-AipError 'could not remove the origin remote; inspect the profiles repository'
        return 1
    }
    $branch = Invoke-AipGit -C $root branch --show-current 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) { Invoke-AipGit -C $root branch --unset-upstream 2>$null | Out-Null }
    Write-Output 'Remote removed; profiles are now local only.'
}

function Invoke-AipRemoteAdd {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)
    if ("$Url".Trim().Length -eq 0) { Write-AipError 'usage: aip remote add URL'; $script:AipCommandStatus = 2; return }
    if ($Url -match '\s') { Write-AipError "invalid remote URL: $Url"; $script:AipCommandStatus = 2; return }
    $root = $script:AipProfileRoot
    $rootGit = Join-Path $root '.git'
    $repoExists = (Test-Path -LiteralPath $rootGit -PathType Container) -and
        $null -ne (Get-Item -LiteralPath $rootGit -Force -ErrorAction SilentlyContinue) -and
        -not ((Get-Item -LiteralPath $rootGit -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))
    if ($repoExists) {
        $existing = @(Invoke-AipGit -C $root remote get-url origin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $existing.Count -eq 1 -and "$existing[0]".Trim().Length -gt 0) {
            Write-AipError "origin is already configured ($($existing[0])); run 'aip remote remove' first"
            $script:AipCommandStatus = 1
            return
        }
        $null = Invoke-AipGit -C $root remote add origin $Url
        if ($LASTEXITCODE -ne 0) {
            Write-AipError "could not configure origin: $Url"
            $script:AipCommandStatus = 1
            return
        }
    }
    else {
        if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-AipError "profiles path exists and is not a directory: $root"
            $script:AipCommandStatus = 1
            return
        }
        if (Test-Path -LiteralPath $rootGit) {
            Write-AipError "profiles repository metadata is missing or linked: $rootGit"
            $script:AipCommandStatus = 1
            return
        }
        if (Test-Path -LiteralPath $root) {
            $contents = Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue
            if ($null -ne $contents) {
                Write-AipError "profiles directory already contains content: $root; use 'aip create NAME' instead of 'aip remote add'"
                $script:AipCommandStatus = 1
                return
            }
        }
        try { New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null }
        catch { Write-AipError "could not create the profiles directory: $root"; $script:AipCommandStatus = 1; return }
        $transport = Get-AipSshTransport $root
        if ($null -eq $transport) {
            Write-AipError 'remote is unavailable because the configured SSH variant cannot be made non-interactive'
            $script:AipCommandStatus = 1
            return
        }
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        $env:GIT_SSH_COMMAND = $transport.Command
        $env:GIT_SSH_VARIANT = $transport.Variant
        try {
            $null = Invoke-AipGit clone --quiet -- $Url $root
            if ($LASTEXITCODE -ne 0) {
                Write-AipError "could not clone $Url into $root; the remote must be a profiles repository created by aip"
                $script:AipCommandStatus = 1
                return
            }
        }
        finally { $env:GIT_TERMINAL_PROMPT = $null; $env:GCM_INTERACTIVE = $null; $env:GIT_SSH_COMMAND = $null; $env:GIT_SSH_VARIANT = $null }
        $null = Invoke-AipGit -C $root config core.symlinks true
        if ($LASTEXITCODE -ne 0) {
            Write-AipError 'could not configure symbolic-link checkout'
            $script:AipCommandStatus = 1
            return
        }
        $null = Invoke-AipGit -C $root config core.longpaths true
        $null = Invoke-AipGit -C $root rev-parse --verify HEAD 2>$null
        if ($LASTEXITCODE -ne 0) {
            $null = Invoke-AipGit -C $root rev-parse --verify refs/remotes/origin/main 2>$null
            if ($LASTEXITCODE -eq 0) {
                $null = Invoke-AipGit -C $root checkout -q -B main refs/remotes/origin/main 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-AipError 'could not check out the cloned profiles branch'
                    $script:AipCommandStatus = 1
                    return
                }
            }
        }
        Write-Output "Cloned profiles from $Url."
    }
    $branch = Invoke-AipGit -C $root branch --show-current 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $branch) { $branch = '' }
    if ([string]::IsNullOrWhiteSpace($branch)) {
        Write-AipError 'cannot attach a remote while detached from a branch'
        $script:AipCommandStatus = 1
        return
    }
    $transport = Get-AipSshTransport $root
    if ($null -eq $transport) {
        Write-AipError 'remote is unavailable because the configured SSH variant cannot be made non-interactive'
        $script:AipCommandStatus = 1
        return
    }
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    $env:GIT_SSH_COMMAND = $transport.Command
    $env:GIT_SSH_VARIANT = $transport.Variant
    try {
        $null = Invoke-AipGit -C $root fetch --quiet origin 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-AipError 'could not fetch origin; check that the remote is reachable and that credentials are not required interactively'
            $script:AipCommandStatus = 1
            return
        }
        $null = Invoke-AipGit -C $root rev-parse --verify "refs/remotes/origin/$branch" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $null = Invoke-AipGit -C $root branch --set-upstream-to "origin/$branch" $branch 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-AipError "could not attach branch $branch to origin"
                $script:AipCommandStatus = 1
                return
            }
            Invoke-AipSync 'manual'
            return
        }
        if (-not (Test-AipTrackedPathsSafe $root)) { return }
        $null = Invoke-AipGit -C $root push --quiet -u origin "HEAD:refs/heads/$branch" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-AipError 'could not publish the profiles repository to origin; the remote may need to be empty'
            $script:AipCommandStatus = 1
            return
        }
        Write-Output "Profiles published to origin/$branch."
    }
    finally { $env:GIT_TERMINAL_PROMPT = $null; $env:GCM_INTERACTIVE = $null; $env:GIT_SSH_COMMAND = $null; $env:GIT_SSH_VARIANT = $null }
}

function Invoke-AipRemote {
    param([object[]]$Arguments)
    $sub = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }
    if ($sub -eq '') {
        Write-AipError 'usage: aip remote add URL | aip remote show | aip remote remove'
        $script:AipCommandStatus = 2
        return
    }
    switch -CaseSensitive ($sub) {
        'add' {
            if ($Arguments.Count -ne 2) { Write-AipError 'usage: aip remote add URL'; $script:AipCommandStatus = 2; return }
            Invoke-AipRemoteAdd ([string]$Arguments[1])
        }
        'show' {
            if ($Arguments.Count -ne 1) { Write-AipError 'usage: aip remote show'; $script:AipCommandStatus = 2; return }
            Invoke-AipRemoteShow
        }
        'remove' {
            if ($Arguments.Count -ne 1) { Write-AipError 'usage: aip remote remove'; $script:AipCommandStatus = 2; return }
            Invoke-AipRemoteRemove
        }
        default {
            Write-AipError "unknown remote command '$sub'; usage: aip remote add URL | aip remote show | aip remote remove"
            $script:AipCommandStatus = 2
        }
    }
}

function Invoke-AipHelp {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 0) { Write-AipError 'usage: aip help'; $script:AipCommandStatus = 2; return }
    @'
aip — shared AI profiles for Claude Code, Codex, Pi, and OpenCode

A profile is one directory: shared AGENTS.md instructions, shared skills/, and
per-harness launch settings. Every profile lives in a single Git repository
(the profiles repository, ~/agent-profiles by default), so one remote keeps
all of your profiles in sync across all of your machines.

Commands:
  aip create NAME [--outfit OUTFIT]  Create a new profile
  aip list                           List profiles, outfits, and selection
  aip which [NAME]                   Show the profile that would be selected
  aip default [NAME]                 Show or set the default profile
  aip use NAME                       Select NAME for this shell only
  aip local [NAME | --remove]        Set or clear the per-directory marker
  aip outfit NAME OUTFIT             Set a profile's outfit (label)
  aip clone SOURCE TARGET            Copy a profile into a new profile
  aip delete NAME [--force]          Delete a profile
  aip sync                           Checkpoint and sync every profile
  aip remote add URL                 Connect the profiles repository to a remote
  aip remote show                    Show the configured remote (if any)
  aip remote remove                  Disconnect the remote
  aip doctor [NAME]                  Diagnose the repository and profiles
  aip run [NAME] HARNESS [ARGS...]   Launch a harness with a profile
  aip update                         Update the aip npm package
  aip version                        Show the aip version
  aip help                           Show this help

Harness wrappers:
  claude, codex, pi, opencode [ARGS...] launch the named tool with the
  selected profile's settings, checkpointing the profiles repository before
  and after the run. If the remote is unreachable they warn and launch the
  committed local profile instead; a Git conflict blocks the launch until
  it is resolved.

Quick start:
  aip create work --outfit suit   create your first profile
  aip remote add <git-url>        connect a shared remote (empty remote ok)
  aip default work                choose your everyday profile
  cd my-project && claude         work with your profile

On a second machine:
  aip remote add <same-git-url>   clones every profile you already have

See the README for full documentation, including Windows setup and the
security guarantees aip enforces on syncable content.
'@ -split "`n" | ForEach-Object { Write-Output $_ }
}

function aip {
    $script:AipCommandStatus = 0
    $script:AipLastError = $null
    $script:AipLastWarning = $null
    $arguments = @($args)
    if ($arguments.Count -eq 0) { Invoke-AipWithoutGitRouting { Invoke-AipStatus } }
    else {
        $command = [string]$arguments[0]
        $rest = @($arguments | Select-Object -Skip 1)
        switch -CaseSensitive ($command) {
            'create' { Invoke-AipWithoutGitRouting { Invoke-AipCreate $rest } }
            'clone' { Invoke-AipWithoutGitRouting { Invoke-AipClone $rest } }
            'default' { Invoke-AipDefault $rest }
            'delete' { Invoke-AipWithoutGitRouting { Invoke-AipDelete $rest } }
            'doctor' { Invoke-AipWithoutGitRouting { Invoke-AipDoctor $rest } }
            'list' { Invoke-AipWithoutGitRouting { Invoke-AipList $rest } }
            'local' { Invoke-AipLocal $rest }
            'outfit' { Invoke-AipOutfit $rest }
            'help' { Invoke-AipHelp $rest }
            '--help' { Invoke-AipHelp @() }
            '-h' { Invoke-AipHelp @() }
            'remote' { Invoke-AipWithoutGitRouting { Invoke-AipRemote $rest } }
            'run' { Invoke-AipRun $rest }
            'sync' { Invoke-AipSyncCommand $rest }
            'use' { Invoke-AipUse $rest }
            'update' { Invoke-AipWithoutGitRouting { Invoke-AipUpdate $rest } }
            'version' { Invoke-AipVersion $rest }
            'which' { Invoke-AipWhich $rest }
            default { Write-AipError "unknown command '$command'"; $script:AipCommandStatus = 2 }
        }
    }
    $global:LASTEXITCODE = $script:AipCommandStatus
}

function claude { Invoke-AipHarness $false '' 'claude' @args }
function codex { Invoke-AipHarness $false '' 'codex' @args }
function pi { Invoke-AipHarness $false '' 'pi' @args }
function opencode { Invoke-AipHarness $false '' 'opencode' @args }
