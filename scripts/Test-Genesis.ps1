#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module Pester -RequiredVersion 5.9.0 -ErrorAction Stop
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop

$sources = @(Get-ChildItem -LiteralPath $repository -Recurse -File | Where-Object {
        $_.Extension -in @('.ps1', '.psm1', '.psd1') -and
        $_.FullName -notmatch '[\\/](?:\.local|\.venv|\.git)[\\/]'
    })
foreach ($file in $sources) {
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw ($file.Name + ' : ' + ($parseErrors.Message -join '; ')) }
}

$issues = @($sources | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Warning, Error -Settings (Join-Path $repository 'PSScriptAnalyzerSettings.psd1') })
if ($issues.Count -gt 0) {
    $issues | Format-Table RuleName, ScriptName, Line, Message -AutoSize | Out-Host
    throw "L'analyse PowerShell signale des problèmes."
}
$testArguments = @{ Path = (Join-Path $repository 'tests'); Output = 'Normal'; PassThru = $true }
if ($env:OS -ne 'Windows_NT') { $testArguments.ExcludeTag = @('Windows') }
$result = Invoke-Pester @testArguments
if ($result.Result -ne 'Passed' -or $result.TotalCount -eq 0) { throw 'Les tests PowerShell ont échoué.' }
