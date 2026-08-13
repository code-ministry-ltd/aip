Describe 'PowerShell test entry point' {
    It 'runs under PowerShell 7 or later' {
        $PSVersionTable.PSVersion.Major | Should -BeGreaterOrEqual 7
    }
}

