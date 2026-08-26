BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepositoryRoot 'aip.ps1')

    function New-FakeHarness {
        param([Parameter(Mandatory)][string]$Name)

        if ($IsWindows) {
            $path = Join-Path $script:FakeBin "$Name.cmd"
            $recorder = Join-Path $script:FakeBin "$Name-recorder.ps1"
            @'
param(
    [Parameter(Position = 0)][string]$HarnessName,
    [Parameter(Position = 1, ValueFromRemainingArguments)][AllowEmptyString()][string[]]$Remaining
)
@(
    "harness=$HarnessName"
    "CLAUDE_CONFIG_DIR=$(if ($null -eq $env:CLAUDE_CONFIG_DIR) { '<unset>' } else { $env:CLAUDE_CONFIG_DIR })"
    "CODEX_HOME=$(if ($null -eq $env:CODEX_HOME) { '<unset>' } else { $env:CODEX_HOME })"
    "PI_CODING_AGENT_DIR=$(if ($null -eq $env:PI_CODING_AGENT_DIR) { '<unset>' } else { $env:PI_CODING_AGENT_DIR })"
    "OPENCODE_CONFIG_DIR=$(if ($null -eq $env:OPENCODE_CONFIG_DIR) { '<unset>' } else { $env:OPENCODE_CONFIG_DIR })"
    foreach ($value in $Remaining) { "arg=$value" }
) | Set-Content -LiteralPath $env:FAKE_CAPTURE -Encoding utf8NoBOM
exit [int]$env:FAKE_EXIT_STATUS
'@ | Set-Content -LiteralPath $recorder -Encoding utf8NoBOM
            @"
@echo off
pwsh -NoProfile -File "%~dp0$Name-recorder.ps1" "$Name" %*
exit /b %ERRORLEVEL%
"@ | Set-Content -LiteralPath $path -Encoding ascii
        }
        else {
            $path = Join-Path $script:FakeBin $Name
            @'
#!/bin/sh
capture=${FAKE_CAPTURE:?}
printf 'harness=%s\n' "${0##*/}" > "$capture"
printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" >> "$capture"
printf 'CODEX_HOME=%s\n' "${CODEX_HOME-<unset>}" >> "$capture"
printf 'PI_CODING_AGENT_DIR=%s\n' "${PI_CODING_AGENT_DIR-<unset>}" >> "$capture"
printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR-<unset>}" >> "$capture"
printf 'arg=%s\n' "$@" >> "$capture"
exit "${FAKE_EXIT_STATUS:-0}"
'@ | Set-Content -LiteralPath $path -Encoding utf8NoBOM
            & chmod +x $path
        }
    }

    function New-TestProfile {
        param([string]$Name)
        aip create $Name *> $null
        $global:LASTEXITCODE | Should -Be 0
    }

    function Initialize-TestUpstream {
        $script:TestRemote = Join-Path $TestDrive ('profile-' + [guid]::NewGuid().ToString('N') + '.git')
        & git init -q --bare $script:TestRemote
        & git -C $script:AipProfileRoot remote add origin $script:TestRemote
        & git -C $script:AipProfileRoot push -q -u origin main
        & git -C $script:TestRemote symbolic-ref HEAD refs/heads/main
    }

    function Get-RootRepo { $script:AipProfileRoot }
}

Describe 'aip' {
BeforeEach {
    Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
    $script:AipProfileRoot = Join-Path $TestDrive 'profile root'
    $script:FakeBin = Join-Path $TestDrive 'fake bin'
    $script:FakeCapture = Join-Path $TestDrive 'capture'
    # Isolate the harness default roots (pass-through + import sources) from the
    # developer's real machine config, like the import Describe does for its own root.
    $script:AipImportHome = Join-Path $TestDrive 'import-home'
    $env:FAKE_CAPTURE = $script:FakeCapture
    $env:FAKE_EXIT_STATUS = '0'
    $env:AIP_PROFILE = $null
    # A host session (e.g. running the suite from inside an agent) may export
    # harness selector variables; null them so wrapper assertions stay hermetic.
    $env:CLAUDE_CONFIG_DIR = $null
    $env:CODEX_HOME = $null
    $env:PI_CODING_AGENT_DIR = $null
    $env:OPENCODE_CONFIG_DIR = $null
    $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig'
    $env:GIT_CONFIG_NOSYSTEM = '1'
    if (Test-Path -LiteralPath $script:AipProfileRoot) { Remove-Item -LiteralPath $script:AipProfileRoot -Recurse -Force }
    if (Test-Path -LiteralPath $script:FakeBin) { Remove-Item -LiteralPath $script:FakeBin -Recurse -Force }
    New-Item -ItemType Directory -Path $script:AipProfileRoot, $script:FakeBin, $script:AipImportHome -Force | Out-Null
    & git config --global user.name 'Aip Tests'
    & git config --global user.email 'aip@example.test'
    # CI git can kick off background auto-maintenance that races the sync lock.
    & git config --global maintenance.auto false
    & git config --global gc.auto 0
    foreach ($harness in 'claude', 'codex', 'pi', 'opencode') { New-FakeHarness $harness }
    $script:AipRealPath = $script:FakeBin
    $script:AipCreateSkillsTreeRoot = $null
    $script:AipCreateSkillsGlobalRoot = $null
    Remove-Variable -Name AipLockAttempts -Scope Script -ErrorAction SilentlyContinue
}

AfterEach {
    $env:AIP_PROFILE = $null
    $env:FAKE_CAPTURE = $null
    $env:FAKE_EXIT_STATUS = $null
    $env:GIT_CONFIG_GLOBAL = $null
    $env:GIT_CONFIG_NOSYSTEM = $null
}

It 'reports the embedded version and rejects extra arguments' {
    $versionSource = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'aip.ps1') -Raw
    # \r? keeps the match working on CRLF checkouts (Windows CI).
    $expectedVersion = 'aip ' + ($versionSource -match "(?m)^\`$script:AipVersion = '([^']+)'\r?$" | ForEach-Object { $Matches[1] })
    aip version | Should -Be $expectedVersion
    $global:LASTEXITCODE | Should -Be 0
    aip --version | Should -Be $expectedVersion
    $global:LASTEXITCODE | Should -Be 0
    aip -v | Should -Be $expectedVersion
    $global:LASTEXITCODE | Should -Be 0
    aip version extra *> $null
    $global:LASTEXITCODE | Should -Not -Be 0
}

It 'update delegates to the npm package update command' {
    New-FakeHarness 'npx'
    $savedPath = $env:PATH
    $env:PATH = "$script:FakeBin$([IO.Path]::PathSeparator)$savedPath"
    try {
        aip update
        $global:LASTEXITCODE | Should -Be 0
        $lines = Get-Content -LiteralPath $script:FakeCapture
        $lines | Should -Contain 'harness=npx'
        $lines | Should -Contain 'arg=--yes'
        $lines | Should -Contain 'arg=@code-ministry/aip@latest'
        $lines | Should -Contain 'arg=update'
    }
    finally { $env:PATH = $savedPath }
}

It 'update rejects extra arguments without invoking npx' {
    aip update extra *> $null
    $global:LASTEXITCODE | Should -Not -Be 0
    Test-Path -LiteralPath $script:FakeCapture | Should -BeFalse
}

It 'help, --help, and -h print the full command table and exit 0' {
    $helpOutput = aip help | Out-String
    $global:LASTEXITCODE | Should -Be 0
    foreach ($command in 'skills', 'create', 'list', 'which', 'default', 'use', 'local', 'clone', 'delete', 'manage', 'sync', 'remote', 'doctor', 'run', 'update', 'uninstall', 'version', 'help', 'import') {
        $helpOutput | Should -Match ([regex]::Escape("aip $command"))
    }
    $helpOutput | Should -Match ([regex]::Escape('aip skills add|update|remove'))
    $helpOutput | Should -Not -Match 'aip add PROFILE'
    $helpOutput | Should -Match ([regex]::Escape('aip manage HARNESS [ARGS...]'))
    $helpOutput | Should -Match ([regex]::Escape('aip remote add URL'))
    $helpOutput | Should -Match ([regex]::Escape('aip remote show'))
    $helpOutput | Should -Match ([regex]::Escape('aip remote remove'))
    $helpOutput | Should -Match 'Quick start'
    $helpOutput | Should -Match 'README'
    $helpOutput | Should -Match 'claude, codex, pi, opencode'

    (aip --help | Out-String) | Should -Be $helpOutput
    (aip -h | Out-String) | Should -Be $helpOutput

    aip help extra *> $null
    $global:LASTEXITCODE | Should -Be 2
    $script:AipLastError | Should -Match 'usage: aip help'
}

