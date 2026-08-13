BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepositoryRoot 'aip.ps1')

    function New-FakeHarness {
        param([Parameter(Mandatory)][string]$Name)

        if ($IsWindows) {
            $path = Join-Path $script:FakeBin "$Name.cmd"
            @"
@echo off
> "%FAKE_CAPTURE%" echo harness=$Name
>> "%FAKE_CAPTURE%" echo CLAUDE_CONFIG_DIR=%CLAUDE_CONFIG_DIR%
>> "%FAKE_CAPTURE%" echo CODEX_HOME=%CODEX_HOME%
>> "%FAKE_CAPTURE%" echo PI_CODING_AGENT_DIR=%PI_CODING_AGENT_DIR%
>> "%FAKE_CAPTURE%" echo OPENCODE_CONFIG_DIR=%OPENCODE_CONFIG_DIR%
:args
if "%~1"=="" goto done
>> "%FAKE_CAPTURE%" echo arg=%~1
shift
goto args
:done
exit /b %FAKE_EXIT_STATUS%
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
        param([string]$Name, [string]$Outfit = 'plain')
        aip create $Name --outfit $Outfit *> $null
        $global:LASTEXITCODE | Should -Be 0
    }

    function Initialize-TestUpstream {
        $script:TestRemote = Join-Path $TestDrive 'profile.git'
        & git init -q --bare $script:TestRemote
        & git -C (Join-Path $script:AipProfileRoot 'work') remote add origin $script:TestRemote
        & git -C (Join-Path $script:AipProfileRoot 'work') push -q -u origin main
        & git -C $script:TestRemote symbolic-ref HEAD refs/heads/main
    }
}

