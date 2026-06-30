# scripts.Tests.ps1 - cheap syntax gate: every shipped .ps1 (engine, wrappers, installers, hooks)
# must parse cleanly. Catches quoting/encoding regressions (e.g. a stray non-ASCII char that
# Windows PowerShell 5.1 mis-reads in a no-BOM file) before they reach a machine.

Describe 'All PowerShell scripts parse without errors' {
    $root  = Join-Path $PSScriptRoot '..'
    $files = @()
    foreach ($sub in 'scripts', 'hooks') {
        $dir = Join-Path $root $sub
        if (Test-Path $dir) { $files += Get-ChildItem $dir -Filter *.ps1 -Recurse -File }
    }

    # -ForEach binds each FileInfo to $_ at run time (a plain foreach + It does not carry $f across
    # Pester's discovery/run boundary).
    It 'parses <Name>' -ForEach $files {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }

    It 'the engine + wrappers + hooks are present' {
        $scripts = Join-Path (Join-Path $PSScriptRoot '..') 'scripts'
        foreach ($n in 'common.ps1','agent-config.ps1','run-dispatch.ps1','run-babysit.ps1','run-triage.ps1','install-tasks.ps1','uninstall-tasks.ps1') {
            (Join-Path $scripts $n) | Should -Exist
        }
        (Join-Path (Join-Path $PSScriptRoot '..') 'hooks/block-dangerous-commands.ps1') | Should -Exist
    }
}