Describe 'profile creation and selection' {
    It 'validates profile names strictly and portably' {
        Test-AipProfileName 'client-42_name' | Should -BeTrue
        foreach ($name in '../work', 'a/b', 'a.b', '-work', 'work_', 'Work', 'con', 'aux', 'com1', 'lpt9', ('a' * 65), '') {
            Test-AipProfileName $name | Should -BeFalse
        }
    }

    It 'exposes no outfit machinery' {
        Get-Command Test-AipOutfit -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command ConvertFrom-AipOutfitText -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command Get-AipOutfit -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command Invoke-AipOutfit -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'rejects C1 control characters in Codex instructions' {
        { ConvertTo-AipTomlString "before$([char]0x85)after" } | Should -Throw '*control character*'
    }

    It 'delete confirmation matcher accepts y yes variants and rejects the rest' {
        Test-AipDeleteConfirm 'y' | Should -BeTrue
        Test-AipDeleteConfirm 'Y' | Should -BeTrue
        Test-AipDeleteConfirm 'yes' | Should -BeTrue
        Test-AipDeleteConfirm 'YES' | Should -BeTrue
        Test-AipDeleteConfirm 'n' | Should -BeFalse
        Test-AipDeleteConfirm '' | Should -BeFalse
        Test-AipDeleteConfirm 'yeah' | Should -BeFalse
    }

    It 'keeps command and harness spellings case-sensitive' {
        aip CREATE work *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        New-TestProfile work
        aip run work CLAUDE *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
    }

    It 'creates the approved relative-link layout atomically in the profiles repository' {
        aip create work
        $global:LASTEXITCODE | Should -Be 0
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        Test-Path -LiteralPath (Join-Path $profile '.aip') | Should -BeFalse
        (Get-Item (Join-Path $profile 'codex/AGENTS.md')).LinkType | Should -Be 'SymbolicLink'
        # On Windows, .Target reports relative links with backslashes; normalize to the stored form.
        [string](Get-Item (Join-Path $profile 'codex/AGENTS.md')).Target -replace '\\', '/' | Should -Be '../AGENTS.md'
        [string](Get-Item (Join-Path $profile 'claude/skills')).Target -replace '\\', '/' | Should -Be '../skills'
        (Get-Content -LiteralPath (Join-Path $profile 'claude/CLAUDE.md') -TotalCount 1) | Should -Be '@../AGENTS.md'
        [IO.File]::ReadAllBytes((Join-Path $profile 'claude/CLAUDE.md')) | Should -Not -Contain 13
        [IO.File]::ReadAllBytes((Join-Path $profile '.gitignore')) | Should -Not -Contain 13
        (Get-Content -LiteralPath (Join-Path $profile '.gitignore') -Raw) | Should -Match '(?m)^\*\*/\.credentials\.json$'
        (Get-Content -LiteralPath (Join-Path $profile '.gitignore') -Raw) | Should -Match '(?m)^\*\*/auth\.json$'
        ((& git -C $root ls-files -s work/codex/AGENTS.md) -split ' ')[0] | Should -Be '120000'
        (& git -C $root config --bool core.symlinks) | Should -Be 'true'
        (& git -C $root ls-files -- work/skills/.gitkeep) | Should -Be 'work/skills/.gitkeep'
        (& git -C $root branch --show-current) | Should -Be 'main'
        (& git -C $root status --porcelain) | Should -BeNullOrEmpty
        Test-Path (Join-Path $profile '.git') | Should -BeFalse
        $rootGitIgnore = Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw
        $rootGitIgnore | Should -Match '\.default'
        $rootGitIgnore | Should -Match '\.aip-\*/'
        [int](& git -C $root rev-list --count HEAD) | Should -Be 1
    }

    It 'creates byte-identical owned primary configs when global sources exist' {
        $sources = @{
            'pi/settings.json' = '{}'
            'claude/settings.json' = '{"permissions":{}}'
            'codex/config.toml' = ''
            'opencode/opencode.json' = ' { } '
        }
        $globalRels = @{
            'pi/settings.json' = '.pi/agent/settings.json'
            'claude/settings.json' = '.claude/settings.json'
            'codex/config.toml' = '.codex/config.toml'
            'opencode/opencode.json' = '.config/opencode/opencode.json'
        }
        foreach ($rel in $sources.Keys) {
            $source = Join-Path $script:AipImportHome $globalRels[$rel]
            New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
            [IO.File]::WriteAllText($source, $sources[$rel])
        }

        aip create portable
        $global:LASTEXITCODE | Should -Be 0
        foreach ($rel in $sources.Keys) {
            $source = Join-Path $script:AipImportHome $globalRels[$rel]
            $destination = Join-Path $script:AipProfileRoot (Join-Path 'portable' $rel)
            (Get-Item -LiteralPath $destination -Force).LinkType | Should -BeNullOrEmpty
            [IO.File]::ReadAllBytes($destination) | Should -Be ([IO.File]::ReadAllBytes($source))
            (& git -C $script:AipProfileRoot ls-files -- "portable/$rel") | Should -Be "portable/$rel"
        }
    }

    It 'leaves missing primary configs absent rather than linking them' {
        foreach ($rel in '.pi/agent/settings.json', '.claude/settings.json', '.codex/config.toml', '.config/opencode/opencode.json') {
            Remove-Item -LiteralPath (Join-Path $script:AipImportHome $rel) -Force -ErrorAction SilentlyContinue
        }

        aip create absent
        $global:LASTEXITCODE | Should -Be 0
        foreach ($rel in 'pi/settings.json', 'claude/settings.json', 'codex/config.toml', 'opencode/opencode.json') {
            Test-Path -LiteralPath (Join-Path $script:AipProfileRoot (Join-Path 'absent' $rel)) | Should -BeFalse
        }
    }

    It 'discovers and copies sorted Pi create skills into the shared profile root' {
        $tree = Join-Path $TestDrive 'skill-tree'
        $global = Join-Path $TestDrive 'global-skills'
        New-Item -ItemType Directory -Path (Join-Path $tree 'profile/pi/skills/beta'), (Join-Path $tree 'profile/pi/skills/alpha'), (Join-Path $global 'alpha') -Force | Out-Null
        'tree alpha' | Set-Content -LiteralPath (Join-Path $tree 'profile/pi/skills/alpha/SKILL.md')
        'tree beta' | Set-Content -LiteralPath (Join-Path $tree 'profile/pi/skills/beta/SKILL.md')
        'global alpha' | Set-Content -LiteralPath (Join-Path $global 'alpha/SKILL.md')
        $script:AipCreateSkillsTreeRoot = $tree
        $script:AipCreateSkillsGlobalRoot = $global

        $skills = @(Get-AipCreateSkills)
        $skills.Name | Should -Be @('alpha', 'beta')
        $skills[0].Source | Should -Be (Join-Path $global 'alpha')
        $stage = Join-Path $TestDrive 'stage'
        New-Item -ItemType Directory -Path (Join-Path $stage 'skills') -Force | Out-Null
        Copy-AipCreateSkills $stage @($skills[0])
        (Get-Content -LiteralPath (Join-Path $stage 'skills/alpha/SKILL.md') -Raw).Trim() | Should -Be 'global alpha'
    }

    It 'create refuses a destination collision before creating the profiles repository' {
        $collision = Join-Path $script:AipProfileRoot 'new'
        'not mine' | Set-Content -LiteralPath $collision

        aip create new *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        (Get-Content -LiteralPath $collision -Raw).Trim() | Should -Be 'not mine'
        Test-Path (Join-Path $script:AipProfileRoot '.git') | Should -BeFalse
    }

    It 'a linked profile root is resolved and listed' {
        New-TestProfile work
        $externalRoot = Join-Path $TestDrive 'external profile root'
        Move-Item -LiteralPath $script:AipProfileRoot -Destination $externalRoot
        New-Item -ItemType SymbolicLink -Path $script:AipProfileRoot -Target $externalRoot | Out-Null

        $output = aip list | Out-String

        $global:LASTEXITCODE | Should -Be 0
        $output | Should -Match 'work'
    }

    It 'resolves session, nearest project marker, and default in order' {
        New-TestProfile work
        New-TestProfile personal
        aip default work *> $null
        $project = Join-Path $TestDrive 'project/child'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        'personal' | Set-Content (Join-Path $TestDrive 'project/.aip-profile')
        Push-Location $project
        try {
            aip which | Should -Be (Join-Path $script:AipProfileRoot 'personal')
            $env:AIP_PROFILE = 'work'
            aip which | Should -Be (Join-Path $script:AipProfileRoot 'work')
        }
        finally { Pop-Location }
    }

    It 'fails closed for an invalid explicit profile instead of falling back' {
        New-TestProfile work
        $env:AIP_PROFILE = 'work'
        aip which '../work' *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'invalid profile name'
    }

    It 'rejects marker files with NUL bytes or unterminated extra lines' {
        New-TestProfile work
        [IO.File]::WriteAllBytes((Join-Path $script:AipProfileRoot '.default'), [byte[]](119, 111, 114, 107, 0))
        aip which *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'invalid default profile marker'

        $project = Join-Path $TestDrive 'bad marker project'
        New-Item -ItemType Directory -Path $project | Out-Null
        [IO.File]::WriteAllText((Join-Path $project '.aip-profile'), "work`npersonal", [Text.UTF8Encoding]::new($false))
        Push-Location $project
        try {
            aip which *> $null
            $global:LASTEXITCODE | Should -Not -Be 0
            $script:AipLastError | Should -Match 'invalid project marker'
        }
        finally { Pop-Location }
    }

    It 'fails closed for a linked project marker and removes only the link' {
        New-TestProfile work
        New-TestProfile personal
        aip default work *> $null
        $project = Join-Path $TestDrive 'linked marker project'
        New-Item -ItemType Directory -Path $project | Out-Null
        $external = Join-Path $TestDrive 'external marker'
        'personal' | Set-Content $external
        New-Item -ItemType SymbolicLink -Path (Join-Path $project '.aip-profile') -Target $external | Out-Null
        Push-Location $project
        try {
            aip which *> $null
            $global:LASTEXITCODE | Should -Not -Be 0
            $script:AipLastError | Should -Match 'invalid project marker'
            aip local --remove *> $null
            $global:LASTEXITCODE | Should -Be 0
            Test-Path (Join-Path $project '.aip-profile') | Should -BeFalse
            (Get-Content $external -Raw).Trim() | Should -Be 'personal'
        }
        finally { Pop-Location }
    }

    It 'refuses to remove an ordinary directory used as a project marker' {
        New-TestProfile work
        $project = Join-Path $TestDrive 'directory marker project'
        New-Item -ItemType Directory -Path (Join-Path $project '.aip-profile') -Force | Out-Null
        Push-Location $project
        try {
            aip local --remove *> $null
            $global:LASTEXITCODE | Should -Not -Be 0
            Test-Path -LiteralPath '.aip-profile' -PathType Container | Should -BeTrue
        }
        finally { Pop-Location }
    }

    It 'supports local markers, listing, and status details' {
        New-TestProfile work
        New-TestProfile personal
        aip default work *> $null
        $project = Join-Path $TestDrive 'project'
        New-Item -ItemType Directory -Path $project | Out-Null
        Push-Location $project
        try {
            aip local personal *> $null
            $env:AIP_PROFILE = 'personal'
            $statusOutput = aip | Out-String
            $statusOutput | Should -Match '🐵 personal'
            $statusOutput | Should -Not -Match ' — '
            $statusOutput | Should -Match 'Selected by: session'
            $statusOutput | Should -Match 'Git: clean, local only'
            $listOutput = aip list | Out-String
            $listOutput | Should -Match 'personal \[session\] \[project\]'
            $listOutput | Should -Match 'work \[default\]'
            aip local --remove *> $null
            Test-Path (Join-Path $project '.aip-profile') | Should -BeFalse
        }
        finally { Pop-Location }
    }

    It 'lists profiles from status when none is selected' {
        New-TestProfile work
        New-TestProfile personal
        $env:AIP_PROFILE = $null
        Push-Location $TestDrive
        try {
            $out = aip | Out-String
            $global:LASTEXITCODE | Should -Be 0
            $out | Should -Match 'No profile selected. Available profiles:'
            $out | Should -Match 'work'
            $out | Should -Not -Match ' — '
            $out | Should -Match "Select one with 'aip use NAME'"
        }
        finally { Pop-Location }
    }

    It 'shows the create hint from status when no profiles exist' {
        $env:AIP_PROFILE = $null
        Push-Location $TestDrive
        try {
            aip *> $null
            $global:LASTEXITCODE | Should -Be 2
            $script:AipLastError | Should -Match "no profile selected; run 'aip create NAME'"
        }
        finally { Pop-Location }
    }

    It 'surfaces an invalid project marker from status' {
        New-TestProfile work
        $env:AIP_PROFILE = $null
        Push-Location $TestDrive
        try {
            'Not A Name' | Set-Content -LiteralPath (Join-Path $TestDrive '.aip-profile')
            aip *> $null
            $global:LASTEXITCODE | Should -Be 2
            $script:AipLastError | Should -Match 'invalid project marker'
        }
        finally {
            Pop-Location
            Remove-Item -LiteralPath (Join-Path $TestDrive '.aip-profile') -ErrorAction SilentlyContinue
        }
    }

    It 'shows the resolved profile from status normally' {
        New-TestProfile work
        aip default work *> $null
        $env:AIP_PROFILE = $null
        Push-Location $TestDrive
        try {
            $out = aip | Out-String
            $global:LASTEXITCODE | Should -Be 0
            $out | Should -Match '🐵 work'
            $out | Should -Not -Match ' — '
            $out | Should -Match 'Selected by: default'
        }
        finally { Pop-Location }
    }

    It 'distinguishes synced, pending push, pending pull, diverged, and conflict status' {
        New-TestProfile work
        $env:AIP_PROFILE = 'work'
        Initialize-TestUpstream
        (aip | Out-String) | Should -Match 'synced with origin/main'

        $root = $script:AipProfileRoot
        'local' | Add-Content (Join-Path $root 'work/AGENTS.md')
        & git -C $root add work/AGENTS.md
        & git -C $root commit -q -m local
        (aip | Out-String) | Should -Match 'pending push \(1 ahead of origin/main\)'

        & git -C $root reset -q --hard origin/main
        $other = Join-Path $TestDrive 'status other'
        & git clone -q $script:TestRemote $other
        'remote' | Set-Content (Join-Path $other 'REMOTE.md')
        & git -C $other add REMOTE.md
        & git -C $other commit -q -m remote
        & git -C $other push -q
        & git -C $root fetch -q origin
        (aip | Out-String) | Should -Match 'pending pull \(1 behind origin/main\)'

        'local again' | Add-Content (Join-Path $root 'work/AGENTS.md')
        & git -C $root add work/AGENTS.md
        & git -C $root commit -q -m diverge
        (aip | Out-String) | Should -Match 'diverged \(1 ahead, 1 behind origin/main\)'

        New-Item -ItemType Directory -Path (Join-Path $root '.git/rebase-merge') | Out-Null
        (aip | Out-String) | Should -Match 'conflict or unfinished Git operation'
    }
}

Describe 'harness wrappers' {
    BeforeEach {
        New-TestProfile work
        $env:AIP_PROFILE = 'work'
    }

    It 'sets the matching selector and forwards discrete arguments for every harness' {
        $selectors = @{
            claude = 'CLAUDE_CONFIG_DIR'
            codex = 'CODEX_HOME'
            pi = 'PI_CODING_AGENT_DIR'
            opencode = 'OPENCODE_CONFIG_DIR'
        }
        foreach ($harness in $selectors.Keys) {
            $testArguments = @('one two', '*literal*', '', 'quote"value', '&', '%PATH%', '!bang!', 'café')
            $expectedArguments = @('arg=one two', 'arg=*literal*', 'arg=', 'arg=quote"value', 'arg=&', 'arg=%PATH%', 'arg=!bang!', 'arg=café')
            if ($IsWindows) {
                # cmd.exe re-expands %VAR% text in arguments passed to .cmd harnesses, so a
                # literal %PATH% cannot round-trip on Windows (true for real shim harnesses too).
                $testArguments = @($testArguments | Where-Object { $_ -ne '%PATH%' })
                $expectedArguments = @($expectedArguments | Where-Object { $_ -ne 'arg=%PATH%' })
            }
            & $harness @testArguments *> $null
            $global:LASTEXITCODE | Should -Be 0
            $capture = Get-Content $script:FakeCapture -Raw
            $capture | Should -Match "harness=$harness"
            $capture | Should -Match ([regex]::Escape("$($selectors[$harness])=$(Join-Path $script:AipProfileRoot "work/$harness")"))
            foreach ($variable in $selectors.Values) {
                if ($variable -ne $selectors[$harness]) {
                    $capture | Should -Match "(?m)^$variable=(?:<unset>)?\r?$"
                }
            }
            $capturedArguments = @(Get-Content $script:FakeCapture | Where-Object { $_ -like 'arg=*' })
            if ($harness -eq 'codex') { $capturedArguments = @($capturedArguments | Select-Object -Skip 2) }
            $capturedArguments | Should -Be $expectedArguments
        }
    }

    It 'disambiguates an explicit profile whose name is also a harness' {
        New-TestProfile claude

        aip run claude codex prompt *> $null

        $capture = Get-Content $script:FakeCapture -Raw
        $capture | Should -Match 'harness=codex'
        $capture | Should -Match ([regex]::Escape("CODEX_HOME=$(Join-Path $script:AipProfileRoot 'claude/codex')"))
        $capture | Should -Match '(?m)^arg=prompt\r?$'
    }

    It 'manage launches the harness with the aip profile and forwards arguments' {
        New-TestProfile aip
        aip manage pi 'one two' '--flag' *> $null
        $global:LASTEXITCODE | Should -Be 0
        $capture = Get-Content $script:FakeCapture -Raw
        $capture | Should -Match 'harness=pi'
        $capture | Should -Match ([regex]::Escape("PI_CODING_AGENT_DIR=$(Join-Path $script:AipProfileRoot 'aip/pi')"))
        $capture | Should -Match '(?m)^arg=one two\r?$'
        $capture | Should -Match '(?m)^arg=--flag\r?$'
    }

    It 'manage validates the harness name' {
        aip manage bogus *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match "unknown harness 'bogus'"
    }

    It 'manage restores a prior AIP_PROFILE and leaves unset unset' {
        New-TestProfile aip
        $env:AIP_PROFILE = 'work'
        aip manage pi *> $null
        $env:AIP_PROFILE | Should -Be 'work'
        Remove-Item Env:AIP_PROFILE -ErrorAction SilentlyContinue
        aip manage pi *> $null
        Test-Path Env:AIP_PROFILE | Should -BeFalse
    }

    It 'manage requires the aip profile with a fix hint' {
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'aip') -Recurse -Force -ErrorAction SilentlyContinue
        aip manage pi *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match "the 'aip' profile does not exist"
        $script:AipLastError | Should -Match 'aip create aip'
    }

    It 'fails closed for an explicit empty profile without launching a harness' {
        Remove-Item -LiteralPath $script:FakeCapture -Force -ErrorAction SilentlyContinue

        aip run '' claude prompt *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match "invalid profile name ''"
        Test-Path -LiteralPath $script:FakeCapture | Should -BeFalse

        aip which '' *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
    }

    It 'does not change run parsing for a corrupt harness-named profile path' {
        'not a profile' | Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'claude')
        Remove-Item -LiteralPath $script:FakeCapture -Force -ErrorAction SilentlyContinue

        aip run claude codex prompt *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        Test-Path -LiteralPath $script:FakeCapture | Should -BeFalse
    }

    It 'injects Codex instructions before an explicit user override' {
        'Codex only — keep this text.' | Set-Content (Join-Path $script:AipProfileRoot 'work/codex/instructions.md')
        codex -c 'developer_instructions=user override' prompt *> $null
        $arguments = @(Get-Content $script:FakeCapture | Where-Object { $_ -like 'arg=*' })
        $arguments | Should -Be @(
            'arg=-c',
            'arg=developer_instructions="Codex only — keep this text."',
            'arg=-c',
            'arg=developer_instructions=user override',
            'arg=prompt'
        )
    }

    It 'encodes scalar-looking and multiline Codex instructions as one TOML string' {
        "true`nQuoted `"text`" and a backslash \ — café 🐵`nsecond line" | Set-Content (Join-Path $script:AipProfileRoot 'work/codex/instructions.md')

        codex prompt *> $null

        $arguments = @(Get-Content $script:FakeCapture | Where-Object { $_ -like 'arg=*' })
        $arguments[1] | Should -Be 'arg=developer_instructions="true\nQuoted \"text\" and a backslash \\ — café 🐵\nsecond line"'
    }

    It 'encodes CRLF Codex instructions without a trailing carriage return' {
        [IO.File]::WriteAllBytes((Join-Path $script:AipProfileRoot 'work/codex/instructions.md'), [Text.Encoding]::UTF8.GetBytes("first`r`nsecond`r`n"))

        codex prompt *> $null

        $arguments = @(Get-Content $script:FakeCapture | Where-Object { $_ -like 'arg=*' })
        $arguments[1] | Should -Be 'arg=developer_instructions="first\r\nsecond"'
    }

    It 'rejects NUL bytes in Codex instructions before launch' {
        [IO.File]::WriteAllBytes((Join-Path $script:AipProfileRoot 'work/codex/instructions.md'), [byte[]](98, 101, 102, 111, 114, 101, 0, 97, 102, 116, 101, 114))
        Remove-Item $script:FakeCapture -ErrorAction SilentlyContinue

        codex prompt *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'required profile file or link is missing or invalid'
        Test-Path $script:FakeCapture | Should -BeFalse
    }

    It 'rejects TOML-forbidden control characters before launching Codex' {
        "unsafe $([char]1) control" | Set-Content (Join-Path $script:AipProfileRoot 'work/codex/instructions.md')
        Remove-Item $script:FakeCapture -ErrorAction SilentlyContinue

        codex prompt *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'control character that TOML cannot represent safely'
        Test-Path $script:FakeCapture | Should -BeFalse
    }

    It 'reports success for an ExternalScript harness that leaves LASTEXITCODE untouched' {
        $externalScript = Join-Path $TestDrive 'claude-success.ps1'
        'param([Parameter(ValueFromRemainingArguments)][object[]]$Arguments); $null = Get-Date' | Set-Content -LiteralPath $externalScript
        Mock Get-AipRealCommand { $externalScript }
        Mock Invoke-AipSync { $script:AipCommandStatus = 0 }
        $global:LASTEXITCODE = 77

        claude prompt *> $null

        $global:LASTEXITCODE | Should -Be 0
    }

    It 'restores a previous selector and preserves the child exit status' {
        $env:CLAUDE_CONFIG_DIR = 'original value'
        $env:FAKE_EXIT_STATUS = '37'
        claude prompt *> $null
        $global:LASTEXITCODE | Should -Be 37
        $env:CLAUDE_CONFIG_DIR | Should -Be 'original value'
    }

    It 'does not replace the child status when after-run sync fails' {
        $fake = Get-AipRealCommand 'claude'
        if ($IsWindows) {
            @'
@echo off
> "%CLAUDE_CONFIG_DIR%\..\codex\auth.json" echo credential material
git -C "%CLAUDE_CONFIG_DIR%\.." add -f codex/auth.json
exit /b 37
'@ | Set-Content -LiteralPath $fake -Encoding ascii
        }
        else {
            @'
#!/bin/sh
printf 'credential material\n' > "$CLAUDE_CONFIG_DIR/../codex/auth.json"
git -C "$CLAUDE_CONFIG_DIR/.." add -f codex/auth.json
exit 37
'@ | Set-Content -LiteralPath $fake -Encoding utf8NoBOM
            & chmod +x $fake
        }
        claude *> $null
        $global:LASTEXITCODE | Should -Be 37
        $script:AipLastError | Should -Match 'forbidden credential or runtime path is tracked'
    }

    It 'restores environment and child status when post-sync throws under Stop preference' {
        $env:CLAUDE_CONFIG_DIR = 'original value'
        $env:FAKE_EXIT_STATUS = '37'
        Mock Invoke-AipSync {
            param([string]$Mode = 'manual')
            if ($Mode -eq 'after') { throw 'simulated cleanup failure' }
            $script:AipCommandStatus = 0
        }
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Stop'
            claude prompt *> $null
        }
        finally { $ErrorActionPreference = $previousPreference }

        $global:LASTEXITCODE | Should -Be 37
        $env:CLAUDE_CONFIG_DIR | Should -Be 'original value'
        $script:AipLastWarning | Should -Match 'after-run sync failed during cleanup'
    }

    It 'preserves an interrupted child status and still checkpoints changes' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $fake = Get-AipRealCommand 'claude'
        if ($IsWindows) {
            @"
@echo off
echo interrupted>>"$profile\AGENTS.md"
exit /b 130
"@ | Set-Content -LiteralPath $fake -Encoding ascii
        }
        else {
            @"
#!/bin/sh
printf 'interrupted\n' >> '$profile/AGENTS.md'
exit 130
"@ | Set-Content -LiteralPath $fake -Encoding utf8NoBOM
            & chmod +x $fake
        }

        claude *> $null

        $global:LASTEXITCODE | Should -Be 130
        (& git -C $script:AipProfileRoot show 'HEAD:work/AGENTS.md')[-1] | Should -Be 'interrupted'
    }

    It 'checkpoints an interrupted harness run and preserves status 130' {
        # A real console Ctrl-C cannot be faithfully simulated in a headless
        # process: a non-interactive pwsh host exits instead of surfacing the
        # interrupt to script code. But the interrupt itself is a
        # PipelineStoppedException, which pwsh treats specially: it bypasses
        # catch clauses and eventually exits the process, while finally
        # blocks still run. That is exactly the path aip relies on in
        # production - its finally checkpoints the in-flight change and
        # records 130. So the fake harness writes a change, then throws a
        # real PipelineStoppedException. The call runs in a child pwsh
        # process (which the unhandled interrupt kills, so it can never take
        # down the Pester host); the child's finally records the
        # LASTEXITCODE that aip set.
        $profile = Join-Path $script:AipProfileRoot 'work'
        $fake = Join-Path $TestDrive 'fake-claude.ps1'
        $runner = Join-Path $TestDrive 'interrupt-runner.ps1'
        $exitFile = Join-Path $TestDrive 'interrupt-exit.txt'
        $profileQ = $profile.Replace("'", "''")
        @"
Add-Content -LiteralPath '$profileQ/AGENTS.md' 'interrupted in flight'
throw [System.Management.Automation.PipelineStoppedException]::new('simulated Ctrl-C')
"@ | Set-Content -LiteralPath $fake -Encoding utf8NoBOM
        $quotedRepository = $script:RepositoryRoot.Replace("'", "''")
        $quotedRoot = $script:AipProfileRoot.Replace("'", "''")
        $quotedFake = $fake.Replace("'", "''")
        @"
. '$quotedRepository/aip.ps1'
`$script:AipProfileRoot = '$quotedRoot'
`$env:AIP_PROFILE = 'work'
# Route the harness call to the in-process fake, so its
# PipelineStoppedException propagates through aip's native call
# statement exactly as a real Ctrl-C would.
function Get-AipRealCommand { param([string]`$Name) '$quotedFake' }
try {
    claude *> `$null
    'completed' | Set-Content -LiteralPath `$env:AIP_PSE_EXIT_FILE
}
finally {
    'lastexit=' + `$global:LASTEXITCODE | Add-Content -LiteralPath `$env:AIP_PSE_EXIT_FILE
}
"@ | Set-Content -LiteralPath $runner -Encoding utf8NoBOM
        $env:AIP_PSE_EXIT_FILE = $exitFile
        try {
            $pwsh = (Get-Process -Id $PID).Path
            [void](& $pwsh -NoProfile -File $runner)
        }
        finally { $env:AIP_PSE_EXIT_FILE = $null }

        Test-Path -LiteralPath $exitFile | Should -BeTrue -Because 'the child pwsh process ran'
        $exitText = (Get-Content -LiteralPath $exitFile -Raw).Trim()
        $exitText | Should -Match 'lastexit=130' -Because "aip's finally must record 130: $exitText"
        (& git -C $script:AipProfileRoot show 'HEAD:work/AGENTS.md')[-1] | Should -Be 'interrupted in flight'
    }

}

Describe 'local lifecycle' {
    BeforeEach { New-TestProfile work suit }

    It 'clones only checkpointed content into the profiles repository without runtime state' {
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        'checkpoint me' | Set-Content (Join-Path $profile 'AGENTS.md')
        'runtime' | Set-Content (Join-Path $profile 'claude/session.json')
        aip clone work copy *> $null
        $global:LASTEXITCODE | Should -Be 0
        $copy = Join-Path $root 'copy'
        (Get-Content (Join-Path $copy 'AGENTS.md') -Raw).Trim() | Should -Be 'checkpoint me'
        Test-Path (Join-Path $copy 'claude/session.json') | Should -BeFalse
        Test-Path (Join-Path $copy '.git') | Should -BeFalse
        Test-Path (Join-Path $copy 'skills/.gitkeep') | Should -BeTrue
        (Get-Item (Join-Path $copy 'codex/skills')).LinkType | Should -Be 'SymbolicLink'
        (& git -C $root config --bool core.symlinks) | Should -Be 'true'
        # create commit + checkpoint commit for the dirty AGENTS.md + clone commit
        (& git -C $root rev-list --count HEAD) | Should -Be 3
    }

    It 'preserves executable file modes when cloning a profile' {
        $root = $script:AipProfileRoot
        $executable = Join-Path $root 'work/skills/tool/run.sh'
        New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force | Out-Null
        '#!/bin/sh' | Set-Content -LiteralPath $executable
        if (-not $IsWindows) { & chmod +x $executable }
        & git -C $root add work/skills/tool/run.sh
        & git -C $root update-index --chmod=+x -- work/skills/tool/run.sh
        & git -C $root commit -q -m 'add executable skill resource'

        aip clone work copy *> $null

        $global:LASTEXITCODE | Should -Be 0
        ((& git -C $root ls-files --stage -- copy/skills/tool/run.sh) -split ' ')[0] | Should -Be '100755'
    }

    It 'preserves an empty skills directory through an ordinary Git clone' {
        $clone = Join-Path $TestDrive 'ordinary clone'
        & git -c core.symlinks=true clone -q $script:AipProfileRoot $clone

        Test-Path (Join-Path $clone 'work/skills/.gitkeep') | Should -BeTrue
        (Get-Item (Join-Path $clone 'work/codex/skills')).LinkType | Should -Be 'SymbolicLink'
    }

    It 'does not remove a colliding temporary directory that it did not create' {
        $collision = Join-Path $script:AipProfileRoot '.aip-copy-collision'
        New-Item -ItemType Directory -Path $collision | Out-Null
        'keep' | Set-Content (Join-Path $collision 'owned-by-user')
        $script:TemporaryNames = [Collections.Generic.Queue[string]]::new()
        $script:TemporaryNames.Enqueue('collision')
        $script:TemporaryNames.Enqueue('fresh')
        Mock Get-AipTemporaryName { $script:TemporaryNames.Dequeue() }

        aip clone work copy *> $null

        $global:LASTEXITCODE | Should -Be 0
        (Get-Content (Join-Path $collision 'owned-by-user') -Raw).Trim() | Should -Be 'keep'
        Test-Path (Join-Path $script:AipProfileRoot 'copy') | Should -BeTrue
    }

    It 'does not remove a colliding create temporary directory that it did not create' {
        $collision = Join-Path $script:AipProfileRoot '.aip-new-collision'
        New-Item -ItemType Directory -Path $collision | Out-Null
        'keep' | Set-Content (Join-Path $collision 'owned-by-user')
        $script:TemporaryNames = [Collections.Generic.Queue[string]]::new()
        $script:TemporaryNames.Enqueue('collision')
        $script:TemporaryNames.Enqueue('fresh')
        Mock Get-AipTemporaryName { $script:TemporaryNames.Dequeue() }

        aip create new *> $null

        $global:LASTEXITCODE | Should -Be 0
        (Get-Content (Join-Path $collision 'owned-by-user') -Raw).Trim() | Should -Be 'keep'
        Test-Path (Join-Path $script:AipProfileRoot 'new') | Should -BeTrue
    }

    It 'refuses dangling-link destinations without replacing them' {
        $dangling = Join-Path $script:AipProfileRoot 'dangling'
        New-Item -ItemType SymbolicLink -Path $dangling -Target (Join-Path $script:AipProfileRoot 'nowhere') | Out-Null

        aip create dangling *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        (Get-Item -LiteralPath $dangling -Force).LinkType | Should -Be 'SymbolicLink'
        aip clone work dangling *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        (Get-Item -LiteralPath $dangling -Force).LinkType | Should -Be 'SymbolicLink'
    }

    It 'refuses the active profile and force-deletes an exact inactive target' {
        New-TestProfile copy
        $env:AIP_PROFILE = 'work'
        aip delete work --force 2>$null
        $global:LASTEXITCODE | Should -Not -Be 0
        Test-Path (Join-Path $script:AipProfileRoot 'work') | Should -BeTrue
        aip delete copy --force *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path $script:AipProfileRoot 'copy') | Should -BeFalse
    }

    It 'requires force for non-interactive deletion and preserves the profile' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $runner = Join-Path $TestDrive 'noninteractive-delete.ps1'
        @"
. `"$(Join-Path $script:RepositoryRoot 'aip.ps1')`"
`$script:AipProfileRoot = `"$script:AipProfileRoot`"
aip delete work
exit `$global:LASTEXITCODE
"@ | Set-Content -LiteralPath $runner -Encoding utf8NoBOM
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = (Get-Process -Id $PID).Path
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in '-NoProfile', '-NonInteractive', '-File', $runner) { [void]$start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        $process.StandardInput.Close()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $process.ExitCode | Should -Not -Be 0
        $errorText | Should -Match 'rerun with --force'
        Test-Path -LiteralPath $profile | Should -BeTrue
    }

    It 'does not clear the default or report success when filesystem deletion fails' {
        aip default work *> $null
        Mock Remove-Item { throw 'simulated locked file' } -ParameterFilter { $LiteralPath -eq (Join-Path $script:AipProfileRoot 'work') }

        aip delete work --force *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        Test-Path (Join-Path $script:AipProfileRoot 'work') | Should -BeTrue
        (Get-Content (Join-Path $script:AipProfileRoot '.default') -Raw).Trim() | Should -Be 'work'
    }

    It 'does not claim dirty content is remotely recoverable during forced deletion' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $remote = Join-Path $TestDrive 'delete.git'
        & git init -q --bare $remote
        & git -C $script:AipProfileRoot remote add origin $remote
        & git -C $script:AipProfileRoot push -q -u origin main
        'dirty' | Add-Content (Join-Path $profile 'AGENTS.md')

        $output = aip delete work --force | Out-String

        $global:LASTEXITCODE | Should -Be 0
        $output | Should -Match 'no complete remote recovery'
        $output | Should -Not -Match 'recoverable from the configured Git upstream'
    }

    It 'treats unique commits on another local branch as unrecoverable' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $remote = Join-Path $TestDrive 'delete branches.git'
        & git init -q --bare $remote
        & git -C $script:AipProfileRoot remote add origin $remote
        & git -C $script:AipProfileRoot push -q -u origin main
        & git -C $script:AipProfileRoot switch -q -c private-work
        'private' | Set-Content (Join-Path $profile 'PRIVATE.md')
        & git -C $script:AipProfileRoot add work/PRIVATE.md
        & git -C $script:AipProfileRoot commit -q -m private
        & git -C $script:AipProfileRoot switch -q main

        $output = aip delete work --force | Out-String

        $global:LASTEXITCODE | Should -Be 0
        $output | Should -Match 'no complete remote recovery'
        $output | Should -Not -Match 'recoverable from the configured Git upstream'
    }

    It 'never claims recovery when Git state inspection fails' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $remote = Join-Path $TestDrive 'delete corrupt.git'
        & git init -q --bare $remote
        & git -C $script:AipProfileRoot remote add origin $remote
        & git -C $script:AipProfileRoot push -q -u origin main
        'dirty' | Add-Content (Join-Path $profile 'AGENTS.md')
        'corrupt index' | Set-Content -LiteralPath (Join-Path $script:AipProfileRoot '.git/index')

        $output = aip delete work --force | Out-String

        $global:LASTEXITCODE | Should -Be 0
        $output | Should -Match 'no complete remote recovery'
        $output | Should -Not -Match 'recoverable from the configured Git upstream'
    }

    It 'doctor detects a broken required link' {
        $link = Join-Path $script:AipProfileRoot 'work/codex/skills'
        Remove-Item $link -Force
        New-Item -ItemType SymbolicLink -Path $link -Target '../other' | Out-Null
        $output = aip doctor work 2>&1 | Out-String
        $global:LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'codex/skills should link to ../skills'
    }

    It 'doctor diagnoses a configured upstream that cannot be resolved' {
        $branch = & git -C $script:AipProfileRoot branch --show-current
        & git -C $script:AipProfileRoot config "branch.$branch.remote" origin
        & git -C $script:AipProfileRoot config "branch.$branch.merge" refs/heads/main

        $output = aip doctor work 2>&1 | Out-String

        $global:LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'configured Git upstream cannot be resolved'
        $output | Should -Match 'branch --unset-upstream'
        $output | Should -Not -Match 'OK: profiles repository'
    }

    It 'doctor diagnoses missing repository metadata and list skips linked profiles' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $externalGit = Join-Path $TestDrive 'external git'
        Move-Item -LiteralPath (Join-Path $script:AipProfileRoot '.git') -Destination $externalGit

        $doctorOutput = aip doctor work | Out-String

        $global:LASTEXITCODE | Should -Not -Be 0
        $doctorOutput | Should -Match 'profiles repository metadata is missing or linked'
        Move-Item -LiteralPath $externalGit -Destination (Join-Path $script:AipProfileRoot '.git')

        $externalProfile = Join-Path $TestDrive 'external profile'
        Move-Item -LiteralPath $profile -Destination $externalProfile
        New-Item -ItemType SymbolicLink -Path $profile -Target $externalProfile | Out-Null
        (aip list | Out-String) | Should -Match 'No profiles'
        Remove-Item -LiteralPath $profile -Force
        Move-Item -LiteralPath $externalProfile -Destination $profile
    }

    It 'a linked profile directory blocks sync' {
        New-TestProfile personal
        $alias = Join-Path $script:AipProfileRoot 'personal-link'
        New-Item -ItemType SymbolicLink -Path $alias -Target (Join-Path $script:AipProfileRoot 'personal') | Out-Null

        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'must not be a symbolic link'
    }

    It 'rejects the removed outfit command' {
        aip outfit work jacket *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match "unknown command 'outfit'"
    }

    It 'doctor reports forbidden tracked content and a stale lock without deleting the lock' {
        $root = $script:AipProfileRoot
        'credential' | Set-Content (Join-Path $root 'work/codex/auth.json')
        & git -C $root add -f work/codex/auth.json
        $lock = Join-Path $root '.git/aip-sync.lock'
        New-Item -ItemType Directory -Path $lock | Out-Null
        '99999999' | Set-Content (Join-Path $lock 'pid')
        [Environment]::MachineName | Set-Content (Join-Path $lock 'host')
        'old' | Set-Content (Join-Path $lock 'token')
        $output = aip doctor work | Out-String
        $global:LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'ERROR: tracked profile path validation failed'
        $output | Should -Match 'WARN: stale sync lock found'
        Test-Path $lock | Should -BeTrue
    }

    It 'doctor reports an unfinished Git operation with recovery commands' {
        New-Item -ItemType Directory -Path (Join-Path $script:AipProfileRoot '.git/rebase-merge') | Out-Null

        $output = aip doctor work | Out-String

        $global:LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'Git conflict or unfinished operation'
        $output | Should -Match 'git rebase --abort'
    }

    It 'rejects directory marker collisions without writing inside them' {
        $default = Join-Path $script:AipProfileRoot '.default'
        New-Item -ItemType Directory -Path $default | Out-Null
        aip default work *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        @(Get-ChildItem -LiteralPath $default -Force).Count | Should -Be 0

        $project = Join-Path $TestDrive 'marker project'
        New-Item -ItemType Directory -Path $project | Out-Null
        Push-Location $project
        try {
            New-Item -ItemType Directory -Path '.aip-profile' | Out-Null
            aip local work *> $null
            $global:LASTEXITCODE | Should -Not -Be 0
            @(Get-ChildItem -LiteralPath '.aip-profile' -Force).Count | Should -Be 0
        }
        finally { Pop-Location }
    }
}

Describe 'Git checkpoint and sync' {
    BeforeEach {
        New-TestProfile work
        $env:AIP_PROFILE = 'work'
    }

    It 'sync rejects an argument as a usage error' {
        aip sync work *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'unexpected argument .work.; aip sync syncs every profile in the profiles repository'
        aip sync work extra *> $null
        $global:LASTEXITCODE | Should -Be 2
    }

    It 'sync fails closed when the profiles repository is missing' {
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot '.git') -Recurse -Force

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'not a Git repository'
    }

    It 'auto-tracks shared skills but leaves unknown native files untracked' {
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        New-Item -ItemType Directory -Path (Join-Path $profile 'skills/reviewer') -Force | Out-Null
        '# Reviewer' | Set-Content (Join-Path $profile 'skills/reviewer/SKILL.md')
        '{}' | Set-Content (Join-Path $profile 'claude/settings.json')
        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $root show 'HEAD:work/skills/reviewer/SKILL.md') | Should -Be '# Reviewer'
        (& git -C $root ls-files -- work/claude/settings.json) | Should -BeNullOrEmpty
    }

    It 'does not create a commit for a no-op sync' {
        $before = [int](& git -C $script:AipProfileRoot rev-list --count HEAD)
        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        [int](& git -C $script:AipProfileRoot rev-list --count HEAD) | Should -Be $before
    }

    It 'hard-fails when a known credential path is tracked' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        'credential material' | Set-Content (Join-Path $profile 'codex/auth.json')
        & git -C $script:AipProfileRoot add -f work/codex/auth.json
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential or runtime path is tracked'
    }

    It 'refuses a forbidden untracked skill even if the user changed gitignore to allow it' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        Add-Content -LiteralPath (Join-Path $profile '.gitignore') -Value '!skills/reviewer/.env'
        New-Item -ItemType Directory -Path (Join-Path $profile 'skills/reviewer') -Force | Out-Null
        'credential' | Set-Content (Join-Path $profile 'skills/reviewer/.env')
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential path exists under skills'
        (& git -C $script:AipProfileRoot ls-files -- work/skills/reviewer/.env) | Should -BeNullOrEmpty
    }

    It 'blocks an extensionless private key even when explicitly unignored' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        Add-Content -LiteralPath (Join-Path $profile '.gitignore') -Value '!skills/reviewer/id_ed25519'
        New-Item -ItemType Directory -Path (Join-Path $profile 'skills/reviewer') -Force | Out-Null
        'private key' | Set-Content (Join-Path $profile 'skills/reviewer/id_ed25519')

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential path exists under skills'
        (& git -C $script:AipProfileRoot ls-files -- work/skills/reviewer/id_ed25519) | Should -BeNullOrEmpty
    }

    It 'blocks skill-tree .credentials.json even when gitignore allows it' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $dir = Join-Path $profile 'skills/x'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $profile '.gitignore') -Value '!skills/x/.credentials.json'
        'secret' | Set-Content (Join-Path $dir '.credentials.json')
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential path exists under skills'
        @(& git -C $script:AipProfileRoot ls-files -- 'work/skills/x/.credentials.json').Count | Should -Be 0
    }

    It 'blocks skill-tree auth.json even when gitignore allows it' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $dir = Join-Path $profile 'skills/x'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $profile '.gitignore') -Value '!skills/x/auth.json'
        'secret' | Set-Content (Join-Path $dir 'auth.json')
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential path exists under skills'
        @(& git -C $script:AipProfileRoot ls-files -- 'work/skills/x/auth.json').Count | Should -Be 0
    }

    It 'blocks uppercase credential extensions under skills' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        Add-Content -LiteralPath (Join-Path $profile '.gitignore') -Value '!skills/reviewer/SECRET.PEM'
        New-Item -ItemType Directory -Path (Join-Path $profile 'skills/reviewer') -Force | Out-Null
        'private key' | Set-Content (Join-Path $profile 'skills/reviewer/SECRET.PEM')

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential path exists under skills'
        (& git -C $script:AipProfileRoot ls-files -- work/skills/reviewer/SECRET.PEM) | Should -BeNullOrEmpty
    }

    It 'blocks Windows-incompatible and case-colliding shared-skill paths' {
        Test-AipPortablePaths @('skills/CON.txt') 'shared skills' | Should -BeFalse
        $script:AipLastError | Should -Match 'not portable to Windows'
        $script:AipLastError = $null
        Test-AipPortablePaths @('skills/Foo/one.md', 'skills/foo/two.md') 'shared skills' | Should -BeFalse
        $script:AipLastError | Should -Match 'case-colliding paths'
    }

    It 'bypasses a caller-defined git function' {
        function global:git { throw 'shadow git function was called' }
        try { aip sync *> $null }
        finally { Remove-Item Function:git -Force -ErrorAction SilentlyContinue }

        $global:LASTEXITCODE | Should -Be 0
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'rejects node_modules and exact runtime roots when they are force-tracked' {
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        $modulePath = Join-Path $profile 'skills/reviewer/node_modules/pkg/index.js'
        New-Item -ItemType Directory -Path (Split-Path -Parent $modulePath) -Force | Out-Null
        'generated' | Set-Content $modulePath
        & git -C $root add -f work/skills/reviewer/node_modules/pkg/index.js
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential or runtime path is tracked'

        & git -C $root reset -q
        Remove-Item -LiteralPath (Join-Path $profile 'skills/reviewer') -Recurse -Force
        'runtime root' | Set-Content (Join-Path $profile 'claude/projects')
        & git -C $root add -f work/claude/projects
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential or runtime path is tracked'
    }

    It 'recreates the owned skills placeholder when the directory is empty' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        Remove-Item -LiteralPath (Join-Path $profile 'skills/.gitkeep') -Force

        aip sync *> $null

        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $profile 'skills/.gitkeep') -PathType Leaf | Should -BeTrue
        (& git -C $script:AipProfileRoot cat-file -t 'HEAD:work/skills') | Should -Be 'tree'
    }

    It 'rejects a nested Git repository instead of recording a gitlink' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $nested = Join-Path $profile 'skills/nested'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        & git -C $nested init -q
        '# Nested' | Set-Content (Join-Path $nested 'SKILL.md')

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'nested Git repositories under skills'
        (& git -C $script:AipProfileRoot ls-files --stage -- work/skills/nested) | Should -BeNullOrEmpty
    }

    It 'rejects Git submodules outside the shared skills tree' {
        $root = $script:AipProfileRoot
        $commit = & git -C $root rev-parse HEAD
        & git -C $root update-index --add --cacheinfo "160000,$commit,work/claude/plugins/tool"

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'Git submodules are not supported'
    }

    It 'rejects profile, Git metadata, and required-file links before mutation' {
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        $externalProfile = Join-Path $TestDrive 'external profile'
        Move-Item -LiteralPath $profile -Destination $externalProfile
        $before = & git -C $root rev-parse HEAD
        New-Item -ItemType SymbolicLink -Path $profile -Target $externalProfile | Out-Null
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'must not be a symbolic link'
        (& git -C $root rev-parse HEAD) | Should -Be $before
        Remove-Item -LiteralPath $profile -Force
        Move-Item -LiteralPath $externalProfile -Destination $profile

        $externalGit = Join-Path $TestDrive 'external git'
        Move-Item -LiteralPath (Join-Path $root '.git') -Destination $externalGit
        New-Item -ItemType SymbolicLink -Path (Join-Path $root '.git') -Target $externalGit | Out-Null
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'not a Git repository'
        Remove-Item -LiteralPath (Join-Path $root '.git') -Force
        Move-Item -LiteralPath $externalGit -Destination (Join-Path $root '.git')

        $externalInstructions = Join-Path $TestDrive 'external instructions'
        'outside' | Set-Content $externalInstructions
        Remove-Item -LiteralPath (Join-Path $profile 'codex/instructions.md')
        New-Item -ItemType SymbolicLink -Path (Join-Path $profile 'codex/instructions.md') -Target $externalInstructions | Out-Null
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        (Get-Content $externalInstructions -Raw).Trim() | Should -Be 'outside'
    }

    It 'ignores exported Git routing and mutates only the profiles repository' {
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        $external = Join-Path $TestDrive 'external repository'
        & git init -q $external
        'external' | Set-Content (Join-Path $external 'file')
        & git -C $external add file
        & git -C $external commit -q -m initial
        $externalHead = & git -C $external rev-parse HEAD
        'profile change' | Add-Content (Join-Path $profile 'AGENTS.md')
        $env:GIT_DIR = Join-Path $external '.git'
        $env:GIT_WORK_TREE = $external
        try { aip sync *> $null }
        finally { $env:GIT_DIR = $null; $env:GIT_WORK_TREE = $null }

        $global:LASTEXITCODE | Should -Be 0
        (& git -C $external rev-parse HEAD) | Should -Be $externalHead
        (& git -C $root show 'HEAD:work/AGENTS.md')[-1] | Should -Be 'profile change'
    }

    It 'rejects a profiles repository whose local Git config routes to another worktree' {
        $root = $script:AipProfileRoot
        $external = Join-Path $TestDrive 'external worktree'
        & git clone -q $root $external
        $gitDirectory = Join-Path $root '.git'
        & git "--git-dir=$gitDirectory" config core.worktree $external
        'external change' | Add-Content (Join-Path $external 'work/AGENTS.md')
        $before = & git "--git-dir=$gitDirectory" rev-parse HEAD

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'Git repository routing escapes the profiles repository'
        (& git "--git-dir=$gitDirectory" rev-parse HEAD) | Should -Be $before
    }

    It 'rejects linked Git metadata beneath the repository during sync and doctor' {
        $external = Join-Path $TestDrive 'external objects'
        Move-Item -LiteralPath (Join-Path $script:AipProfileRoot '.git/objects') -Destination $external
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot '.git/objects') -Target $external | Out-Null

        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'Git metadata contains'
        $doctorOutput = aip doctor work | Out-String
        $global:LASTEXITCODE | Should -Not -Be 0
        $doctorOutput | Should -Match 'Git metadata contains a symbolic link or reparse point'
    }

    It 'rejects optional links that escape the live profile boundary' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $external = Join-Path $TestDrive 'external-settings'
        'outside' | Set-Content -LiteralPath $external
        New-Item -ItemType SymbolicLink -Path (Join-Path $profile 'claude/settings.json') -Target $external | Out-Null

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'unsupported symbolic link'
        (Get-Content -LiteralPath $external -Raw).Trim() | Should -Be 'outside'
    }

    It 'tolerates npm-managed symlinks under node_modules' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $bin = Join-Path $profile 'pi/npm/node_modules/.bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $external = Join-Path $TestDrive 'external-bin'
        'outside' | Set-Content -LiteralPath $external
        # Deliberately points outside the profile: the exemption is the
        # node_modules location, not where the link happens to point.
        New-Item -ItemType SymbolicLink -Path (Join-Path $bin 'anthropic-ai-sdk') -Target $external | Out-Null

        aip sync *> $null

        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath $external -Raw).Trim() | Should -Be 'outside'
    }

    It 'tolerates a profile whose tracked .gitignore is missing when its links are intact' {
        $root = $script:AipProfileRoot
        & git -C $root rm -q --cached work/.gitignore
        & git -C $root commit -q -m 'drop tracked gitignore'

        aip sync *> $null

        $global:LASTEXITCODE | Should -Be 0
        (& git -C $root ls-files -- work/.gitignore) | Should -Not -BeNullOrEmpty
    }

    It 'rejects a tracked required link with an unexpected target' {
        $root = $script:AipProfileRoot
        $evil = Join-Path $TestDrive 'evil-target'
        '../../..' | Set-Content -LiteralPath $evil -NoNewline
        $hash = & git -C $root hash-object -w $evil
        & git -C $root update-index --add --cacheinfo "120000,$hash,work/codex/skills"

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'unexpected target'
    }

    It 'rejects a tracked optional link even under a healthy profile' {
        $root = $script:AipProfileRoot
        $blob = Join-Path $TestDrive 'optional-target'
        'outside' | Set-Content -LiteralPath $blob -NoNewline
        $hash = & git -C $root hash-object -w $blob
        & git -C $root update-index --add --cacheinfo "120000,$hash,work/claude/settings.json"

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'unsupported symbolic link'
    }

    It 'pulls and pushes through a local bare upstream' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git clone -q $script:TestRemote $other
        'remote' | Set-Content (Join-Path $other 'REMOTE.md')
        & git -C $other add REMOTE.md
        & git -C $other commit -q -m remote
        & git -C $other push -q
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        New-Item -ItemType Directory -Path (Join-Path $profile 'skills/local') -Force | Out-Null
        'local' | Set-Content (Join-Path $profile 'skills/local/SKILL.md')
        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path $root 'REMOTE.md') | Should -BeTrue
        & git -C $other pull -q
        Test-Path (Join-Path $other 'work/skills/local/SKILL.md') | Should -BeTrue
    }

    It 'pushes to the fetched upstream even when pushRemote points elsewhere' {
        Initialize-TestUpstream
        $root = $script:AipProfileRoot
        $other = Join-Path $TestDrive 'other.git'
        & git init -q --bare $other
        & git -C $root remote add other $other
        & git -C $root push -q other main
        $otherBefore = & git "--git-dir=$other" rev-parse refs/heads/main
        & git -C $root config branch.main.pushRemote other
        'upstream only' | Add-Content (Join-Path $root 'work/AGENTS.md')

        aip sync *> $null

        $global:LASTEXITCODE | Should -Be 0
        (& git "--git-dir=$script:TestRemote" rev-parse refs/heads/main) | Should -Be (& git -C $root rev-parse HEAD)
        (& git "--git-dir=$other" rev-parse refs/heads/main) | Should -Be $otherBefore
    }

    It 'keeps SSH authentication failures noninteractive' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $fakeSsh = Join-Path $script:FakeBin "fake-ssh$(if ($IsWindows) { '.cmd' } else { '' })"
        $sshArgs = Join-Path $TestDrive 'ssh-args'
        $promptFlag = Join-Path $TestDrive 'ssh-prompted'
        if ($IsWindows) {
            @"
@echo off
echo %*>>"$sshArgs"
echo %*| findstr /c:"BatchMode=yes" >nul || type nul >"$promptFlag"
exit /b 1
"@ | Set-Content -LiteralPath $fakeSsh -Encoding ascii
            $env:GIT_SSH_COMMAND = '"' + $fakeSsh + '"'
        }
        else {
            @"
#!/bin/sh
printf '%s\n' "`$@" >>'$sshArgs'
case " `$* " in *" BatchMode=yes "*) ;; *) : >'$promptFlag' ;; esac
exit 1
"@ | Set-Content -LiteralPath $fakeSsh -Encoding utf8NoBOM
            & chmod +x $fakeSsh
            $env:GIT_SSH_COMMAND = "'$fakeSsh'"
        }
        & git -C $script:AipProfileRoot remote add origin 'ssh://example.invalid/profile.git'
        & git -C $script:AipProfileRoot update-ref refs/remotes/origin/main HEAD
        & git -C $script:AipProfileRoot branch --set-upstream-to origin/main *> $null

        try { aip sync *> $null }
        finally { $env:GIT_SSH_COMMAND = $null }

        $global:LASTEXITCODE | Should -Be 0
        $script:AipLastWarning | Should -Match 'remote sync unavailable'
        Test-Path -LiteralPath $promptFlag | Should -BeFalse
        if ($IsWindows) {
            # git-for-windows routes GIT_SSH_COMMAND through sh, which cannot
            # execute a .cmd, so the fake never runs here. Assert the
            # transport aip hands to git instead; the full args e2e (git
            # executing the fake) runs on the POSIX jobs.
            $env:GIT_SSH_COMMAND = '"' + $fakeSsh + '"'
            try {
                (Get-AipSshTransport $script:AipProfileRoot).Command | Should -Be ("`"$fakeSsh`" -o BatchMode=yes")
            }
            finally { $env:GIT_SSH_COMMAND = $null }
        }
        else {
            (Get-Content -LiteralPath $sshArgs -Raw) | Should -Match 'BatchMode=yes'
        }
    }

    It 'places the noninteractive SSH setting before a configured BatchMode=no' {
        $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=no'
        try { $transport = Get-AipSshTransport $script:AipProfileRoot }
        finally { $env:GIT_SSH_COMMAND = $null }

        $transport.Command | Should -Be 'ssh -o BatchMode=yes -o BatchMode=no'
    }

    It 'does not invoke a simple SSH transport that cannot be made noninteractive' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $invoked = Join-Path $TestDrive 'simple-invoked'
        $fakeSsh = Join-Path $script:FakeBin "simple-ssh$(if ($IsWindows) { '.cmd' } else { '' })"
        if ($IsWindows) {
            "@echo off`r`ntype nul >`"$invoked`"`r`nexit /b 1`r`n" | Set-Content -LiteralPath $fakeSsh -Encoding ascii
        }
        else {
            "#!/bin/sh`n: >'$invoked'`nexit 1`n" | Set-Content -LiteralPath $fakeSsh -Encoding utf8NoBOM
            & chmod +x $fakeSsh
        }
        & git -C $script:AipProfileRoot remote add origin 'ssh://example.invalid/profile.git'
        & git -C $script:AipProfileRoot update-ref refs/remotes/origin/main HEAD
        & git -C $script:AipProfileRoot branch --set-upstream-to origin/main *> $null
        & git -C $script:AipProfileRoot config core.sshCommand $fakeSsh
        & git -C $script:AipProfileRoot config ssh.variant simple

        aip sync *> $null

        $global:LASTEXITCODE | Should -Be 0
        $script:AipLastWarning | Should -Match 'cannot be made non-interactive'
        Test-Path -LiteralPath $invoked | Should -BeFalse
    }

    It 'preserves a spaced GIT_SSH executable path while making it noninteractive' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $sshArgs = Join-Path $TestDrive 'spaced-ssh-args'
        $fakeSsh = Join-Path $script:FakeBin "fake ssh$(if ($IsWindows) { '.cmd' } else { '' })"
        if ($IsWindows) {
            "@echo off`r`necho %* >`"$sshArgs`"`r`nexit /b 1`r`n" | Set-Content -LiteralPath $fakeSsh -Encoding ascii
        }
        else {
            @"
#!/bin/sh
printf '%s\n' "`$@" >'$sshArgs'
exit 1
"@ | Set-Content -LiteralPath $fakeSsh -Encoding utf8NoBOM
            & chmod +x $fakeSsh
        }
        & git -C $script:AipProfileRoot remote add origin 'ssh://example.invalid/profile.git'
        & git -C $script:AipProfileRoot update-ref refs/remotes/origin/main HEAD
        & git -C $script:AipProfileRoot branch --set-upstream-to origin/main *> $null
        $env:GIT_SSH = $fakeSsh
        $env:GIT_SSH_COMMAND = $null
        $env:GIT_SSH_VARIANT = $null

        try { aip sync *> $null }
        finally { $env:GIT_SSH = $null }

        $global:LASTEXITCODE | Should -Be 0
        if ($IsWindows) {
            # git-for-windows cannot launch a .cmd via CreateProcess for
            # GIT_SSH either, so assert the transport construction instead:
            # the spaced path must survive quoting with BatchMode=yes added.
            $env:GIT_SSH = $fakeSsh
            try {
                (Get-AipSshTransport $script:AipProfileRoot).Command | Should -Be ("`"$fakeSsh`" -o BatchMode=yes")
            }
            finally { $env:GIT_SSH = $null }
        }
        else {
            (Get-Content -LiteralPath $sshArgs -Raw) | Should -Match 'BatchMode=yes'
        }
    }

    It 'never overwrites ignored local profile state during remote integration' {
        Initialize-TestUpstream
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        $nativePath = Join-Path $profile 'claude/native-state.json'
        Add-Content -LiteralPath (Join-Path $root '.git/info/exclude') -Value 'work/claude/native-state.json'
        [IO.File]::WriteAllText($nativePath, "local ignored bytes`n", [Text.UTF8Encoding]::new($false))
        $other = Join-Path $TestDrive 'other'
        & git clone -q $script:TestRemote $other
        [IO.File]::WriteAllText((Join-Path $other 'work/claude/native-state.json'), "remote tracked bytes`n", [Text.UTF8Encoding]::new($false))
        & git -C $other add work/claude/native-state.json
        & git -C $other commit -q -m 'track colliding native state'
        & git -C $other push -q

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'would overwrite or replace untracked or ignored local profile state'
        [IO.File]::ReadAllText($nativePath) | Should -Be "local ignored bytes`n"
        (& git -C $root ls-files -- work/claude/native-state.json) | Should -BeNullOrEmpty
    }

    It 'blocks local Git metadata failures instead of reporting remote offline' {
        Initialize-TestUpstream
        $root = $script:AipProfileRoot
        Remove-Item -LiteralPath (Join-Path $root '.git/FETCH_HEAD') -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path (Join-Path $root '.git/FETCH_HEAD') | Out-Null

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'must be an ordinary file'
    }

    It 'rejects hard-linked mutable Git metadata without changing its other name' {
        $external = Join-Path $TestDrive 'external-fetch-head'
        'external' | Set-Content -LiteralPath $external
        $fetchHead = Join-Path $script:AipProfileRoot '.git/FETCH_HEAD'
        Remove-Item -LiteralPath $fetchHead -Force -ErrorAction SilentlyContinue
        New-Item -ItemType HardLink -Path $fetchHead -Target $external | Out-Null

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'hard-linked mutable file'
        (Get-Content -LiteralPath $external -Raw).Trim() | Should -Be 'external'
    }

    It 'reports unfinished Git state before validating conflicted content' {
        $root = $script:AipProfileRoot
        New-Item -ItemType Directory -Path (Join-Path $root '.git/rebase-merge') | Out-Null
        'broken import' | Set-Content -LiteralPath (Join-Path $root 'work/claude/CLAUDE.md')

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'Git conflict or unfinished operation'
        $script:AipLastError | Should -Not -Match 'must begin with'
    }

    It 'rejects forbidden remote content before it enters the working profile' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git clone -q $script:TestRemote $other
        'remote credential' | Set-Content (Join-Path $other 'work/codex/auth.json')
        & git -C $other add -f work/codex/auth.json
        & git -C $other commit -q -m unsafe-remote
        & git -C $other push -q
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        $before = & git -C $root rev-parse HEAD
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'remote profile contains a forbidden credential or runtime path'
        Test-Path (Join-Path $profile 'codex/auth.json') | Should -BeFalse
        (& git -C $root rev-parse HEAD) | Should -Be $before
    }

    It 'rejects a corrupt remote link before it changes the working profile' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git -c core.symlinks=true clone -q $script:TestRemote $other
        $link = Join-Path $other 'work/codex/skills'
        Remove-Item -LiteralPath $link -Force
        New-Item -ItemType SymbolicLink -Path $link -Target '../other' | Out-Null
        & git -C $other add work/codex/skills
        & git -C $other commit -q -m corrupt-link
        & git -C $other push -q
        $profile = Join-Path $script:AipProfileRoot 'work'
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'unexpected target'
        [string](Get-Item (Join-Path $profile 'codex/skills')).Target -replace '\\', '/' | Should -Be '../skills'
    }

    It 'tolerates a remote profile whose .gitignore is missing when its links are intact' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git clone -q $script:TestRemote $other
        & git -C $other rm -q work/.gitignore
        & git -C $other commit -q -m 'drop tracked gitignore'
        & git -C $other push -q

        aip sync *> $null

        $global:LASTEXITCODE | Should -Be 0
    }

    It 'rejects a remote required link with a foreign target even when the profile prefix is incomplete' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git clone -q $script:TestRemote $other
        & git -C $other rm -q work/.gitignore
        $link = Join-Path $other 'work/codex/skills'
        Remove-Item -LiteralPath $link -Force
        New-Item -ItemType SymbolicLink -Path $link -Target '../other' | Out-Null
        & git -C $other add work/codex/skills
        & git -C $other commit -q -m 'corrupt remote link'
        & git -C $other push -q

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'unexpected target'
    }

    It 'rejects optional remote links before they enter a harness directory' {
        Initialize-TestUpstream
        $profile = Join-Path $script:AipProfileRoot 'work'
        $other = Join-Path $TestDrive 'optional link'
        & git -c core.symlinks=true clone -q $script:TestRemote $other
        New-Item -ItemType SymbolicLink -Path (Join-Path $other 'work/claude/settings.json') -Target '../outside-settings' | Out-Null
        & git -C $other add work/claude/settings.json
        & git -C $other commit -q -m optional-link
        & git -C $other push -q

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'unsupported symbolic link'
        Test-Path -LiteralPath (Join-Path $profile 'claude/settings.json') | Should -BeFalse
    }

    It 'rejects a remote profile that stops importing common Claude instructions' {
        Initialize-TestUpstream
        $root = $script:AipProfileRoot
        $before = & git -C $root rev-parse HEAD
        $other = Join-Path $TestDrive 'bad Claude import'
        & git clone -q $script:TestRemote $other
        @('../AGENTS.md', '', '# Claude Code instructions') | Set-Content -LiteralPath (Join-Path $other 'work/claude/CLAUDE.md')
        & git -C $other add work/claude/CLAUDE.md
        & git -C $other commit -q -m 'break Claude import'
        & git -C $other push -q

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'claude/CLAUDE.md must begin with @../AGENTS.md'
        (& git -C $root rev-parse HEAD) | Should -Be $before
    }

    It 'treats a stranded .aip/outfit file from an older aip as inert' {
        Initialize-TestUpstream
        $stranded = Join-Path $script:AipProfileRoot 'work/.aip/outfit'
        [void][IO.Directory]::CreateDirectory((Split-Path $stranded -Parent))
        [IO.File]::WriteAllText($stranded, "old label`n", [Text.UTF8Encoding]::new($false))
        & git -C $script:AipProfileRoot add work/.aip/outfit
        & git -C $script:AipProfileRoot commit -q -m 'simulated older aip'

        aip doctor work *> $null
        $global:LASTEXITCODE | Should -Be 0

        @(aip list) | Out-String | Should -Match 'work'

        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath $stranded | Should -BeTrue
    }

    It 'rejects NUL bytes in remote required text before rebase' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'bad text'
        & git clone -q $script:TestRemote $other
        [IO.File]::WriteAllBytes((Join-Path $other 'work/codex/instructions.md'), [byte[]](98, 101, 102, 111, 114, 101, 0, 97, 102, 116, 101, 114))
        & git -C $other add work/codex/instructions.md
        & git -C $other commit -q -m nul-text
        & git -C $other push -q

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'not valid NUL-free UTF-8'
    }

    It 'rejects remote paths that cannot be checked out on Windows' {
        Initialize-TestUpstream
        $profile = Join-Path $script:AipProfileRoot 'work'
        $other = Join-Path $TestDrive 'bad portable path'
        & git clone -q $script:TestRemote $other
        $blob = ('not portable' | & git -C $other hash-object -w --stdin)
        & git -C $other -c core.protectNTFS=false update-index --add --cacheinfo "100644,$blob,work/skills/CON.txt"
        $tree = & git -C $other write-tree
        $parent = & git -C $other rev-parse HEAD
        $commit = ('add nonportable path' | & git -C $other commit-tree $tree -p $parent)
        & git -C $other update-ref refs/heads/main $commit
        & git -C $other push -q

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'not portable to Windows'
        Test-Path -LiteralPath (Join-Path $profile 'skills/CON.txt') | Should -BeFalse
    }

    It 'rejects a remote required file stored as a symbolic link' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git -c core.symlinks=true clone -q $script:TestRemote $other
        Remove-Item -LiteralPath (Join-Path $other 'work/AGENTS.md')
        New-Item -ItemType SymbolicLink -Path (Join-Path $other 'work/AGENTS.md') -Target outside | Out-Null
        & git -C $other add work/AGENTS.md
        & git -C $other commit -q -m linked-required-file
        & git -C $other push -q
        $root = $script:AipProfileRoot
        $before = & git -C $root rev-parse HEAD

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'unsupported symbolic link'
        (& git -C $root rev-parse HEAD) | Should -Be $before
    }

    It 'launches offline and retains a local checkpoint' {
        Initialize-TestUpstream
        Move-Item $script:TestRemote "$script:TestRemote.offline"
        $root = $script:AipProfileRoot
        'offline change' | Add-Content (Join-Path $root 'work/AGENTS.md')
        claude prompt *> $null
        $global:LASTEXITCODE | Should -Be 0
        $script:AipLastWarning | Should -Match 'remote sync unavailable'
        Test-Path $script:FakeCapture | Should -BeTrue
        [int](& git -C $root rev-list --count '@{upstream}..HEAD') | Should -Be 1
    }

    It 'leaves a conflict recoverable and blocks the next launch' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git clone -q $script:TestRemote $other
        'remote version' | Set-Content (Join-Path $other 'work/AGENTS.md')
        & git -C $other add work/AGENTS.md
        & git -C $other commit -q -m remote-conflict
        & git -C $other push -q
        $root = $script:AipProfileRoot
        'local version' | Set-Content (Join-Path $root 'work/AGENTS.md')
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'Git conflict'
        (Test-Path (Join-Path $root '.git/rebase-merge')) -or (Test-Path (Join-Path $root '.git/rebase-apply')) | Should -BeTrue
        Remove-Item $script:FakeCapture -ErrorAction SilentlyContinue
        claude prompt 2>$null
        $global:LASTEXITCODE | Should -Not -Be 0
        Test-Path $script:FakeCapture | Should -BeFalse
    }

    It 'does not steal a live sync lock' {
        $lock = Join-Path $script:AipProfileRoot '.git/aip-sync.lock'
        New-Item -ItemType Directory -Path $lock | Out-Null
        $PID | Set-Content (Join-Path $lock 'pid')
        [Environment]::MachineName | Set-Content (Join-Path $lock 'host')
        'held-by-test' | Set-Content (Join-Path $lock 'token')
        $script:AipLockAttempts = 1
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'sync is already running'
        (Get-Content (Join-Path $lock 'token') -Raw).Trim() | Should -Be 'held-by-test'
    }

    It 'removes an incomplete lock when owner metadata cannot be written' {
        $lock = Join-Path $script:AipProfileRoot '.git/aip-sync.lock'
        Mock Set-Content { throw 'simulated metadata failure' } -ParameterFilter { $LiteralPath -like '*aip-sync.lock*' }

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'incomplete lock was removed'
        Test-Path $lock | Should -BeFalse
    }
}

