BeforeAll {
    $script:Repository = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Repository 'modules/Genesis/Genesis.psd1') -Force
}

Describe 'Profils et suivi des personnalisations' {
    It 'prevoit les reglages demandes dans le profil Windows' {
        $plan = Get-GenesisPlan -ProfilePath (Join-Path $script:Repository 'profiles/windows.json')
        $plan.Steps.Id | Should -Contain 'explorer-home'
        $plan.Steps.Id | Should -Contain 'windows-suggestions'
        $plan.Steps.Id | Should -Contain 'tray-icons'
        $plan.Steps.Id | Should -Contain 'taskbar-pins'
        $plan.Steps.Id | Should -Contain 'time-sync'
        $plan.Steps.Id | Should -Contain 'outlook-autodiscover'
        $plan.Steps.Id | Should -Contain 'power-ac'
        $plan.Steps.Id | Should -Contain 'local-user'
    }

    It 'décrit le réglage Outlook classique ExcludeExplicitO365Endpoint' {
        InModuleScope Genesis {
            $change = @(Get-GenesisRegistryChange -StepId 'outlook-autodiscover')
            $change.Count | Should -Be 1
            $change.Path | Should -Be 'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover'
            $change.Name | Should -Be 'ExcludeExplicitO365Endpoint'
            $change.Kind | Should -Be 'DWord'
            $change.Data | Should -Be 1
        }
    }

    It 'affiche la progression sans presenter une action en attente comme faite' {
        $state = [pscustomobject]@{ Steps = @(
            [pscustomobject]@{ Id = 'inventory'; Status = 'Completed'; Percent = 100; Message = ''; UndoStatus = 'NotAvailable' },
            [pscustomobject]@{ Id = 'taskbar-pins'; Status = 'NeedsAttention'; Percent = 0; Message = 'Office requis'; UndoStatus = 'NotAvailable' }
        ) }
        $view = Get-GenesisProgress -State $state
        $view.Completed | Should -Be 1
        $view.Percent | Should -Be 50
        $view.Rows[1].State | Should -Be 'À faire'
        $view.Rows[1].Detail | Should -Be 'Office requis'
    }

    It 'conserve les etapes independantes quand une action exige une intervention' {
        Mock Get-GenesisMachineId -ModuleName Genesis { 'fictive' }
        Mock Get-GenesisUserSid -ModuleName Genesis { 'user-fictif' }
        Mock Invoke-GenesisCustomization -ModuleName Genesis {
            param($StepId)
            if ($StepId -eq 'taskbar-pins') { return [pscustomobject]@{ Status = 'NeedsAttention'; Message = 'Office requis'; Percent = 0 } }
            [pscustomobject]@{ Status = 'Completed'; Message = 'Verifie'; Percent = 100 }
        }
        $path = Join-Path $TestDrive 'partial.json'
        '{"schemaVersion":1,"id":"partial","name":"Partiel","steps":["taskbar-pins","explorer-home"]}' | Set-Content $path
        $run = Start-GenesisRun -ProfilePath $path -DataRoot (Join-Path $TestDrive 'jobs')
        $run.Status | Should -Be 'NeedsAttention'
        $run.Steps[1].Status | Should -Be 'Completed'
    }

    It 'calcule le retour arriere uniquement sur les actions effectivement appliquees' {
        $state = [pscustomobject]@{ Status = 'Restored'; Steps = @(
            [pscustomobject]@{ Id = 'inventory'; Status = 'Completed'; Percent = 100; UndoStatus = 'NotAvailable' },
            [pscustomobject]@{ Id = 'explorer-home'; Status = 'Restored'; Percent = 100; UndoStatus = 'Restored' },
            [pscustomobject]@{ Id = 'taskbar-pins'; Status = 'NeedsAttention'; Percent = 0; UndoStatus = 'NotAvailable' }
        ) }
        $view = Get-GenesisProgress -State $state
        $view.Mode | Should -Be 'Undo'
        $view.Percent | Should -Be 100
        $view.Restored | Should -Be 1
        $view.Reversible | Should -Be 1
    }

    It 'ne reprend aucune action avec WhatIf' {
        Mock Get-GenesisMachineId -ModuleName Genesis { 'fictive' }
        Mock Get-GenesisUserSid -ModuleName Genesis { 'user-fictif' }
        Mock Invoke-GenesisCustomization -ModuleName Genesis { [pscustomobject]@{ Status = 'NeedsAttention'; Message = 'Prerequis'; Percent = 0 } }
        $path = Join-Path $TestDrive 'whatif.json'
        '{"schemaVersion":1,"id":"whatif","name":"Simulation","steps":["taskbar-pins"]}' | Set-Content $path
        $root = Join-Path $TestDrive 'simulation'
        $run = Start-GenesisRun -ProfilePath $path -DataRoot $root
        Resume-GenesisRun -RunId $run.RunId -DataRoot $root -WhatIf
        Should -Invoke Invoke-GenesisCustomization -ModuleName Genesis -Exactly -Times 1
        (Get-GenesisRun -RunId $run.RunId -DataRoot $root).Steps[0].Attempts | Should -Be 1
    }
}

