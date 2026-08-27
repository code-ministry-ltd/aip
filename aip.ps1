# aip — AI Profile for PowerShell 7.3+. Dot-source this file from your profile.

if ($PSVersionTable.PSVersion -lt [version]'7.3') { throw 'aip requires PowerShell 7.3 or later' }

if (-not (Get-Variable -Name AipProfileRoot -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AipProfileRoot = Join-Path $HOME 'agent-profiles'
}
if (-not (Get-Variable -Name AipImportHome -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AipImportHome = $HOME
}
$script:AipCommandStatus = 0
$script:AipVersion = '0.8.0'
$script:AipResolveReason = ''
$script:AipResolveQuiet = $false
$script:AipCreateSkillsTreeRoot = $null
$script:AipCreateSkillsGlobalRoot = $null
$script:AipCreateSkillsAgentsRoot = $null
$script:AipCreateSkipSkillSelection = $false

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

function Get-AipRedactedUrl {
    # Display-only: strip URL userinfo (user@ or user:pass@). scp-style git@host: is left alone.
    param([AllowEmptyString()][string]$Url)
    if ($Url -match '://[^/]*@') {
        return [regex]::Replace($Url, '(://)[^/]*@', '$1')
    }
    return $Url
}

function Test-AipPathUnder {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Child)
    $sep = [IO.Path]::DirectorySeparatorChar
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd($sep) + $sep
    $childFull = [IO.Path]::GetFullPath($Child)
    $comparison = Test-AipPathComparison
    return $childFull.StartsWith($parentFull, $comparison)
}

function Test-AipHasDisallowedControl {
    # Reject U+0000–U+001F, U+007F, U+0080–U+009F by UTF-16 code unit (BMP).
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        if ($code -le 0x1F -or $code -eq 0x7F -or ($code -ge 0x80 -and $code -le 0x9F)) { return $true }
    }
    return $false
}

function Test-AipDeleteConfirm {
    param([AllowEmptyString()][string]$Answer)
    switch -CaseSensitive ($Answer) {
        'y' { return $true }
        'Y' { return $true }
        'yes' { return $true }
        'YES' { return $true }
        default { return $false }
    }
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
                if (Test-AipHasDisallowedControl ([string]$character)) { throw 'Codex instructions contain a control character that TOML cannot represent safely' }
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
            ($null -ne (Get-Item -LiteralPath (Join-Path $_.FullName '.gitignore') -Force -ErrorAction SilentlyContinue))
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
        Invoke-AipGit -C $root config --replace-all core.symlinks true
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

    $script:AipResolveReason = ''
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
    $script:AipResolveReason = 'no-selection'
    if (-not $script:AipResolveQuiet) {
        Write-AipError "no profile selected; run 'aip create NAME' then 'aip use NAME'"
        $script:AipCommandStatus = 2
    }
    return $null
}

function Get-AipGitIgnoreLines {
    return @(
        '# aip-managed credential and runtime exclusions',
        '.env', '.env.*', '!.env.example', '*.pem', '*.key', '*.p12', '*.pfx',
        '.netrc', '.npmrc', '.pypirc', 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'node_modules/',
        '**/.credentials.json', '**/auth.json',
        'claude/.credentials.json', 'claude/history.jsonl', 'claude/projects/', 'claude/session-env/', 'claude/shell-snapshots/', 'claude/statsig/', 'claude/todos/', 'claude/debug/', 'claude/cache/', 'claude/logs/', 'claude/file-history/',
        'codex/auth.json', 'codex/history.jsonl', 'codex/sessions/', 'codex/archived_sessions/', 'codex/log/', 'codex/logs/', 'codex/cache/', 'codex/*.db', 'codex/*.db-*', 'codex/*.sqlite', 'codex/*.sqlite-*',
        'pi/auth.json', 'pi/sessions/', 'pi/logs/', 'pi/cache/', 'pi/models-store.json',
        'opencode/auth.json', 'opencode/sessions/', 'opencode/logs/', 'opencode/cache/'
    )
}

function Get-AipCreateSkillRoots {
    $tree = if ($script:AipCreateSkillsTreeRoot) { $script:AipCreateSkillsTreeRoot } else { (Get-Location).Path }
    $global = if ($script:AipCreateSkillsGlobalRoot) { $script:AipCreateSkillsGlobalRoot } else { Join-Path $HOME '.pi/agent/skills' }
    $agents = if ($script:AipCreateSkillsAgentsRoot) { $script:AipCreateSkillsAgentsRoot } else { Join-Path $HOME '.agents/skills' }
    return @($tree, $global, $agents)
}

function Get-AipCreateSkills {
    $roots = Get-AipCreateSkillRoots
    $treeRoot = if (Test-Path -LiteralPath $roots[0] -PathType Container) { (Resolve-Path -LiteralPath $roots[0]).Path } else { $null }
    $globalRoots = @($roots | Select-Object -Skip 1 | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
    $candidates = @()
    foreach ($globalRoot in $globalRoots) {
        foreach ($item in @(Get-ChildItem -LiteralPath $globalRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $item.FullName 'SKILL.md') -PathType Leaf) { $candidates += [pscustomobject]@{ Name = $item.Name; Source = $item.FullName; Priority = 0 } }
        }
    }
    if ($treeRoot) {
        foreach ($item in @(Get-ChildItem -LiteralPath $treeRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'skills' -and $_.Parent.Name -eq 'pi' })) {
            foreach ($skill in @(Get-ChildItem -LiteralPath $item.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                if ((Test-Path -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -PathType Leaf) -and (Test-AipPathUnder $treeRoot $skill.FullName)) { $candidates += [pscustomobject]@{ Name = $skill.Name; Source = $skill.FullName; Priority = 1 } }
            }
        }
    }
    return @($candidates | Sort-Object Priority, Source | Group-Object Name | ForEach-Object { $_.Group[0] } | Sort-Object Name)
}

function Read-AipCreateSkillSelection {
    param([object[]]$Skills = @())
    if ($script:AipCreateSkipSkillSelection -or $Skills.Count -eq 0 -or [Console]::IsInputRedirected) { return @() }
    Write-Host 'Available Pi skills:'
    for ($i = 0; $i -lt $Skills.Count; $i++) { Write-Host "$($i + 1). $($Skills[$i].Name)" }
    while ($true) {
        $input = Read-Host 'Select skills by number (comma or space separated; Enter for none)'
        if ([string]::IsNullOrWhiteSpace($input)) { return @() }
        if ($input -notmatch '^[0-9,\s]+$') { Write-AipError 'invalid skill selection; enter menu numbers separated by commas or spaces'; continue }
        $numbers = @($input -split '[,\s]+' | Where-Object { $_ })
        $selected = @(); $valid = $true
        foreach ($number in $numbers) {
            $n = 0
            if (-not [int]::TryParse($number, [ref]$n) -or $n -lt 1 -or $n -gt $Skills.Count) { $valid = $false; break }
            if ($selected -notcontains $n) { $selected += $n }
        }
        if ($valid) { return @($selected | ForEach-Object { $Skills[$_ - 1] }) }
        Write-AipError 'invalid skill selection; enter menu numbers separated by commas or spaces'
    }
}

function Copy-AipCreateSkills {
    param([Parameter(Mandatory)][string]$ProfilePath, [object[]]$Skills = @())
    foreach ($skill in $Skills) {
        $links = Get-ChildItem -LiteralPath $skill.Source -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($links) { throw "selected skill contains a symbolic link and cannot be copied safely: $($skill.Name)" }
        $destination = Join-Path $ProfilePath (Join-Path 'skills' $skill.Name)
        if (Test-AipPathEntry $destination) { throw "selected skill destination already exists: $($skill.Name)" }
        Copy-Item -LiteralPath $skill.Source -Destination $destination -Recurse -ErrorAction Stop
    }
}

function Get-AipPrimaryConfigRel {
    return @('pi/settings.json', 'claude/settings.json', 'codex/config.toml', 'opencode/opencode.json')
}

function Copy-AipPrimaryConfigs {
    param([Parameter(Mandatory)][string]$ProfilePath)
    foreach ($rel in @(Get-AipPrimaryConfigRel)) {
        $parts = $rel -split '/', 2
        $source = Join-Path (Get-AipImportHarnessRoot $parts[0]) $parts[1]
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $ProfilePath $rel) -Force -ErrorAction Stop
        }
    }
}

function New-AipProfileFiles {
    param([Parameter(Mandatory)][string]$ProfilePath)

    foreach ($directory in 'skills', 'claude', 'codex', 'pi', 'opencode') {
        New-Item -ItemType Directory -Path (Join-Path $ProfilePath $directory) -Force -ErrorAction Stop | Out-Null
    }
    New-Item -ItemType File -Path (Join-Path $ProfilePath 'skills/.gitkeep') -ErrorAction Stop | Out-Null
    Set-AipUtf8LfFile (Join-Path $ProfilePath 'AGENTS.md') @('# Common profile instructions')
    Set-AipUtf8LfFile (Join-Path $ProfilePath 'claude/CLAUDE.md') @('@../AGENTS.md', '', '# Claude Code instructions')
    Set-AipUtf8LfFile (Join-Path $ProfilePath 'codex/instructions.md') @('# Codex instructions')
    Set-AipUtf8LfFile (Join-Path $ProfilePath 'pi/APPEND_SYSTEM.md') @('# Pi instructions')
    Copy-AipPrimaryConfigs $ProfilePath
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
    if ($Arguments.Count -ne 1) {
        Write-AipError 'usage: aip create NAME'
        $script:AipCommandStatus = 2
        return
    }
    $name = [string]$Arguments[0]
    if (-not (Test-AipProfileName $name)) {
        Write-AipError "invalid profile name '$name'"
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
        New-AipProfileFiles $temporary
        $skills = @(Get-AipCreateSkills)
        $selectedSkills = @(Read-AipCreateSkillSelection $skills)
        Copy-AipCreateSkills $temporary $selectedSkills
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
    Invoke-AipPassthroughProfile $name
    # Add only the profile's owned paths, never the whole directory: pass-through
    # links exist on disk at this point (machine-local, untracked by design) and a
    # broad add would track any that reconciliation failed to ignore.
    $owned = @('.gitignore', 'AGENTS.md', 'skills', 'claude/CLAUDE.md', 'claude/skills', 'codex/AGENTS.md', 'codex/instructions.md', 'codex/skills', 'pi/AGENTS.md', 'pi/APPEND_SYSTEM.md', 'pi/skills', 'opencode/AGENTS.md', 'opencode/skills')
    foreach ($rel in @(Get-AipPrimaryConfigRel)) {
        $ownedConfig = Join-Path $destination $rel
        if ((Test-Path -LiteralPath $ownedConfig -PathType Leaf) -and $null -eq (Get-Item -LiteralPath $ownedConfig -Force).LinkType) { $owned += $rel }
    }
    Invoke-AipGit -C $script:AipProfileRoot add .gitignore @($owned | ForEach-Object { "$($name)/$_" })
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
    Invoke-AipPassthroughProfile $targetName
    Invoke-AipGit -C $script:AipProfileRoot add $targetName
    if ($LASTEXITCODE -ne 0) { Write-AipError "could not commit clone of profile '$sourceName'; check Git identity and hooks"; return }
    # A broad add must not track pass-through links (machine-local, untracked by
    # design); unstage any that reconciliation failed to ignore.
    foreach ($harness in @('pi', 'claude', 'codex', 'opencode')) {
        foreach ($rel in (Get-AipPassthroughRel $harness)) {
            if (-not (Test-AipPassthroughLink "$harness/$rel" $targetPath)) { continue }
            $trackedPath = "$($targetName)/$harness/$rel"
            Invoke-AipGit -C $script:AipProfileRoot ls-files --error-unmatch -- $trackedPath 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            Invoke-AipGit -C $script:AipProfileRoot rm -q --cached -- $trackedPath
            if ($LASTEXITCODE -ne 0) { Write-AipError "could not commit clone of profile '$sourceName'; check Git identity and hooks"; return }
        }
    }
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
        if (-not (Test-AipDeleteConfirm $answer)) { Write-AipError 'deletion cancelled; rerun with --force for non-interactive use'; return }
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
                    # node_modules is machine-local and forbidden from ever being
                    # tracked (see Test-AipForbiddenPath); the links npm creates
                    # inside it are npm's, not the profile's.
                    if ($relative -eq 'node_modules' -or $relative -like 'node_modules/*' -or $relative -like '*/node_modules' -or $relative -like '*/node_modules/*') { continue }
                    if ($item.LinkType -ne 'SymbolicLink' -or (-not $required.Contains($relative) -and -not (Test-AipPassthroughLink $relative $ProfilePath))) {
                        if ($item.LinkType -eq 'SymbolicLink' -and (Test-AipLegacyPrimaryConfigLink $relative $ProfilePath)) {
                            Write-AipWarning "legacy primary-config link $relative is tolerated until migration; run 'aip update' to make it profile-owned"
                            continue
                        }
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
    foreach ($directory in 'skills', 'claude', 'codex', 'pi', 'opencode') {
        $item = Get-Item -LiteralPath (Join-Path $ProfilePath $directory) -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or -not $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            if ($Report) { Write-Output "ERROR: required directory is missing or linked: $directory" }
            $valid = $false
        }
    }
    foreach ($file in '.gitignore', 'AGENTS.md', 'skills/.gitkeep', 'claude/CLAUDE.md', 'codex/instructions.md', 'pi/APPEND_SYSTEM.md') {
        $item = Get-Item -LiteralPath (Join-Path $ProfilePath $file) -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            if ($Report) { Write-Output "ERROR: required file is missing or linked: $file" }
            $valid = $false
        }
    }
    foreach ($file in '.gitignore', 'AGENTS.md', 'skills/.gitkeep', 'claude/CLAUDE.md', 'codex/instructions.md', 'pi/APPEND_SYSTEM.md') {
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
        else {
            Write-AipDoctorPassthrough $profilePath $name
            Write-Output "OK: profile layout and links ($name)"
        }
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
    $leaf = ($relative -split '/')[-1]
    if ($leaf -eq '.credentials.json' -or $leaf -eq 'auth.json') { return $true }
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
        'pi/models-store.json' { return $true }
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
        if ($normalized -like '*/.gitignore') { [void]$prefixes.Add($normalized.Split('/')[0]) }
    }
    return @($prefixes)
}