Describe 'remote' {
    BeforeEach {
        $script:TestRemote = Join-Path $TestDrive 'remote.git'
        & git init -q --bare $script:TestRemote
    }

    It 'reports no remote before a repository exists' {
        aip remote show | Should -Be 'no remote is configured'
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'sets origin on an existing repository and publishes an empty remote' {
        New-TestProfile work
        aip remote add $script:TestRemote | Out-String | Should -Match 'Profiles published to origin/main.'
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $script:AipProfileRoot remote get-url origin) | Should -Be $script:TestRemote
        & git -C $script:TestRemote rev-parse --verify refs/heads/main *> $null
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'attaches to an already published remote and syncs' {
        New-TestProfile work
        aip remote add $script:TestRemote *> $null
        $global:LASTEXITCODE | Should -Be 0
        aip remote remove *> $null

        aip remote add $script:TestRemote | Out-String | Should -Match 'Profiles synced with origin/main.'
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $script:AipProfileRoot config --get branch.main.remote) | Should -Be 'origin'
    }

    It 'refuses a second origin and points at remote remove' {
        New-TestProfile work
        aip remote add $script:TestRemote *> $null
        $global:LASTEXITCODE | Should -Be 0

        aip remote add (Join-Path $TestDrive 'other.git') *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'origin is already configured'
        $script:AipLastError | Should -Match 'aip remote remove'
    }

    It 'never prints URL userinfo on an unreachable clone' {
        $script:AipProfileRoot = Join-Path $TestDrive 'fresh-secret'
        aip remote add 'https://user:s3cret@example.test/nope.git' *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'could not clone'
        $script:AipLastError | Should -Not -Match 's3cret'
        aip remote add 'https://s3cret@example.test/nope.git' *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'could not clone'
        $script:AipLastError | Should -Not -Match 's3cret'
    }

    It 'redacts userinfo when origin is already configured' {
        New-TestProfile work
        & git -C $script:AipProfileRoot remote add origin 'https://user:s3cret@example.test/repo.git'
        aip remote add 'https://example.test/other.git' *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'origin is already configured'
        $script:AipLastError | Should -Not -Match 's3cret'
    }

    It 'redacts userinfo on a successful fresh-machine clone' {
        New-TestProfile work
        aip remote add $script:TestRemote *> $null
        $fileUrl = if ($script:TestRemote -match '^[A-Za-z]:') { 'file:///' + $script:TestRemote.Replace('\', '/') } else { 'file://' + $script:TestRemote }
        & git config --global "url.$fileUrl.insteadOf" 'https://user:s3cret@example.test/repo.git'
        $freshRoot = Join-Path $TestDrive 'fresh-userinfo'
        $script:AipProfileRoot = $freshRoot
        $out = (aip remote add 'https://user:s3cret@example.test/repo.git' | Out-String)
        $global:LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Cloned profiles from https://example.test/repo.git.'
        $out | Should -Not -Match 's3cret'
    }

    It 'restores GIT_SSH_COMMAND after remote add' {
        $env:GIT_SSH_COMMAND = 'keep-me'
        try {
            New-TestProfile work
            aip remote add $script:TestRemote *> $null
            $env:GIT_SSH_COMMAND | Should -Be 'keep-me'
        }
        finally { Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue }
    }

    It 'clones the repository on a fresh machine and lists every profile' {
        New-TestProfile work
        New-TestProfile personal
        aip remote add $script:TestRemote *> $null
        $global:LASTEXITCODE | Should -Be 0

        $freshRoot = Join-Path $TestDrive 'fresh machine/profile root'
        $script:AipProfileRoot = $freshRoot

        aip remote add $script:TestRemote | Out-String | Should -Match "Cloned profiles from $([regex]::Escape($script:TestRemote))."
        $global:LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path $freshRoot '.git') | Should -BeTrue
        $listOutput = @(aip list)
        $listOutput | Should -Contain 'work'
        $listOutput | Should -Contain 'personal'
        aip which work | Should -Be (Join-Path $freshRoot 'work')
        (Get-Item (Join-Path $freshRoot 'work/codex/AGENTS.md')).LinkType | Should -Be 'SymbolicLink'
        (& git -C $freshRoot config --bool core.symlinks) | Should -Be 'true'
    }

    It 'refuses a non-empty directory that is not a repository' {
        $stuffed = Join-Path $TestDrive 'stuffed'
        New-Item -ItemType Directory -Path $stuffed | Out-Null
        'user data' | Set-Content (Join-Path $stuffed 'mine.txt')
        $script:AipProfileRoot = $stuffed

        aip remote add $script:TestRemote *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'already contains content'
        $script:AipLastError | Should -Match 'aip create NAME'
        (Get-Content (Join-Path $stuffed 'mine.txt') -Raw).Trim() | Should -Be 'user data'
    }

    It 'unsets origin and the branch upstream on remove' {
        New-TestProfile work
        aip remote add $script:TestRemote *> $null

        aip remote remove | Out-String | Should -Match 'Remote removed; profiles are now local only.'
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $script:AipProfileRoot remote) | Should -BeNullOrEmpty
        (& git -C $script:AipProfileRoot config --get branch.main.remote 2>$null) | Should -BeNullOrEmpty

        aip remote show | Should -Be 'no remote is configured'
        aip sync | Out-String | Should -Match 'Profiles are local only \(no upstream\)'
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'remove without a configured remote is a no-op message' {
        New-TestProfile work
        aip remote remove | Should -Be 'no remote is configured'
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'usage and unknown subcommands exit 2' {
        aip remote *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'usage: aip remote add URL \| aip remote show \| aip remote remove'

        aip remote add *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'usage: aip remote add URL'

        aip remote add one two *> $null
        $global:LASTEXITCODE | Should -Be 2

        aip remote show extra *> $null
        $global:LASTEXITCODE | Should -Be 2

        aip remote remove extra *> $null
        $global:LASTEXITCODE | Should -Be 2

        aip remote push *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match "unknown remote command 'push'"
    }
}

Describe 'sync output' {
    It 'harness sync skips fetch and push when HEAD matches ls-remote' {
        New-TestProfile work
        Initialize-TestUpstream
        $script:AipGitLog = [System.Collections.Generic.List[string]]::new()
        $original = ${function:Invoke-AipGit}
        ${function:Invoke-AipGit} = {
            $script:AipGitLog.Add(($args -join ' '))
            & $original @args
        }
        try {
            $out = Invoke-AipSync 'before' | Out-String
            $global:LASTEXITCODE | Should -Be 0
            $out | Should -Match 'Profiles up to date with'
            $joined = $script:AipGitLog -join "`n"
            $joined | Should -Match 'ls-remote'
            $joined | Should -Not -Match '(?i)\bfetch\b'
            $joined | Should -Not -Match '(?i)\bpush\b'
        }
        finally { ${function:Invoke-AipGit} = $original }
    }

    It 'a sync emits its result line and no spinner machinery exists' {
        New-TestProfile work
        Initialize-TestUpstream
        aip sync | Out-String | Should -Match 'Profiles synced with origin/main.'
        $global:LASTEXITCODE | Should -Be 0
        Get-Command Start-AipSpinner -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command Stop-AipSpinner -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Variable -Scope Script -Name AipSpinnerRunspace -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Variable -Scope Script -Name AipSpinnerPowerShell -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'installer' {
    BeforeEach {
        # Hermetic profile root + git identity for the profile/skill setup.
        $env:_AIP_PROFILE_ROOT = Join-Path $TestDrive 'agent-profiles'
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        & git config --global user.name 'Aip Tests'
        & git config --global user.email 'aip@example.test'
    }

    AfterEach {
        $env:_AIP_PROFILE_ROOT = $null
        $env:GIT_CONFIG_GLOBAL = $null
        $env:GIT_CONFIG_NOSYSTEM = $null
    }

    It 'installs per-user without duplicating or replacing unrelated profile content' {
        $installRoot = Join-Path $TestDrive 'installed aip'
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        'Set-Variable KeepThis yes' | Set-Content -LiteralPath $profilePath
        $env:_AIP_INSTALL_ROOT = $installRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            $LASTEXITCODE | Should -Be 0
            $withWindowsLineEndings = (Get-Content -LiteralPath $profilePath -Raw) -replace '(?<!\r)\n', "`r`n"
            [IO.File]::WriteAllText($profilePath, $withWindowsLineEndings)
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            $LASTEXITCODE | Should -Be 0
            Test-Path (Join-Path $installRoot 'aip.ps1') | Should -BeTrue
            $content = Get-Content -LiteralPath $profilePath -Raw
            $content | Should -Match 'Set-Variable KeepThis yes'
            @($content -split '\r?\n' | Where-Object { $_ -eq '# >>> aip >>>' }).Count | Should -Be 1
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 'stamps VERSION and reports install, update, and no-op' {
    $installRoot = Join-Path $TestDrive 'installed aip'
    $profilePath = Join-Path $TestDrive 'profile.ps1'
    'keep' | Set-Content -LiteralPath $profilePath
    $env:_AIP_INSTALL_ROOT = $installRoot
    $env:_AIP_SHELL_PROFILE = $profilePath
    $aipSource = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'aip.ps1') -Raw
    $current = [regex]::Match($aipSource, "\`$script:AipVersion = '([^']+)'").Groups[1].Value
    $parts = $current.Split('.')
    $newer = '{0}.{1}.{2}' -f $parts[0], $parts[1], ([int]$parts[2] + 1)
    try {
        $output = (& (Join-Path $script:RepositoryRoot 'install.ps1') 2>&1) | Out-String
        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $installRoot 'VERSION') -Raw).Trim() | Should -Be $current
        $output | Should -Match ([regex]::Escape("Installed aip $current."))

        $output = (& (Join-Path $script:RepositoryRoot 'install.ps1') 2>&1) | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match ([regex]::Escape("aip $current is already installed"))

        $pkgCopy = Join-Path $TestDrive 'pkg'
        New-Item -ItemType Directory -Path $pkgCopy | Out-Null
        $aipCopy = Join-Path $pkgCopy 'aip.ps1'
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'aip.ps1') -Destination $aipCopy
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'install.ps1') -Destination (Join-Path $pkgCopy 'install.ps1')
        $pattern = [regex]::Escape("`$script:AipVersion = '$current'")
        $replacement = "`$script:AipVersion = '$newer'"
        $content = (Get-Content -LiteralPath $aipCopy -Raw) -replace $pattern, $replacement
        Set-Content -LiteralPath $aipCopy -Value $content -Encoding utf8NoBOM

        $output = (& (Join-Path $pkgCopy 'install.ps1') 2>&1) | Out-String
        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $installRoot 'VERSION') -Raw).Trim() | Should -Be $newer
        $output | Should -Match ([regex]::Escape("Updated aip from $current to $newer."))
    }
    finally {
        $env:_AIP_INSTALL_ROOT = $null
        $env:_AIP_SHELL_PROFILE = $null
    }
}

