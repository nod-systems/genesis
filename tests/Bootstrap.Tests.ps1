BeforeAll {
    $repository = Split-Path -Parent $PSScriptRoot
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'install.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Le lanceur PowerShell est invalide.' }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

Describe 'Lancement du menu Genesis' {
    BeforeEach {
        $script:PreviousGenesisTestOS = $env:OS
        $env:OS = 'Windows_NT'
        Mock Invoke-RestMethod { [pscustomobject]@{ sha = ('a' * 40) } }
        Mock Get-GenesisBootstrapContext { [pscustomobject]@{ Administrator = $false; DesktopHost = $true; PowerShell = 'powershell.exe' } }
        Mock Test-Path { $true }
        Mock Start-Process {}
        Mock Receive-GenesisRelease { throw 'Le processus non élevé ne doit pas télécharger le programme.' }
    }

    AfterEach { $env:OS = $script:PreviousGenesisTestOS }

    It 'demande une élévation UAC en conservant le commit résolu' {
        Start-GenesisOnline
        Should -Invoke Start-Process -Exactly -Times 1 -ParameterFilter {
            $Verb -eq 'RunAs' -and $FilePath -eq 'powershell.exe' -and
            [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[4])) -match ("Start-GenesisOnline -Commit '" + ('a' * 40) + "'")
        }
        Should -Invoke Receive-GenesisRelease -Exactly -Times 0
    }

    It 'démarre directement le menu Windows dans une session native déjà élevée' {
        Mock Get-GenesisBootstrapContext { [pscustomobject]@{ Administrator = $true; DesktopHost = $true; PowerShell = 'powershell.exe' } }
        Mock Receive-GenesisRelease {
            param($Directory)
            New-Item -Path $Directory -ItemType Directory -Force | Out-Null
            $script:GenesisTestDownloadDirectory = $Directory
            $path = Join-Path $Directory 'example.ps1'
            'param($Action, $ProfileId); "$Action/$ProfileId"' | Set-Content -LiteralPath $path
            return $path
        }
        $previousGenesisTestTemp = $env:TEMP
        try {
            $env:TEMP = $TestDrive
            Start-GenesisOnline | Should -Be 'Menu/windows'
            [IO.Directory]::Exists($script:GenesisTestDownloadDirectory) | Should -BeFalse
            Should -Invoke Start-Process -Exactly -Times 0
        }
        finally { $env:TEMP = $previousGenesisTestTemp }
    }

    It 'arrête le lancement si la demande UAC est annulée' {
        Mock Start-Process { throw 'Élévation annulée.' }
        { Start-GenesisOnline } | Should -Throw '*annulée*'
        Should -Invoke Receive-GenesisRelease -Exactly -Times 0
    }
}

Describe 'Téléchargement public de Genesis' {
    BeforeEach {
        $script:Commit = 'a' * 40
        $script:ArtifactBytes = [Text.Encoding]::UTF8.GetBytes('Write-Output "example"')
        $memory = [IO.MemoryStream]::new($script:ArtifactBytes)
        try { $script:Digest = (Get-FileHash -InputStream $memory -Algorithm SHA256).Hash } finally { $memory.Dispose() }
        Mock Invoke-RestMethod {
            [pscustomobject]@{ schemaVersion = 1; sha256 = [pscustomobject]@{ 'Genesis-Portable.ps1' = $script:Digest } }
        }
        Mock Invoke-WebRequest {
            param([string]$OutFile)
            [IO.File]::WriteAllBytes($OutFile, $script:ArtifactBytes)
        }
    }

    It 'télécharge le manifeste et le programme depuis le même commit' {
        $path = Receive-GenesisRelease -Commit $script:Commit -Directory $TestDrive
        $path | Should -Exist
        Should -Invoke Invoke-RestMethod -Exactly -Times 1 -ParameterFilter {
            $Uri -eq ('https://raw.githubusercontent.com/nod-systems/genesis/' + $script:Commit + '/public-manifest.json')
        }
        Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter {
            $Uri -eq ('https://raw.githubusercontent.com/nod-systems/genesis/' + $script:Commit + '/Genesis-Portable.ps1')
        }
    }

    It 'refuse un programme différent de son empreinte publiée' {
        $script:Digest = '0' * 64
        { Receive-GenesisRelease -Commit $script:Commit -Directory $TestDrive } | Should -Throw '*SHA-256*'
        (Join-Path $TestDrive 'Genesis-Portable.ps1') | Should -Not -Exist
    }

    It 'refuse un manifeste incomplet avant de télécharger du code' {
        Mock Invoke-RestMethod { [pscustomobject]@{ schemaVersion = 1 } }
        { Receive-GenesisRelease -Commit $script:Commit -Directory $TestDrive } | Should -Throw '*manifeste*'
        Should -Invoke Invoke-WebRequest -Exactly -Times 0
    }

    It 'refuse une référence injectée dans les URL' {
        { Receive-GenesisRelease -Commit '../main' -Directory $TestDrive } | Should -Throw
        Should -Invoke Invoke-WebRequest -Exactly -Times 0
    }
}