function Test-AipPathUnderProfile {
    # $ProfilePrefixes may be $null or empty (a repo with no tracked .gitignore
    # files); Mandatory rejects both, so it is optional and a missing prefix
    # list simply means nothing is under a profile prefix.
    param([Parameter(Mandatory)][string]$RelativePath, [string[]]$ProfilePrefixes = @())
    $normalized = [string]$RelativePath.Replace('\', '/')
    $first = $normalized.Split('/')[0]
    if ($normalized -eq $first) { return $false }
    return @($ProfilePrefixes) -contains $first
}

function Get-AipRequiredLinkTarget {
    # $Path = a full relative path (e.g. work/claude/skills). Returns the exact
    # target aip creates for its fixed required profile links, requiring a profile
    # prefix so root-level lookalikes are rejected; $null for any path aip does not
    # link.
    param([Parameter(Mandatory)][string]$Path)
    $normalized = [string]$Path.Replace('\', '/')
    $slashIndex = $normalized.IndexOf('/')
    if ($slashIndex -lt 1) { return $null }
    $relative = $normalized.Substring($slashIndex + 1)
    switch -CaseSensitive ($relative) {
        'claude/skills' { return '../skills' }
        'codex/skills' { return '../skills' }
        'pi/skills' { return '../skills' }
        'opencode/skills' { return '../skills' }
        'codex/AGENTS.md' { return '../AGENTS.md' }
        'pi/AGENTS.md' { return '../AGENTS.md' }
        'opencode/AGENTS.md' { return '../AGENTS.md' }
        default { return $null }
    }
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
    # Marker-free, like the remote-tree scan: a tracked 120000 entry is accepted
    # only when it is a profile-prefixed required link whose stored target is
    # exactly the target aip creates.
    $stagedEntries = @(Invoke-AipGit -C $Root ls-files --stage)
    if ($LASTEXITCODE -ne 0) { Write-AipError 'could not inspect tracked profile modes'; return $false }
    foreach ($entry in $stagedEntries) {
        if ([string]$entry -match '^120000 [0-9a-f]+ \d+\t(.+)$') {
            $relative = ([string]$Matches[1]).Replace('\', '/')
            $expected = Get-AipRequiredLinkTarget $relative
            if ($null -eq $expected) {
                Write-AipError "tracked profile contains an unsupported symbolic link: $relative"
                return $false
            }
            $hash = ([string]$entry -split ' ')[1]
            $target = [string](Invoke-AipGit -C $Root cat-file blob $hash 2>$null)
            if ($LASTEXITCODE -ne 0) {
                Write-AipError "could not read the stored target of tracked link: $relative"
                return $false
            }
            if ($target -cne $expected) {
                Write-AipError "tracked profile link has an unexpected target: $relative"
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
            if ($null -ne $resolved -and (Test-Path -LiteralPath (Join-Path $resolved.FullName '.gitignore'))) { $targetIsProfile = $true }
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
        if ([string]$line -match '^100644 \S+ \S+\t(.+)$' -and ([string]$Matches[1]).Replace('\', '/') -like '*/.gitignore') {
            [void]$prefixes.Add(([string]$Matches[1]).Replace('\', '/').Split('/')[0])
        }
    }
    $profilePrefixList = @($prefixes)
    # Marker-free, like the local tracked-link check: a remote 120000 entry is
    # accepted only when it is a profile-prefixed required link whose stored
    # target is exactly the target aip creates.
    foreach ($entry in @($remoteTree -split "`n")) {
        if ($entry -match '^120000 (?:blob )?[0-9a-f]+\t(.+)$') {
            $relative = ([string]$Matches[1]).Replace('\', '/')
            $expected = Get-AipRequiredLinkTarget $relative
            if ($null -eq $expected) {
                Write-AipError "remote profile contains an unsupported symbolic link: $relative"
                return $false
            }
            $target = [string](Invoke-AipGit -C $Root show "$Tree`:$relative" 2>$null)
            if ($LASTEXITCODE -ne 0) {
                Write-AipError "could not read the stored target of remote link: $relative"
                return $false
            }
            if ($target -cne $expected) {
                Write-AipError "remote profile link has an unexpected target: $relative"
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
    $requiredFiles = @('.gitignore', 'AGENTS.md', 'skills/.gitkeep', 'claude/CLAUDE.md', 'codex/instructions.md', 'pi/APPEND_SYSTEM.md')
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
                if ($file -eq 'claude/CLAUDE.md') {
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

function Invoke-AipUninstall {
    param([object[]]$Arguments)
    $force = $false
    $others = 0
    foreach ($arg in $Arguments) {
        if ([string]$arg -eq '--force') { $force = $true } else { $others++ }
    }
    if ($others -ne 0) { Write-AipError 'usage: aip uninstall [--force]'; $script:AipCommandStatus = 2; return }
    $installRoot = if ($env:_AIP_INSTALL_ROOT) {
        $env:_AIP_INSTALL_ROOT
    } elseif ($IsWindows) {
        Join-Path $env:LOCALAPPDATA 'aip'
    } else {
        Join-Path $HOME '.local/share/aip'
    }
    $shellProfile = if ($env:_AIP_SHELL_PROFILE) { $env:_AIP_SHELL_PROFILE } else { $PROFILE.CurrentUserAllHosts }
    $hasRoot = $false
    if (Test-Path -LiteralPath $installRoot -PathType Container) {
        foreach ($marker in @('aip.sh', 'aip.ps1', 'VERSION')) {
            if (Test-Path -LiteralPath (Join-Path $installRoot $marker) -PathType Leaf) { $hasRoot = $true; break }
        }
    }
    $hasBlock = $false
    if (Test-Path -LiteralPath $shellProfile -PathType Leaf) {
        $hasBlock = ([IO.File]::ReadAllText($shellProfile) -match '(?m)^# >>> aip >>>\s*$')
    }
    if (-not $hasRoot -and -not $hasBlock) {
        Write-Output "Nothing to uninstall (no aip install at $installRoot and no aip block in $shellProfile)."
        return
    }
    if (-not $force) {
        $prompt = if ($hasRoot -and $hasBlock) { 'Remove the aip installation root and the shell profile block? [y/N]' } elseif ($hasRoot) { 'Remove the aip installation root? [y/N]' } else { 'Remove the aip block from your shell profile? [y/N]' }
        $answer = $null
        try { $answer = Read-Host $prompt }
        catch {
            Write-AipError 'uninstall requires confirmation; rerun with --force for non-interactive use'
            return
        }
        if (-not (Test-AipDeleteConfirm $answer)) { Write-AipError 'uninstall cancelled; rerun with --force for non-interactive use'; return }
    }
    if ($hasBlock) {
        $raw = [IO.File]::ReadAllText($shellProfile)
        # Drops the marked block and the separator newline the installer adds
        # before it; every other line is preserved verbatim.
        $removed = [regex]::Replace($raw, '(?:\r?\n)?# >>> aip >>>\r?\n(?:.*?\r?\n)?# <<< aip <<<\r?\n', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        try {
            [IO.File]::WriteAllText($shellProfile, $removed)
        }
        catch {
            Write-AipError "could not update the shell profile: $shellProfile"
            return
        }
    }
    if ($hasRoot) {
        try {
            Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-AipError "could not remove the install root: $installRoot"
            return
        }
    }
    Write-Output "Uninstalled aip. Your profiles repository at $($script:AipProfileRoot) and your harness configuration are untouched; restart your shell to finish."
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
    $owned = @('.gitignore', 'AGENTS.md', 'skills', 'claude/CLAUDE.md', 'claude/skills', 'codex/AGENTS.md', 'codex/instructions.md', 'codex/skills', 'pi/AGENTS.md', 'pi/APPEND_SYSTEM.md', 'pi/skills', 'opencode/AGENTS.md', 'opencode/skills')
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
        $preSha = Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify 'HEAD^{commit}' 2>$null
        if ($LASTEXITCODE -ne 0) { $preSha = '' }
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
            if ($Mode -eq 'before' -or $Mode -eq 'after') {
                $curSha = Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify 'HEAD^{commit}' 2>$null
                if ($LASTEXITCODE -eq 0 -and $curSha -eq $preSha) {
                    $storedSha = Invoke-AipGit -C $script:AipProfileRoot rev-parse --verify "refs/remotes/$remote/$branch^{commit}" 2>$null
                    $remoteLine = Invoke-AipGit -C $script:AipProfileRoot ls-remote $remote $mergeRef 2>$null
                    $remoteSha = if ($LASTEXITCODE -eq 0 -and $remoteLine) { ("$remoteLine" -split '\s+')[0] } else { '' }
                    if ($remoteSha -and $remoteSha -eq $storedSha -and $curSha -eq $storedSha) {
                        Write-Output "Profiles up to date with $upstream."
                        return
                    }
                }
            }
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
    finally {
        Exit-AipSyncLock
    }
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
    Invoke-AipPassthrough $Harness $profile.Name
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

function Test-AipLegacyPrimaryConfigLink {
    param([Parameter(Mandatory)][string]$Relative, [Parameter(Mandatory)][string]$ProfilePath)
    if ($Relative -notin @(Get-AipPrimaryConfigRel)) { return $false }
    $slash = $Relative.IndexOf('/')
    $harness = $Relative.Substring(0, $slash)
    $rel = $Relative.Substring($slash + 1)
    $root = Get-AipImportHarnessRoot $harness
    $item = Get-Item -LiteralPath (Join-Path $ProfilePath $Relative) -Force -ErrorAction SilentlyContinue
    if (-not $root -or $null -eq $item -or $item.LinkType -ne 'SymbolicLink') { return $false }
    $raw = ([string]$item.Target).Replace('\\', '/')
    $expected = ConvertTo-AipRelativePath (Join-Path $ProfilePath $harness) (Join-Path $root $rel)
    if ($raw -eq $expected) { return $true }
    # Lexical absolute form: matches the exact config path even when the target is
    # absent (a broken link), so migration can still retire it.
    $sep = [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::GetFullPath($raw.Replace('/', $sep)) -eq [IO.Path]::GetFullPath((Join-Path $root $rel))) { return $true }
    try {
        $resolved = $item.ResolveLinkTarget($true)
        if ($null -eq $resolved) { return $false }
        return [IO.Path]::GetFullPath($resolved.FullName) -eq [IO.Path]::GetFullPath((Join-Path $root $rel))
    }
    catch { return $false }
}

function Invoke-AipMigrateLegacyPrimaryConfigLinks {
    $root = $script:AipProfileRoot
    if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container)) { return }
    foreach ($name in @(Get-AipProfileNames)) {
        $profile = Get-AipProfilePath $name
        $gitignore = Join-Path $profile '.gitignore'
        foreach ($relative in @(Get-AipPrimaryConfigRel)) {
            if (-not (Test-AipLegacyPrimaryConfigLink $relative $profile)) { continue }
            $slash = $relative.IndexOf('/')
            $harness = $relative.Substring(0, $slash); $rel = $relative.Substring($slash + 1)
            $source = Join-Path (Get-AipImportHarnessRoot $harness) $rel
            $destination = Join-Path $profile $relative
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                # Copy to a sibling temporary file first so a failed copy never
                # destroys the link.
                $temporary = "$destination.$([IO.Path]::GetRandomFileName())"
                try {
                    Copy-Item -LiteralPath $source -Destination $temporary -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
                    Move-Item -LiteralPath $temporary -Destination $destination -Force -ErrorAction Stop
                    Remove-AipPassthroughGitIgnoreEntry $gitignore $relative
                    Invoke-AipGit -C $root add -- "$name/$relative"
                    if ($global:LASTEXITCODE -ne 0) { throw 'git add failed' }
                    Write-Output "aip: staged $name/$relative for sharing (the next checkpoint commits it)"
                }
                catch {
                    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
                    Write-AipWarning "could not migrate legacy link $name/$relative"
                }
            }
            else {
                # A legacy link is normally untracked (the pass-through block
                # ignored it), so there is nothing to stage for its removal
                # unless it was force-tracked.
                $tracked = Test-AipTrackedPath "$name/$relative"
                try {
                    Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
                    Remove-AipPassthroughGitIgnoreEntry $gitignore $relative
                    if ($tracked) {
                        Invoke-AipGit -C $root add -u -- "$name/$relative"
                        if ($global:LASTEXITCODE -ne 0) { throw 'git add -u failed' }
                        Write-Output "aip: staged deletion of $name/$relative (the global config is absent)"
                    }
                    else {
                        Write-Output "aip: removed legacy link $name/$relative (the global config is absent)"
                    }
                }
                catch { Write-AipWarning "could not remove legacy link $name/$relative" }
            }
        }
    }
}

function Invoke-AipAdoptUntrackedSettings {
    # One-time adoption for profiles created before aip tracked pi/settings.json:
    # stage (never commit) every profile's real, untracked file so the next
    # checkpoint shares it. Warn-only; never fails.
    $root = $script:AipProfileRoot
    if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container)) { return }
    foreach ($name in @(Get-AipProfileNames)) {
        $settings = Join-Path (Get-AipProfilePath $name) 'pi/settings.json'
        $item = Get-Item -LiteralPath $settings -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer -or $null -ne $item.LinkType) { continue }
        if (Test-AipTrackedPath "$name/pi/settings.json") { continue }
        Invoke-AipGit -C $root add -- "$name/pi/settings.json"
        if ($global:LASTEXITCODE -eq 0) {
            Write-Output "aip: staged $name/pi/settings.json for sharing (the next checkpoint commits it)"
        }
        else {
            Write-AipWarning "could not stage $name/pi/settings.json"
        }
    }
}

function Invoke-AipSyncPackages {
    # Sync a profile's pi package list (the "packages" array of pi/settings.json)
    # with the machine-wide global settings. Node performs the JSON splice so
    # unrelated lines of the settings file stay byte-identical.
    # Modes: bulk (default) copies the global array when absent and reports a diff
    # otherwise; --replace adopts the global list; --add SPEC / --remove PKG are
    # surgical. Stage-only: edits the file, no Git write.
    param([object[]]$Arguments)
    $name = ''; $mode = 'bulk'; $spec = ''; $pkg = ''; $haveName = $false
    if ($Arguments.Count -gt 5) { Write-AipError 'usage: aip sync-packages [NAME] [--add SPEC | --remove PKG | --replace]'; $script:AipCommandStatus = 2; return }
    $i = 0
    while ($i -lt $Arguments.Count) {
        $arg = [string]$Arguments[$i]
        switch ($arg) {
            '--add' {
                if ($i + 1 -ge $Arguments.Count) { Write-AipError '--add requires a package spec'; $script:AipCommandStatus = 2; return }
                if ($mode -ne 'bulk') { Write-AipError 'combine at most one of --add, --remove, --replace'; $script:AipCommandStatus = 2; return }
                $mode = 'add'; $spec = [string]$Arguments[$i + 1]; $i += 2
            }
            '--remove' {
                if ($i + 1 -ge $Arguments.Count) { Write-AipError '--remove requires a package name'; $script:AipCommandStatus = 2; return }
                if ($mode -ne 'bulk') { Write-AipError 'combine at most one of --add, --remove, --replace'; $script:AipCommandStatus = 2; return }
                $mode = 'remove'; $pkg = [string]$Arguments[$i + 1]; $i += 2
            }
            '--replace' {
                if ($mode -ne 'bulk') { Write-AipError 'combine at most one of --add, --remove, --replace'; $script:AipCommandStatus = 2; return }
                $mode = 'replace'; $i += 1
            }
            default {
                if ($arg -like '-*') { Write-AipError "unknown option '$arg'"; $script:AipCommandStatus = 2; return }
                if ($haveName) { Write-AipError "unexpected argument '$arg'"; $script:AipCommandStatus = 2; return }
                $haveName = $true; $name = $arg; $i += 1
            }
        }
    }
    $profile = Resolve-AipProfile $name $haveName
    if ($null -eq $profile) { return }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-AipError 'sync-packages requires Node.js on PATH'; $script:AipCommandStatus = 1; return }
    $profileSettings = Join-Path $profile.Path 'pi/settings.json'
    $linkItem = Get-Item -LiteralPath $profileSettings -Force -ErrorAction SilentlyContinue
    if ($null -ne $linkItem -and $null -ne $linkItem.LinkType) {
        Write-AipError "$($profile.Name)/pi/settings.json is a pass-through link; give the profile its own settings file first (copy the global one), then retry"
        $script:AipCommandStatus = 1
        return
    }
    if (-not (Test-Path -LiteralPath $profileSettings -PathType Leaf)) { Write-AipError "$($profile.Name) has no pi/settings.json"; $script:AipCommandStatus = 1; return }
    $globalSettings = Join-Path (Get-AipImportHarnessRoot 'pi') 'settings.json'
    $js = @'
const fs = require("fs");
// node -e puts the -e script outside argv: [node, mode, profile, global, spec, pkg]
const mode = process.argv[1];
const profilePath = process.argv[2];
const globalPath = process.argv[3];
const spec = process.argv[4];
const pkg = process.argv[5];

const profileText = fs.readFileSync(profilePath, "utf8");
const globalText = fs.existsSync(globalPath) ? fs.readFileSync(globalPath, "utf8") : null;

function skipString(text, i) {
  let j = i + 1;
  while (j < text.length) {
    if (text[j] === "\\") j += 2;
    else if (text[j] === '"') return j + 1;
    j++;
  }
  return j;
}

function findPackages(text) {
  // { arrStart, arrEnd, indent } of the top-level "packages" array member, or null
  let depth = 0;
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') {
      const end = skipString(text, i);
      if (depth === 1 && text.slice(i + 1, end - 1) === "packages") {
        let k = end;
        while (k < text.length && /\s/.test(text[k])) k++;
        if (text[k] === ":") {
          k++;
          while (k < text.length && /\s/.test(text[k])) k++;
          if (text[k] !== "[") {
            // a top-level "packages" member that is not an array: refuse to
            // touch the file rather than insert a duplicate member
            return { nonArray: true };
          }
          {
            let d = 0;
            let m = k;
            while (m < text.length) {
              const ch = text[m];
              if (ch === '"') m = skipString(text, m);
              else if (ch === "[") d++;
              else if (ch === "]") { d--; if (d === 0) break; }
              m++;
            }
            const lineStart = text.lastIndexOf("\n", i) + 1;
            return { arrStart: k, arrEnd: m, indent: text.slice(lineStart, i) };
          }
        }
      }
      i = end;
    } else {
      if (c === "{" || c === "[") depth++;
      else if (c === "}" || c === "]") depth--;
      i++;
    }
  }
  return null;
}

function parseEntries(text, arrStart, arrEnd) {
  const inner = text.slice(arrStart + 1, arrEnd);
  const entries = [];
  let i = 0;
  while (i < inner.length) {
    while (i < inner.length && /[\s,]/.test(inner[i])) i++;
    if (i >= inner.length) break;
    let end;
    if (inner[i] === '"') end = skipString(inner, i);
    else if (inner[i] === "{") {
      let d = 0;
      let m = i;
      while (m < inner.length) {
        const ch = inner[m];
        if (ch === '"') m = skipString(inner, m);
        else if (ch === "{") d++;
        else if (ch === "}") { d--; if (d === 0) break; }
        m++;
      }
      end = m + 1;
    } else {
      let m = i;
      while (m < inner.length && !/[\s,]/.test(inner[m])) m++;
      end = m;
    }
    entries.push(inner.slice(i, end));
    i = end;
  }
  return entries;
}

function renderArray(entries, indent) {
  if (entries.length === 0) return "[]";
  const child = indent + "  ";
  return "[\n" + entries.map((e) => child + e).join(",\n") + "\n" + indent + "]";
}

function insertMember(text, entries, indent) {
  // splice a new top-level "packages" member just before the root object's close
  let depth = 0;
  let closeIdx = -1;
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') { i = skipString(text, i); continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) { closeIdx = i; break; } }
    i++;
  }
  if (closeIdx === -1) return null;
  const pre = text.slice(0, closeIdx).replace(/\s+$/, "");
  const suffix = text.slice(closeIdx);
  const comma = pre.endsWith("{") ? "" : ",";
  return pre + comma + "\n" + indent + '"packages": ' + renderArray(entries, indent) + "\n" + suffix;
}

function entryName(entry) {
  let value;
  try { value = JSON.parse(entry); } catch (e) { return entry; }
  if (typeof value === "object" && value !== null) value = value.source ?? entry;
  if (typeof value === "string" && value.startsWith("npm:")) return value.slice(4);
  return typeof value === "string" ? value : entry;
}

const globalMember = globalText ? findPackages(globalText) : null;
if (globalMember && globalMember.nonArray) {
  console.error("the global settings' \"packages\" member is not an array; fix it by hand");
  process.exit(2);
}
const globalEntries = globalMember && !globalMember.nonArray ? parseEntries(globalText, globalMember.arrStart, globalMember.arrEnd) : null;
const profileMember = findPackages(profileText);
if (profileMember && profileMember.nonArray) {
  console.error("the profile settings' \"packages\" member is not an array; fix it by hand");
  process.exit(2);
}
const profileEntries = profileMember && !profileMember.nonArray ? parseEntries(profileText, profileMember.arrStart, profileMember.arrEnd) : null;

function spliceIntoProfile(entries) {
  if (profileMember) {
    return profileText.slice(0, profileMember.arrStart) + renderArray(entries, profileMember.indent) + profileText.slice(profileMember.arrEnd + 1);
  }
  const inserted = insertMember(profileText, entries, "  ");
  if (inserted === null) {
    console.error("could not locate the end of the settings object");
    process.exit(2);
  }
  return inserted;
}

function writeProfile(newText) { fs.writeFileSync(profilePath, newText); }

if (mode === "bulk" || mode === "replace") {
  if (!globalEntries) {
    if (mode === "replace") { console.error("the global pi settings define no packages to replace with"); process.exit(2); }
    console.log("global pi settings define no packages; nothing to copy");
    process.exit(0);
  }
  if (profileEntries === null) {
    writeProfile(spliceIntoProfile(globalEntries));
    console.log(`copied ${globalEntries.length} package(s) from global settings`);
    process.exit(0);
  }
  if (profileEntries.length === globalEntries.length && profileEntries.every((e, i) => e === globalEntries[i])) {
    console.log("package list already matches global settings");
    process.exit(0);
  }
  console.log("package list differs from global settings:");
  for (const e of profileEntries.filter((e) => !globalEntries.includes(e))) console.log(`  - ${e} (profile only)`);
  for (const e of globalEntries.filter((e) => !profileEntries.includes(e))) console.log(`  + ${e} (global only)`);
  if (mode === "replace") {
    writeProfile(spliceIntoProfile(globalEntries));
    console.log(`replaced the profile package list with the global ${globalEntries.length} package(s)`);
    process.exit(0);
  }
  console.log("re-run with --replace to adopt the global list");
  process.exit(1);
}

if (mode === "add") {
  // a bare spec (npm:foo) is JSON-stringified; a quoted or object entry is kept verbatim
  let entry = spec;
  try {
    const parsed = JSON.parse(spec);
    if (typeof parsed === "string") entry = JSON.stringify(parsed);
  } catch (e) {
    entry = JSON.stringify(spec);
  }
  if (profileEntries === null) {
    writeProfile(spliceIntoProfile([entry]));
    console.log(`added ${entry}`);
    process.exit(0);
  }
  if (profileEntries.includes(entry)) { console.log(`${entry} is already present`); process.exit(0); }
  writeProfile(spliceIntoProfile([...profileEntries, entry]));
  console.log(`added ${entry}`);
  process.exit(0);
}

if (mode === "remove") {
  if (profileEntries === null) { console.log("profile has no packages; nothing to remove"); process.exit(0); }
  const idx = profileEntries.findIndex((e) => e === pkg || entryName(e) === pkg);
  if (idx === -1) { console.log(`${pkg} is not in the profile package list`); process.exit(0); }
  const removed = profileEntries[idx];
  writeProfile(spliceIntoProfile(profileEntries.filter((_, i) => i !== idx)));
  console.log(`removed ${removed}`);
  process.exit(0);
}

console.error(`unknown mode ${mode}`);
process.exit(2);
'@
    & node -e $js $mode $profileSettings $globalSettings $spec $pkg
    $script:AipCommandStatus = $LASTEXITCODE
}

function Invoke-AipUpdate {
    param([object[]]$Arguments)
    if ($Arguments.Count -gt 0) { Write-AipError 'usage: aip update'; $script:AipCommandStatus = 2; return }
    Invoke-AipMigrateLegacyPrimaryConfigLinks
    Invoke-AipAdoptUntrackedSettings
    if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { Write-AipError 'update requires Node.js (npx) on PATH'; $script:AipCommandStatus = 1; return }
    & npx --yes '@code-ministry/aip@latest' update
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
    $script:AipResolveReason = ''
    $script:AipResolveQuiet = $true
    try { $profile = Resolve-AipProfile } finally { $script:AipResolveQuiet = $false }
    if ($null -eq $profile) {
        if ($script:AipResolveReason -eq 'no-selection') {
            if (@(Get-AipProfileNames).Count -gt 0) {
                Write-Output 'No profile selected. Available profiles:'
                Invoke-AipList -Arguments @()
                Write-Output "Select one with 'aip use NAME' (this shell) or 'aip default NAME' (persistent)."
                return
            }
            Write-AipError "no profile selected; run 'aip create NAME' then 'aip use NAME'"
            $script:AipCommandStatus = 2
        }
        return
    }
    Write-Output "🐵 $($profile.Name)"
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
            ($null -ne (Get-Item -LiteralPath (Join-Path $_.FullName '.gitignore') -Force -ErrorAction SilentlyContinue))
    } | Sort-Object Name)
    if ($profiles.Count -eq 0) { Write-Output 'No profiles. Create one with: aip create NAME'; return }
    foreach ($profile in $profiles) {
        $tags = @()
        if ($env:AIP_PROFILE -eq $profile.Name) { $tags += '[session]' }
        if ($null -ne $project -and $project.Name -eq $profile.Name) { $tags += '[project]' }
        if ($defaultName -eq $profile.Name) { $tags += '[default]' }
        $suffix = if ($tags.Count) { ' ' + ($tags -join ' ') } else { '' }
        Write-Output "$($profile.Name)$suffix"
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

function Invoke-AipManage {
    param([object[]]$Arguments)
    if ($Arguments.Count -eq 0) { Write-AipError 'usage: aip manage HARNESS [ARGS...]'; $script:AipCommandStatus = 2; return }
    $harness = [string]$Arguments[0]
    $rest = @($Arguments | Select-Object -Skip 1)
    if ($harness -notin @('claude', 'codex', 'pi', 'opencode')) {
        Write-AipError "unknown harness '$harness'; expected claude, codex, pi, or opencode"
        $script:AipCommandStatus = 2
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'aip') -PathType Container)) {
        Write-AipError "the 'aip' profile does not exist; run 'aip create aip' first (the aip installer creates it)"
        $script:AipCommandStatus = 1
        return
    }
    $previousProfile = if (Test-Path Env:AIP_PROFILE) { $env:AIP_PROFILE } else { $null }
    $env:AIP_PROFILE = 'aip'
    try { Invoke-AipRun (@('aip', $harness) + @($rest)) }
    finally {
        if ($null -eq $previousProfile) { Remove-Item Env:AIP_PROFILE -ErrorAction SilentlyContinue }
        else { $env:AIP_PROFILE = $previousProfile }
    }
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
    if ($url.Count -eq 1 -and "$url[0]".Trim().Length -gt 0) { Write-Output (Get-AipRedactedUrl $url[0]) }
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
    if ($Url -match '\s') { Write-AipError "invalid remote URL: $(Get-AipRedactedUrl $Url)"; $script:AipCommandStatus = 2; return }
    $root = $script:AipProfileRoot
    $rootGit = Join-Path $root '.git'
    $repoExists = (Test-Path -LiteralPath $rootGit -PathType Container) -and
        $null -ne (Get-Item -LiteralPath $rootGit -Force -ErrorAction SilentlyContinue) -and
        -not ((Get-Item -LiteralPath $rootGit -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))
    if ($repoExists) {
        $existing = @(Invoke-AipGit -C $root remote get-url origin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $existing.Count -eq 1 -and "$existing[0]".Trim().Length -gt 0) {
            Write-AipError "origin is already configured ($(Get-AipRedactedUrl $existing[0])); run 'aip remote remove' first"
            $script:AipCommandStatus = 1
            return
        }
        $null = Invoke-AipGit -C $root remote add origin $Url
        if ($LASTEXITCODE -ne 0) {
            Write-AipError "could not configure origin: $(Get-AipRedactedUrl $Url)"
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
        $oldPrompt = $env:GIT_TERMINAL_PROMPT
        $oldGcm = $env:GCM_INTERACTIVE
        $oldSsh = $env:GIT_SSH_COMMAND
        $oldVariant = $env:GIT_SSH_VARIANT
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        $env:GIT_SSH_COMMAND = $transport.Command
        $env:GIT_SSH_VARIANT = $transport.Variant
        try {
            $null = Invoke-AipGit clone -c core.symlinks=true --quiet -- $Url $root
            if ($LASTEXITCODE -ne 0) {
                Write-AipError "could not clone $(Get-AipRedactedUrl $Url) into $root; the remote must be a profiles repository created by aip"
                $script:AipCommandStatus = 1
                return
            }
        }
        finally {
            if ($null -eq $oldPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
            if ($null -eq $oldGcm) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue } else { $env:GCM_INTERACTIVE = $oldGcm }
            if ($null -eq $oldSsh) { Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue } else { $env:GIT_SSH_COMMAND = $oldSsh }
            if ($null -eq $oldVariant) { Remove-Item Env:GIT_SSH_VARIANT -ErrorAction SilentlyContinue } else { $env:GIT_SSH_VARIANT = $oldVariant }
        }
        $null = Invoke-AipGit -C $root config --replace-all core.symlinks true
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
        Write-Output "Cloned profiles from $(Get-AipRedactedUrl $Url)."
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
    $oldPrompt = $env:GIT_TERMINAL_PROMPT
    $oldGcm = $env:GCM_INTERACTIVE
    $oldSsh = $env:GIT_SSH_COMMAND
    $oldVariant = $env:GIT_SSH_VARIANT
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
    finally {
        if ($null -eq $oldPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
        if ($null -eq $oldGcm) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue } else { $env:GCM_INTERACTIVE = $oldGcm }
        if ($null -eq $oldSsh) { Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue } else { $env:GIT_SSH_COMMAND = $oldSsh }
        if ($null -eq $oldVariant) { Remove-Item Env:GIT_SSH_VARIANT -ErrorAction SilentlyContinue } else { $env:GIT_SSH_VARIANT = $oldVariant }
    }
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

function Get-AipImportHarnessRoot {
    param([Parameter(Mandatory)][string]$Harness)
    switch ($Harness) {
        'pi' { return Join-Path $script:AipImportHome '.pi/agent' }
        'claude' { return Join-Path $script:AipImportHome '.claude' }
        'codex' { return Join-Path $script:AipImportHome '.codex' }
        'opencode' { return Join-Path $script:AipImportHome '.config/opencode' }
        default { return $null }
    }
}

$script:AipPassthroughBegin = '# aip pass-through (machine-local, do not sync) BEGIN'
$script:AipPassthroughEnd = '# aip pass-through END'

function Get-AipPassthroughRel {
    # The per-harness pass-through allowlist: machine-local configuration inputs that
    # every profile falls back to unless it defines the path itself. Only these paths
    # may ever be linked by pass-through maintenance.
    param([Parameter(Mandatory)][string]$Harness)
    switch ($Harness) {
        'pi' { return @('models.json', 'auth.json', 'themes', 'prompts', 'extensions', 'npm') }
        'claude' { return @('settings.local.json', '.credentials.json', 'agents', 'commands', 'context-mode', 'output-styles', 'workflows', 'keybindings.json', 'plugins') }
        'codex' { return @('auth.json', 'plugins') }
        'opencode' { return @('auth.json', 'tui.json', 'agent', 'command', 'plugins') }
        default { return @() }
    }
}

function ConvertTo-AipRelativePath {
    # $From (absolute directory), $To (absolute path); prints the relative path from
    # $From to $To (forward slashes), e.g. ../../../.pi/agent/models.json.
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $rel = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($From), [IO.Path]::GetFullPath($To))
    return $rel.Replace('\', '/')
}

function Test-AipPathComparison {
    # Case-insensitive on Windows (where paths are case-insensitive), ordinal elsewhere.
    if ($IsWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Test-AipPassthroughLink {
    # $Relative (e.g. pi/models.json), $ProfilePath. Returns $true when the link is a
    # pass-through link: allowlisted rel whose target is confined to the harness
    # default root. Accepts broken links whose raw target is exactly the expected
    # relative path; for absolute targets the canonical target must resolve under the
    # root, and when it cannot resolve (broken link) the raw target must stay inside
    # the root after lexical ..-normalisation (so crafted ../ escapes are rejected
    # even when the escape path does not exist).
    param([Parameter(Mandatory)][string]$Relative, [Parameter(Mandatory)][string]$ProfilePath)
    $slash = $Relative.IndexOf('/')
    if ($slash -lt 0) { return $false }
    $harness = $Relative.Substring(0, $slash)
    $rel = $Relative.Substring($slash + 1)
    if ($harness -notin 'pi', 'claude', 'codex', 'opencode') { return $false }
    if ($rel -eq '' -or $rel.Contains('/')) { return $false }
    if ((Get-AipPassthroughRel $harness) -cnotcontains $rel) { return $false }
    $root = Get-AipImportHarnessRoot $harness
    if (-not $root) { return $false }
    $item = Get-Item -LiteralPath (Join-Path $ProfilePath $Relative) -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.LinkType -ne 'SymbolicLink') { return $false }
    $raw = ([string]$item.Target).Replace('\', '/')
    $expected = ConvertTo-AipRelativePath (Join-Path $ProfilePath $harness) (Join-Path $root $rel)
    if ($raw -eq $expected) { return $true }
    $comparison = Test-AipPathComparison
    $sep = [IO.Path]::DirectorySeparatorChar
    $normRoot = [IO.Path]::GetFullPath($root).TrimEnd($sep) + $sep
    $canonical = $null
    try {
        $resolved = $item.ResolveLinkTarget($true)
        if ($null -ne $resolved) { $canonical = $resolved.FullName }
    }
    catch {
        # Broken link: ResolveLinkTarget cannot resolve; fall through to the
        # lexical ..-normalisation check below.
        $canonical = $null
    }
    if ($null -ne $canonical -and $canonical -ne '') {
        $normCanonical = [IO.Path]::GetFullPath($canonical)
        return $normCanonical.StartsWith($normRoot, $comparison)
    }
    # broken link: lexical resolution must stay under the root
    $normRaw = [IO.Path]::GetFullPath($raw.Replace('/', $sep))
    return $normRaw.StartsWith($normRoot, $comparison)
}

function Test-AipImportBlockedByPassthroughDir {
    # True when a prefix of dest (not dest itself) is a pass-through directory link.
    # Managed skills/AGENTS.md links are not pass-through and are left alone.
    param(
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$Rel
    )
    $parts = @($Rel.Replace('\', '/').Split('/') | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2) { return $false }
    $prefix = ''
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        if ($prefix -eq '') { $prefix = $parts[$i] } else { $prefix = $prefix + '/' + $parts[$i] }
        $candidate = Join-Path $ProfilePath (Join-Path $Harness $prefix)
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        $isDirLink = $item.PSIsContainer -and ($null -ne $item.LinkType) -and ($item.LinkType -eq 'SymbolicLink')
        if (-not $isDirLink) { continue }
        if (Test-AipImportManagedLink $candidate) { continue }
        if (Test-AipPassthroughLink -Relative "$Harness/$prefix" -ProfilePath $ProfilePath) { return $true }
    }
    return $false
}

function Get-AipPassthroughGitIgnoreEntry {
    param([Parameter(Mandatory)][string]$GitIgnorePath)
    if (-not (Test-Path -LiteralPath $GitIgnorePath -PathType Leaf)) { return @() }
    $entries = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    foreach ($line in (Get-Content -LiteralPath $GitIgnorePath)) {
        if ($line -eq $script:AipPassthroughBegin) { $inBlock = $true; continue }
        if ($inBlock -and $line -eq $script:AipPassthroughEnd) { $inBlock = $false; continue }
        if ($inBlock -and $line -ne '') { $entries.Add($line) }
    }
    return @($entries)
}

function Set-AipPassthroughGitIgnoreBlock {
    # Rewrites only the marked block; every other line is preserved verbatim.
    param([Parameter(Mandatory)][string]$GitIgnorePath, [string[]]$Entries)
    $out = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    foreach ($line in (Get-Content -LiteralPath $GitIgnorePath)) {
        if ($line -eq $script:AipPassthroughBegin) { $inBlock = $true; continue }
        if ($inBlock -and $line -eq $script:AipPassthroughEnd) { $inBlock = $false; continue }
        if ($inBlock) { continue }
        $out.Add($line)
    }
    if (@($Entries).Count -gt 0) {
        $out.Add($script:AipPassthroughBegin)
        foreach ($entry in (@($Entries) | Sort-Object -Unique)) { $out.Add($entry) }
        $out.Add($script:AipPassthroughEnd)
    }
    Set-AipUtf8LfFile $GitIgnorePath @($out)
}

function Remove-AipPassthroughGitIgnoreEntry {
    param([Parameter(Mandatory)][string]$GitIgnorePath, [Parameter(Mandatory)][string]$Entry)
    $current = @(Get-AipPassthroughGitIgnoreEntry $GitIgnorePath | Where-Object { $_ -ne $Entry })
    Set-AipPassthroughGitIgnoreBlock $GitIgnorePath $current
}

function Test-AipTrivialJsonFile {
    # True when the file holds only an empty value (no bytes, or an empty JSON
    # object/array up to whitespace) — a stub that never carries user content.
    param([Parameter(Mandatory)][string]$LiteralPath)
    try {
        $content = (Get-Content -LiteralPath $LiteralPath -Raw -ErrorAction Stop) -replace '\s', ''
    } catch { return $false }
    return ($null -eq $content) -or $content -eq '{}' -or $content -eq '[]'
}

function Test-AipTrackedPath {
    # Returns $true when the profile-relative path is tracked in the profiles repo.
    param([Parameter(Mandatory)][string]$RepoRel)
    Invoke-AipGit -C $script:AipProfileRoot ls-files --error-unmatch -- $RepoRel *> $null
    return $global:LASTEXITCODE -eq 0
}

function Test-AipPathResolve {
    # PowerShell's Test-Path reports $true for a broken symlink (the provider treats
    # the link itself as a path entry), so link targets are resolved and checked:
    # a link is "resolving" only when its final target exists.
    param([Parameter(Mandatory)][string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if ($null -ne $item.LinkType) {
        try {
            $resolved = $item.ResolveLinkTarget($true)
            return $null -ne $resolved -and $resolved.Exists
        }
        catch { return $false }
    }
    return $true
}

function Invoke-AipPassthrough {
    # $Harness, $Name. Ensures the profile's pass-through links for one harness match
    # the machine-local default root: creates missing links (never overwriting an
    # existing path, skipping paths already tracked in Git), removes broken links with
    # a warning, and reconciles the .gitignore block. Never throws: problems warn.
    param([Parameter(Mandatory)][string]$Harness, [Parameter(Mandatory)][string]$Name)
    try {
        $profilePath = Get-AipProfilePath $Name
        $root = Get-AipImportHarnessRoot $Harness
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return }
        $harnessDir = Join-Path $profilePath $Harness
        if (-not (Test-Path -LiteralPath $harnessDir -PathType Container)) { return }
        $gitIgnorePath = Join-Path $profilePath '.gitignore'
        $relList = @(Get-AipPassthroughRel $Harness)
        $removedThisRun = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

        # 1. Remove broken pass-through links (raw target is pass-through but the
        #    machine-local file or directory is gone). Removing first lets a link be
        #    re-created below when the default path comes back.
        foreach ($rel in $relList) {
            $dest = Join-Path $harnessDir $rel
            $item = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and $item.LinkType -eq 'SymbolicLink' -and (Test-AipPassthroughLink "$Harness/$rel" $profilePath) -and -not (Test-AipPathResolve $dest)) {
                Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
                if (Test-AipPathResolve $dest) {
                    Write-AipWarning "could not remove stale pass-through link $Name/$Harness/$rel"
                }
                else {
                    Write-AipWarning "removed stale pass-through link $Name/$Harness/$rel (its machine-local target is gone)"
                    [void]$removedThisRun.Add("$Harness/$rel")
                }
            }
        }

        # 2. Create missing links for allowlisted paths that exist in the default root
        #    and are absent from the profile (or were just removed as broken). A real
        #    file or directory with content shadows the link; a tracked path is exempt.
        #    A trivial real file (an empty stub) is replaced by the link so it never
        #    shadows the machine-wide default for good.
        foreach ($rel in $relList) {
            $dest = Join-Path $harnessDir $rel
            $existing = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                if ($null -eq $existing.LinkType -and $existing.PSIsContainer -eq $false -and
                    (Test-AipTrivialJsonFile $dest) -and
                    (Test-Path -LiteralPath (Join-Path $root $rel)) -and
                    -not (Test-AipTrackedPath "$Name/$Harness/$rel")) {
                    $source = Join-Path $root $rel
                    $expected = ConvertTo-AipRelativePath $harnessDir $source
                    # Remove-Item returns nothing: re-check the path instead of its return value.
                    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
                    if (-not (Test-AipPathEntry $dest)) {
                        try {
                            New-Item -ItemType SymbolicLink -Path $dest -Target $expected -ErrorAction Stop | Out-Null
                            Write-AipWarning "replaced trivial $Name/$Harness/$rel with its pass-through link (it held only an empty value)"
                        }
                        catch {
                            Write-AipWarning "could not re-create pass-through link $Name/$Harness/$rel after removing its trivial file"
                        }
                    }
                    else {
                        Write-AipWarning "could not remove trivial file $Name/$Harness/$rel; kept it"
                    }
                }
                continue
            }
            $source = Join-Path $root $rel
            if (-not (Test-Path -LiteralPath $source)) { continue }
            if (Test-AipTrackedPath "$Name/$Harness/$rel") { continue }
            $expected = ConvertTo-AipRelativePath $harnessDir $source
            try {
                New-Item -ItemType SymbolicLink -Path $dest -Target $expected -ErrorAction Stop | Out-Null
            }
            catch {
                Write-AipWarning "could not create pass-through link $Name/$Harness/$rel -> $expected"
            }
        }

        # 3. Reconcile the .gitignore block (harness-qualified entries, convergent
        #    rule: an entry is added when a pass-through link exists and the path is
        #    untracked; removed when the path exists but is not a pass-through link,
        #    is tracked, or was just removed as broken; otherwise left exactly as it
        #    is, and other harnesses' entries are preserved untouched).
        $current = @(Get-AipPassthroughGitIgnoreEntry $gitIgnorePath)
        $entries = [System.Collections.Generic.List[string]]::new()
        foreach ($rel in $relList) {
            $dest = Join-Path $harnessDir $rel
            $item = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            $isLink = $null -ne $item -and $item.LinkType -eq 'SymbolicLink' -and (Test-AipPassthroughLink "$Harness/$rel" $profilePath)
            if ($isLink -and (Test-AipPathResolve $dest)) {
                if (-not (Test-AipTrackedPath "$Name/$Harness/$rel")) { $entries.Add("$Harness/$rel") }
            }
            elseif (Test-AipPathResolve $dest) {
                # path exists but is not a pass-through link: no entry
            }
            elseif ($removedThisRun.Contains("$Harness/$rel")) {
                # link removed as broken this run: no entry
            }
            elseif ($current -cnotcontains "$Harness/$rel") {
                # path absent and no current entry: nothing to do
            }
            else {
                # path absent but entry present (convergence): keep it
                $entries.Add("$Harness/$rel")
            }
        }
        foreach ($entry in $current) {
            $slashIndex = $entry.IndexOf('/')
            if ($slashIndex -lt 0) { continue }
            $entryHarness = $entry.Substring(0, $slashIndex)
            if ($entryHarness -notin 'pi', 'claude', 'codex', 'opencode') { continue }
            if ($entryHarness -eq $Harness) { continue }
            if ($removedThisRun.Contains($entry)) { continue }
            $entries.Add($entry)
        }
        Set-AipPassthroughGitIgnoreBlock $gitIgnorePath @($entries)
    }
    catch {
        Write-AipWarning "pass-through maintenance failed for $Name/${Harness}: $($_.Exception.Message)"
    }
}

function Invoke-AipPassthroughProfile {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($harness in 'pi', 'claude', 'codex', 'opencode') { Invoke-AipPassthrough $harness $Name }
}

function Write-AipDoctorPassthrough {
    # Reports pass-through links and warns (never fails) on broken ones, plus two
    # pi-specific advisories: a shadowing real pi/npm dir, and a profile-owned
    # settings.json that is not shared.
    param([Parameter(Mandatory)][string]$ProfilePath, [Parameter(Mandatory)][string]$Name)
    foreach ($harness in 'pi', 'claude', 'codex', 'opencode') {
        $root = Get-AipImportHarnessRoot $harness
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($rel in @(Get-AipPassthroughRel $harness)) {
            $dest = Join-Path $ProfilePath (Join-Path $harness $rel)
            $item = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or $item.LinkType -ne 'SymbolicLink') { continue }
            if (-not (Test-AipPassthroughLink "$harness/$rel" $ProfilePath)) { continue }
            if (Test-AipPathResolve $dest) {
                Write-Output "OK: pass-through $Name/$harness/$rel -> $($item.Target)"
            }
            else {
                Write-Output "WARN: pass-through $Name/$harness/$rel is broken (its machine-local target is missing)"
            }
        }
    }
    $piRoot = Get-AipImportHarnessRoot 'pi'
    if ($piRoot -and (Test-Path -LiteralPath (Join-Path $piRoot 'npm') -PathType Container)) {
        $npmDir = Join-Path $ProfilePath 'pi/npm'
        $npmItem = Get-Item -LiteralPath $npmDir -Force -ErrorAction SilentlyContinue
        if ($null -ne $npmItem -and $npmItem.PSIsContainer -and $null -eq $npmItem.LinkType) {
            Write-Output "WARN: $Name/pi/npm is a local directory shadowing the machine-wide pi npm dir; inspect it, then remove it so the pass-through link can form (pi re-installs missing packages on next launch)"
        }
    }
    $settingsPath = Join-Path $ProfilePath 'pi/settings.json'
    $settingsItem = Get-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $settingsItem -and $settingsItem.PSIsContainer -eq $false -and $null -eq $settingsItem.LinkType -and
        -not (Test-AipTrackedPath "$Name/pi/settings.json")) {
        Write-Output "WARN: $Name/pi/settings.json is not shared (untracked); run aip update, or: git -C $($script:AipProfileRoot) add $Name/pi/settings.json"
    }
}

function Write-AipImportUsage {
    # Prints usage without clobbering AipLastError: the specific error (e.g.
    # 'no profiles selected') is what tests and users need to see.
    [Console]::Error.WriteLine('aip: usage: aip import HARNESS FILE... --profile NAME[,NAME...] | --all-profiles [--force] [--skip-existing] [--dry-run]')
    $script:AipCommandStatus = 2
}

function Test-AipImportRelPath {
    param([AllowEmptyString()][string]$Rel)
    if ([string]::IsNullOrEmpty($Rel)) { return $false }
    $norm = $Rel.Replace('\', '/')
    if ($norm.StartsWith('/') -or $norm.EndsWith('/')) { return $false }
    foreach ($part in $norm.Split('/')) {
        if ($part -eq '' -or $part -eq '.' -or $part -eq '..') { return $false }
    }
    return $true
}

function Test-AipImportProfile {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-AipProfileName $Name)) { Write-AipError "invalid profile name '$Name'"; $script:AipCommandStatus = 2; return $false }
    $item = Get-Item -LiteralPath (Get-AipProfilePath $Name) -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item -isnot [IO.DirectoryInfo] -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        Write-AipError "profile '$Name' does not exist"
        $script:AipCommandStatus = 2
        return $false
    }
    return $true
}

function Test-AipImportManagedLink {
    # The aip-managed profile links: <profile>/<harness>/AGENTS.md -> ../AGENTS.md and
    # .../skills -> ../skills. On Windows without symlink privileges git materializes
    # symlinks as ordinary files containing the target text, so both representations
    # must be recognised (refusing is the safe direction either way).
    param([Parameter(Mandatory)][string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if ($null -ne $item.LinkType) {
        if ($item.LinkType -ne 'SymbolicLink') { return $false }
        $raw = [string]$item.Target
        if ($raw -eq '../AGENTS.md' -or $raw -eq '../skills') { return $true }
        $resolved = $item.ResolveLinkTarget($true)
        if ($null -ne $resolved -and ($resolved.Name -eq 'AGENTS.md' -or $resolved.Name -eq 'skills')) { return $true }
        return $false
    }
    if ($item -is [IO.FileInfo]) {
        try {
            $content = [IO.File]::ReadAllText($LiteralPath).Trim()
            return ($content -eq '../AGENTS.md') -or ($content -eq '../skills')
        }
        catch { return $false }
    }
    return $false
}

function Copy-AipImportFile {
    # Sets $script:AipImportStatus: 0 copied, 3 skipped, 1 error, 2 abort.
    # Sets $script:AipImportOverwrite on a/n. Writes dry-run lines via Write-Output.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][ValidateSet('ask', 'force', 'skip')][string]$Overwrite,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Rel,
        [Parameter(Mandatory)][int]$DryRun,
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$ProfilePath
    )
    if ($DryRun -eq 1) {
        if (Test-Path -LiteralPath $Dest) { Write-Output "copy $Rel -> $Name/$Rel (exists)" }
        else { Write-Output "copy $Rel -> $Name/$Rel" }
        $script:AipImportStatus = 0
        return
    }
    $destItem = Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    $passthroughReplaced = $false
    if ($null -ne $destItem) {
        if (Test-AipImportManagedLink -LiteralPath $Dest) {
            Write-AipError "refusing to overwrite the profile link $Name/$Rel"
            $script:AipImportStatus = 1
            return
        }
        # A pass-through link is replaceable: the imported profile-owned copy becomes
        # the profile's own version (and its .gitignore entry is dropped below so the
        # copy can be tracked again).
        if ($destItem.LinkType -eq 'SymbolicLink' -and (Test-AipPassthroughLink "$Harness/$Rel" $ProfilePath)) {
            $passthroughReplaced = $true
        }
        $doOverwrite = $false
        switch ($Overwrite) {
            'force' { $doOverwrite = $true }
            'skip' { $doOverwrite = $false }
            default {
                while ($true) {
                    [Console]::Error.Write("aip: $Name/$Rel exists: [o]verwrite [s]kip [a]ll [n]one [q]uit: ")
                    $line = [Console]::In.ReadLine()
                    if ($null -eq $line) { break }
                    $answer = $line.Trim()
                    if ($answer -in @('o', 'O')) { $doOverwrite = $true; break }
                    if ($answer -in @('s', 'S')) { $doOverwrite = $false; break }
                    if ($answer -in @('a', 'A')) { $doOverwrite = $true; $script:AipImportOverwrite = 'force'; break }
                    if ($answer -in @('n', 'N')) { $doOverwrite = $false; $script:AipImportOverwrite = 'skip'; break }
                    if ($answer -in @('q', 'Q')) { $script:AipImportStatus = 2; return }
                }
            }
        }
        if (-not $doOverwrite) { $script:AipImportStatus = 3; return }
    }
    $parent = Split-Path -Parent $Dest
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Write-AipError "could not create $parent"
        $script:AipImportStatus = 1
        return
    }
    $destItem = Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    if ($null -ne $destItem -and $null -ne $destItem.LinkType) {
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    }
    try {
        Copy-Item -LiteralPath $Source -Destination $Dest -Force -ErrorAction Stop
        if (-not $IsWindows) {
            $mode = [IO.File]::GetUnixFileMode($Source)
            [IO.File]::SetUnixFileMode($Dest, $mode)
        }
    }
    catch {
        Write-AipError "could not copy ${Rel}: $($_.Exception.Message)"
        $script:AipImportStatus = 1
        return
    }
    if ($passthroughReplaced) {
        Remove-AipPassthroughGitIgnoreEntry (Join-Path $ProfilePath '.gitignore') "$Harness/$Rel"
    }
    $script:AipImportStatus = 0
}

function Invoke-AipImportCopy {
    # Writes the summary (and dry-run lines) via Write-Output; sets $script:AipCommandStatus on error.
    param(
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][int]$DryRun,
        [Parameter(Mandatory)][string[]]$FileList,
        [Parameter(Mandatory)][string[]]$ProfileNames,
        [Parameter(Mandatory)][int]$Force,
        [Parameter(Mandatory)][int]$SkipExisting
    )
    if ($Force -eq 1) { $script:AipImportOverwrite = 'force' }
    elseif ($SkipExisting -eq 1) { $script:AipImportOverwrite = 'skip' }
    else { $script:AipImportOverwrite = 'ask' }
    $copied = 0; $skipped = 0; $errors = 0; $aborted = $false
    foreach ($name in $ProfileNames) {
        $profilePath = Get-AipProfilePath $name
        foreach ($rel in $FileList) {
            $normRel = $rel.Replace('\', '/')
            $dest = Join-Path $profilePath (Join-Path $Harness $normRel)
            if (-not (Test-AipPathUnder -Parent $profilePath -Child $dest)) {
                Write-AipError "invalid file path: $rel"
                return
            }
            if (Test-AipImportBlockedByPassthroughDir -Dest $dest -ProfilePath $profilePath -Harness $Harness -Rel $normRel) {
                Write-AipError "refusing to import through a pass-through directory: $name/$normRel"
                return
            }
            $overwrite = if ($script:AipImportOverwrite -eq 'ask') { 'ask' } else { $script:AipImportOverwrite }
            Copy-AipImportFile -Source (Join-Path $SourceRoot $rel) -Dest $dest -Overwrite $overwrite -Name $name -Rel $normRel -DryRun $DryRun -Harness $Harness -ProfilePath $profilePath
            switch ($script:AipImportStatus) {
                0 { $copied++ }
                3 { $skipped++ }
                1 { $errors = 1 }
                2 { $aborted = $true }
            }
            if ($aborted) { break }
        }
        if ($aborted) { break }
    }
    if ($DryRun -eq 0) {
        if ($aborted) {
            Write-AipError "import cancelled; $copied file(s) copied so far"
            $script:AipCommandStatus = 1
            return
        }
        if ($copied -gt 0) {
            Write-Output "aip: imported $copied file(s) into $($ProfileNames.Count) profile(s)"
            if ($skipped -gt 0) { Write-Output "aip: $skipped existing file(s) skipped" }
        }
        else { Write-Output 'aip: no files were copied' }
    }
    if ($errors -eq 1) { $script:AipCommandStatus = 1 }
}

function Test-AipImportTrackedWarning {
    param(
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string[]]$FileList,
        [Parameter(Mandatory)][string[]]$ProfileNames
    )
    if (-not (Test-Path -LiteralPath (Join-Path $script:AipProfileRoot '.git') -PathType Container)) { return }
    $first = $true
    foreach ($name in $ProfileNames) {
        foreach ($rel in $FileList) {
            $repoRel = "$name/$Harness/$rel"
            Invoke-AipGit -C $script:AipProfileRoot check-ignore -q -- $repoRel 2> $null
            if ($global:LASTEXITCODE -ne 0) {
                if ($first) {
                    # Informational only: must not set AipCommandStatus (Write-AipError does).
                    [Console]::Error.WriteLine('aip: the next sync checkpoint may track these imported files (not covered by the profile .gitignore):')
                    $script:AipLastError = 'the next sync checkpoint may track these imported files (not covered by the profile .gitignore):'
                    $first = $false
                }
                [Console]::Error.WriteLine("  $repoRel")
            }
        }
    }
}

function Invoke-AipImport {
    param([object[]]$Arguments)
    $harness = $null
    $profilesOpt = $null
    $allProfiles = $false
    $force = $false
    $skipExisting = $false
    $dryRun = $false
    $fileList = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $Arguments.Count) {
        $arg = [string]$Arguments[$i]
        switch ($arg) {
            '--profile' {
                if ($i + 1 -ge $Arguments.Count -or $null -ne $profilesOpt) { Write-AipImportUsage; return }
                # PowerShell parses 'work,suit' as an array argument; rejoin with the comma.
                $profilesOpt = ($Arguments[$i + 1] -join ',')
                $i++
            }
            '--all-profiles' { $allProfiles = $true }
            '--force' { $force = $true }
            '--skip-existing' { $skipExisting = $true }
            '--dry-run' { $dryRun = $true }
            '--' {
                $i++
                while ($i -lt $Arguments.Count) { $fileList.Add([string]$Arguments[$i]); $i++ }
            }
            default {
                if ($arg.StartsWith('-') -and $arg -ne '-') {
                    Write-AipError "unknown import option '$arg'"
                    Write-AipImportUsage
                    return
                }
                if ($null -eq $harness) { $harness = $arg } else { $fileList.Add($arg) }
            }
        }
        $i++
    }
    if ($null -eq $harness) { Write-AipError 'no harness specified; expected pi, claude, codex, or opencode'; Write-AipImportUsage; return }
    $sourceRoot = Get-AipImportHarnessRoot $harness
    if ($null -eq $sourceRoot) {
        Write-AipError "unknown harness '$harness'; expected pi, claude, codex, or opencode"
        $script:AipCommandStatus = 2
        return
    }
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        Write-AipError "no $harness configuration found at: $sourceRoot"
        return
    }
    if ($force -and $skipExisting) { Write-AipError '--force and --skip-existing conflict'; $script:AipCommandStatus = 2; return }
    if ($allProfiles -and $null -ne $profilesOpt) { Write-AipError '--profile and --all-profiles conflict'; $script:AipCommandStatus = 2; return }
    $profiles = [System.Collections.Generic.List[string]]::new()
    if ($fileList.Count -eq 0) {
        Write-AipError 'no files given'
        Write-AipImportUsage
        $script:AipCommandStatus = 2
        return
    }
    if (-not $allProfiles -and $null -eq $profilesOpt) {
        Write-AipError 'no profiles selected; pass --profile NAME or --all-profiles'
        Write-AipImportUsage
        return
    }
    foreach ($rel in $fileList) {
        if (-not (Test-AipImportRelPath $rel)) { Write-AipError "invalid file path: $rel"; return }
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $rel) -PathType Leaf)) { Write-AipError "no such file in the $harness configuration: $rel"; return }
    }
    if ($allProfiles) {
        foreach ($n in (Get-AipProfileNames)) { if ($n -cne 'aip') { $profiles.Add($n) } }
        if ($profiles.Count -eq 0) {
            if (@(Get-AipProfileNames).Count -gt 0) {
                Write-AipError 'no user profiles found; --all-profiles skips the aip management profile'
                $script:AipCommandStatus = 1
                return
            }
            Write-AipError 'no profiles selected; nothing to do'
            return
        }
    }
    else { foreach ($n in $profilesOpt.Split(',')) { if (-not (Test-AipImportProfile $n)) { return }; $profiles.Add($n) } }
    if ($profiles.Count -eq 0) { Write-AipError 'no profiles selected; nothing to do'; return }
    Invoke-AipImportCopy -Harness $harness -SourceRoot $sourceRoot -DryRun $dryRun -FileList $fileList.ToArray() -ProfileNames $profiles.ToArray() -Force $force -SkipExisting $skipExisting
    if ($script:AipCommandStatus -ne 0) { return }
    if (-not $dryRun) { Test-AipImportTrackedWarning -Harness $harness -FileList $fileList.ToArray() -ProfileNames $profiles.ToArray() }
}