It 'returns a nonzero process status when installation fails' {
        $blockedRoot = Join-Path $TestDrive 'blocked root'
        'not a directory' | Set-Content $blockedRoot
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        $env:_AIP_INSTALL_ROOT = $blockedRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            $pwsh = (Get-Process -Id $PID).Path
            & $pwsh -NoProfile -File (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            $LASTEXITCODE | Should -Not -Be 0
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 'fresh install creates the aip profile with the managed skill, untracked' {
        $installRoot = Join-Path $TestDrive 'installed aip'
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        Set-Content -LiteralPath $profilePath -Value 'keep'
        $env:_AIP_INSTALL_ROOT = $installRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            $output = (& (Join-Path $script:RepositoryRoot 'install.ps1') 2>&1) | Out-String
            $LASTEXITCODE | Should -Be 0
            $root = $env:_AIP_PROFILE_ROOT
            foreach ($name in 'SKILL.md', 'README.md', 'setup.md', 'audit.md', 'conflicts.md', '.aip-managed') {
                Test-Path -LiteralPath (Join-Path $root "aip/skills/aip/$name") | Should -BeTrue
            }
            & git -C $root rev-parse --verify HEAD 2>$null | Out-Null
            $global:LASTEXITCODE | Should -Be 0
            @(& git -C $root ls-files -- 'aip/skills/aip/SKILL.md' 'aip/skills/aip/.aip-managed').Count | Should -Be 0
            @(& git -C $root remote).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $root '.default') | Should -BeFalse
            $output | Should -Match 'aip manage pi'
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 're-running the installer with nothing changed leaves the tree byte-identical' {
        $installRoot = Join-Path $TestDrive 'installed aip'
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        Set-Content -LiteralPath $profilePath -Value 'keep'
        $env:_AIP_INSTALL_ROOT = $installRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            $root = $env:_AIP_PROFILE_ROOT
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            $LASTEXITCODE | Should -Be 0
            $skillDir = Join-Path $root 'aip/skills/aip'
            $before = @(Get-ChildItem -LiteralPath $skillDir -Recurse -File | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm MD5).Hash })
            $commits = @(& git -C $root rev-list --count HEAD)[0]
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            $LASTEXITCODE | Should -Be 0
            $after = @(Get-ChildItem -LiteralPath $skillDir -Recurse -File | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm MD5).Hash })
            $after | Should -Be $before
            @(& git -C $root rev-list --count HEAD)[0] | Should -Be $commits
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 'a user-edited managed skill is refreshed on the next install' {
        $installRoot = Join-Path $TestDrive 'installed aip'
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        Set-Content -LiteralPath $profilePath -Value 'keep'
        $env:_AIP_INSTALL_ROOT = $installRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            $skillFile = Join-Path $env:_AIP_PROFILE_ROOT 'aip/skills/aip/SKILL.md'
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            Add-Content -LiteralPath $skillFile -Value 'user edit'
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            $LASTEXITCODE | Should -Be 0
            (Get-Content -LiteralPath $skillFile -Raw) | Should -Not -Match 'user edit'
            Test-Path -LiteralPath (Join-Path (Split-Path $skillFile) '.aip-managed') | Should -BeTrue
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 'a marker-less skill directory is left untouched with a note' {
        $installRoot = Join-Path $TestDrive 'installed aip'
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        Set-Content -LiteralPath $profilePath -Value 'keep'
        $env:_AIP_INSTALL_ROOT = $installRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            $skillFile = Join-Path $env:_AIP_PROFILE_ROOT 'aip/skills/aip/SKILL.md'
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            Remove-Item -LiteralPath (Join-Path (Split-Path $skillFile) '.aip-managed') -Force
            Add-Content -LiteralPath $skillFile -Value 'user edit'
            $output = (& (Join-Path $script:RepositoryRoot 'install.ps1') 2>&1) | Out-String
            $LASTEXITCODE | Should -Be 0
            (Get-Content -LiteralPath $skillFile -Raw) | Should -Match 'user edit'
            $output | Should -Match '\.aip-managed marker'
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 'install without a git identity warns and skips profile setup' {
        $installRoot = Join-Path $TestDrive 'installed aip'
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        Set-Content -LiteralPath $profilePath -Value 'keep'
        $env:_AIP_INSTALL_ROOT = $installRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'empty-gitconfig'
            $output = (& (Join-Path $script:RepositoryRoot 'install.ps1') 2>&1) | Out-String
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath (Join-Path $installRoot 'aip.ps1') | Should -BeTrue
            Test-Path -LiteralPath $env:_AIP_PROFILE_ROOT | Should -BeFalse
            $output | Should -Match 'user\.name'
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 'the packaged skill has the aip frontmatter and package membership' {
        # Line-wise so a Windows CRLF checkout still matches; (?m)$ does not.
        (Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/aip/SKILL.md')) | Should -Contain 'name: aip'
        (Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'package.json') -Raw) | Should -Match '"skills/aip"'
    }

    It 'uninstall removes the install root and the shell profile block' {
        $installRoot = Join-Path $TestDrive 'installed aip'
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        'Set-Variable KeepThis yes' | Set-Content -LiteralPath $profilePath
        $env:_AIP_INSTALL_ROOT = $installRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath (Join-Path $installRoot 'aip.ps1') | Should -BeTrue
            (Get-Content -LiteralPath $profilePath -Raw) | Should -Match '# >>> aip >>>'

            aip uninstall --force
            $global:LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $installRoot | Should -BeFalse
            (Get-Content -LiteralPath $profilePath -Raw).Trim() | Should -Be 'Set-Variable KeepThis yes'
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 'uninstall is a no-op with a note when nothing is installed' {
        $env:_AIP_INSTALL_ROOT = Join-Path $TestDrive 'never installed'
        $profilePath = Join-Path $TestDrive 'plain.ps1'
        'keep' | Set-Content -LiteralPath $profilePath
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            $output = (aip uninstall --force) | Out-String
            $global:LASTEXITCODE | Should -Be 0
            $output | Should -Match 'Nothing to uninstall'
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }

    It 'uninstall without --force does not remove anything non-interactively' {
        $installRoot = Join-Path $TestDrive 'installed aip'
        $profilePath = Join-Path $TestDrive 'profile.ps1'
        'Set-Variable KeepThis yes' | Set-Content -LiteralPath $profilePath
        $env:_AIP_INSTALL_ROOT = $installRoot
        $env:_AIP_SHELL_PROFILE = $profilePath
        try {
            & (Join-Path $script:RepositoryRoot 'install.ps1') *> $null
            $LASTEXITCODE | Should -Be 0

            aip uninstall *> $null
            $global:LASTEXITCODE | Should -Not -Be 0
            Test-Path -LiteralPath $installRoot | Should -BeTrue
            (Get-Content -LiteralPath $profilePath -Raw) | Should -Match '# >>> aip >>>'
        }
        finally {
            $env:_AIP_INSTALL_ROOT = $null
            $env:_AIP_SHELL_PROFILE = $null
        }
    }
}
}

Describe 'import' {
    BeforeAll {
        function Invoke-AipImportInChild {
            # Run aip import in a fresh pwsh with the test HOME, feeding $Input to stdin
            # (the only way to drive the [Console]::In overwrite prompt deterministically).
            param([string]$AnswerText, [string[]]$ImportArgs)
            $pwsh = (Get-Process -Id $PID).Path
            $savedHome = $env:HOME
            $savedUserProfile = $env:USERPROFILE
            # pwsh derives $HOME from USERPROFILE on Windows and from HOME elsewhere;
            # set both so the child resolves the same profile root on either OS.
            $env:HOME = $script:ImportRoot
            $env:USERPROFILE = $script:ImportRoot
            try {
                $escapedArgs = ($ImportArgs | ForEach-Object { "'$_'" }) -join ' '
                $command = ". '$($script:RepositoryRoot)/aip.ps1'; aip import $escapedArgs; exit `$global:LASTEXITCODE"
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $pwsh
                $psi.Arguments = "-NoProfile -Command `"$($command.Replace('"', '\"'))`""
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $process = [System.Diagnostics.Process]::Start($psi)
                $process.StandardInput.Write($AnswerText)
                $process.StandardInput.Close()
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                return @{ Exit = $process.ExitCode; Output = ($stdout + $stderr) }
            }
            finally {
                $env:HOME = $savedHome
                $env:USERPROFILE = $savedUserProfile
            }
        }
    }

    BeforeEach {
        # Fresh, unique root per test: Pester 5.9 reuses one TestDrive path for the
        # whole run and the other Describes share script-scope state, so a fixed
        # TestDrive-relative root would leak profiles between tests.
        $script:ImportRoot = Join-Path $TestDrive ('import-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ImportRoot -Force | Out-Null
        $script:AipImportHome = $script:ImportRoot
        $script:AipProfileRoot = Join-Path $script:ImportRoot 'agent-profiles'
        $script:FakeBin = Join-Path $script:ImportRoot 'fake bin'
        $script:FakeCapture = Join-Path $script:ImportRoot 'capture'
        $env:FAKE_CAPTURE = $script:FakeCapture
        $env:FAKE_EXIT_STATUS = '0'
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:ImportRoot 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        New-Item -ItemType Directory -Path $script:FakeBin -Force | Out-Null
        & git config --global user.name 'Aip Tests'
        & git config --global user.email 'aip@example.test'
        & git config --global maintenance.auto false
        & git config --global gc.auto 0
        New-TestProfile work
        New-TestProfile suit
        $script:Pidir = Join-Path $script:ImportRoot '.pi/agent'
        New-Item -ItemType Directory -Path (Join-Path $script:Pidir 'skills/reviewer') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'auth.json') -Value '{"token":"secret"}' -Encoding utf8NoBOM -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Pidir 'models.json') -Value '{"models":[]}' -Encoding utf8NoBOM -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Pidir 'skills/reviewer/SKILL.md') -Value '# Reviewer' -Encoding utf8NoBOM -NoNewline
    }

    AfterEach {
        $env:FAKE_CAPTURE = $null
        $env:FAKE_EXIT_STATUS = $null
        $env:GIT_CONFIG_GLOBAL = $null
        $env:GIT_CONFIG_NOSYSTEM = $null
    }

    It 'copies the given files into every profile without committing' {
        aip import pi auth.json models.json --all-profiles --force
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') -Raw) | Should -Be '{"token":"secret"}'
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'suit/pi/models.json') -Raw) | Should -Be '{"models":[]}'
        (& git -C $script:AipProfileRoot ls-files -- work/pi/auth.json suit/pi/models.json) | Should -BeNullOrEmpty
    }

    It 'copies files into subdirectories through the harness link' {
        aip import pi skills/reviewer/SKILL.md --all-profiles --force
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/reviewer/SKILL.md') -Raw) | Should -Be '# Reviewer'
    }

    It '--profile targets exactly those profiles' {
        aip import pi auth.json --profile work --force
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'suit/pi/auth.json') | Should -BeFalse

        aip import pi auth.json --profile work,suit --force
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'suit/pi/auth.json') | Should -BeTrue
    }

    It 'requires profile selection outside a terminal' {
        aip import pi auth.json *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'no profiles selected'
    }

    It 'without files and without a terminal is a usage error' {
        aip import pi *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'no files given'
    }

    It 'rejects unknown profiles, harnesses, and conflicting flags' {
        aip import pi auth.json --profile nope *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match "profile 'nope' does not exist"

        aip import foo auth.json --all-profiles *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match "unknown harness 'foo'"

        aip import pi auth.json --all-profiles --force --skip-existing *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match '--force and --skip-existing conflict'

        aip import pi auth.json --profile work --all-profiles *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match '--profile and --all-profiles conflict'
    }

    It 'errors when the harness configuration root is missing' {
        Remove-Item -LiteralPath (Join-Path $script:ImportRoot '.pi') -Recurse -Force
        aip import pi auth.json --all-profiles *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'no pi configuration found'
    }

    It 'rejects a path that escapes the source root' {
        aip import pi ../secret.json --all-profiles *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'invalid file path: ../secret.json'
    }

    It 'overwrite prompt: o overwrites, s skips, a and n persist' {
        aip import pi auth.json models.json --all-profiles --force *> $null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'auth.json') -Value 'modified-a' -Encoding utf8NoBOM -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Pidir 'models.json') -Value 'modified-m' -Encoding utf8NoBOM -NoNewline

        $result = Invoke-AipImportInChild -AnswerText "o`ns" -ImportArgs @('pi', 'auth.json', 'models.json', '--profile', 'work')
        $result.Exit | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') -Raw) | Should -Be 'modified-a'
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Raw) | Should -Be '{"models":[]}'

        Set-Content -LiteralPath (Join-Path $script:Pidir 'models.json') -Value 'new-m' -Encoding utf8NoBOM -NoNewline
        $result = Invoke-AipImportInChild -AnswerText 'a' -ImportArgs @('pi', 'auth.json', 'models.json', '--profile', 'work')
        $result.Exit | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Raw) | Should -Be 'new-m'

        Set-Content -LiteralPath (Join-Path $script:Pidir 'auth.json') -Value 'new-a' -Encoding utf8NoBOM -NoNewline
        $result = Invoke-AipImportInChild -AnswerText 'n' -ImportArgs @('pi', 'auth.json', 'models.json', '--profile', 'work')
        $result.Exit | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') -Raw) | Should -Be 'modified-a'
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Raw) | Should -Be 'new-m'
    }

    It 'overwrite prompt: q aborts the import' {
        aip import pi auth.json models.json --all-profiles --force *> $null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'auth.json') -Value 'new' -Encoding utf8NoBOM -NoNewline
        $result = Invoke-AipImportInChild -AnswerText 'q' -ImportArgs @('pi', 'auth.json', '--profile', 'work')
        $result.Exit | Should -Be 1
        $result.Output | Should -Match 'import cancelled'
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') -Raw) | Should -Be '{"token":"secret"}'
    }

    It '--force and --skip-existing set the overwrite decision' {
        aip import pi auth.json --all-profiles --force *> $null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'auth.json') -Value 'new' -Encoding utf8NoBOM -NoNewline

        aip import pi auth.json --all-profiles --skip-existing *> $null
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') -Raw) | Should -Be '{"token":"secret"}'

        aip import pi auth.json --all-profiles --force *> $null
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') -Raw) | Should -Be 'new'
    }

    It '--dry-run reports without writing' {
        $output = aip import pi auth.json models.json --all-profiles --dry-run | Out-String
        $global:LASTEXITCODE | Should -Be 0
        # Get-AipProfileNames sorts; suit precedes work.
        $output | Should -Match 'copy auth.json -> suit/auth.json'
        $output | Should -Match 'copy models.json -> work/models.json'
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'suit/pi/models.json') | Should -BeFalse
    }

    It 'refuses to overwrite the scaffold profile links' {
        Set-Content -LiteralPath (Join-Path $script:Pidir 'AGENTS.md') -Value '# Pi' -Encoding utf8NoBOM -NoNewline
        aip import pi AGENTS.md --all-profiles --force *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'refusing to overwrite the profile link work/AGENTS.md'
        ((Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/AGENTS.md')).Target -replace '\\', '/') | Should -Be '../AGENTS.md'
    }

    It 'replaces a non-managed symlink destination instead of writing through' {
        $target = Join-Path $TestDrive 'target.txt'
        Set-Content -LiteralPath $target -Value 'elsewhere' -Encoding utf8NoBOM -NoNewline
        $link = New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Target $target
        $link | Should -Not -BeNullOrEmpty
        $link.LinkType | Should -Be 'SymbolicLink'
        aip import pi models.json --profile work --force *> $null
        $global:LASTEXITCODE | Should -Be 0
        (Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json')).LinkType | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Raw) | Should -Be '{"models":[]}'
        (Get-Content -LiteralPath $target -Raw) | Should -Be 'elsewhere'
    }

    It 'warns when a destination is not covered by the profile gitignore' {
        aip import pi models.json --all-profiles --force *> $null
        $global:LASTEXITCODE | Should -Be 0
        $script:AipLastError | Should -Match 'may track'

        aip import pi auth.json --all-profiles --force *> $null
        $script:AipLastError | Should -Not -Match 'may track'
    }

    It 'sources the static default root even when the harness env var is redirected' {
        $decoy = Join-Path $TestDrive 'decoy'
        New-Item -ItemType Directory -Path $decoy -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $decoy 'auth.json') -Value '{"decoy":true}' -Encoding utf8NoBOM
        $env:PI_CODING_AGENT_DIR = $decoy
        try {
            aip import pi auth.json --all-profiles --force
            $global:LASTEXITCODE | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') -Raw) | Should -Be '{"token":"secret"}'
        }
        finally { $env:PI_CODING_AGENT_DIR = $null }
    }

    It 'rejects backslash and mixed-separator traversal' {
        $outside = Join-Path $script:AipProfileRoot 'outside.txt'
        Set-Content -LiteralPath $outside -Value 'keep' -Encoding utf8NoBOM -NoNewline
        aip import pi '..\..\outside.txt' --profile work --force *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'invalid file path'
        (Get-Content -LiteralPath $outside -Raw) | Should -Be 'keep'
        aip import pi 'foo\..\bar' --profile work --force *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'invalid file path'
        aip import pi 'foo/..\bar' --profile work --force *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'invalid file path'
    }

    It '--all-profiles skips the aip management profile' {
        New-TestProfile aip
        aip import pi auth.json --all-profiles --force *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/auth.json') | Should -BeTrue
        (Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'aip/pi/auth.json') -Force).LinkType | Should -Be 'SymbolicLink'
    }

    It '--all-profiles with only aip is a distinct error' {
        Remove-Item -LiteralPath $script:AipProfileRoot -Recurse -Force
        $null = New-Item -ItemType Directory -Path $script:AipProfileRoot -Force
        New-TestProfile aip
        aip import pi auth.json --all-profiles --force *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'skips the aip management profile'
        $script:AipLastError | Should -Not -Match 'no profiles found'
    }

    It 'exposes no picker machinery and requires files' {
        Get-Command Invoke-AipImportInteractive -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        aip import pi *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'no files given'
    }

    It 'appears in help' {
        $help = aip help | Out-String
        $help | Should -Match 'aip import HARNESS'
        $help | Should -Match 'aip skills add\|update\|remove'
    }
}