Describe 'Veille secteur et sessions locales' {
    It 'decode lindex AC de powercfg en secondes' {
        InModuleScope Genesis {
            ConvertFrom-GenesisPowerQuery -Output 'Current AC Power Setting Index: 0x00000384' | Should -Be 900
        }
    }

    It 'desactive la mise en veille secteur et conserve la sauvegarde initiale' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisMachineId { 'machine-fictive' }
            Mock Get-GenesisUserSid { 'user-fictif' }
            Mock Set-GenesisStepProgress {}
            $script:PowerQueryCount = 0
            Mock Invoke-GenesisNativeCommand {
                param([string]$Arguments)
                if ($Arguments -like '/getactivescheme*') {
                    return [pscustomobject]@{ ExitCode = 0; Output = 'Power Scheme GUID: 11111111-2222-3333-4444-555555555555  (Balanced)'; ErrorOutput = '' }
                }
                if ($Arguments -like '/query*') {
                    $script:PowerQueryCount++
                    $index = if ($script:PowerQueryCount -eq 1) { '00000384' } else { '00000000' }
                    return [pscustomobject]@{ ExitCode = 0; Output = "Current AC Power Setting Index: 0x$index"; ErrorOutput = '' }
                }
                [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = '' }
            }
            $result = Set-GenesisPowerAc -RunDirectory $Root
            $result.Status | Should -Be 'Completed'
            (Get-Content (Join-Path $Root 'power-ac.json') -Raw | ConvertFrom-Json).BeforeAcStandbySeconds | Should -Be 900
            (Get-Content (Join-Path $Root 'power-ac.json') -Raw | ConvertFrom-Json).AfterAcStandbySeconds | Should -Be 0
        }
    }

    It 'demande nom et prenom sans enregistrer le mot de passe' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisMachineId { 'machine-fictive' }
            Mock Get-GenesisUserSid { 'user-fictif' }
            Mock Get-GenesisLocalUserRecord { $null }
            Mock Set-GenesisLocalUserVisibility {
                [pscustomobject]@{
                    UsersGroupName = 'Utilisateurs'
                    UserSwitchBefore = [pscustomobject]@{ Exists = $false; KeyExists = $false; Kind = ''; Data = $null }
                    UserSwitchAfter = [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 1 }
                }
            }
            Mock New-GenesisLocalUserNative {
                param([string]$Name)
                [pscustomobject]@{ Name = $Name; SID = [pscustomobject]@{ Value = 'S-1-5-21-fictif' } }
            }
            $script:PromptNumber = 0
            Mock Read-Host {
                param([string]$Prompt, [switch]$AsSecureString)
                $script:LastPrompt = $Prompt
                $script:LastWasSecure = [bool]$AsSecureString
                $script:PromptNumber++
                switch ($script:PromptNumber) {
                    1 { 'Exemple' }
                    2 { 'Prénom' }
                    3 { '' }
                    4 { 'O' }
                    default {
                        $secure = New-Object Security.SecureString
                        foreach ($character in 'test-only'.ToCharArray()) { $secure.AppendChar($character) }
                        $secure.MakeReadOnly()
                        $secure
                    }
                }
            }
            $result = New-GenesisLocalUser -RunDirectory $Root
            $result.Status | Should -Be 'Completed'
            $snapshotPath = Join-Path $Root 'local-user.json'
            $snapshot = Get-Content $snapshotPath -Raw | ConvertFrom-Json
            $snapshot.UserName | Should -Be 'prenom.exemple'
            $snapshot.UsersGroupName | Should -Be 'Utilisateurs'
            $snapshot.UserSwitchAfter.Data | Should -Be 1
            (Get-Content $snapshotPath -Raw) | Should -Not -Match 'Password'
        }
    }

    It 'prepare le compte pour le journal de connexion et conserve les sauvegardes' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisMachineId { 'machine-fictive' }
            Mock Get-GenesisUserSid { 'user-fictif' }
            Mock Get-GenesisLocalUserRecord { $null }
            Mock Set-GenesisLocalUserVisibility {
                [pscustomobject]@{
                    UsersGroupName = 'Utilisateurs'
                    UserSwitchBefore = [pscustomobject]@{ Exists = $false; KeyExists = $false; Kind = ''; Data = $null }
                    UserSwitchAfter = [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 1 }
                }
            }
            Mock New-GenesisLocalUserNative { [pscustomobject]@{ Name = 'prenom.exemple'; SID = [pscustomobject]@{ Value = 'S-1-5-21-fictif' } } }
            $script:PromptNumber = 0
            Mock Read-Host {
                param([string]$Prompt, [switch]$AsSecureString)
                if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'Invite de saisie absente.' }
                if ($script:PromptNumber -ge 4 -and -not $AsSecureString) { throw 'Le mot de passe doit être lu comme SecureString.' }
                $script:PromptNumber++
                switch ($script:PromptNumber) {
                    1 { 'Exemple' }
                    2 { 'Prénom' }
                    3 { '' }
                    4 { 'O' }
                    default {
                        $secure = New-Object Security.SecureString
                        foreach ($character in 'test-only'.ToCharArray()) { $secure.AppendChar($character) }
                        $secure.MakeReadOnly()
                        $secure
                    }
                }
            }
            $result = New-GenesisLocalUser -RunDirectory $Root
            $result.Status | Should -Be 'Completed'
            Should -Invoke Set-GenesisLocalUserVisibility -Exactly -Times 1 -ParameterFilter { $Name -eq 'prenom.exemple' }
            $snapshot = Get-Content (Join-Path $Root 'local-user.json') -Raw | ConvertFrom-Json
            $snapshot.UsersGroupName | Should -Be 'Utilisateurs'
            $snapshot.UserSwitchAfter.Data | Should -Be 1
        }
    }

    It 'ajoute un compte au groupe Utilisateurs et active UserSwitch' -Tag Windows {
        InModuleScope Genesis {
            $script:RegistryRecord = [pscustomobject]@{ Exists = $false; KeyExists = $false; Kind = ''; Data = $null }
            Mock Get-Command {
                param([string]$Name)
                if ($Name -in @('Get-LocalUser', 'Get-LocalGroup', 'Get-LocalGroupMember', 'Enable-LocalUser', 'Add-LocalGroupMember')) { [pscustomobject]@{ Name = $Name } }
            }
            Mock Get-LocalGroup { [pscustomobject]@{ Name = 'Utilisateurs'; SID = [pscustomobject]@{ Value = 'S-1-5-32-545' } } }
            Mock Get-LocalGroupMember { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-fictif' } } }
            Mock Get-LocalUser { [pscustomobject]@{ Name = 'prenom.exemple'; SID = [pscustomobject]@{ Value = 'S-1-5-21-fictif' } } }
            Mock Enable-LocalUser {}
            Mock Add-LocalGroupMember { param([string]$Group, [string]$Member) $script:AddGroup = $Group; $script:AddMember = $Member }
            Mock Get-GenesisRegistryValue { $script:RegistryRecord }
            Mock Set-GenesisRegistryValue { $script:RegistryRecord = [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 1 } }
            $result = Set-GenesisLocalUserVisibility -Name 'prenom.exemple'
            $result.UsersGroupName | Should -Be 'Utilisateurs'
            $result.UserSwitchBefore.Exists | Should -BeFalse
            $result.UserSwitchAfter.Data | Should -Be 1
            Should -Invoke Enable-LocalUser -Exactly -Times 1 -ParameterFilter { $Name -eq 'prenom.exemple' }
            Should -Invoke Add-LocalGroupMember -Exactly -Times 1
            $script:AddGroup | Should -Be 'Utilisateurs'
            $script:AddMember | Should -Be 'prenom.exemple'
            Should -Invoke Set-GenesisRegistryValue -Exactly -Times 1 -ParameterFilter { $Path -like '*LogonUI\UserSwitch' -and $Name -eq 'Enabled' -and $Record.Data -eq 1 }
        }
    }

    It 'retourne la cause native quand la creation de session echoue' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $caseRoot = Join-Path $Root 'native-failure'
            New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
            Mock Get-GenesisMachineId { 'machine-fictive' }
            Mock Get-GenesisUserSid { 'user-fictif' }
            Mock Get-GenesisLocalUserRecord { $null }
            Mock New-GenesisLocalUserNative { throw [InvalidOperationException]::new('Le mot de passe ne respecte pas la strategie locale.') }
            $script:PromptNumber = 0
            Mock Read-Host {
                param([string]$Prompt, [switch]$AsSecureString)
                if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'Invite de saisie absente.' }
                if ($script:PromptNumber -ge 4 -and -not $AsSecureString) { throw 'Le mot de passe doit être lu comme SecureString.' }
                $script:PromptNumber++
                switch ($script:PromptNumber) {
                    1 { 'Test' }
                    2 { 'Genesis' }
                    3 { '' }
                    4 { 'O' }
                    default {
                        $secure = New-Object Security.SecureString
                        foreach ($character in 'test-only'.ToCharArray()) { $secure.AppendChar($character) }
                        $secure.MakeReadOnly()
                        $secure
                    }
                }
            }
            $result = New-GenesisLocalUser -RunDirectory $caseRoot
            $result.Status | Should -Be 'NeedsAttention'
            $result.Message | Should -BeLike '*mot de passe*strategie locale*'
            Test-Path (Join-Path $caseRoot 'local-user.json') | Should -BeFalse
        }
    }

    It 'reverse uniquement le compte dont le SID a ete cree par Genesis' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisMachineId { 'machine-fictive' }
            Mock Get-GenesisUserSid { 'user-fictif' }
            $script:TestLocalUserRecord = [pscustomobject]@{
                Name = 'prenom.exemple'; SID = [pscustomobject]@{ Value = 'S-1-5-21-fictif' }; Removed = $false
            }
            Mock Get-GenesisLocalUserRecord {
                if (-not $script:TestLocalUserRecord.Removed) { $script:TestLocalUserRecord }
            }
            Mock Remove-GenesisLocalUserNative { $script:TestLocalUserRecord.Removed = $true }
            Write-GenesisJson -Path (Join-Path $Root 'local-user.json') -Value ([pscustomobject]@{
                SchemaVersion = 1; MachineId = 'machine-fictive'; UserSid = 'user-fictif'
                UserName = 'prenom.exemple'; CreatedSid = 'S-1-5-21-fictif'; Removed = $false
            })
            $result = Undo-GenesisCustomization -StepId 'local-user' -RunDirectory $Root
            $result.Status | Should -Be 'Restored'
            Should -Invoke Remove-GenesisLocalUserNative -Exactly -Times 1
        }
    }

    It 'refuse de supprimer la session admin' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisMachineId { 'machine-fictive' }
            Mock Get-GenesisUserSid { 'user-fictif' }
            Mock Get-GenesisLocalUserRecord { [pscustomobject]@{ Name = 'admin'; SID = [pscustomobject]@{ Value = 'S-1-5-21-admin' } } }
            Mock Remove-GenesisLocalUserNative { throw 'Ne doit jamais être appelé.' }
            Write-GenesisJson -Path (Join-Path $Root 'local-user.json') -Value ([pscustomobject]@{
                SchemaVersion = 1; MachineId = 'machine-fictive'; UserSid = 'user-fictif'
                UserName = 'admin'; CreatedSid = 'S-1-5-21-admin'; Removed = $false
            })
            $result = Undo-GenesisCustomization -StepId 'local-user' -RunDirectory $Root
            $result.Status | Should -Be 'Conflict'
            $result.Message | Should -BeLike '*protégée*'
            Should -Invoke Get-GenesisLocalUserRecord -Exactly -Times 0
            Should -Invoke Remove-GenesisLocalUserNative -Exactly -Times 0
        }
    }
}