function Write-AipSkillsUsage {
    Write-AipError 'usage: aip skills add|update|remove …'
    $script:AipCommandStatus = 2
}

function Invoke-AipSkills {
    param([object[]]$Arguments)
    $sub = if ($null -ne $Arguments -and $Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }
    $rest = @(if ($null -ne $Arguments) { $Arguments | Select-Object -Skip 1 })
    switch -CaseSensitive ($sub) {
        'add' { Invoke-AipAdd $rest }
        'update' { Invoke-AipSkillsUpdate $rest }
        'remove' { Invoke-AipSkillsRemove $rest }
        default { Write-AipSkillsUsage }
    }
}

function Read-AipSkillSource {
    param([Parameter(Mandatory)][string]$Dest)
    $file = Join-Path $Dest '.aip-source'
    $item = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        return $null
    }
    $text = Get-AipUtf8TextFile $file
    if ($text.StartsWith([char]0xFEFF)) { $text = $text.Substring(1) }
    $text = $text.Replace("`r", '')
    if (-not $text.EndsWith("`n")) { return $null }
    $lines = $text.Substring(0, $text.Length - 1).Split([char]10)
    if ($lines.Length -ne 3) { return $null }
    if (-not $lines[0].StartsWith('source=')) { return $null }
    if (-not $lines[1].StartsWith('url=')) { return $null }
    if (-not $lines[2].StartsWith('path=')) { return $null }
    $url = $lines[1].Substring(4)
    if ([string]::IsNullOrEmpty($url)) { return $null }
    return @{
        Source = $lines[0].Substring(7)
        Url = $url
        Path = $lines[2].Substring(5)
    }
}