Describe 'add' {
    BeforeAll {
        function Get-AddFileUrl {
            # file:// URL for a local path, on either OS.
            param([Parameter(Mandatory)][string]$Path)
            $p = $Path.Replace('\', '/')
            if ($p -match '^[A-Za-z]:/') { return "file:///$p" }
            return "file://$p"
        }

        function New-AddSourceRepo {
            # The skill-source repository, cloned via file:// (the local-skill test vector).
            $script:AddSrc = Join-Path $script:AddRoot 'source'
            & git init -q $script:AddSrc
            & git -C $script:AddSrc config core.symlinks true
            $null = New-Item -ItemType Directory -Path (Join-Path $script:AddSrc 'alpha'), (Join-Path $script:AddSrc 'pack/beta'), (Join-Path $script:AddSrc 'gamma'), (Join-Path $script:AddSrc 'dup/alpha'), (Join-Path $script:AddSrc 'Bad-Name') -Force
            Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha`n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/helper.sh') -Value 'helper' -Encoding utf8NoBOM
            if (-not $IsWindows) { & chmod 755 (Join-Path $script:AddSrc 'alpha/helper.sh') }
            Set-Content -LiteralPath (Join-Path $script:AddSrc 'pack/beta/SKILL.md') -Value "---`nname: beta`n---`n# Beta`n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $script:AddSrc 'gamma/README.md') -Value 'not a skill' -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $script:AddSrc 'dup/alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha copy`n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $script:AddSrc 'Bad-Name/SKILL.md') -Value "---`nname: bad`n---`n# Bad`n" -Encoding utf8NoBOM
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:AddSrc 'linkdir') -Target 'alpha'
            $null = New-Item -ItemType Directory -Path (Join-Path $script:AddSrc 'nestedlink') -Force
            Set-Content -LiteralPath (Join-Path $script:AddSrc 'nestedlink/SKILL.md') -Value "---`nname: nestedlink`n---`n# Nested`n" -Encoding utf8NoBOM
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:AddSrc 'nestedlink/inside.md') -Target 'SKILL.md'
            & git -C $script:AddSrc add -A
            & git -C $script:AddSrc commit -q -m 'source'
            # A repository whose root is itself a skill (repo-root source form).
            $script:AddSrcRoot = Join-Path $script:AddRoot 'rootskill'
            & git init -q $script:AddSrcRoot
            Set-Content -LiteralPath (Join-Path $script:AddSrcRoot 'SKILL.md') -Value "---`nname: rootskill`n---`n# Root skill`n" -Encoding utf8NoBOM
            & git -C $script:AddSrcRoot add -A
            & git -C $script:AddSrcRoot commit -q -m 'root skill'
        }
    }

    BeforeEach {
        # Fresh, unique root per test (Pester 5.9 reuses one TestDrive path per run
        # and the other Describes share script-scope state).
        $script:AddRoot = Join-Path $TestDrive ('add-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AddRoot -Force | Out-Null
        $script:AipProfileRoot = Join-Path $script:AddRoot 'profile root'
        $script:FakeBin = Join-Path $script:AddRoot 'fake bin'
        $script:FakeCapture = Join-Path $script:AddRoot 'capture'
        $env:FAKE_CAPTURE = $script:FakeCapture
        $env:FAKE_EXIT_STATUS = '0'
        $env:AIP_PROFILE = $null
        $env:CLAUDE_CONFIG_DIR = $null
        $env:CODEX_HOME = $null
        $env:PI_CODING_AGENT_DIR = $null
        $env:OPENCODE_CONFIG_DIR = $null
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:AddRoot 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        & git config --global user.name 'Aip Tests'
        & git config --global user.email 'aip@example.test'
        New-TestProfile work
        New-AddSourceRepo
    }

    AfterEach {
        $env:AIP_PROFILE = $null
        $env:FAKE_CAPTURE = $null
        $env:FAKE_EXIT_STATUS = $null
        $env:GIT_CONFIG_GLOBAL = $null
        $env:GIT_CONFIG_NOSYSTEM = $null
    }

    It 'installs a skill from a file:// source with a #path into the profile' {
        $out = (aip skills add work "$(Get-AddFileUrl $script:AddSrc)#pack/beta" 2>&1) -join "`n"
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/beta/SKILL.md') -Raw).Trim() | Should -Be "---`nname: beta`n---`n# Beta"
        $out | Should -Match 'added beta to work'
    }

    It 'installs every file in the skill directory, preserving modes' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/helper.sh') | Should -BeTrue
        if (-not $IsWindows) {
            $helper = Join-Path $script:AipProfileRoot 'work/skills/alpha/helper.sh'
            $mode = & stat -c '%a' $helper 2>$null
            if ($LASTEXITCODE -ne 0) { $mode = & stat -f '%Lp' $helper }
            $mode | Should -Be '755'
        }
    }

    It 'names the skill after the repository for a repo-root source' {
        $out = (aip skills add work (Get-AddFileUrl $script:AddSrcRoot) 2>&1) -join "`n"
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/rootskill/SKILL.md') | Should -BeTrue
        $out | Should -Match 'added rootskill to work'
    }

    It 'lands the skill untracked with the harness symlinks intact' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 0
        $tracked = & git -C $script:AipProfileRoot ls-files -- 'work/skills/alpha/'
        @($tracked).Count | Should -Be 0
        $link = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/skills') -Force
        $null -ne $link.LinkType | Should -BeTrue
    }

    It 'creates no commit: the profiles history is unchanged' {
        $before = (& git -C $script:AipProfileRoot rev-list --count HEAD)[0]
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 0
        $after = (& git -C $script:AipProfileRoot rev-list --count HEAD)[0]
        $after | Should -Be $before
    }

    It 'a following aip sync checkpoints and pushes the added skill' {
        Initialize-TestUpstream
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 0
        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        & git -C $script:TestRemote cat-file -e 'main:work/skills/alpha/SKILL.md'
        $global:LASTEXITCODE | Should -Be 0
    }

    It '--all-profiles installs into every profile' {
        New-TestProfile suit
        $out = (aip skills add --all-profiles "$(Get-AddFileUrl $script:AddSrc)#alpha" 2>&1) -join "`n"
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'suit/skills/alpha/SKILL.md') | Should -BeTrue
        $out | Should -Match 'added alpha to suit'
        $out | Should -Match 'added alpha to work'
    }

    It '--all-profiles with no profiles is an error' {
        Remove-Item -LiteralPath $script:AipProfileRoot -Recurse -Force
        $null = New-Item -ItemType Directory -Path $script:AipProfileRoot -Force
        aip skills add --all-profiles "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'no profiles found'
    }

    It 'with a missing profile is an import-style error' {
        aip skills add missing "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match "profile 'missing' does not exist"
    }

    It 'without a profile or without a source is a usage error' {
        aip skills add *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'no profile selected'
        aip skills add work *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'no source given'
    }

    It 'with conflicting flags is a usage error' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" --force --skip-existing *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match '--force and --skip-existing conflict'
    }

    It 'rejects unknown options' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" --bogus *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match "unknown add option '--bogus'"
    }

    It 'rejects plain local paths with a file:// hint' {
        aip skills add work $script:AddSrc *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'file://'
        aip skills add work '/abs/where' *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'file://'
    }

    It 'reports an unreachable source without cloning anything' {
        aip skills add work (Get-AddFileUrl (Join-Path $script:AddRoot 'no-such-repo')) *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'could not clone'
    }

    It 'converts GitHub shorthand to a github.com URL' {
        aip skills add work 'nope/nosuch-repo-xyz-123/some/skill' *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'github.com/nope/nosuch-repo-xyz-123'
        $script:AipLastError | Should -Match 'could not clone'
    }

    It 'rejects a source path that does not exist in the repository' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#nope" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'no such path in the source repository: nope'
    }

    It 'rejects a source path without a SKILL.md' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#gamma" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'no SKILL.md in the source path: gamma'
    }

    It 'rejects traversal segments in the source path' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#../secret" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'invalid source path: ../secret'
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha/../beta" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'invalid source path: alpha/../beta'
    }

    It 'rejects a source path that follows a symlinked directory' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#linkdir" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'source path follows a symlink: linkdir'
    }

    It 'rejects a skill directory name that is not a valid profile name' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#Bad-Name" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match "invalid skill name 'Bad-Name'"
    }

    It 'rejects two sources that resolve to the same skill name' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" "$(Get-AddFileUrl $script:AddSrc)#dup/alpha" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'duplicate skill name in this call: alpha'
    }

    It 'collides with an existing skill by default' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match "skill 'alpha' already exists in profile work"
        $script:AipLastError | Should -Match '--force'
    }

    It '--skip-existing skips an existing skill with a note' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $out = (aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" --skip-existing 2>&1) -join "`n"
        $global:LASTEXITCODE | Should -Be 0
        $out | Should -Match 'skipped alpha in work'
    }

    It '--force replaces an existing skill directory' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha v2`n" -Encoding utf8NoBOM
        & git -C $script:AddSrc commit -q -am 'v2'
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" --force *> $null
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw) | Should -Match 'Alpha v2'
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/helper.sh') | Should -BeTrue
    }

    It 'copies a repo-root skill without its .git and a following sync succeeds' {
        Initialize-TestUpstream
        aip skills add work (Get-AddFileUrl $script:AddSrcRoot) *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/rootskill/SKILL.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/rootskill/.git') | Should -BeFalse
        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        & git -C $script:TestRemote cat-file -e 'main:work/skills/rootskill/SKILL.md'
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'rejects a symlink inside the skill directory and leaves dest absent' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#nestedlink" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'nested symlink'
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/nestedlink') | Should -BeFalse
    }

    It 'never prints URL userinfo' {
        aip skills add work 'https://user:s3cret@example.test/nope.git' *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'could not clone'
        $script:AipLastError | Should -Not -Match 's3cret'
        aip skills add work 'https://s3cret@example.test/nope.git' *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'could not clone'
        $script:AipLastError | Should -Not -Match 's3cret'
        aip skills add work 'http://user:s3cret@example.test/nope.git' *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'unsupported source URL'
        $script:AipLastError | Should -Not -Match 's3cret'
    }

    It 'rejects mixed-separator traversal in the source path' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#..\outside" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'invalid source path'
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#foo/..\bar" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'invalid source path'
    }

    It '--all-profiles skips the aip management profile' {
        New-TestProfile aip
        aip skills add --all-profiles "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'aip/skills/alpha/SKILL.md') | Should -BeFalse
        @(aip list) | Should -Contain 'aip'
    }

    It 'explicit add aip still installs into the management profile' {
        New-TestProfile aip
        aip skills add aip "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'aip/skills/alpha/SKILL.md') | Should -BeTrue
    }

    It '--all-profiles with only aip is a distinct error' {
        Remove-Item -LiteralPath $script:AipProfileRoot -Recurse -Force
        $null = New-Item -ItemType Directory -Path $script:AipProfileRoot -Force
        New-TestProfile aip
        aip skills add --all-profiles "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'skips the aip management profile'
        $script:AipLastError | Should -Not -Match 'no profiles found'
    }

    It 'treats aip add as an unknown command' {
        aip add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match "unknown command 'add'"
    }

    It 'prints usage for aip skills and an unknown subcommand' {
        aip skills *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'usage: aip skills'
        $script:AipLastError | Should -Not -Match "unknown command 'skills'"
        aip skills bogus *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'usage: aip skills'
        $script:AipLastError | Should -Not -Match "unknown command 'skills'"
    }

    It 'writes a .aip-source sidecar and a following sync checkpoints it' {
        Initialize-TestUpstream
        $source = "$(Get-AddFileUrl $script:AddSrc)#alpha"
        aip skills add work $source *> $null
        $global:LASTEXITCODE | Should -Be 0
        $sidecar = Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source'
        $lines = Get-Content -LiteralPath $sidecar
        $lines | Should -Contain "source=$source"
        $lines | Should -Contain ("url=" + (Get-AddFileUrl $script:AddSrc))
        $lines | Should -Contain 'path=alpha'
        $lines.Count | Should -Be 3
        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        & git -C $script:TestRemote cat-file -e 'main:work/skills/alpha/.aip-source'
        $global:LASTEXITCODE | Should -Be 0
    }

    It '--skip-existing does not rewrite an existing sidecar' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $sidecar = Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source'
        Set-Content -LiteralPath $sidecar -Value "source=stale`nurl=stale`npath=stale`n" -Encoding utf8NoBOM
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" --skip-existing *> $null
        $global:LASTEXITCODE | Should -Be 0
        $lines = Get-Content -LiteralPath $sidecar
        $lines | Should -Contain 'source=stale'
        $lines | Should -Contain 'url=stale'
        $lines | Should -Contain 'path=stale'
    }

    It '--force rewrites the sidecar' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $sidecar = Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source'
        Set-Content -LiteralPath $sidecar -Value "source=stale`nurl=stale`npath=stale`n" -Encoding utf8NoBOM
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" --force *> $null
        $global:LASTEXITCODE | Should -Be 0
        $lines = Get-Content -LiteralPath $sidecar
        $lines | Should -Contain ("source=$(Get-AddFileUrl $script:AddSrc)#alpha")
        $lines | Should -Contain ("url=" + (Get-AddFileUrl $script:AddSrc))
        $lines | Should -Contain 'path=alpha'
    }
}