Describe 'Sauvegarde et restauration du registre' {
    It 'repere les sauvegardes de registre et du service horaire' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            '{}' | Set-Content (Join-Path $Root 'explorer-home.registry.json')
            '{}' | Set-Content (Join-Path $Root 'time-service.json')
            Test-GenesisUndoAvailable -StepId 'explorer-home' -RunDirectory $Root | Should -BeTrue
            Test-GenesisUndoAvailable -StepId 'time-sync' -RunDirectory $Root | Should -BeTrue
            Test-GenesisUndoAvailable -StepId 'taskbar-pins' -RunDirectory $Root | Should -BeFalse
        }
    }

    BeforeEach {
        InModuleScope Genesis {
            $script:TestRegistry = @{}
            Mock Get-GenesisUserSid { 'user-fictif' }
            Mock Get-GenesisMachineId { 'machine-fictive' }
            Mock Get-GenesisRegistryValue {
                param($Path, $Name)
                $key = $Path + '|' + $Name
                if ($script:TestRegistry.ContainsKey($key)) { return $script:TestRegistry[$key] }
                [pscustomobject]@{ Exists = $false; KeyExists = $false; Kind = ''; Data = $null }
            }
            Mock Set-GenesisRegistryValue {
                param($Path, $Name, $Record)
                $key = $Path + '|' + $Name
                if ($Record.Exists) { $script:TestRegistry[$key] = $Record }
                else { $script:TestRegistry.Remove($key) }
            }
        }
    }

    It 'retire une valeur creee par Genesis lors de la restauration' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $file = Join-Path $Root 'snapshot.json'
            $changes = @([pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Kind = 'DWord'; Data = 1 })
            Invoke-GenesisRegistryTransaction -Changes $changes -SnapshotPath $file
            $script:TestRegistry.Count | Should -Be 1
            $result = Undo-GenesisRegistryTransaction -SnapshotPath $file
            $result.ConflictCount | Should -Be 0
            $script:TestRegistry.Count | Should -Be 0
        }
    }

    It 'accepte le defaut zero recree par Windows pour une icone de notification' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $path = 'HKCU:\Control Panel\NotifyIconSettings\12345'
            $file = Join-Path $Root 'tray-default.json'
            Invoke-GenesisRegistryTransaction -Changes @([pscustomobject]@{ Path = $path; Name = 'IsPromoted'; Kind = 'DWord'; Data = 1 }) -SnapshotPath $file
            Mock Set-GenesisRegistryValue {
                param($Path, $Name)
                $script:TestRegistry[$Path + '|' + $Name] = [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 0 }
            }
            (Undo-GenesisRegistryTransaction -SnapshotPath $file).ConflictCount | Should -Be 0
            $script:TestRegistry[$path + '|IsPromoted'].Data | Should -Be 0
        }
    }

    It 'restaure le type et la valeur precedente au lieu dun defaut suppose' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            $script:TestRegistry[$path + '|LaunchTo'] = [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'String'; Data = 'ancienne valeur' }
            $file = Join-Path $Root 'typed.json'
            Invoke-GenesisRegistryTransaction -Changes @([pscustomobject]@{ Path = $path; Name = 'LaunchTo'; Kind = 'DWord'; Data = 1 }) -SnapshotPath $file
            Undo-GenesisRegistryTransaction -SnapshotPath $file | Out-Null
            $script:TestRegistry[$path + '|LaunchTo'].Kind | Should -Be 'String'
            $script:TestRegistry[$path + '|LaunchTo'].Data | Should -Be 'ancienne valeur'
        }
    }

    It 'necrase pas une modification posterieure de lutilisateur' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            $file = Join-Path $Root 'conflict.json'
            Invoke-GenesisRegistryTransaction -Changes @([pscustomobject]@{ Path = $path; Name = 'LaunchTo'; Kind = 'DWord'; Data = 1 }) -SnapshotPath $file
            $script:TestRegistry[$path + '|LaunchTo'] = [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 2 }
            $result = Undo-GenesisRegistryTransaction -SnapshotPath $file
            $result.ConflictCount | Should -Be 1
            $script:TestRegistry[$path + '|LaunchTo'].Data | Should -Be 2
        }
    }

    It 'conserve la premiere sauvegarde lors dune nouvelle tentative' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            $file = Join-Path $Root 'retry.json'
            $changes = @([pscustomobject]@{ Path = $path; Name = 'LaunchTo'; Kind = 'DWord'; Data = 1 })
            Invoke-GenesisRegistryTransaction -Changes $changes -SnapshotPath $file
            Invoke-GenesisRegistryTransaction -Changes $changes -SnapshotPath $file
            (Get-Content $file -Raw | ConvertFrom-Json).Changes[0].Before.Exists | Should -BeFalse
            Undo-GenesisRegistryTransaction -SnapshotPath $file | Out-Null
            $script:TestRegistry.Count | Should -Be 0
        }
    }

    It 'refuse de restaurer la sauvegarde dune autre session utilisateur' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $file = Join-Path $Root 'user.json'
            Invoke-GenesisRegistryTransaction -Changes @([pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Kind = 'DWord'; Data = 1 }) -SnapshotPath $file
            Mock Get-GenesisUserSid { 'autre-user' }
            { Undo-GenesisRegistryTransaction -SnapshotPath $file } | Should -Throw '*utilisateur*'
        }
    }

    It 'ne marque pas restauree une ecriture qui na pas pris effet' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $file = Join-Path $Root 'failed-restore.json'
            Invoke-GenesisRegistryTransaction -Changes @([pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Kind = 'DWord'; Data = 1 }) -SnapshotPath $file
            Mock Set-GenesisRegistryValue {}
            { Undo-GenesisRegistryTransaction -SnapshotPath $file } | Should -Throw '*Vérification*'
            (Get-Content $file -Raw | ConvertFrom-Json).Changes[0].Restored | Should -BeFalse
        }
    }

    It 'refuse une cible de registre hors des reglages autorises' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $file = Join-Path $Root 'bad.json'
            { Invoke-GenesisRegistryTransaction -Changes @([pscustomobject]@{ Path = 'HKLM:\SAM'; Name = 'arbitrary'; Kind = 'DWord'; Data = 1 }) -SnapshotPath $file } | Should -Throw '*autoris*'
        }
    }
}