function Write-AipSkillsUpdateUsage {
    Write-AipError 'usage: aip skills update PROFILE NAME... | aip skills update --all-profiles NAME... | aip skills update PROFILE --all | aip skills update --all-profiles --all'
    $script:AipCommandStatus = 2
}

function Invoke-AipSkillsUpdateOne {
    # Writes the update line via Write-Output; sets $script:AipCommandStatus on error.
    # Callers must not wrap this in `if (-not (...))` — that consumes the success line.
    param([Parameter(Mandatory)][string]$ProfileName, [Parameter(Mandatory)][string]$Name)
    $dest = Join-Path (Join-Path (Get-AipProfilePath $ProfileName) 'skills') $Name
    $existing = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        Write-AipError "skill '$Name' is not installed in profile $ProfileName"
        $script:AipCommandStatus = 1
        return
    }
    $parsed = Read-AipSkillSource $dest
    if ($null -eq $parsed) {
        Write-AipError "skill '$Name' in profile $ProfileName has no recorded source; reinstall it with aip skills add"
        $script:AipCommandStatus = 1
        return
    }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('aip-add-' + [guid]::NewGuid().ToString('N'))
    $staging = $null
    try {
        if (-not (Invoke-AipAddClone -Url $parsed.Url -Dir $dir)) { return }
        $script:AipAddName = $Name
        if (-not (Test-AipAddSkillPath -ClonedRoot $dir -Path $parsed.Path)) { return }
        $skillDir = $script:AipAddSkillDir
        $staging = Join-Path ([IO.Path]::GetTempPath()) ('aip-upd-' + [guid]::NewGuid().ToString('N'))
        if (-not (Copy-AipSkillTree -SkillDir $skillDir -Dest $staging -Name $Name)) { return }
        if (-not (Write-AipSkillSource -Dest $staging -Source $parsed.Source -Url $parsed.Url -Path $parsed.Path)) { return }
        try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop }
        catch {
            Write-AipError "could not remove the existing skill $Name"
            $script:AipCommandStatus = 1
            return
        }
        try { Move-Item -LiteralPath $staging -Destination $dest -ErrorAction Stop }
        catch {
            Write-AipError "could not replace the skill $Name"
            $script:AipCommandStatus = 1
            return
        }
        $staging = $null
        Write-Output "updated $Name in $ProfileName"
    }
    finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-AipSkillsUpdateAll {
    param([Parameter(Mandatory)][string]$ProfileName)
    $skills = Join-Path (Get-AipProfilePath $ProfileName) 'skills'
    if (-not (Test-Path -LiteralPath $skills -PathType Container)) { return }
    $dirs = @(Get-ChildItem -LiteralPath $skills -Force | Where-Object { $_.PSIsContainer -and $_.Name -cne '.git' } | Sort-Object -Property Name)
    foreach ($item in $dirs) {
        $sidecar = Join-Path $item.FullName '.aip-source'
        if (Test-Path -LiteralPath $sidecar) {
            if ($null -ne (Read-AipSkillSource $item.FullName)) {
                Invoke-AipSkillsUpdateOne -ProfileName $ProfileName -Name $item.Name
                if ($script:AipCommandStatus -ne 0) { return }
            }
            else {
                Write-AipError "skill '$($item.Name)' in profile $ProfileName has no recorded source; reinstall it with aip skills add"
                $script:AipCommandStatus = 1
                return
            }
        }
        else {
            Write-Output "skipped $($item.Name) in $ProfileName (no recorded source)"
        }
    }
}