Describe 'aip' {
BeforeEach {
    Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
    $script:AipProfileRoot = Join-Path $TestDrive 'profile root'
    $script:FakeBin = Join-Path $TestDrive 'fake bin'
    $script:FakeCapture = Join-Path $TestDrive 'capture'
    $env:FAKE_CAPTURE = $script:FakeCapture
    $env:FAKE_EXIT_STATUS = '0'
    $env:AIP_PROFILE = $null
    $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig'
    $env:GIT_CONFIG_NOSYSTEM = '1'
    if (Test-Path -LiteralPath $script:AipProfileRoot) { Remove-Item -LiteralPath $script:AipProfileRoot -Recurse -Force }
    if (Test-Path -LiteralPath $script:FakeBin) { Remove-Item -LiteralPath $script:FakeBin -Recurse -Force }
    New-Item -ItemType Directory -Path $script:AipProfileRoot, $script:FakeBin -Force | Out-Null
    & git config --global user.name 'Aip Tests'
    & git config --global user.email 'aip@example.test'
    foreach ($harness in 'claude', 'codex', 'pi', 'opencode') { New-FakeHarness $harness }
    $script:AipRealPath = $script:FakeBin
    Remove-Variable -Name AipLockAttempts -Scope Script -ErrorAction SilentlyContinue
}

AfterEach {
    $env:AIP_PROFILE = $null
    $env:FAKE_CAPTURE = $null
    $env:FAKE_EXIT_STATUS = $null
    $env:GIT_CONFIG_GLOBAL = $null
    $env:GIT_CONFIG_NOSYSTEM = $null
}

Describe 'profile creation and selection' {
    It 'validates profile names strictly' {
        Test-AipProfileName 'client-42_name' | Should -BeTrue
        foreach ($name in '../work', 'a/b', 'a.b', '-work', 'work_', 'Work', ('a' * 65), '') {
            Test-AipProfileName $name | Should -BeFalse
        }
    }

    It 'creates the approved relative-link layout atomically on main' {
        aip create work --outfit suit
        $global:LASTEXITCODE | Should -Be 0
        $profile = Join-Path $script:AipProfileRoot 'work'
        (Get-Content (Join-Path $profile '.aip/outfit') -Raw).Trim() | Should -Be 'suit'
        (Get-Item (Join-Path $profile 'codex/AGENTS.md')).LinkType | Should -Be 'SymbolicLink'
        [string](Get-Item (Join-Path $profile 'codex/AGENTS.md')).Target | Should -Be '../AGENTS.md'
        [string](Get-Item (Join-Path $profile 'claude/skills')).Target | Should -Be '../skills'
        (& git -C $profile branch --show-current) | Should -Be 'main'
        (& git -C $profile status --porcelain) | Should -BeNullOrEmpty
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

    It 'supports local markers, outfits, listing, and status details' {
        New-TestProfile work suit
        New-TestProfile personal hoodie
        aip default work *> $null
        $project = Join-Path $TestDrive 'project'
        New-Item -ItemType Directory -Path $project | Out-Null
        Push-Location $project
        try {
            aip local personal *> $null
            aip outfit personal 'blue hoodie' *> $null
            $env:AIP_PROFILE = 'personal'
            $statusOutput = aip | Out-String
            $statusOutput | Should -Match '🐵 personal — blue hoodie'
            $statusOutput | Should -Match 'Selected by: session'
            $statusOutput | Should -Match 'Git: changes, local only'
            $listOutput = aip list | Out-String
            $listOutput | Should -Match 'personal — blue hoodie \[session\] \[project\]'
            $listOutput | Should -Match 'work — suit \[default\]'
            aip local --remove *> $null
            Test-Path (Join-Path $project '.aip-profile') | Should -BeFalse
        }
        finally { Pop-Location }
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
            & $harness 'one two' '*literal*' *> $null
            $global:LASTEXITCODE | Should -Be 0
            $capture = Get-Content $script:FakeCapture -Raw
            $capture | Should -Match "harness=$harness"
            $capture | Should -Match ([regex]::Escape("$($selectors[$harness])=$(Join-Path $script:AipProfileRoot "work/$harness")"))
            $capture | Should -Match 'arg=one two'
            $capture | Should -Match 'arg=\*literal\*'
        }
    }

    It 'injects Codex instructions before an explicit user override' {
        'Codex only — keep this text.' | Set-Content (Join-Path $script:AipProfileRoot 'work/codex/instructions.md')
        codex -c 'developer_instructions=user override' prompt *> $null
        $arguments = @(Get-Content $script:FakeCapture | Where-Object { $_ -like 'arg=*' })
        $arguments | Should -Be @(
            'arg=-c',
            'arg=developer_instructions=Codex only — keep this text.',
            'arg=-c',
            'arg=developer_instructions=user override',
            'arg=prompt'
        )
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
}

Describe 'local lifecycle' {
    BeforeEach { New-TestProfile work suit }

    It 'clones only checkpointed content into a fresh repository without runtime state or remotes' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        'checkpoint me' | Set-Content (Join-Path $profile 'AGENTS.md')
        'runtime' | Set-Content (Join-Path $profile 'claude/session.json')
        aip clone work copy *> $null
        $global:LASTEXITCODE | Should -Be 0
        $copy = Join-Path $script:AipProfileRoot 'copy'
        (Get-Content (Join-Path $copy 'AGENTS.md') -Raw).Trim() | Should -Be 'checkpoint me'
        Test-Path (Join-Path $copy 'claude/session.json') | Should -BeFalse
        (& git -C $copy remote) | Should -BeNullOrEmpty
        (& git -C $copy rev-list --count HEAD) | Should -Be 1
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

    It 'doctor detects a broken required link' {
        $link = Join-Path $script:AipProfileRoot 'work/codex/skills'
        Remove-Item $link -Force
        New-Item -ItemType SymbolicLink -Path $link -Target '../other' | Out-Null
        $output = aip doctor work 2>&1 | Out-String
        $global:LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'codex/skills should link to ../skills'
    }

    It 'doctor reports forbidden tracked content and a stale lock without deleting the lock' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        'credential' | Set-Content (Join-Path $profile 'codex/auth.json')
        & git -C $profile add -f codex/auth.json
        $lock = Join-Path $profile '.git/aip-sync.lock'
        New-Item -ItemType Directory -Path $lock | Out-Null
        '99999999' | Set-Content (Join-Path $lock 'pid')
        [Environment]::MachineName | Set-Content (Join-Path $lock 'host')
        'old' | Set-Content (Join-Path $lock 'token')
        $output = aip doctor work | Out-String
        $global:LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'ERROR: remove forbidden tracked content'
        $output | Should -Match 'WARN: stale sync lock found'
        Test-Path $lock | Should -BeTrue
    }
}

Describe 'Git checkpoint and sync' {
    BeforeEach {
        New-TestProfile work
        $env:AIP_PROFILE = 'work'
    }

    It 'auto-tracks shared skills but leaves unknown native files untracked' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        New-Item -ItemType Directory -Path (Join-Path $profile 'skills/reviewer') -Force | Out-Null
        '# Reviewer' | Set-Content (Join-Path $profile 'skills/reviewer/SKILL.md')
        '{}' | Set-Content (Join-Path $profile 'claude/settings.json')
        aip sync work *> $null
        $global:LASTEXITCODE | Should -Be 0
        (& git -C $profile show 'HEAD:skills/reviewer/SKILL.md') | Should -Be '# Reviewer'
        (& git -C $profile ls-files -- claude/settings.json) | Should -BeNullOrEmpty
    }

    It 'does not create a commit for a no-op sync' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $before = [int](& git -C $profile rev-list --count HEAD)
        aip sync work *> $null
        $global:LASTEXITCODE | Should -Be 0
        [int](& git -C $profile rev-list --count HEAD) | Should -Be $before
    }

    It 'hard-fails when a known credential path is tracked' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        'credential material' | Set-Content (Join-Path $profile 'codex/auth.json')
        & git -C $profile add -f codex/auth.json
        aip sync work *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'forbidden credential or runtime path is tracked'
    }

    It 'pulls and pushes through a local bare upstream' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git clone -q $script:TestRemote $other
        'remote' | Set-Content (Join-Path $other 'REMOTE.md')
        & git -C $other add REMOTE.md
        & git -C $other commit -q -m remote
        & git -C $other push -q
        $profile = Join-Path $script:AipProfileRoot 'work'
        New-Item -ItemType Directory -Path (Join-Path $profile 'skills/local') -Force | Out-Null
        'local' | Set-Content (Join-Path $profile 'skills/local/SKILL.md')
        aip sync work *> $null
        $global:LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path $profile 'REMOTE.md') | Should -BeTrue
        & git -C $other pull -q
        Test-Path (Join-Path $other 'skills/local/SKILL.md') | Should -BeTrue
    }

    It 'launches offline and retains a local checkpoint' {
        Initialize-TestUpstream
        Move-Item $script:TestRemote "$script:TestRemote.offline"
        $profile = Join-Path $script:AipProfileRoot 'work'
        'offline change' | Add-Content (Join-Path $profile 'AGENTS.md')
        claude prompt *> $null
        $global:LASTEXITCODE | Should -Be 0
        $script:AipLastWarning | Should -Match 'remote sync unavailable'
        Test-Path $script:FakeCapture | Should -BeTrue
        [int](& git -C $profile rev-list --count '@{upstream}..HEAD') | Should -Be 1
    }

    It 'leaves a conflict recoverable and blocks the next launch' {
        Initialize-TestUpstream
        $other = Join-Path $TestDrive 'other'
        & git clone -q $script:TestRemote $other
        'remote version' | Set-Content (Join-Path $other 'AGENTS.md')
        & git -C $other add AGENTS.md
        & git -C $other commit -q -m remote-conflict
        & git -C $other push -q
        $profile = Join-Path $script:AipProfileRoot 'work'
        'local version' | Set-Content (Join-Path $profile 'AGENTS.md')
        aip sync work *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'Git conflict'
        (Test-Path (Join-Path $profile '.git/rebase-merge')) -or (Test-Path (Join-Path $profile '.git/rebase-apply')) | Should -BeTrue
        Remove-Item $script:FakeCapture -ErrorAction SilentlyContinue
        claude prompt 2>$null
        $global:LASTEXITCODE | Should -Not -Be 0
        Test-Path $script:FakeCapture | Should -BeFalse
    }

    It 'does not steal a live sync lock' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $lock = Join-Path $profile '.git/aip-sync.lock'
        New-Item -ItemType Directory -Path $lock | Out-Null
        $PID | Set-Content (Join-Path $lock 'pid')
        [Environment]::MachineName | Set-Content (Join-Path $lock 'host')
        'held-by-test' | Set-Content (Join-Path $lock 'token')
        $script:AipLockAttempts = 1
        aip sync work *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'sync is already running'
        (Get-Content (Join-Path $lock 'token') -Raw).Trim() | Should -Be 'held-by-test'
    }
}
}