Describe 'Acces natif au registre sous Windows' {
    It 'ecrit et retire reellement une valeur dans une cle de test isolee' -Skip:($env:OS -ne 'Windows_NT') {
        InModuleScope Genesis {
            $path = 'HKCU:\Software\Genesis\Tests\' + [guid]::NewGuid().ToString('N')
            try {
                $before = Get-GenesisRegistryValue -Path $path -Name 'RoundTrip'
                Set-GenesisRegistryValue -Path $path -Name 'RoundTrip' -Record ([pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 7 })
                (Get-GenesisRegistryValue -Path $path -Name 'RoundTrip').Data | Should -Be 7
                Set-GenesisRegistryValue -Path $path -Name 'RoundTrip' -Record $before
                (Get-GenesisRegistryValue -Path $path -Name 'RoundTrip').Exists | Should -BeFalse
            }
            finally { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Prerequis Office et protocole horaire' {
    It 'utilise la strategie Widgets sur Pro plutot que la valeur protegee' {
        InModuleScope Genesis {
            Mock Get-ItemProperty { [pscustomobject]@{ EditionID = 'Professional' } }
            $changes = @(Get-GenesisRegistryChange -StepId 'taskbar-controls')
            $changes.Name | Should -Contain 'AllowNewsAndInterests'
            $changes.Name | Should -Not -Contain 'TaskbarDa'
        }
    }

    It 'decode lheure NTP et sa fraction de seconde en UTC' {
        InModuleScope Genesis {
            $packet = New-Object byte[] 48
            $packet[0] = 36; $packet[1] = 2
            $origin = [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8)
            [Array]::Copy($origin, 0, $packet, 24, 8)
            $seconds = [uint32](([datetime]'2026-10-12T10:00:00Z').ToUniversalTime() - ([datetime]'1900-01-01T00:00:00Z').ToUniversalTime()).TotalSeconds
            for ($i = 0; $i -lt 4; $i++) { $packet[40 + $i] = [byte](($seconds -shr (24 - $i * 8)) -band 255) }
            $packet[44] = 128
            $utc = ConvertFrom-GenesisNtpPacket -Packet $packet -Origin $origin
            $utc.Kind | Should -Be 'Utc'
            $utc.ToString('yyyy-MM-dd HH:mm:ss.fff') | Should -Be '2026-10-12 10:00:00.500'
        }
    }

    It 'ne modifie pas les epingles si Office classique est absent' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisOfficeApp { @() }
            Mock Invoke-GenesisRegistryTransaction {}
            $result = Set-GenesisTaskbarLayout -RunDirectory $Root
            $result.Status | Should -Be 'NeedsAttention'
            Should -Invoke Invoke-GenesisRegistryTransaction -Exactly -Times 0
        }
    }

    It 'genere les cinq epingles dans lordre et exclut le nouvel Outlook' {
        $xml = New-GenesisTaskbarXml -Links @('C:\Test\Word.lnk', 'C:\Test\Excel.lnk', 'C:\Test\PowerPoint.lnk', 'C:\Test\Outlook classique.lnk')
        $xml | Should -Match 'PinListPlacement="Replace"'
        $xml | Should -Match 'Microsoft.Windows.Explorer'
        ([xml]$xml).GetElementsByTagName('taskbar:DesktopApp').Count | Should -Be 5
        $xml | Should -Not -Match 'Microsoft.OutlookForWindows'
    }

    It 'rejette une reponse NTP non synchronisee' {
        InModuleScope Genesis {
            $packet = New-Object byte[] 48
            $packet[0] = 228
            $packet[1] = 2
            { ConvertFrom-GenesisNtpPacket -Packet $packet -Origin (New-Object byte[] 8) } | Should -Throw
        }
    }

    It 'refuse une reponse NTP qui ne correspond pas a la requete' {
        InModuleScope Genesis {
            $packet = New-Object byte[] 48
            $packet[0] = 36
            $packet[1] = 2
            $origin = New-Object byte[] 8
            $origin[0] = 99
            { ConvertFrom-GenesisNtpPacket -Packet $packet -Origin $origin } | Should -Throw
        }
    }

    It 'selectionne uniquement linstallateur PDFCraft Windows x64' {
        InModuleScope Genesis {
            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    tag_name = 'v9.9.9'
                    assets = @(
                        [pscustomobject]@{ name = 'pdfcraft-9.9.9-windows-arm64.msi'; browser_download_url = 'https://example.invalid/arm.msi'; digest = 'sha256:arm' }
                        [pscustomobject]@{ name = 'pdfcraft-9.9.9-windows-x64.msi'; browser_download_url = 'https://example.invalid/x64.msi'; digest = 'sha256:1234' }
                    )
                }
            }
            $asset = Get-GenesisPdfCraftAsset
            $asset.Name | Should -Be 'pdfcraft-9.9.9-windows-x64.msi'
            $asset.Version | Should -Be 'v9.9.9'
            $asset.Sha256 | Should -Be '1234'
        }
    }

    It 'installe NetBird et prépare le serveur sans lancer de connexion' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Read-Host { 'https://private.example.test:443' }
            Mock Get-GenesisNetBirdPath { 'C:\Program Files\NetBird\netbird.exe' }
            Mock Set-GenesisStepProgress {}
            Mock Set-GenesisNetBirdManagementServer {
                param([string]$ManagementUrl)
                $script:NetBirdManagementUrl = $ManagementUrl
                [pscustomobject]@{
                    DefaultConfigPath = 'C:\ProgramData\NetBird\default.json'
                    PolicyPath = 'HKLM:\SOFTWARE\Policies\NetBird'
                    Configured = $true
                }
            }
            $script:NetBirdNativeCalls = @()
            Mock Invoke-GenesisNativeCommand {
                $script:NetBirdNativeCalls += ,$args
                [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = '' }
            }
            $result = Install-GenesisNetBird -RunDirectory $Root
            $result.Status | Should -Be 'Completed'
            $script:NetBirdManagementUrl | Should -Be 'https://private.example.test:443'
            @($script:NetBirdNativeCalls).Count | Should -Be 0
            $statePath = Join-Path $Root 'software-netbird.json'
            (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8) | Should -Not -Match 'private\.example\.test'
            (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8) | Should -Match 'ManagementUrlConfigured'
        }
    }

    It 'écrit la configuration NetBird avec une URL structurée et une stratégie machine' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Set-GenesisRegistryValue {}
            $result = Set-GenesisNetBirdManagementServer -ManagementUrl 'https://private.example.test:443' -ConfigRoot $Root
            $config = Get-Content -LiteralPath (Join-Path $Root 'default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $config.ManagementURL.Scheme | Should -Be 'https'
            $config.ManagementURL.Host | Should -Be 'private.example.test:443'
            $result.Configured | Should -BeTrue
            Should -Invoke Set-GenesisRegistryValue -Exactly -Times 1 -ParameterFilter {
                $Path -eq 'HKLM:\SOFTWARE\Policies\NetBird' -and $Name -eq 'ManagementURL' -and
                $Record.Kind -eq 'String' -and $Record.Data -eq 'https://private.example.test:443'
            }
        }
    }

    It 'accepte un téléchargement déjà présent quand lempreinte correspond' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $path = Join-Path $Root 'artifact.bin'
            [IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $result = Save-GenesisDownload -Uri 'https://example.invalid/artifact.bin' -Path $path -ExpectedSha256 $hash
            $result.Path | Should -Be $path
            $result.Sha256 | Should -Be $hash
        }
    }

    It 'utilise curl.exe en priorite sans lancer BITS et valide le fichier' -Tag Windows {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisCurlPath { 'C:\Windows\System32\curl.exe' }
            Mock Start-BitsTransfer {
                throw 'BITS ne doit plus etre appele.'
            }
            Mock Invoke-GenesisNativeCommand {
                param([string]$Arguments)
                if ($Arguments -match '--output\s+"(?<path>[^"]+)"') { [IO.File]::WriteAllBytes($Matches['path'], [byte[]](4, 5, 6)) }
                [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = '' }
            }
            $path = Join-Path $Root 'bits.bin'
            $expected = (Get-FileHash -InputStream ([IO.MemoryStream]::new([byte[]](4, 5, 6))) -Algorithm SHA256).Hash
            $result = Save-GenesisDownload -Uri 'https://example.invalid/bits.bin' -Path $path -ExpectedSha256 $expected
            $result.Method | Should -Be 'curl.exe'
            $result.Sha256 | Should -Be $expected
            $path | Should -Exist
            Should -Invoke Start-BitsTransfer -Exactly -Times 0
            Should -Invoke Invoke-GenesisNativeCommand -Exactly -Times 1
        }
    }

    It 'utilise Invoke-WebRequest en dernier recours quand curl.exe est indisponible' -Tag Windows {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisCurlPath { $null }
            Mock Start-BitsTransfer { throw 'BITS ne doit plus etre appele.' }
            Mock Invoke-WebRequest {
                param([string]$OutFile)
                [IO.File]::WriteAllBytes($OutFile, [byte[]](7, 8, 9))
            }
            $path = Join-Path $Root 'curl.bin'
            $expected = (Get-FileHash -InputStream ([IO.MemoryStream]::new([byte[]](7, 8, 9))) -Algorithm SHA256).Hash
            $result = Save-GenesisDownload -Uri 'https://example.invalid/curl.bin' -Path $path -ExpectedSha256 $expected
            $result.Method | Should -Be 'WebRequest'
            $result.Sha256 | Should -Be $expected
            Should -Invoke Invoke-WebRequest -Exactly -Times 1
            Should -Invoke Start-BitsTransfer -Exactly -Times 0
        }
    }

    It 'conserve un telechargement curl partiel pour la reprise' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisCurlPath { 'C:\Windows\System32\curl.exe' }
            Mock Invoke-GenesisNativeCommand {
                param([string]$Arguments)
                $Arguments | Should -Match '--continue-at -'
                if ($Arguments -match '--output\s+"(?<path>[^"]+)"') { [IO.File]::WriteAllBytes($Matches['path'], [byte[]](10, 11, 12)) }
                [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = '' }
            }
            $path = Join-Path $Root 'resume.bin'
            $result = Save-GenesisDownload -Uri 'https://example.invalid/resume.bin' -Path $path
            $result.Method | Should -Be 'curl.exe'
            $path | Should -Exist
        }
    }

    It 'convertit une commande MSI en desinstallation silencieuse' {
        InModuleScope Genesis {
            $parsed = ConvertFrom-GenesisUninstallCommand -Command 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}'
            $parsed.FilePath | Should -Match '(?i)msiexec\.exe$'
            $parsed.Arguments | Should -Match '(?i)/X\{11111111-2222-3333-4444-555555555555\}'
            $parsed.Arguments | Should -Match '(?i)/qn'
            $parsed.Arguments | Should -Match '(?i)/norestart'
        }
    }

    It 'verifie quun programme selectionne a disparu apres sa desinstallation' {
        InModuleScope Genesis {
            Mock Invoke-GenesisNativeCommand { [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = '' } }
            Mock Get-GenesisInstalledProgram { @() }
            $program = [pscustomobject]@{
                Name = 'Programme de test'; RegistryPath = 'HKLM:\SOFTWARE\Test';
                UninstallString = 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}'; QuietUninstallString = ''
            }
            $result = Invoke-GenesisProgramUninstall -Program $program
            $result.Status | Should -Be 'Completed'
            Should -Invoke Invoke-GenesisNativeCommand -Exactly -Times 1
        }
    }

    It 'dedoublonne les logiciels presents dans les ruches 32 et 64 bits' {
        InModuleScope Genesis {
            $oldOs = $env:OS
            $env:OS = 'Windows_NT'
            try {
                $entry = [pscustomobject]@{ PSPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{TEST}' }
                Mock Get-ChildItem { param([string]$LiteralPath) if ($LiteralPath -match '\\Uninstall$') { return $entry } }
                Mock Get-ItemProperty {
                    [pscustomobject]@{
                        DisplayName = 'Programme de test'; DisplayVersion = '1.0'; Publisher = 'Example Publisher'
                        UninstallString = 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}'
                        QuietUninstallString = ''; SystemComponent = 0; ReleaseType = ''
                    }
                }
                $programs = @(Get-GenesisInstalledProgram)
                $programs.Count | Should -Be 1
                $programs[0].Name | Should -Be 'Programme de test'
                $programs[0].CanUninstall | Should -BeTrue
            }
            finally { $env:OS = $oldOs }
        }
    }
}