function Invoke-AipSkillsUpdate {
    param([object[]]$Arguments)
    $profile = $null
    $allProfiles = $false
    $all = $false
    $names = [System.Collections.Generic.List[string]]::new()
    $i = 0
    if ($null -eq $Arguments) { $Arguments = @() }
    while ($i -lt $Arguments.Count) {
        $arg = [string]$Arguments[$i]
        switch -CaseSensitive ($arg) {
            '--all-profiles' { $allProfiles = $true }
            '--all' { $all = $true }
            '--' {
                $i++
                while ($i -lt $Arguments.Count) { $names.Add([string]$Arguments[$i]); $i++ }
            }
            default {
                if ($arg.StartsWith('-') -and $arg -ne '-') {
                    Write-AipError "unknown update option '$arg'"
                    Write-AipSkillsUpdateUsage
                    return
                }
                if ($null -eq $profile -and -not $allProfiles) { $profile = $arg } else { $names.Add($arg) }
            }
        }
        $i++
    }
    if ($null -eq $profile -and -not $allProfiles) {
        Write-AipError 'no profile selected; pass a PROFILE or --all-profiles'
        Write-AipSkillsUpdateUsage
        return
    }
    if ($allProfiles -and $null -ne $profile) { Write-AipError '--all-profiles conflicts with the PROFILE argument'; Write-AipSkillsUpdateUsage; return }
    if ($all -and $names.Count -gt 0) { Write-AipError '--all conflicts with NAME arguments'; Write-AipSkillsUpdateUsage; return }
    if (-not $all -and $names.Count -eq 0) { Write-AipSkillsUpdateUsage; return }
    $profiles = [System.Collections.Generic.List[string]]::new()
    if ($allProfiles) {
        foreach ($n in (Get-AipProfileNames)) { if ($n -cne 'aip') { $profiles.Add($n) } }
        if ($profiles.Count -eq 0) {
            if (@(Get-AipProfileNames).Count -gt 0) {
                Write-AipError 'no user profiles found; --all-profiles skips the aip management profile'
                $script:AipCommandStatus = 1
                return
            }
            Write-AipError 'no profiles found; create a profile with aip create first'
            $script:AipCommandStatus = 1
            return
        }
    }
    else {
        if (-not (Test-AipImportProfile $profile)) { return }
        $profiles.Add($profile)
    }
    if ($all) {
        foreach ($pname in $profiles) {
            Invoke-AipSkillsUpdateAll -ProfileName $pname
            if ($script:AipCommandStatus -ne 0) { return }
        }
        return
    }
    foreach ($name in $names) {
        if (-not (Test-AipProfileName $name)) {
            Write-AipError "invalid skill name '$name'; use lowercase letters, digits, hyphens or underscores"
            $script:AipCommandStatus = 1
            return
        }
        if ($allProfiles) {
            $found = $false
            foreach ($pname in $profiles) {
                $dest = Join-Path (Join-Path (Get-AipProfilePath $pname) 'skills') $name
                $sidecar = Join-Path $dest '.aip-source'
                if (Test-Path -LiteralPath $sidecar) {
                    if ($null -ne (Read-AipSkillSource $dest)) {
                        Invoke-AipSkillsUpdateOne -ProfileName $pname -Name $name
                        if ($script:AipCommandStatus -ne 0) { return }
                        $found = $true
                    }
                    else {
                        Write-AipError "skill '$name' in profile $pname has no recorded source; reinstall it with aip skills add"
                        $script:AipCommandStatus = 1
                        return
                    }
                }
                elseif (Test-Path -LiteralPath $dest) {
                    Write-Output "skipped $name in $pname (no recorded source)"
                }
            }
            if (-not $found) {
                Write-AipError "skill '$name' has no recorded source in any target profile"
                $script:AipCommandStatus = 1
                return
            }
        }
        else {
            Invoke-AipSkillsUpdateOne -ProfileName $profile -Name $name
            if ($script:AipCommandStatus -ne 0) { return }
        }
    }
}