Describe 'pass-through' {
    BeforeAll {
        function Test-AipProfileLink {
            param([Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Relative)
            $item = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot (Join-Path $Profile $Relative)) -Force -ErrorAction SilentlyContinue
            return $null -ne $item -and $item.LinkType -eq 'SymbolicLink'
        }

        function Get-AipGitIgnoreText {
            param([Parameter(Mandatory)][string]$Profile)
            return Get-Content -LiteralPath (Join-Path $script:AipProfileRoot (Join-Path $Profile '.gitignore')) -Raw
        }
    }

    BeforeEach {
        # Fresh, unique root per test (Pester 5.9 reuses one TestDrive path for the
        # whole run), mirroring the import Describe. AipImportHome is isolated so the
        # tests never read the developer's real machine config.
        $script:PassRoot = Join-Path $TestDrive ('pass-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:PassRoot -Force | Out-Null
        $script:AipImportHome = Join-Path $script:PassRoot 'home'
        $script:AipProfileRoot = Join-Path $script:PassRoot 'agent-profiles'
        $script:FakeBin = Join-Path $script:PassRoot 'fake bin'
        $script:FakeCapture = Join-Path $script:PassRoot 'capture'
        $env:FAKE_CAPTURE = $script:FakeCapture
        $env:FAKE_EXIT_STATUS = '0'
        $env:AIP_PROFILE = $null
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:PassRoot 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        New-Item -ItemType Directory -Path $script:AipImportHome, $script:FakeBin -Force | Out-Null
        & git config --global user.name 'Aip Tests'
        & git config --global user.email 'aip@example.test'
        & git config --global maintenance.auto false
        & git config --global gc.auto 0
        foreach ($harness in 'claude', 'codex', 'pi', 'opencode') { New-FakeHarness $harness }
        $script:AipRealPath = $script:FakeBin
        # Fixtures are created BEFORE profile creation so that creation seeds the
        # links (the behaviour under test).
        $script:Pidir = Join-Path $script:AipImportHome '.pi/agent'
        New-Item -ItemType Directory -Path (Join-Path $script:Pidir 'themes') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'models.json') -Value '{"models":[]}' -Encoding utf8NoBOM -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Pidir 'auth.json') -Value '{"token":"secret"}' -Encoding utf8NoBOM -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Pidir 'themes/custom.json') -Value '{"name":"custom"}' -Encoding utf8NoBOM -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:Pidir 'npm/node_modules/fake-pkg') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'npm/node_modules/fake-pkg/package.json') -Value '{"name":"fake-pkg","version":"1.0.0"}' -Encoding utf8NoBOM -NoNewline
        New-TestProfile work
        New-TestProfile suit
        $env:AIP_PROFILE = 'work'
    }

    AfterEach {
        $env:AIP_PROFILE = $null
        $env:FAKE_CAPTURE = $null
        $env:FAKE_EXIT_STATUS = $null
        $env:GIT_CONFIG_GLOBAL = $null
        $env:GIT_CONFIG_NOSYSTEM = $null
    }

    function Test-AipProfileLink {
        param([Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Relative)
        $item = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot (Join-Path $Profile $Relative)) -Force -ErrorAction SilentlyContinue
        return $null -ne $item -and $item.LinkType -eq 'SymbolicLink'
    }

    function Get-AipGitIgnoreText {
        param([Parameter(Mandatory)][string]$Profile)
        return Get-Content -LiteralPath (Join-Path $script:AipProfileRoot (Join-Path $Profile '.gitignore')) -Raw
    }

    It 'create seeds pass-through links and commits the gitignore entries' {
        Test-AipProfileLink 'work' 'pi/models.json' | Should -BeTrue
        Test-AipProfileLink 'work' 'pi/auth.json' | Should -BeTrue
        Test-AipProfileLink 'work' 'pi/themes' | Should -BeTrue
        $resolved = (Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json')).ResolveLinkTarget($true).FullName
        $resolved | Should -Be (Join-Path $script:Pidir 'models.json')
        $gitIgnore = Get-AipGitIgnoreText 'work'
        $gitIgnore | Should -Match "(?m)^pi/models.json$"
        $gitIgnore | Should -Match "(?m)^pi/auth.json$"
        $gitIgnore | Should -Match "(?m)^pi/themes$"
        & git -C $script:AipProfileRoot check-ignore -- work/pi/models.json work/pi/auth.json work/pi/themes *> $null
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $script:AipProfileRoot ls-files -- work/pi/models.json work/pi/auth.json work/pi/themes) | Should -BeNullOrEmpty
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'create seeds nothing when the default root is absent' {
        $script:AipImportHome = Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AipImportHome -Force | Out-Null
        aip create bare *> $null
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'bare/pi/models.json') | Should -BeFalse
        (Get-AipGitIgnoreText 'bare') | Should -Not -Match 'aip pass-through'
    }

    It 'maintenance is idempotent: a second session changes nothing' {
        $before = (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/.gitignore') -Raw)
        & pi *> $null
        & pi *> $null
        $after = (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/.gitignore') -Raw)
        $after | Should -Be $before
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'a wrapper session maintains links for the resolved profile' {
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Force
        & pi *> $null
        Test-AipProfileLink 'work' 'pi/models.json' | Should -BeTrue
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'profile precedence: a real file shadows the link and clears its entry' {
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Force
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Value '{"own":true}' -Encoding utf8NoBOM -NoNewline
        & pi *> $null
        $item = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json')
        $item.LinkType | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Raw) | Should -Be '{"own":true}'
        (Get-AipGitIgnoreText 'work') | Should -Not -Match "(?m)^pi/models.json$"
    }

    It 'a broken pass-through link is removed with a warning and its entry cleared' {
        Remove-Item -LiteralPath (Join-Path $script:Pidir 'models.json') -Force
        & pi *> $null
        $script:AipLastWarning | Should -Match 'removed stale pass-through link work/pi/models.json'
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') | Should -BeFalse
        (Get-AipGitIgnoreText 'work') | Should -Not -Match "(?m)^pi/models.json$"
        (Get-AipGitIgnoreText 'work') | Should -Match "(?m)^pi/auth.json$"
    }

    It 'restoring the default file brings the link and entry back' {
        Remove-Item -LiteralPath (Join-Path $script:Pidir 'models.json') -Force
        & pi *> $null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'models.json') -Value '{"models":[]}' -Encoding utf8NoBOM -NoNewline
        & pi *> $null
        Test-AipProfileLink 'work' 'pi/models.json' | Should -BeTrue
        (Get-AipGitIgnoreText 'work') | Should -Match "(?m)^pi/models.json$"
    }

    It 'doctor tolerates a legacy primary-config link with a migration warning' {
        aip doctor work *> $null
        $script:AipCommandStatus | Should -Be 0
        $output = aip doctor work
        $output | Out-String | Should -Match 'OK: pass-through work/pi/models.json'
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot 'work/pi/settings.json') -Target (Join-Path $script:Pidir 'settings.json') | Out-Null
        aip doctor work *> $null
        $script:AipCommandStatus | Should -Be 0
        $script:AipLastWarning | Should -Match 'legacy primary-config link'
    }

    It 'the launch checkpoint tolerates a legacy primary-config link' {
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot 'work/pi/settings.json') -Target (Join-Path $script:Pidir 'settings.json') | Out-Null
        & pi *> $null
        $global:LASTEXITCODE | Should -Be 0
    }


    It 'security: an off-allowlist symlink still fails doctor' {
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot 'work/pi/evil.json') -Target (Join-Path $TestDrive 'outside') | Out-Null
        aip doctor work *> $null
        $script:AipCommandStatus | Should -Be 1
        $script:AipLastError | Should -Be $null
        (& { $output = aip doctor work 2>&1; $output | Out-String }) | Should -Match 'unsupported symbolic link'
    }

    It 'security: a crafted ../ escape under the default root is rejected' {
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Force
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Target (Join-Path $script:Pidir '../../models.json') | Out-Null
        Test-AipProfileReparsePoints (Join-Path $script:AipProfileRoot 'work') | Should -BeFalse
        $script:AipProfileBoundaryError | Should -Match 'unsupported symbolic link'
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Force
    }

    It 'security: an absolute pass-through target under the default root is accepted' {
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Force
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Target (Join-Path $script:Pidir 'models.json') | Out-Null
        Test-AipProfileReparsePoints (Join-Path $script:AipProfileRoot 'work') | Should -BeTrue
    }

    It 'clone seeds pass-through links into the new profile' {
        aip clone work suit2 *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-AipProfileLink 'suit2' 'pi/models.json' | Should -BeTrue
        (Get-AipGitIgnoreText 'suit2') | Should -Match "(?m)^pi/models.json$"
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'import --force over a pass-through link replaces it and clears the entry' {
        aip import pi models.json --profile work --force *> $null
        $global:LASTEXITCODE | Should -Be 0
        $item = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json')
        $item.LinkType | Should -BeNullOrEmpty
        (Get-AipGitIgnoreText 'work') | Should -Not -Match "(?m)^pi/models.json$"
        & git -C $script:AipProfileRoot add work/pi/models.json
        $global:LASTEXITCODE | Should -Be 0
        Test-AipProfileLink 'work' 'pi/auth.json' | Should -BeTrue
        (Get-AipGitIgnoreText 'work') | Should -Match "(?m)^pi/auth.json$"
    }

    It 'convergence: maintenance with no default root leaves the block untouched' {
        $block = Get-AipGitIgnoreText 'work'
        $script:AipImportHome = Join-Path $TestDrive ('other-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AipImportHome -Force | Out-Null
        Invoke-AipPassthroughProfile 'work'
        (Get-AipGitIgnoreText 'work') | Should -Be $block
    }

    It 'import refuses children of a pass-through directory' {
        $plugins = Join-Path $script:AipImportHome '.claude/plugins'
        New-Item -ItemType Directory -Path $plugins -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $plugins 'hook.json') -Value '{"hook":true}' -Encoding utf8NoBOM -NoNewline
        New-TestProfile claudy
        $link = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'claudy/claude/plugins') -Force
        $link.LinkType | Should -Be 'SymbolicLink'
        aip import claude plugins/hook.json --profile claudy --force *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Match 'pass-through directory'
        (Get-Content -LiteralPath (Join-Path $plugins 'hook.json') -Raw) | Should -Be '{"hook":true}'
        (Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'claudy/claude/plugins') -Force).LinkType | Should -Be 'SymbolicLink'
    }

    It 'convergence: non-primary Claude entries survive Pi maintenance' {
        $cldir = Join-Path $script:AipImportHome '.claude'
        New-Item -ItemType Directory -Path $cldir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cldir 'settings.local.json') -Value '{"permissions":{}}' -Encoding utf8NoBOM -NoNewline
        Invoke-AipPassthrough 'claude' 'work'
        (Get-AipGitIgnoreText 'work') | Should -Match "(?m)^claude/settings.local.json$"
        Invoke-AipPassthrough 'pi' 'work'
        (Get-AipGitIgnoreText 'work') | Should -Match "(?m)^claude/settings.local.json$"
        (Get-AipGitIgnoreText 'work') | Should -Match "(?m)^pi/models.json$"
    }

    It 'create seeds the npm pass-through link and never tracks its contents' {
        Test-AipProfileLink 'work' 'pi/npm' | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/npm/node_modules/fake-pkg/package.json') | Should -BeTrue
        (Get-AipGitIgnoreText 'work') | Should -Match "(?m)^pi/npm$"
        & git -C $script:AipProfileRoot check-ignore -- work/pi/npm *> $null
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $script:AipProfileRoot ls-files -- 'work/pi/npm' 'work/pi/npm/*') | Should -BeNullOrEmpty
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'npm pass-through is absent when the machine has no pi npm root' {
        Remove-Item -LiteralPath (Join-Path $script:Pidir 'npm') -Recurse -Force
        aip create nonpm *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'nonpm/pi/npm') | Should -BeFalse
        (Get-AipGitIgnoreText 'nonpm') | Should -Not -Match "(?m)^pi/npm$"
    }

    It 'launch checkpoint passes with the npm link present' {
        & pi *> $null
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'a trivial real file shadowing the link is replaced by the link' {
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Force
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Value '{}' -Encoding utf8NoBOM -NoNewline
        & pi *> $null
        Test-AipProfileLink 'work' 'pi/models.json' | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:Pidir 'models.json') -Raw) | Should -Be '{"models":[]}'
        (Get-AipGitIgnoreText 'work') | Should -Match "(?m)^pi/models.json$"
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'a non-trivial real file is never replaced' {
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Force
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Value '{"own":1} junk' -Encoding utf8NoBOM -NoNewline
        & pi *> $null
        $item = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json')
        $item.LinkType | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models.json') -Raw) | Should -Be '{"own":1} junk'
    }

    It 'a tracked trivial file is exempt from replacement' {
        $script:AipImportHome = Join-Path $TestDrive ('no-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AipImportHome -Force | Out-Null
        aip create own *> $null
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'own/pi/models.json') -Value '{}' -Encoding utf8NoBOM -NoNewline
        & git -C $script:AipProfileRoot add own/pi/models.json
        & git -C $script:AipProfileRoot commit -q -m 'own trivial models.json' *> $null
        New-Item -ItemType Directory -Path $script:Pidir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'models.json') -Value '{"default":true}' -Encoding utf8NoBOM -NoNewline
        $env:AIP_PROFILE = 'own'
        & pi *> $null
        $item = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'own/pi/models.json')
        $item.LinkType | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'own/pi/models.json') -Raw) | Should -Be '{}'
    }
}