Describe 'Source publique Office LTSC' {
    It 'résout uniquement un installateur ODT HTTPS du serveur officiel Microsoft' {
        InModuleScope Genesis {
            Mock Invoke-WebRequest {
                [pscustomobject]@{ Links = @(
                    [pscustomobject]@{ href = 'https://example.invalid/officedeploymenttool.exe' }
                    [pscustomobject]@{ href = 'https://download.microsoft.com/download/example/officedeploymenttool_example.exe' }
                ) }
            }
            Get-GenesisOfficeDeploymentToolUri | Should -Be 'https://download.microsoft.com/download/example/officedeploymenttool_example.exe'
        }
    }

    It 'refuse une page qui ne contient aucun téléchargement Microsoft officiel' {
        InModuleScope Genesis {
            Mock Invoke-WebRequest { [pscustomobject]@{ Links = @([pscustomobject]@{ href = 'https://example.invalid/officedeploymenttool.exe' }) } }
            { Get-GenesisOfficeDeploymentToolUri } | Should -Throw '*Microsoft*'
        }
    }

    It 'refuse un exécutable sans signature Microsoft valide' -Tag Windows {
        InModuleScope Genesis {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
            { Assert-GenesisMicrosoftSignature -Path 'example.exe' } | Should -Throw '*signature Microsoft*'
        }
    }

    It 'installe depuis ODT avec une configuration générique sans clé de licence' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $script:OfficeInstalled = $false
            Mock Get-GenesisOfficeInstallationStatus {
                if ($script:OfficeInstalled) { return @(1, 2, 3, 4) }
                return @()
            }
            Mock Get-GenesisOfficeDeploymentToolUri { 'https://download.microsoft.com/download/example/officedeploymenttool_example.exe' }
            Mock Save-GenesisDownload {
                param($Path)
                [IO.File]::WriteAllBytes($Path, [byte[]](1, 2, 3))
                [pscustomobject]@{ Uri = 'https://download.microsoft.com/download/example/officedeploymenttool_example.exe'; Path = $Path; Sha256 = 'fictitious' }
            }
            Mock Assert-GenesisMicrosoftSignature {}
            Mock Set-GenesisStepProgress {}
            Mock Invoke-GenesisNativeCommand {
                param($FilePath, $Arguments)
                if ($Arguments -match '/extract:') {
                    $setup = Join-Path (Join-Path (Split-Path -Parent $FilePath) 'odt') 'setup.exe'
                    [IO.File]::WriteAllBytes($setup, [byte[]](1, 2, 3))
                }
                if ($Arguments -match '/configure') { $script:OfficeInstalled = $true }
                [pscustomobject]@{ ExitCode = 0 }
            }
            $result = Install-GenesisOffice2024 -RunDirectory $Root
            $result.Status | Should -Be 'Completed'
            $config = Get-Content -LiteralPath (Join-Path (Join-Path $Root 'software') 'office-2024.xml') -Raw
            $config | Should -Match 'Standard2024Volume'
            $config | Should -Match 'PerpetualVL2024'
            $config | Should -Match 'fr-fr'
            $config | Should -Not -Match 'PIDKEY|RemoveMSI|SourcePath|AUTOACTIVATE'
            Should -Invoke Assert-GenesisMicrosoftSignature -Exactly -Times 2
            Should -Invoke Invoke-GenesisNativeCommand -Exactly -Times 2
        }
    }
}