function Write-AipSkillSource {
    param(
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Source,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Url,
        [AllowEmptyString()][string]$Path = ''
    )
    try {
        Set-AipUtf8LfFile (Join-Path $Dest '.aip-source') @(
            "source=$Source"
            "url=$Url"
            "path=$Path"
        )
        return $true
    }
    catch {
        Write-AipError "could not write provenance for $(Split-Path -Leaf $Dest)"
        $script:AipCommandStatus = 1
        return $false
    }
}

function Write-AipSkillsRemoveUsage {
    Write-AipError 'usage: aip skills remove PROFILE NAME... | aip skills remove --all-profiles NAME...'
    $script:AipCommandStatus = 2
}

function Invoke-AipSkillsRemoveOne {
    # Writes the remove line via Write-Output; sets $script:AipCommandStatus on error.
    # Callers must not wrap this in `if (-not (...))` — that consumes the success line.
    param([Parameter(Mandatory)][string]$ProfileName, [Parameter(Mandatory)][string]$Name)
    $skills = Join-Path (Get-AipProfilePath $ProfileName) 'skills'
    $dest = Join-Path $skills $Name
    $existing = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        Write-AipError "skill '$Name' is not installed in profile $ProfileName"
        $script:AipCommandStatus = 1
        return
    }
    if (-not (Test-AipPathUnder -Parent $skills -Child $dest)) {
        Write-AipError "invalid skill name '$Name'"
        $script:AipCommandStatus = 1
        return
    }
    try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop }
    catch {
        Write-AipError "could not remove the skill $Name"
        $script:AipCommandStatus = 1
        return
    }
    Write-Output "removed $Name from $ProfileName"
}