Describe 'pi settings and packages' {
    BeforeEach {
        $script:PassRoot = Join-Path $TestDrive ('pkg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:PassRoot -Force | Out-Null
        $script:AipImportHome = Join-Path $script:PassRoot 'home'
        $script:AipProfileRoot = Join-Path $script:PassRoot 'agent-profiles'
        $script:FakeBin = Join-Path $script:PassRoot 'fake bin'
        $script:FakeCapture = Join-Path $script:PassRoot 'capture'
        $env:FAKE_CAPTURE = $script:FakeCapture
        $env:FAKE_EXIT_STATUS = '0'
        $env:AIP_PROFILE = $null
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:PassRoot 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        New-Item -ItemType Directory -Path $script:AipImportHome, $script:FakeBin -Force | Out-Null
        & git config --global user.name 'Aip Tests'
        & git config --global user.email 'aip@example.test'
        & git config --global maintenance.auto false
        & git config --global gc.auto 0
        foreach ($harness in 'claude', 'codex', 'pi', 'opencode') { New-FakeHarness $harness }
        $script:AipRealPath = $script:FakeBin
        $script:Pidir = Join-Path $script:AipImportHome '.pi/agent'
        New-Item -ItemType Directory -Path $script:Pidir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pidir 'settings.json') -Value '{
  "theme": "dark",
  "packages": [
    "npm:pi-web-access",
    "npm:@the-librarian/pi-extension",
    "npm:context-mode"
  ]
}' -Encoding utf8NoBOM
        New-TestProfile work
        $env:AIP_PROFILE = 'work'
    }

    BeforeAll {
        function Get-ProfileSettings {
            return (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json') -Raw)
        }
    }

    AfterEach {
        $env:AIP_PROFILE = $null
    }

    It 'create materialises and tracks pi/settings.json from the global settings' {
        $item = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json')
        $item.LinkType | Should -BeNullOrEmpty
        (Get-ProfileSettings) | Should -Match '"theme": "dark"'
        (Get-ProfileSettings) | Should -Match '"npm:context-mode"'
        & git -C $script:AipProfileRoot ls-files --error-unmatch -- work/pi/settings.json *> $null
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $script:AipProfileRoot status --porcelain) | Should -BeNullOrEmpty
    }

    It 'create copies and tracks settings when the global file is trivial' {
        Set-Content -LiteralPath (Join-Path $script:Pidir 'settings.json') -Value '{}' -Encoding utf8NoBOM -NoNewline
        aip create linked *> $null
        $settings = Join-Path $script:AipProfileRoot 'linked/pi/settings.json'
        (Get-Item -LiteralPath $settings).LinkType | Should -BeNullOrEmpty
        [IO.File]::ReadAllBytes($settings) | Should -Be ([IO.File]::ReadAllBytes((Join-Path $script:Pidir 'settings.json')))
        (& git -C $script:AipProfileRoot ls-files -- linked/pi/settings.json) | Should -Be 'linked/pi/settings.json'
    }

    It 'clone carries the tracked settings.json into the new profile' {
        aip clone work copy *> $null
        $global:LASTEXITCODE | Should -Be 0
        $item = Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'copy/pi/settings.json')
        $item.LinkType | Should -BeNullOrEmpty
        & git -C $script:AipProfileRoot ls-files --error-unmatch -- copy/pi/settings.json *> $null
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'new profile gitignore excludes the pi model-catalog cache' {
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/.gitignore') -Raw) | Should -Match '(?m)^pi/models-store.json$'
        & git -C $script:AipProfileRoot check-ignore -- work/pi/models-store.json *> $null
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'sync hard-fails when the pi model-catalog cache is tracked' {
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/models-store.json') -Value 'catalog cache' -Encoding utf8NoBOM
        & git -C $script:AipProfileRoot add -f work/pi/models-store.json
        & git -C $script:AipProfileRoot commit -q -m 'unsafe tracked file' *> $null
        Add-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/AGENTS.md') -Value 'change waiting'
        aip sync *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
    }

    It 'sync-packages bulk: seeded profile is in sync, idempotently' {
        aip sync-packages work | Out-String | Should -Match 'already matches'
        $script:AipCommandStatus | Should -Be 0
        $before = (Get-FileHash -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json')).Hash
        aip sync-packages work | Out-String | Should -Match 'already matches'
        $after = (Get-FileHash -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json')).Hash
        $after | Should -Be $before
    }

    It 'sync-packages bulk copy: a profile without packages adopts the global list' {
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json') -Value '{
  "theme": "light"
}' -Encoding utf8NoBOM
        aip sync-packages work | Out-String | Should -Match 'copied 3 package\(s\)'
        $settings = Get-ProfileSettings
        $settings | Should -Match '"npm:pi-web-access",'
        $settings | Should -Match '"npm:context-mode"'
        $settings | Should -Match '"theme": "light"'
        aip sync-packages work | Out-String | Should -Match 'already matches'
    }

    It 'sync-packages bulk diff: reported, non-zero, untouched without --replace' {
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json') -Value '{
  "packages": [
    "npm:only-here"
  ]
}' -Encoding utf8NoBOM
        $before = (Get-FileHash -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json')).Hash
        aip sync-packages work | Out-String | Should -Match 'profile only'
        $script:AipCommandStatus | Should -Be 1
        $after = (Get-FileHash -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json')).Hash
        $after | Should -Be $before

        aip sync-packages work --replace | Out-String | Should -Match 'replaced'
        $script:AipCommandStatus | Should -Be 0
        $settings = Get-ProfileSettings
        $settings | Should -Match '"npm:pi-web-access",'
        $settings | Should -Not -Match 'only-here'
    }

    It 'sync-packages --add is surgical and idempotent; --remove drops by name' {
        aip sync-packages work --add npm:brand-new | Out-String | Should -Match 'added'
        (Get-ProfileSettings) | Should -Match '"npm:brand-new"'
        $before = (Get-FileHash -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json')).Hash
        aip sync-packages work --add npm:brand-new | Out-String | Should -Match 'already present'
        $after = (Get-FileHash -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json')).Hash
        $after | Should -Be $before

        aip sync-packages work --remove pi-web-access | Out-String | Should -Match 'removed'
        (Get-ProfileSettings) | Should -Not -Match 'pi-web-access'
        aip sync-packages work --remove pi-web-access | Out-String | Should -Match 'not in the profile package list'
    }

    It 'sync-packages refuses a non-array packages member' {
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json') -Value '{
  "packages": {"broken": true}
}' -Encoding utf8NoBOM
        aip sync-packages work --add npm:x *> $null
        $script:AipCommandStatus | Should -Be 2
        (Get-ProfileSettings) | Should -Match '"broken": true'
    }

    It 'sync-packages edits an owned untracked settings file without changing the global file' {
        & git -C $script:AipProfileRoot rm --cached -q work/pi/settings.json
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json') -Value '{}' -Encoding utf8NoBOM -NoNewline
        & pi *> $null
        (Get-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json')).LinkType | Should -BeNullOrEmpty
        aip sync-packages work --add npm:evil *> $null
        $script:AipCommandStatus | Should -Be 0
        (Get-ProfileSettings) | Should -Match 'evil'
        (Get-Content -LiteralPath (Join-Path $script:Pidir 'settings.json') -Raw) | Should -Not -Match 'evil'
    }

    It 'doctor warns (without failing) on a shadowing pi/npm dir and an untracked settings file' {
        New-Item -ItemType Directory -Path (Join-Path $script:Pidir 'npm/node_modules') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AipProfileRoot 'work/pi/npm/node_modules') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/settings.json') -Value '{"theme":"light"}' -Encoding utf8NoBOM -NoNewline
        & git -C $script:AipProfileRoot rm --cached -q work/pi/settings.json  # legacy untracked state

        aip doctor work *> $null
        $script:AipCommandStatus | Should -Be 0
        $output = (aip doctor work) | Out-String
        $output | Should -Match 'WARN: work/pi/npm is a local directory shadowing the machine-wide pi npm dir'
        $output | Should -Match 'WARN: work/pi/settings.json is not shared \(untracked\)'

        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/pi/npm') -Recurse -Force
        & pi *> $null
        & git -C $script:AipProfileRoot add work/pi/settings.json
        & git -C $script:AipProfileRoot commit -q -m 'share settings' *> $null
        $output = (aip doctor work) | Out-String
        $output | Should -Not -Match 'shadowing the machine-wide pi npm dir'
        $output | Should -Not -Match 'not shared \(untracked\)'
    }

    It 'aip update migrates valid legacy links for every primary config' {
        New-FakeHarness 'npx'
        $globalRels = @{
            'pi/settings.json' = '.pi/agent/settings.json'
            'claude/settings.json' = '.claude/settings.json'
            'codex/config.toml' = '.codex/config.toml'
            'opencode/opencode.json' = '.config/opencode/opencode.json'
        }
        foreach ($globalRel in $globalRels.Values) { Remove-Item -LiteralPath (Join-Path $script:AipImportHome $globalRel) -Force -ErrorAction SilentlyContinue }
        aip create legacy *> $null
        foreach ($rel in $globalRels.Keys) {
            $source = Join-Path $script:AipImportHome $globalRels[$rel]
            New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
            [IO.File]::WriteAllText($source, "source-$rel")
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot (Join-Path 'legacy' $rel)) -Target $source | Out-Null
        }
        # The genuine legacy shape: the block entries that kept the links untracked
        # must be cleared before staging or git add refuses the ignored paths.
        Set-AipPassthroughGitIgnoreBlock (Join-Path $script:AipProfileRoot 'legacy/.gitignore') @($globalRels.Keys)

        aip update *> $null
        $script:AipCommandStatus | Should -Be 0
        foreach ($rel in $globalRels.Keys) {
            $source = Join-Path $script:AipImportHome $globalRels[$rel]
            $destination = Join-Path $script:AipProfileRoot (Join-Path 'legacy' $rel)
            (Get-Item -LiteralPath $destination -Force).LinkType | Should -BeNullOrEmpty
            [IO.File]::ReadAllBytes($destination) | Should -Be ([IO.File]::ReadAllBytes($source))
            (& git -C $script:AipProfileRoot diff --cached --name-only) | Should -Contain "legacy/$rel"
        }
        (Get-AipPassthroughGitIgnoreEntry (Join-Path $script:AipProfileRoot 'legacy/.gitignore')) | Should -BeNullOrEmpty
    }

    It 'leaves malformed and foreign primary-config links untouched during migration' {
        aip create legacy *> $null
        $foreign = Join-Path $TestDrive 'foreign-settings.json'
        [IO.File]::WriteAllText($foreign, '{}')
        $link = Join-Path $script:AipProfileRoot 'legacy/pi/settings.json'
        Remove-Item -LiteralPath $link -Force
        New-Item -ItemType SymbolicLink -Path $link -Target $foreign | Out-Null

        Invoke-AipMigrateLegacyPrimaryConfigLinks

        (Get-Item -LiteralPath $link -Force).LinkType | Should -Be 'SymbolicLink'
        [string](Get-Item -LiteralPath $link -Force).Target | Should -Be $foreign
    }

    It 'aip update removes untracked legacy links whose primary config targets are absent' {
        New-FakeHarness 'npx'
        $source = Join-Path $script:AipImportHome '.pi/agent/settings.json'
        Remove-Item -LiteralPath (Join-Path $script:Pidir 'settings.json') -Force -ErrorAction SilentlyContinue
        aip create legacy *> $null
        New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot 'legacy/pi/settings.json') -Target $source | Out-Null
        Set-AipPassthroughGitIgnoreBlock (Join-Path $script:AipProfileRoot 'legacy/.gitignore') @('pi/settings.json')

        (& { $output = aip update 2>&1; $output | Out-String }) | Should -Match 'removed legacy link legacy/pi/settings.json'
        $script:AipCommandStatus | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'legacy/pi/settings.json') | Should -BeFalse
        (Get-AipPassthroughGitIgnoreEntry (Join-Path $script:AipProfileRoot 'legacy/.gitignore')) | Should -Not -Contain 'pi/settings.json'
        (& git -C $script:AipProfileRoot diff --cached --name-only) | Should -Not -Contain 'legacy/pi/settings.json'
    }

    It 'aip update removes tracked legacy links whose primary config targets are absent' {
        New-FakeHarness 'npx'
        $globalRels = @{
            'pi/settings.json' = '.pi/agent/settings.json'
            'claude/settings.json' = '.claude/settings.json'
            'codex/config.toml' = '.codex/config.toml'
            'opencode/opencode.json' = '.config/opencode/opencode.json'
        }
        foreach ($globalRel in $globalRels.Values) { Remove-Item -LiteralPath (Join-Path $script:AipImportHome $globalRel) -Force -ErrorAction SilentlyContinue }
        aip create legacy *> $null
        foreach ($rel in $globalRels.Keys) {
            $source = Join-Path $script:AipImportHome $globalRels[$rel]
            New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:AipProfileRoot (Join-Path 'legacy' $rel)) -Target $source | Out-Null
            & git -C $script:AipProfileRoot add -f -- "legacy/$rel"
        }
        & git -C $script:AipProfileRoot commit -qm 'legacy primary config links'

        aip update *> $null
        $script:AipCommandStatus | Should -Be 0
        foreach ($rel in $globalRels.Keys) {
            Test-Path -LiteralPath (Join-Path $script:AipProfileRoot (Join-Path 'legacy' $rel)) | Should -BeFalse
            (& git -C $script:AipProfileRoot diff --cached --name-only) | Should -Contain "legacy/$rel"
        }
    }

    It 'aip update never overwrites a regular owned primary config' {
        New-FakeHarness 'npx'
        aip create legacy *> $null
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'legacy/pi/settings.json') -Value '{"theme":"light"}' -Encoding utf8NoBOM -NoNewline
        & git -C $script:AipProfileRoot add legacy/pi/settings.json
        & git -C $script:AipProfileRoot commit -qm 'owned settings'

        aip update *> $null
        $script:AipCommandStatus | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'legacy/pi/settings.json') -Raw) | Should -Match '"theme":"light"'
        (& git -C $script:AipProfileRoot diff --cached --name-only) | Should -Not -Contain 'legacy/pi/settings.json'
    }

    It 'aip update stages an untracked owned pi/settings.json without committing' {
        New-FakeHarness 'npx'
        Remove-Item -LiteralPath (Join-Path $script:Pidir 'settings.json') -Force
        aip create legacy *> $null
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'legacy/pi/settings.json') -Value '{"theme":"light"}' -Encoding utf8NoBOM -NoNewline

        $savedPath = $env:PATH
        $env:PATH = "$script:FakeBin$([IO.Path]::PathSeparator)$savedPath"
        try {
            aip update | Out-String | Should -Match 'staged legacy/pi/settings.json for sharing'
            $script:AipCommandStatus | Should -Be 0
            (& git -C $script:AipProfileRoot diff --cached --name-only) | Should -Contain 'legacy/pi/settings.json'
            aip update | Out-String | Should -Not -Match 'staged'
        }
        finally { $env:PATH = $savedPath }
    }
}