Describe 'Signatures des installateurs' {
    It 'accepte uniquement l''éditeur attendu' -Tag Windows {
        InModuleScope Genesis {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Google LLC, O=Google LLC, L=Mountain View, C=US' } } }
            { Assert-GenesisPublisherSignature -Path 'chrome.msi' -Publisher 'Google LLC' } | Should -Not -Throw
            { Assert-GenesisPublisherSignature -Path 'chrome.msi' -Publisher 'Mozilla Corporation' } | Should -Throw '*Mozilla Corporation*'
        }
    }

    It 'refuse une signature invalide même avec le bon éditeur' -Tag Windows {
        InModuleScope Genesis {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=NetBird GmbH, O=NetBird GmbH' } } }
            { Assert-GenesisPublisherSignature -Path 'netbird.msi' -Publisher 'NetBird GmbH' } | Should -Throw '*non exécuté*'
        }
    }

    It 'n''installe pas un navigateur dont la signature est refusée' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $runDirectory = $Root
            Mock Save-GenesisDownload { param($Path) [pscustomobject]@{ Path = $Path; Uri = 'https://dl.google.com/example.msi'; Sha256 = 'fictitious' } }
            Mock Assert-GenesisPublisherSignature { throw 'signature refusée' }
            Mock Set-GenesisStepProgress {}
            Mock Invoke-GenesisNativeCommand { [pscustomobject]@{ ExitCode = 0 } }
            { Install-GenesisBrowser -RunDirectory $runDirectory -Choice 'Chrome' } | Should -Throw '*signature refusée*'
            Should -Invoke Assert-GenesisPublisherSignature -Exactly -Times 1 -ParameterFilter { $Publisher -eq 'Google LLC' }
            Should -Invoke Invoke-GenesisNativeCommand -Exactly -Times 0
        }
    }

    It 'vérifie l''éditeur Mozilla pour Firefox' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $runDirectory = $Root
            Mock Save-GenesisDownload { param($Path) [pscustomobject]@{ Path = $Path; Uri = 'https://download.mozilla.org/example'; Sha256 = 'fictitious' } }
            Mock Assert-GenesisPublisherSignature { throw 'signature refusée' }
            Mock Invoke-GenesisNativeCommand { [pscustomobject]@{ ExitCode = 0 } }
            { Install-GenesisBrowser -RunDirectory $runDirectory -Choice 'Firefox' } | Should -Throw
            Should -Invoke Assert-GenesisPublisherSignature -Exactly -Times 1 -ParameterFilter { $Publisher -eq 'Mozilla Corporation' }
            Should -Invoke Invoke-GenesisNativeCommand -Exactly -Times 0
        }
    }

    It 'n''installe pas NetBird dont la signature est refusée' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            $runDirectory = $Root
            Mock Read-GenesisNetBirdManagementUrl { 'https://netbird.example.test:443' }
            Mock Set-GenesisNetBirdManagementServer { [pscustomobject]@{ Configured = $true } }
            Mock Get-GenesisNetBirdPath { $null }
            Mock Set-GenesisStepProgress {}
            Mock Save-GenesisDownload { param($Path) [pscustomobject]@{ Path = $Path; Uri = 'https://pkgs.netbird.io/windows/msi/x64'; Sha256 = 'fictitious' } }
            Mock Assert-GenesisPublisherSignature { throw 'signature refusée' }
            Mock Invoke-GenesisNativeCommand { [pscustomobject]@{ ExitCode = 0 } }
            { Install-GenesisNetBird -RunDirectory $runDirectory } | Should -Throw '*signature refusée*'
            Should -Invoke Assert-GenesisPublisherSignature -Exactly -Times 1 -ParameterFilter { $Publisher -eq 'NetBird GmbH' }
            Should -Invoke Invoke-GenesisNativeCommand -Exactly -Times 0
        }
    }
}

Describe 'Lecteurs PDF et winget' {
    It 'recherche le lecteur Acrobat 64 bits unifié' -Tag Windows {
        InModuleScope Genesis {
            Mock Get-GenesisExecutablePath { param($Names, $Candidates) $script:AcrobatCandidates = $Candidates; $script:AcrobatNames = $Names; $null }
            Get-GenesisPdfReaderPath -Reader 'Acrobat' | Out-Null
            ($script:AcrobatCandidates -join '|') | Should -Match ([regex]::Escape('Adobe\Acrobat DC\Acrobat\Acrobat.exe'))
            $script:AcrobatNames | Should -Contain 'Acrobat.exe'
        }
    }

    It 'considère un paquet winget déjà installé comme terminé' {
        InModuleScope Genesis {
            Mock Get-Command { [pscustomobject]@{ Name = 'winget.exe'; Source = 'winget.exe' } } -ParameterFilter { $Name -eq 'winget.exe' }
            Mock Invoke-GenesisNativeCommand { [pscustomobject]@{ ExitCode = -1978335135; Output = ''; ErrorOutput = '' } }
            (Install-GenesisWingetPackage -Id 'Exemple.Paquet').Status | Should -Be 'Completed'
        }
    }

    It 'considère l''absence de mise à jour winget applicable comme terminée' {
        InModuleScope Genesis {
            Mock Get-Command { [pscustomobject]@{ Name = 'winget.exe'; Source = 'winget.exe' } } -ParameterFilter { $Name -eq 'winget.exe' }
            Mock Invoke-GenesisNativeCommand { [pscustomobject]@{ ExitCode = -1978335189; Output = ''; ErrorOutput = '' } }
            (Install-GenesisWingetPackage -Id 'Exemple.Paquet').Status | Should -Be 'Completed'
        }
    }

    It 'signale toujours un échec winget réel' {
        InModuleScope Genesis {
            Mock Get-Command { [pscustomobject]@{ Name = 'winget.exe'; Source = 'winget.exe' } } -ParameterFilter { $Name -eq 'winget.exe' }
            Mock Invoke-GenesisNativeCommand { [pscustomobject]@{ ExitCode = 1603; Output = ''; ErrorOutput = '' } }
            { Install-GenesisWingetPackage -Id 'Exemple.Paquet' } | Should -Throw '*1603*'
        }
    }
}

