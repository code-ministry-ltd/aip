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
        param([string]$Name, [string]$Outfit = 'plain')
        aip create $Name --outfit $Outfit *> $null
        $global:LASTEXITCODE | Should -Be 0
    }

    function Initialize-TestUpstream {
        $script:TestRemote = Join-Path $TestDrive 'profile.git'
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
    $env:FAKE_CAPTURE = $script:FakeCapture
    $env:FAKE_EXIT_STATUS = '0'
    $env:AIP_PROFILE = $null
    $env:AIP_ANIMATION = 'off'
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
    $env:AIP_ANIMATION = $null
    $env:FAKE_CAPTURE = $null
    $env:FAKE_EXIT_STATUS = $null
    $env:GIT_CONFIG_GLOBAL = $null
    $env:GIT_CONFIG_NOSYSTEM = $null
}

It 'reports the embedded version and rejects extra arguments' {
    aip version | Should -Be 'aip 0.3.0'
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
        $lines | Should -Contain 'arg=@code-ministry/aip'
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
    foreach ($command in 'create', 'list', 'which', 'default', 'use', 'local', 'outfit', 'clone', 'delete', 'sync', 'remote', 'doctor', 'run', 'update', 'version', 'help') {
        $helpOutput | Should -Match ([regex]::Escape("aip $command"))
    }
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

    It 'counts Unicode scalars for outfit length consistently' {
        Test-AipOutfit ('🐵' * 40) | Should -BeTrue
        Test-AipOutfit ('🐵' * 65) | Should -BeFalse
        Test-AipOutfit "bad$([char]0x85)label" | Should -BeFalse
    }

    It 'allows TOML-compatible C1 characters in Codex instructions' {
        ConvertTo-AipTomlString "before$([char]0x85)after" | Should -Be "`"before$([char]0x85)after`""
    }

    It 'keeps command and harness spellings case-sensitive' {
        aip CREATE work *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
        New-TestProfile work
        aip run work CLAUDE *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
    }

    It 'creates the approved relative-link layout atomically in the profiles repository' {
        aip create work --outfit suit
        $global:LASTEXITCODE | Should -Be 0
        $root = $script:AipProfileRoot
        $profile = Join-Path $root 'work'
        (Get-Content (Join-Path $profile '.aip/outfit') -Raw).Trim() | Should -Be 'suit'
        (Get-Item (Join-Path $profile 'codex/AGENTS.md')).LinkType | Should -Be 'SymbolicLink'
        # On Windows, .Target reports relative links with backslashes; normalize to the stored form.
        [string](Get-Item (Join-Path $profile 'codex/AGENTS.md')).Target -replace '\\', '/' | Should -Be '../AGENTS.md'
        [string](Get-Item (Join-Path $profile 'claude/skills')).Target -replace '\\', '/' | Should -Be '../skills'
        (Get-Content -LiteralPath (Join-Path $profile 'claude/CLAUDE.md') -TotalCount 1) | Should -Be '@../AGENTS.md'
        [IO.File]::ReadAllBytes((Join-Path $profile 'claude/CLAUDE.md')) | Should -Not -Contain 13
        [IO.File]::ReadAllBytes((Join-Path $profile '.gitignore')) | Should -Not -Contain 13
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
        $output | Should -Match 'work —'
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

    It 'outfit refuses a linked metadata directory without changing its target' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $external = Join-Path $TestDrive 'external aip'
        New-Item -ItemType Directory -Path $external | Out-Null
        'outside' | Set-Content (Join-Path $external 'outfit')
        Remove-Item -LiteralPath (Join-Path $profile '.aip') -Recurse -Force
        New-Item -ItemType SymbolicLink -Path (Join-Path $profile '.aip') -Target $external | Out-Null

        aip outfit work changed *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        (Get-Content (Join-Path $external 'outfit') -Raw).Trim() | Should -Be 'outside'
        $listOutput = aip list | Out-String
        $listOutput | Should -Match 'invalid outfit'
        $listOutput | Should -Not -Match 'outside'
    }

    It 'replaces an outfit hard link without changing the external inode' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $external = Join-Path $TestDrive 'external outfit'
        'outside' | Set-Content $external
        $outfitPath = Join-Path $profile '.aip/outfit'
        Remove-Item -LiteralPath $outfitPath
        New-Item -ItemType HardLink -Path $outfitPath -Target $external | Out-Null

        aip outfit work changed *> $null

        $global:LASTEXITCODE | Should -Be 0
        (Get-Content $external -Raw).Trim() | Should -Be 'outside'
        (Get-Content $outfitPath -Raw).Trim() | Should -Be 'changed'
    }

    It 'repairs corrupt outfit content and rejects multiple stored lines' {
        $profile = Join-Path $script:AipProfileRoot 'work'
        $outfitPath = Join-Path $profile '.aip/outfit'
        [IO.File]::WriteAllBytes($outfitPath, [byte[]](255))

        aip outfit work repaired *> $null

        $global:LASTEXITCODE | Should -Be 0
        (Get-AipOutfit $profile) | Should -Be 'repaired'
        [IO.File]::WriteAllText($outfitPath, "suit`n`n", [Text.UTF8Encoding]::new($false))
        (Get-AipOutfit $profile) | Should -Be 'invalid outfit'
        aip doctor work *> $null
        $global:LASTEXITCODE | Should -Not -Be 0
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
        $script:AipLastError | Should -Match 'remote profile has an invalid required link'
        [string](Get-Item (Join-Path $profile 'codex/skills')).Target -replace '\\', '/' | Should -Be '../skills'
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

    It 'rejects invalid remote outfit framing before rebase' {
        Initialize-TestUpstream
        $root = $script:AipProfileRoot
        $other = Join-Path $TestDrive 'bad outfit'
        & git clone -q $script:TestRemote $other
        [IO.File]::WriteAllText((Join-Path $other 'work/.aip/outfit'), "suit`n`n", [Text.UTF8Encoding]::new($false))
        & git -C $other add work/.aip/outfit
        & git -C $other commit -q -m invalid-outfit
        & git -C $other push -q
        $before = & git -C $root rev-parse HEAD

        aip sync *> $null

        $global:LASTEXITCODE | Should -Not -Be 0
        $script:AipLastError | Should -Match 'invalid outfit'
        (& git -C $root rev-parse HEAD) | Should -Be $before
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
        New-TestProfile work suit
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

    It 'clones the repository on a fresh machine and lists every profile' {
        New-TestProfile work suit
        New-TestProfile personal hoodie
        aip remote add $script:TestRemote *> $null
        $global:LASTEXITCODE | Should -Be 0

        $freshRoot = Join-Path $TestDrive 'fresh machine/profile root'
        $script:AipProfileRoot = $freshRoot

        aip remote add $script:TestRemote | Out-String | Should -Match "Cloned profiles from $([regex]::Escape($script:TestRemote))."
        $global:LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path $freshRoot '.git') | Should -BeTrue
        $listOutput = aip list | Out-String
        $listOutput | Should -Match 'work — suit'
        $listOutput | Should -Match 'personal — hoodie'
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

Describe 'sync animation' {
    It 'AIP_ANIMATION=off never starts the spinner' {
        New-TestProfile work
        Initialize-TestUpstream
        $env:AIP_ANIMATION = 'off'
        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        $script:AipSpinnerRunspace | Should -BeNullOrEmpty
        $script:AipSpinnerPowerShell | Should -BeNullOrEmpty
    }

    It 'a forced sync animation stops cleanly after the sync' {
        New-TestProfile work
        Initialize-TestUpstream
        $env:AIP_ANIMATION = 'always'
        aip sync | Out-String | Should -Match 'Profiles synced with origin/main.'
        $global:LASTEXITCODE | Should -Be 0
        $script:AipSpinnerRunspace | Should -BeNullOrEmpty
        $script:AipSpinnerPowerShell | Should -BeNullOrEmpty
    }

    It 'a forced-animation sync that warns still stops the spinner' {
        New-TestProfile work
        Initialize-TestUpstream
        $env:AIP_ANIMATION = 'always'
        & git -C $script:AipProfileRoot remote set-url origin (Join-Path $TestDrive 'missing.git')
        aip sync *> $null
        $global:LASTEXITCODE | Should -Be 0
        $script:AipLastWarning | Should -Match 'remote sync unavailable'
        $script:AipSpinnerRunspace | Should -BeNullOrEmpty
        $script:AipSpinnerPowerShell | Should -BeNullOrEmpty
    }
}

Describe 'installer' {
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
}
}