function Invoke-AipSkillsRemove {
    param([object[]]$Arguments)
    $profile = $null
    $allProfiles = $false
    $names = [System.Collections.Generic.List[string]]::new()
    $i = 0
    if ($null -eq $Arguments) { $Arguments = @() }
    while ($i -lt $Arguments.Count) {
        $arg = [string]$Arguments[$i]
        switch -CaseSensitive ($arg) {
            '--all-profiles' { $allProfiles = $true }
            '--' {
                $i++
                while ($i -lt $Arguments.Count) { $names.Add([string]$Arguments[$i]); $i++ }
            }
            default {
                if ($arg.StartsWith('-') -and $arg -ne '-') {
                    Write-AipError "unknown remove option '$arg'"
                    Write-AipSkillsRemoveUsage
                    return
                }
                if ($null -eq $profile -and -not $allProfiles) { $profile = $arg } else { $names.Add($arg) }
            }
        }
        $i++
    }
    if ($null -eq $profile -and -not $allProfiles) {
        Write-AipError 'no profile selected; pass a PROFILE or --all-profiles'
        Write-AipSkillsRemoveUsage
        return
    }
    if ($names.Count -eq 0) { Write-AipSkillsRemoveUsage; return }
    if ($allProfiles -and $null -ne $profile) { Write-AipError '--all-profiles conflicts with the PROFILE argument'; Write-AipSkillsRemoveUsage; return }
    $profiles = [System.Collections.Generic.List[string]]::new()
    if ($allProfiles) {
        foreach ($n in (Get-AipProfileNames)) { if ($n -cne 'aip') { $profiles.Add($n) } }
        if ($profiles.Count -eq 0) {
            if (@(Get-AipProfileNames).Count -gt 0) {
                Write-AipError 'no user profiles found; --all-profiles skips the aip management profile'
                $script:AipCommandStatus = 1
                return
            }
            Write-AipError 'no profiles found; create a profile with aip create first'
            $script:AipCommandStatus = 1
            return
        }
    }
    else {
        if (-not (Test-AipImportProfile $profile)) { return }
        $profiles.Add($profile)
    }
    foreach ($name in $names) {
        if (-not (Test-AipProfileName $name)) {
            Write-AipError "invalid skill name '$name'; use lowercase letters, digits, hyphens or underscores"
            $script:AipCommandStatus = 1
            return
        }
        if ($allProfiles) {
            $found = $false
            foreach ($pname in $profiles) {
                $dest = Join-Path (Join-Path (Get-AipProfilePath $pname) 'skills') $name
                if (Test-Path -LiteralPath $dest) {
                    Invoke-AipSkillsRemoveOne -ProfileName $pname -Name $name
                    if ($script:AipCommandStatus -ne 0) { return }
                    $found = $true
                }
            }
            if (-not $found) {
                Write-AipError "skill '$name' is not installed in any target profile"
                $script:AipCommandStatus = 1
                return
            }
        }
        else {
            Invoke-AipSkillsRemoveOne -ProfileName $profile -Name $name
            if ($script:AipCommandStatus -ne 0) { return }
        }
    }
}

function Write-AipAddUsage {
    [Console]::Error.WriteLine('aip: usage: aip skills add PROFILE SOURCE... | aip skills add --all-profiles SOURCE... [--force] [--skip-existing]')
    $script:AipCommandStatus = 2
}

function ConvertFrom-AipAddSource {
    # Parses a source into @{Url=..;Path=..;Name=..} or returns $null with the error printed.
    # Path is the in-repo path ('' = repository root); Name is the basename of the
    # path, or of the repository URL for a repo-root source.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source) -or $Source -match '\s') {
        Write-AipError "invalid source: $(Get-AipRedactedUrl $Source)"
        $script:AipCommandStatus = 2
        return $null
    }
    $url = $null
    $path = ''
    if ($Source.Contains('://')) {
        $idx = $Source.IndexOf('#')
        if ($idx -ge 0) { $url = $Source.Substring(0, $idx); $path = $Source.Substring($idx + 1) } else { $url = $Source }
        if (-not ($url.StartsWith('https://') -or $url.StartsWith('ssh://') -or $url.StartsWith('file://'))) {
            Write-AipError "unsupported source URL: $(Get-AipRedactedUrl $Source); expected https://, ssh://, git@, or file://"
            $script:AipCommandStatus = 2
            return $null
        }
    }
    elseif ($Source.Contains('@')) {
        # scp-style ssh: user@host:owner/repo[.git]
        $idx = $Source.IndexOf('#')
        if ($idx -ge 0) { $url = $Source.Substring(0, $idx); $path = $Source.Substring($idx + 1) } else { $url = $Source }
    }
    elseif ($Source.StartsWith('/') -or $Source.StartsWith('\') -or $Source.StartsWith('~') -or $Source.StartsWith('./') -or $Source.StartsWith('../') -or -not $Source.Contains('/')) {
        Write-AipError "unsupported source: $Source; plain local paths need a file:// URL, or use owner/repo[/path] or a git URL"
        $script:AipCommandStatus = 2
        return $null
    }
    else {
        # GitHub shorthand: owner/repo[/sub/path]
        $parts = $Source.Split('/')
        $owner = $parts[0]
        $repo = $parts[1]
        $path = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)]) -join '/' } else { '' }
        $url = "https://github.com/$owner/$repo.git"
    }
    if ($path -ne '') { $path = $path.Replace('\', '/') }
    if ($path -ne '' -and ($path.StartsWith('/') -or $path.EndsWith('/'))) {
        Write-AipError "invalid source path: $path"
        $script:AipCommandStatus = 1
        return $null
    }
    # Note: in PowerShell '' -split '/' yields @(''), so the empty path is excluded.
    if ($path -ne '') {
        foreach ($part in $path.Split('/')) {
            if ($part -eq '' -or $part -eq '.' -or $part -eq '..') {
                Write-AipError "invalid source path: $path"
                $script:AipCommandStatus = 1
                return $null
            }
        }
    }
    $name = ''
    if ($path -ne '') { $name = ($path.Split('/') | Select-Object -Last 1) }
    else {
        $name = ($url -replace '.*[/:]', '') -replace '\.git$', ''
    }
    if ([string]::IsNullOrEmpty($name)) {
        Write-AipError "unsupported source: $(Get-AipRedactedUrl $Source); cannot determine the skill name"
        $script:AipCommandStatus = 2
        return $null
    }
    @{ Url = $url; Path = $path; Name = $name }
}

function Invoke-AipAddClone {
    # Shallow, non-interactive clone of $Url into $Dir (which must not exist yet).
    # core.symlinks=true is required at clone time so Windows materializes
    # tracked symlinks as reparse points; the path-walk rejects them.
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Dir)
    $transport = Get-AipSshTransport $Dir
    if ($null -eq $transport) {
        Write-AipError 'source is unavailable because the configured SSH variant cannot be made non-interactive'
        $script:AipCommandStatus = 1
        return $false
    }
    $oldPrompt = $env:GIT_TERMINAL_PROMPT
    $oldGcm = $env:GCM_INTERACTIVE
    $oldSsh = $env:GIT_SSH_COMMAND
    $oldVariant = $env:GIT_SSH_VARIANT
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    $env:GIT_SSH_COMMAND = $transport.Command
    $env:GIT_SSH_VARIANT = $transport.Variant
    try {
        $null = Invoke-AipGit clone -c core.symlinks=true --quiet --depth 1 -- $Url $Dir 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-AipError "could not clone $(Get-AipRedactedUrl $Url); the source repository is unreachable or requires interactive credentials"
            $script:AipCommandStatus = 1
            return $false
        }
    }
    finally {
        if ($null -eq $oldPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
        if ($null -eq $oldGcm) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue } else { $env:GCM_INTERACTIVE = $oldGcm }
        if ($null -eq $oldSsh) { Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue } else { $env:GIT_SSH_COMMAND = $oldSsh }
        if ($null -eq $oldVariant) { Remove-Item Env:GIT_SSH_VARIANT -ErrorAction SilentlyContinue } else { $env:GIT_SSH_VARIANT = $oldVariant }
    }
    return $true
}