Describe 'Journal Debloat' {
    It 'prépare le journal dans le répertoire de données par défaut' {
        InModuleScope Genesis -Parameters @{ Root = (Join-Path $TestDrive 'genesis-data') } {
            param($Root)
            Mock Resolve-GenesisDataRoot { $Root }
            Mock Get-GenesisInstalledProgram { @() }
            Mock Write-Host {}
            Show-GenesisDebloatMenu
            Test-Path -LiteralPath (Join-Path $Root 'debloat') -PathType Container | Should -BeTrue
            Should -Invoke Resolve-GenesisDataRoot -Exactly -Times 1 -ParameterFilter { [string]::IsNullOrWhiteSpace($DataRoot) }
        }
    }
}

Describe 'Protection du répertoire de données' {
    It 'retire les droits ajoutés avant Genesis et rétablit le propriétaire' -Tag Windows {
        InModuleScope Genesis -Parameters @{ Root = (Join-Path $TestDrive 'acl-root') } {
            param($Root)
            $runs = Join-Path $Root 'runs'
            New-Item -Path $runs -ItemType Directory -Force | Out-Null
            $file = Join-Path $runs 'state.json'
            Set-Content -LiteralPath $file -Value '{}'
            $everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
            foreach ($path in @($Root, $file)) {
                $acl = Get-Acl -LiteralPath $path
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($everyone, 'FullControl', 'Allow')))
                Set-Acl -LiteralPath $path -AclObject $acl
            }

            Protect-GenesisDataRoot -DataRoot $Root

            $rootAcl = Get-Acl -LiteralPath $Root
            $rootAcl.AreAccessRulesProtected | Should -BeTrue
            $rootSids = @($rootAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value }) | Sort-Object -Unique
            $rootSids | Should -Be @('S-1-5-18', 'S-1-5-32-544')
            $fileAcl = Get-Acl -LiteralPath $file
            @($fileAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])).Count | Should -Be 0
            @($fileAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-1-0' }).Count | Should -Be 0
            $fileAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        }
    }

    It 'refuse une jonction dans le répertoire de données' -Tag Windows {
        InModuleScope Genesis -Parameters @{ Root = (Join-Path $TestDrive 'acl-junction'); Target = (Join-Path $TestDrive 'ailleurs') } {
            param($Root, $Target)
            New-Item -Path $Root, $Target -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $Root 'runs') -ItemType Junction -Value $Target | Out-Null
            { Protect-GenesisDataRoot -DataRoot $Root } | Should -Throw '*jonction*'
        }
    }
}