Describe 'skills update' {
    BeforeAll {
        function Get-AddFileUrl {
            param([Parameter(Mandatory)][string]$Path)
            $p = $Path.Replace('\', '/')
            if ($p -match '^[A-Za-z]:/') { return "file:///$p" }
            return "file://$p"
        }
    }

    BeforeEach {
        $script:AddRoot = Join-Path $TestDrive ('upd-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AddRoot -Force | Out-Null
        $script:AipProfileRoot = Join-Path $script:AddRoot 'profile root'
        $script:FakeBin = Join-Path $script:AddRoot 'fake bin'
        $script:FakeCapture = Join-Path $script:AddRoot 'capture'
        $env:FAKE_CAPTURE = $script:FakeCapture
        $env:FAKE_EXIT_STATUS = '0'
        $env:AIP_PROFILE = $null
        $env:CLAUDE_CONFIG_DIR = $null
        $env:CODEX_HOME = $null
        $env:PI_CODING_AGENT_DIR = $null
        $env:OPENCODE_CONFIG_DIR = $null
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:AddRoot 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        & git config --global user.name 'Aip Tests'
        & git config --global user.email 'aip@example.test'
        New-TestProfile work
        $script:AddSrc = Join-Path $script:AddRoot 'source'
        & git init -q $script:AddSrc
        $null = New-Item -ItemType Directory -Path (Join-Path $script:AddSrc 'alpha') -Force
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha`n" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/helper.sh') -Value 'helper' -Encoding utf8NoBOM
        & git -C $script:AddSrc add -A
        & git -C $script:AddSrc commit -q -m 'source'
    }

    AfterEach {
        $env:AIP_PROFILE = $null
        $env:FAKE_CAPTURE = $null
        $env:FAKE_EXIT_STATUS = $null
        $env:GIT_CONFIG_GLOBAL = $null
        $env:GIT_CONFIG_NOSYSTEM = $null
    }

    It 'refreshes a named skill from its sidecar without committing' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha v2`n" -Encoding utf8NoBOM
        & git -C $script:AddSrc commit -q -am 'v2'
        $before = (& git -C $script:AipProfileRoot rev-list --count HEAD)[0]
        aip skills update work alpha *> $null
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw) | Should -Match 'Alpha v2'
        $sidecar = Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source'
        $lines = Get-Content -LiteralPath $sidecar
        $lines | Should -Contain ("source=$(Get-AddFileUrl $script:AddSrc)#alpha")
        $lines | Should -Contain ("url=" + (Get-AddFileUrl $script:AddSrc))
        $lines | Should -Contain 'path=alpha'
        $after = (& git -C $script:AipProfileRoot rev-list --count HEAD)[0]
        $after | Should -Be $before
    }

    It 'leaves dest unchanged when the sidecar is missing' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        Remove-Item -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source') -Force
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Value 'keep' -Encoding utf8NoBOM
        aip skills update work alpha *> $null
        $global:LASTEXITCODE | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw).Trim() | Should -Be 'keep'
    }

    It 'errors on an unknown name' {
        aip skills update work nosuch *> $null
        $global:LASTEXITCODE | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/nosuch') | Should -BeFalse
    }

    It 'is a usage error without a name and without --all' {
        aip skills update work *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'usage: aip skills update'
    }

    It 'never prints sidecar URL userinfo' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source') -Value "source=kept`nurl=https://user:s3cret@example.test/repo.git`npath=`n" -Encoding utf8NoBOM
        aip skills update work alpha *> $null
        $global:LASTEXITCODE | Should -Be 1
        $script:AipLastError | Should -Not -Match 's3cret'
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') | Should -BeTrue
    }

    It 'rejects a traversing sidecar path and leaves dest unchanged' {
        $outside = Join-Path $script:AddSrc 'outside'
        $null = New-Item -ItemType Directory -Path $outside -Force
        Set-Content -LiteralPath (Join-Path $outside 'SKILL.md') -Value "---`nname: outside`n---`n# Outside`n" -Encoding utf8NoBOM
        & git -C $script:AddSrc add -A
        & git -C $script:AddSrc commit -q -m 'outside'
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $url = Get-AddFileUrl $script:AddSrc
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source') -Value "source=kept`nurl=$url`npath=alpha/../outside`n" -Encoding utf8NoBOM
        aip skills update work alpha *> $null
        $global:LASTEXITCODE | Should -Be 1
        $text = Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw
        $text | Should -Match '# Alpha'
        $text | Should -Not -Match 'Outside'
    }

    It 'rejects an empty name' {
        aip skills update work '' *> $null
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'accepts a CRLF sidecar' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha v2`n" -Encoding utf8NoBOM
        & git -C $script:AddSrc commit -q -am 'v2'
        $url = Get-AddFileUrl $script:AddSrc
        $bytes = [Text.Encoding]::UTF8.GetBytes("source=$url#alpha`r`nurl=$url`r`npath=alpha`r`n")
        [IO.File]::WriteAllBytes((Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source'), $bytes)
        aip skills update work alpha *> $null
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw) | Should -Match 'Alpha v2'
    }

    It 'rejects a sidecar with a trailing extra line' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $url = Get-AddFileUrl $script:AddSrc
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source') -Value "source=$url#alpha`nurl=$url`npath=alpha`n`n" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Value 'keep' -Encoding utf8NoBOM
        aip skills update work alpha *> $null
        $global:LASTEXITCODE | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw).Trim() | Should -Be 'keep'
    }
}

Describe 'skills update --all' {
    BeforeAll {
        function Get-AddFileUrl {
            param([Parameter(Mandatory)][string]$Path)
            $p = $Path.Replace('\', '/')
            if ($p -match '^[A-Za-z]:/') { return "file:///$p" }
            return "file://$p"
        }
    }

    BeforeEach {
        $script:AddRoot = Join-Path $TestDrive ('upda-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AddRoot -Force | Out-Null
        $script:AipProfileRoot = Join-Path $script:AddRoot 'profile root'
        $script:FakeBin = Join-Path $script:AddRoot 'fake bin'
        $script:FakeCapture = Join-Path $script:AddRoot 'capture'
        $env:FAKE_CAPTURE = $script:FakeCapture
        $env:FAKE_EXIT_STATUS = '0'
        $env:AIP_PROFILE = $null
        $env:CLAUDE_CONFIG_DIR = $null
        $env:CODEX_HOME = $null
        $env:PI_CODING_AGENT_DIR = $null
        $env:OPENCODE_CONFIG_DIR = $null
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:AddRoot 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        & git config --global user.name 'Aip Tests'
        & git config --global user.email 'aip@example.test'
        New-TestProfile work
        New-TestProfile suit
        $script:AddSrc = Join-Path $script:AddRoot 'source'
        & git init -q $script:AddSrc
        $null = New-Item -ItemType Directory -Path (Join-Path $script:AddSrc 'alpha'), (Join-Path $script:AddSrc 'beta') -Force
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha`n" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'beta/SKILL.md') -Value "---`nname: beta`n---`n# Beta`n" -Encoding utf8NoBOM
        & git -C $script:AddSrc add -A
        & git -C $script:AddSrc commit -q -m 'source'
    }

    AfterEach {
        $env:AIP_PROFILE = $null
        $env:FAKE_CAPTURE = $null
        $env:FAKE_EXIT_STATUS = $null
        $env:GIT_CONFIG_GLOBAL = $null
        $env:GIT_CONFIG_NOSYSTEM = $null
    }

    It 'refreshes sidecar-backed skills and notes a bare directory' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#beta" *> $null
        $orphan = Join-Path $script:AipProfileRoot 'work/skills/orphan'
        $null = New-Item -ItemType Directory -Path $orphan -Force
        Set-Content -LiteralPath (Join-Path $orphan 'SKILL.md') -Value "---`nname: orphan`n---`n# Orphan`n" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha v2`n" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'beta/SKILL.md') -Value "---`nname: beta`n---`n# Beta v2`n" -Encoding utf8NoBOM
        & git -C $script:AddSrc commit -q -am 'v2'
        $out = (aip skills update work --all 2>&1) -join "`n"
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw) | Should -Match 'Alpha v2'
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/beta/SKILL.md') -Raw) | Should -Match 'Beta v2'
        (Get-Content -LiteralPath (Join-Path $orphan 'SKILL.md') -Raw) | Should -Match 'Orphan'
        $out | Should -Match 'orphan'
    }

    It 'is sidecar-keyed for --all-profiles NAME' {
        New-TestProfile extra
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        aip skills add suit "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        $extra = Join-Path $script:AipProfileRoot 'extra/skills/alpha'
        $null = New-Item -ItemType Directory -Path $extra -Force
        Set-Content -LiteralPath (Join-Path $extra 'SKILL.md') -Value "---`nname: alpha`n---`n# Extra`n" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha v2`n" -Encoding utf8NoBOM
        & git -C $script:AddSrc commit -q -am 'v2'
        aip skills update --all-profiles alpha *> $null
        $global:LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw) | Should -Match 'Alpha v2'
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'suit/skills/alpha/SKILL.md') -Raw) | Should -Match 'Alpha v2'
        (Get-Content -LiteralPath (Join-Path $extra 'SKILL.md') -Raw) | Should -Match 'Extra'
    }

    It 'errors when --all-profiles NAME finds no sidecar' {
        $dest = Join-Path $script:AipProfileRoot 'work/skills/alpha'
        $null = New-Item -ItemType Directory -Path $dest -Force
        Set-Content -LiteralPath (Join-Path $dest 'SKILL.md') -Value "---`nname: alpha`n---`n# Local`n" -Encoding utf8NoBOM
        aip skills update --all-profiles alpha *> $null
        $global:LASTEXITCODE | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $dest 'SKILL.md') -Raw) | Should -Match 'Local'
    }

    It 'rejects --all plus a NAME as usage' {
        aip skills update work --all alpha *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'usage: aip skills update'
    }

    It 'errors on a malformed sidecar' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        Set-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/.aip-source') -Value "not a sidecar`n" -Encoding utf8NoBOM
        aip skills update work --all *> $null
        $global:LASTEXITCODE | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha/SKILL.md') -Raw) | Should -Match '# Alpha'
    }
}

Describe 'skills remove' {
    BeforeAll {
        function Get-AddFileUrl {
            param([Parameter(Mandatory)][string]$Path)
            $p = $Path.Replace('\', '/')
            if ($p -match '^[A-Za-z]:/') { return "file:///$p" }
            return "file://$p"
        }
    }

    BeforeEach {
        $script:AddRoot = Join-Path $TestDrive ('rm-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AddRoot -Force | Out-Null
        $script:AipProfileRoot = Join-Path $script:AddRoot 'profile root'
        $script:FakeBin = Join-Path $script:AddRoot 'fake bin'
        $script:FakeCapture = Join-Path $script:AddRoot 'capture'
        $env:FAKE_CAPTURE = $script:FakeCapture
        $env:FAKE_EXIT_STATUS = '0'
        $env:AIP_PROFILE = $null
        $env:CLAUDE_CONFIG_DIR = $null
        $env:CODEX_HOME = $null
        $env:PI_CODING_AGENT_DIR = $null
        $env:OPENCODE_CONFIG_DIR = $null
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:AddRoot 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        & git config --global user.name 'Aip Tests'
        & git config --global user.email 'aip@example.test'
        New-TestProfile work
        $script:AddSrc = Join-Path $script:AddRoot 'source'
        & git init -q $script:AddSrc
        $null = New-Item -ItemType Directory -Path (Join-Path $script:AddSrc 'alpha'), (Join-Path $script:AddSrc 'beta') -Force
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'alpha/SKILL.md') -Value "---`nname: alpha`n---`n# Alpha`n" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:AddSrc 'beta/SKILL.md') -Value "---`nname: beta`n---`n# Beta`n" -Encoding utf8NoBOM
        & git -C $script:AddSrc add -A
        & git -C $script:AddSrc commit -q -m 'source'
    }

    AfterEach {
        $env:AIP_PROFILE = $null
        $env:FAKE_CAPTURE = $null
        $env:FAKE_EXIT_STATUS = $null
        $env:GIT_CONFIG_GLOBAL = $null
        $env:GIT_CONFIG_NOSYSTEM = $null
    }

    It 'deletes a named skill and leaves siblings and history alone' {
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#beta" *> $null
        $before = (& git -C $script:AipProfileRoot rev-list --count HEAD)[0]
        aip skills remove work alpha *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/beta/SKILL.md') | Should -BeTrue
        $after = (& git -C $script:AipProfileRoot rev-list --count HEAD)[0]
        $after | Should -Be $before
    }

    It 'errors when the directory is missing' {
        aip skills remove work alpha *> $null
        $global:LASTEXITCODE | Should -Be 1
    }

    It '--all-profiles deletes every existing directory of that name' {
        New-TestProfile suit
        aip skills add work "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        aip skills add suit "$(Get-AddFileUrl $script:AddSrc)#alpha" *> $null
        aip skills remove --all-profiles alpha *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'work/skills/alpha') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:AipProfileRoot 'suit/skills/alpha') | Should -BeFalse
    }

    It '--all-profiles errors when the name exists in no profile' {
        aip skills remove --all-profiles alpha *> $null
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'rejects --all as usage' {
        aip skills remove work --all *> $null
        $global:LASTEXITCODE | Should -Be 2
        $script:AipLastError | Should -Match 'usage: aip skills remove'
    }

    It 'rejects a git source as a name' {
        aip skills remove work 'owner/repo#path' *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
    }

    It 'rejects an empty name' {
        aip skills remove work '' *> $null
        $global:LASTEXITCODE | Should -Be 1
    }
}