function Test-AipAddSkillPath {
    # Validates the in-repo path (rejecting traversal and symlinked directories) and
    # requires an ordinary SKILL.md. Sets $script:AipAddSkillDir on success.
    param([Parameter(Mandatory)][string]$ClonedRoot, [AllowEmptyString()][string]$Path)
    $prefix = ''
    if ($Path -ne '') {
        $normalized = $Path.Replace('\', '/')
        foreach ($part in $normalized.Split('/')) {
            if ($part -eq '' -or $part -eq '.' -or $part -eq '..') {
                Write-AipError "invalid source path: $Path"
                $script:AipCommandStatus = 1
                return $false
            }
            if ($prefix -eq '') { $candidate = Join-Path $ClonedRoot $part } else { $candidate = Join-Path (Join-Path $ClonedRoot $prefix) $part }
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            if ($null -eq $item) {
                Write-AipError "no such path in the source repository: $Path"
                $script:AipCommandStatus = 1
                return $false
            }
            if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
                Write-AipError "source path follows a symlink: $Path"
                $script:AipCommandStatus = 1
                return $false
            }
            if ($item -isnot [IO.DirectoryInfo]) {
                Write-AipError "no such path in the source repository: $Path"
                $script:AipCommandStatus = 1
                return $false
            }
            if ($prefix -eq '') { $prefix = $part } else { $prefix = $prefix + '/' + $part }
        }
        $dir = Join-Path $ClonedRoot $prefix
    }
    else { $dir = $ClonedRoot }
    $rootFull = [IO.Path]::GetFullPath($ClonedRoot)
    $dirFull = [IO.Path]::GetFullPath($dir)
    if ($dirFull -ne $rootFull -and -not (Test-AipPathUnder -Parent $ClonedRoot -Child $dir)) {
        Write-AipError "invalid source path: $Path"
        $script:AipCommandStatus = 1
        return $false
    }
    $skillFile = Join-Path $dir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
        $display = if ($Path -ne '') { $Path } else { $script:AipAddName }
        Write-AipError "no SKILL.md in the source path: $display"
        $script:AipCommandStatus = 1
        return $false
    }
    $script:AipAddSkillDir = $dir
    return $true
}

function Invoke-AipAddInstall {
    # Returns 0 installed, 3 skipped, 1 error (message printed).
    param(
        [Parameter(Mandatory)][string]$SkillDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ProfileName,
        [Parameter(Mandatory)][bool]$Force,
        [Parameter(Mandatory)][bool]$SkipExisting
    )
    $script:AipAddInstallStatus = 0
    $profilePath = Get-AipProfilePath $ProfileName
    $skills = Join-Path $profilePath 'skills'
    $dest = Join-Path $skills $Name
    $existing = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if ($SkipExisting) { Write-Output "skipped $Name in $ProfileName (already present)"; $script:AipAddInstallStatus = 3; return }
        if ($Force) {
            try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop }
            catch { Write-AipError "could not remove the existing skill $Name"; $script:AipCommandStatus = 1; $script:AipAddInstallStatus = 1; return }
        }
        else {
            Write-AipError "skill '$Name' already exists in profile $ProfileName; pass --force to replace it or --skip-existing to keep it"
            $script:AipCommandStatus = 1
            $script:AipAddInstallStatus = 1
            return
        }
    }
    if (-not (Test-Path -LiteralPath $skills -PathType Container)) {
        try { $null = New-Item -ItemType Directory -Path $skills -Force -ErrorAction Stop }
        catch { Write-AipError "could not create $skills"; $script:AipCommandStatus = 1; $script:AipAddInstallStatus = 1; return }
    }
    if (-not (Test-AipPathUnder -Parent $skills -Child $dest)) {
        Write-AipError "invalid source path: $Name"
        $script:AipCommandStatus = 1
        $script:AipAddInstallStatus = 1
        return
    }
    if (-not (Copy-AipSkillTree -SkillDir $SkillDir -Dest $dest -Name $Name)) {
        $script:AipAddInstallStatus = 1
        return
    }
}

function Copy-AipSkillTree {
    # Walk the source first: any reparse point fails (dest absent). Then copy excluding .git.
    param(
        [Parameter(Mandatory)][string]$SkillDir,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][string]$Name
    )
    $walk = Get-ChildItem -LiteralPath $SkillDir -Force -Recurse -ErrorAction SilentlyContinue
    foreach ($item in @($walk)) {
        $rel = $item.FullName.Substring($SkillDir.Length).TrimStart('\', '/')
        if ($rel -eq '.git' -or $rel.StartsWith('.git\') -or $rel.StartsWith('.git/')) { continue }
        if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            Write-AipError "skill '$Name' contains a nested symlink; dest is not created"
            $script:AipCommandStatus = 1
            return $false
        }
    }
    try {
        $null = New-Item -ItemType Directory -Path $Dest -Force -ErrorAction Stop
        Copy-AipSkillTreeContents -Src $SkillDir -Dest $Dest
    }
    catch {
        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue }
        Write-AipError "could not copy the skill $Name"
        $script:AipCommandStatus = 1
        return $false
    }
    return $true
}

function Copy-AipSkillTreeContents {
    param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Dest)
    foreach ($item in Get-ChildItem -LiteralPath $Src -Force) {
        if ($item.Name -eq '.git') { continue }
        $target = Join-Path $Dest $item.Name
        if ($item.PSIsContainer -and -not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            $null = New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop
            Copy-AipSkillTreeContents -Src $item.FullName -Dest $target
        }
        else {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop
        }
    }
}

function Invoke-AipAdd {
    param([object[]]$Arguments)
    $profile = $null
    $allProfiles = $false
    $force = $false
    $skipExisting = $false
    $sources = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $Arguments.Count) {
        $arg = [string]$Arguments[$i]
        switch ($arg) {
            '--all-profiles' { $allProfiles = $true }
            '--force' { $force = $true }
            '--skip-existing' { $skipExisting = $true }
            '--' {
                $i++
                while ($i -lt $Arguments.Count) { $sources.Add([string]$Arguments[$i]); $i++ }
            }
            default {
                if ($arg.StartsWith('-') -and $arg -ne '-') {
                    Write-AipError "unknown add option '$arg'"
                    Write-AipAddUsage
                    return
                }
                # The first positional is the profile, unless --all-profiles was given
                # first (in which case it is a source).
                if ($null -eq $profile -and -not $allProfiles) { $profile = $arg } else { $sources.Add($arg) }
            }
        }
        $i++
    }
    if ($null -eq $profile -and -not $allProfiles) {
        Write-AipError 'no profile selected; pass a PROFILE or --all-profiles'
        Write-AipAddUsage
        return
    }
    if ($sources.Count -eq 0) { Write-AipError 'no source given'; Write-AipAddUsage; return }
    if ($force -and $skipExisting) { Write-AipError '--force and --skip-existing conflict'; $script:AipCommandStatus = 2; return }
    if ($allProfiles -and $null -ne $profile) { Write-AipError '--all-profiles conflicts with the PROFILE argument'; $script:AipCommandStatus = 2; return }
    $profiles = [System.Collections.Generic.List[string]]::new()
    if ($allProfiles) {
        foreach ($n in (Get-AipProfileNames)) { if ($n -cne 'aip') { $profiles.Add($n) } }
        if ($profiles.Count -eq 0) {
            if (@(Get-AipProfileNames).Count -gt 0) {
                Write-AipError 'no user profiles found; --all-profiles skips the aip management profile'
                $script:AipCommandStatus = 1
                return
            }
            Write-AipError 'no profiles found; create a profile with aip create first'
            $script:AipCommandStatus = 1
            return
        }
    }
    else {
        if (-not (Test-AipImportProfile $profile)) { return }
        $profiles.Add($profile)
    }
    $installed = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($source in $sources) {
        $parsed = ConvertFrom-AipAddSource $source
        if ($null -eq $parsed) { return }
        $name = $parsed.Name
        if (-not (Test-AipProfileName $name)) {
            Write-AipError "invalid skill name '$name'; use lowercase letters, digits, hyphens or underscores"
            $script:AipCommandStatus = 1
            return
        }
        if (-not $installed.Add($name)) {
            Write-AipError "duplicate skill name in this call: $name"
            $script:AipCommandStatus = 1
            return
        }
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('aip-add-' + [guid]::NewGuid().ToString('N'))
        if (-not (Invoke-AipAddClone -Url $parsed.Url -Dir $dir)) { return }
        try {
            $script:AipAddName = $name
            if (-not (Test-AipAddSkillPath -ClonedRoot $dir -Path $parsed.Path)) { return }
            $skillDir = $script:AipAddSkillDir
            foreach ($pname in $profiles) {
                Invoke-AipAddInstall -SkillDir $skillDir -Name $name -ProfileName $pname -Force $force -SkipExisting $skipExisting
                if ($script:AipAddInstallStatus -eq 1) { return }
                if ($script:AipAddInstallStatus -eq 0) {
                    $dest = Join-Path (Join-Path (Get-AipProfilePath $pname) 'skills') $name
                    if (-not (Write-AipSkillSource -Dest $dest -Source $source -Url $parsed.Url -Path $parsed.Path)) { return }
                    Write-Output "added $name to $pname"
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return
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
  aip create NAME                    Create a new profile
  aip list                           List profiles and selection
  aip which [NAME]                   Show the profile that would be selected
  aip default [NAME]                 Show or set the default profile
  aip use NAME                       Select NAME for this shell only
  aip local [NAME | --remove]        Set or clear the per-directory marker
  aip clone SOURCE TARGET            Copy a profile into a new profile
  aip delete NAME [--force]          Delete a profile
  aip manage HARNESS [ARGS...]       Launch a harness with the aip profile
  aip sync                           Checkpoint and sync every profile
  aip sync-packages [NAME] [--add SPEC | --remove PKG | --replace]   Sync a profile's pi package list with the global settings
  aip remote add URL                 Connect the profiles repository to a remote
  aip remote show                    Show the configured remote (if any)
  aip remote remove                  Disconnect the remote
  aip skills add|update|remove       Install, refresh, or remove skills
  aip import HARNESS FILE... --profile NAME[,NAME...] | --all-profiles
                                     Copy config from a harness into profiles
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
  aip create work                 create your first profile
  aip remote add <git-url>        connect a shared remote (empty remote ok)
  aip default work                choose your everyday profile
  aip uninstall [--force]         remove the aip installation (not your profiles)
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
            'skills' { Invoke-AipWithoutGitRouting { Invoke-AipSkills $rest } }
            'create' { Invoke-AipWithoutGitRouting { Invoke-AipCreate $rest } }
            'manage' { Invoke-AipManage $rest }
            'clone' { Invoke-AipWithoutGitRouting { Invoke-AipClone $rest } }
            'default' { Invoke-AipDefault $rest }
            'delete' { Invoke-AipWithoutGitRouting { Invoke-AipDelete $rest } }
            'doctor' { Invoke-AipWithoutGitRouting { Invoke-AipDoctor $rest } }
            'list' { Invoke-AipWithoutGitRouting { Invoke-AipList $rest } }
            'local' { Invoke-AipLocal $rest }
            'help' { Invoke-AipHelp $rest }
            '--help' { Invoke-AipHelp @() }
            '-h' { Invoke-AipHelp @() }
            '--version' { Invoke-AipVersion $rest }
            '-v' { Invoke-AipVersion $rest }
            'remote' { Invoke-AipWithoutGitRouting { Invoke-AipRemote $rest } }
            'import' { Invoke-AipWithoutGitRouting { Invoke-AipImport $rest } }
            'run' { Invoke-AipRun $rest }
            'sync' { Invoke-AipSyncCommand $rest }
            'sync-packages' { Invoke-AipWithoutGitRouting { Invoke-AipSyncPackages $rest } }
            'use' { Invoke-AipUse $rest }
            'uninstall' { Invoke-AipUninstall $rest }
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