Describe 'Capture FOG' {
    It 'normalise l''adresse du serveur FOG saisie par le technicien' {
        InModuleScope Genesis {
            ConvertTo-GenesisFogServerUrl -Value ' fog.example.test ' | Should -Be 'http://fog.example.test'
            ConvertTo-GenesisFogServerUrl -Value 'http://fog.example.test/fog/management/index.php' | Should -Be 'http://fog.example.test'
            ConvertTo-GenesisFogServerUrl -Value 'https://fog.example.test:8443/' | Should -Be 'https://fog.example.test:8443'
            { ConvertTo-GenesisFogServerUrl -Value 'fog.example.test/fog/?node=home' } | Should -Throw '*requête*'
            { ConvertTo-GenesisFogServerUrl -Value 'ftp://fog.example.test' } | Should -Throw '*invalide*'
        }
    }

    It 'choisit l''entrée UEFI réseau IPv4 dans une liste bcdedit française' {
        InModuleScope Genesis {
            $text = @(
                'Gestionnaire de démarrage du microprogramme', '--------------------------------', 'identificateur          {fwbootmgr}', 'displayorder            {bootmgr}', '                        {11111111-1111-1111-1111-111111111111}', '',
                'Gestionnaire de démarrage Windows', '--------------------------------', 'identificateur          {bootmgr}', 'description             Windows Boot Manager', '',
                'Application du microprogramme (101fffff)', '--------------------------------', 'identificateur          {22222222-2222-2222-2222-222222222222}', 'description             UEFI: PXE IPv6 Intel(R) Ethernet', '',
                'Application du microprogramme (101fffff)', '--------------------------------', 'identificateur          {11111111-1111-1111-1111-111111111111}', 'description             UEFI: PXE IPv4 Intel(R) Ethernet'
            ) -join "`r`n"
            $entries = @(ConvertFrom-GenesisFirmwareBootList -Text $text)
            $entries.Count | Should -Be 4
            (Select-GenesisPxeBootEntry -Entries $entries).Id | Should -Be '{11111111-1111-1111-1111-111111111111}'
            Select-GenesisPxeBootEntry -Entries @($entries[1]) | Should -BeNullOrEmpty
        }
    }

    It 'explique quand FOG renvoie sa page web au lieu de l''API' {
        InModuleScope Genesis {
            Mock Invoke-RestMethod { '<!DOCTYPE html><html><body>FOG Project</body></html>' }
            $settings = [pscustomobject]@{ Server = 'http://fog.example.test'; ApiToken = 'api-fictive'; UserToken = 'user-fictif'; ImageName = 'Win11-Ref' }
            { Invoke-GenesisFogApi -Settings $settings -Path '/fog/image' } | Should -Throw '*FOG_API_ENABLED*'
        }
    }

    It 'réutilise un poste FOG connu par son adresse MAC et lui associe l''image' {
        InModuleScope Genesis {
            $settings = [pscustomobject]@{ Server = 'http://fog.example.test'; ApiToken = 'api-fictive'; UserToken = 'user-fictif'; ImageName = 'Win11-Ref' }
            Mock Get-GenesisFogItem {
                param($Kind)
                switch ($Kind) {
                    'macaddressassociation' { @([pscustomobject]@{ hostID = 7; mac = 'AA:BB:CC:00:11:22' }) }
                    'host' { @([pscustomobject]@{ id = 7; name = 'PC-ANCIEN'; imageID = 1 }) }
                }
            }
            $script:FogCalls = @()
            Mock Invoke-GenesisFogApi { $script:FogCalls += ,([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body }) }
            $result = Register-GenesisFogHost -Settings $settings -Mac 'aa-bb-cc-00-11-22' -ImageId 4 -Name 'PC-NEUF'
            $result.Id | Should -Be 7
            $result.Created | Should -BeFalse
            $script:FogCalls.Count | Should -Be 1
            $script:FogCalls[0].Method | Should -Be 'PUT'
            $script:FogCalls[0].Path | Should -Be '/fog/host/7/edit'
            $script:FogCalls[0].Body.imageID | Should -Be 4
        }
    }

    It 'enregistre un nouveau poste FOG avec un nom unique' {
        InModuleScope Genesis {
            $settings = [pscustomobject]@{ Server = 'http://fog.example.test'; ApiToken = 'api-fictive'; UserToken = 'user-fictif'; ImageName = 'Win11-Ref' }
            Mock Get-GenesisFogItem {
                param($Kind)
                if ($Kind -eq 'host') { @([pscustomobject]@{ id = 3; name = 'DESKTOP-ABC'; imageID = 4 }) } else { @() }
            }
            $script:FogCalls = @()
            Mock Invoke-GenesisFogApi { $script:FogCalls += ,([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body }); [pscustomobject]@{ id = 12 } }
            $result = Register-GenesisFogHost -Settings $settings -Mac 'aabbcc001122' -ImageId 4 -Name 'DESKTOP-ABC'
            $result.Id | Should -Be 12
            $result.Created | Should -BeTrue
            $script:FogCalls[0].Path | Should -Be '/fog/host/create'
            $script:FogCalls[0].Body.name | Should -Be 'GAABBCC001122'
            $script:FogCalls[0].Body.macs | Should -Be @('aa:bb:cc:00:11:22')
        }
    }

    Context 'Déroulement de la capture' {
        BeforeEach {
            Mock Read-GenesisFogConfigurationFile -ModuleName Genesis { [pscustomobject]@{ Server = 'http://fog.example.test'; ApiToken = 'api-fictive'; UserToken = 'user-fictif'; ImageName = 'Win11-Ref' } }
            Mock Set-GenesisStepProgress -ModuleName Genesis {}
            Mock Get-GenesisSysprepBlocker -ModuleName Genesis { $null }
            Mock Get-GenesisFogNetworkAdapter -ModuleName Genesis { [pscustomobject]@{ Name = 'Ethernet'; Mac = 'aa:bb:cc:00:11:22' } }
            Mock Get-GenesisPxeBootEntry -ModuleName Genesis { [pscustomobject]@{ Id = '{11111111-1111-1111-1111-111111111111}'; Description = 'UEFI: PXE IPv4' } }
            Mock Get-GenesisFogImage -ModuleName Genesis { [pscustomobject]@{ id = 4; name = 'Win11-Ref' } }
            Mock Register-GenesisFogHost -ModuleName Genesis { [pscustomobject]@{ Id = 7; Created = $false } }
            Mock Disable-GenesisSystemEncryption -ModuleName Genesis { $false }
            Mock Invoke-GenesisNativeCommand -ModuleName Genesis { [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = '' } }
            Mock Clear-GenesisNetBirdIdentity -ModuleName Genesis { $true }
            Mock Remove-GenesisSysprepBlockingAppx -ModuleName Genesis { 0 }
            Mock Test-GenesisWindowsGeneralized -ModuleName Genesis { $false }
            Mock Invoke-GenesisSysprep -ModuleName Genesis {}
            Mock New-GenesisFogCaptureTask -ModuleName Genesis {}
            Mock Set-GenesisNextBootEntry -ModuleName Genesis {}
            Mock Remove-GenesisFogConfigurationFile -ModuleName Genesis {}
        }

        It 'généralise, programme la capture puis force un démarrage réseau' {
            InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
                param($Root)
                $result = Invoke-GenesisFogCapture -RunDirectory $Root
                $result.Status | Should -Be 'Completed'
                $result.Message | Should -Match 'Win11-Ref'
                Should -Invoke Invoke-GenesisSysprep -Exactly -Times 1
                Should -Invoke New-GenesisFogCaptureTask -Exactly -Times 1 -ParameterFilter { $HostId -eq 7 }
                Should -Invoke Set-GenesisNextBootEntry -Exactly -Times 1 -ParameterFilter { $Id -eq '{11111111-1111-1111-1111-111111111111}' }
                Should -Invoke Invoke-GenesisNativeCommand -Exactly -Times 1 -ParameterFilter { $FilePath -eq 'powercfg.exe' -and $Arguments -eq '/hibernate off' }
                Should -Invoke Remove-GenesisFogConfigurationFile -Exactly -Times 1
            }
        }

        It 'ne touche pas au poste quand le démarrage réseau est introuvable' {
            Mock Get-GenesisPxeBootEntry -ModuleName Genesis { throw 'Aucune entrée de démarrage réseau (PXE).' }
            InModuleScope Genesis {
                { Invoke-GenesisFogCapture -RunDirectory $TestDrive } | Should -Throw '*PXE*'
                Should -Invoke Disable-GenesisSystemEncryption -Exactly -Times 0
                Should -Invoke Invoke-GenesisSysprep -Exactly -Times 0
                Should -Invoke New-GenesisFogCaptureTask -Exactly -Times 0
            }
        }

        It 'ne programme pas la capture si Sysprep échoue' {
            Mock Invoke-GenesisSysprep -ModuleName Genesis { throw 'Sysprep n''a pas généralisé Windows.' }
            InModuleScope Genesis {
                { Invoke-GenesisFogCapture -RunDirectory $TestDrive } | Should -Throw '*Sysprep*'
                Should -Invoke New-GenesisFogCaptureTask -Exactly -Times 0
                Should -Invoke Set-GenesisNextBootEntry -Exactly -Times 0
            }
        }

        It 'reprend un poste déjà généralisé sans relancer Sysprep' {
            Mock Test-GenesisWindowsGeneralized -ModuleName Genesis { $true }
            InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
                param($Root)
                (Invoke-GenesisFogCapture -RunDirectory $Root).Status | Should -Be 'Completed'
                Should -Invoke Get-GenesisSysprepBlocker -Exactly -Times 0
                Should -Invoke Invoke-GenesisSysprep -Exactly -Times 0
                Should -Invoke New-GenesisFogCaptureTask -Exactly -Times 1
            }
        }

        It 'indique quoi faire quand FOG refuse la tâche après Sysprep' {
            Mock New-GenesisFogCaptureTask -ModuleName Genesis { throw 'Réponse FOG refusée.' }
            InModuleScope Genesis {
                { Invoke-GenesisFogCapture -RunDirectory $TestDrive } | Should -Throw '*ne pas redémarrer sur Windows*aa:bb:cc:00:11:22*'
                Should -Invoke Set-GenesisNextBootEntry -Exactly -Times 0
            }
        }

        It 'attend une intervention quand Sysprep serait refusé' {
            Mock Get-GenesisSysprepBlocker -ModuleName Genesis { 'Un redémarrage est en attente.' }
            InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
                param($Root)
                $result = Invoke-GenesisFogCapture -RunDirectory $Root
                $result.Status | Should -Be 'NeedsAttention'
                Should -Invoke Register-GenesisFogHost -Exactly -Times 0
                Should -Invoke Invoke-GenesisSysprep -Exactly -Times 0
            }
        }

        It 'demande de relancer depuis le menu sans paramètres FOG' {
            Mock Read-GenesisFogConfigurationFile -ModuleName Genesis { $null }
            InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
                param($Root)
                (Invoke-GenesisFogCapture -RunDirectory $Root).Status | Should -Be 'NeedsAttention'
                Should -Invoke Invoke-GenesisSysprep -Exactly -Times 0
            }
        }
    }
}
