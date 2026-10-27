BeforeAll {
    $script:Repository = Split-Path -Parent $PSScriptRoot
    $script:BaseProfile = Join-Path $script:Repository 'profiles/base.json'
    Import-Module (Join-Path $script:Repository 'modules/Genesis/Genesis.psd1') -Force
}

Describe 'Contrat des profils Genesis' {
    It 'construit un plan de diagnostic sans modifier le poste ni creer de journal' {
        $plan = Get-GenesisPlan -ProfilePath $script:BaseProfile
        $plan.ProfileId | Should -Be 'base'
        $plan.Steps.Count | Should -Be 1
        $plan.Steps[0].Id | Should -Be 'inventory'
        $plan.Steps[0].ChangesMachine | Should -BeFalse
    }

    It 'refuse une operation inconnue plutot que de lancer du code fourni par le profil' {
        $path = Join-Path $TestDrive 'unknown.json'
        '{"schemaVersion":1,"id":"test","name":"Test","steps":["arbitrary-command"]}' | Set-Content $path
        { Get-GenesisPlan -ProfilePath $path } | Should -Throw '*inconnue*'
    }

    It 'refuse les operations en double' {
        $path = Join-Path $TestDrive 'duplicate.json'
        '{"schemaVersion":1,"id":"test","name":"Test","steps":["inventory","inventory"]}' | Set-Content $path
        { Get-GenesisPlan -ProfilePath $path } | Should -Throw '*double*'
    }

    It 'refuse une version de schema non prise en charge' {
        $path = Join-Path $TestDrive 'version.json'
        '{"schemaVersion":2,"id":"test","name":"Test","steps":["inventory"]}' | Set-Content $path
        { Get-GenesisPlan -ProfilePath $path } | Should -Throw '*schema*'
    }

    It 'refuse un champ secret dans un profil' {
        $path = Join-Path $TestDrive 'secret.json'
        '{"schemaVersion":1,"id":"test","name":"Test","steps":["inventory"],"password":"fictitious"}' | Set-Content $path
        { Get-GenesisPlan -ProfilePath $path } | Should -Throw '*champ*'
    }

    It 'refuse une liste vide ou un mauvais type de liste' -ForEach @('[]', '"inventory"') {
        $path = Join-Path $TestDrive 'steps.json'
        ('{"schemaVersion":1,"id":"test","name":"Test","steps":' + $_ + '}') | Set-Content $path
        { Get-GenesisPlan -ProfilePath $path } | Should -Throw
    }

    It 'construit un plan à partir dun profil embarqué sans chemin externe' {
        $profileObject = [pscustomobject]@{
            schemaVersion = 1
            id = 'embedded'
            name = 'Profil embarqué'
            steps = @('inventory')
        }
        $plan = Get-GenesisPlan -ProfileObject $profileObject
        $plan.ProfileId | Should -Be 'embedded'
        $plan.Steps[0].Id | Should -Be 'inventory'
    }

    It 'expose les choix logiciels dans le profil Windows' {
        $windowsProfile = Get-Content (Join-Path $script:Repository 'profiles/windows.json') -Raw | ConvertFrom-Json
        $windowsProfile.steps | Should -Contain 'windows-update'
        $windowsProfile.steps | Should -Contain 'office-2024'
        $windowsProfile.steps | Should -Contain 'browser'
        $windowsProfile.steps | Should -Contain 'pdf-reader'
        $windowsProfile.steps | Should -Contain 'netbird'
        (Get-GenesisStepCatalog | Where-Object Id -in @('office-2024', 'browser', 'pdf-reader')).Reversible | Should -Not -Contain $true
    }

    It 'ne configure aucun serveur ni accès dans les profils publics' {
        foreach ($name in @('base', 'windows')) {
            $profileObject = Get-Content (Join-Path $script:Repository ('profiles/' + $name + '.json')) -Raw | ConvertFrom-Json
            @($profileObject.PSObject.Properties.Name | Sort-Object) | Should -Be @('id', 'name', 'schemaVersion', 'steps')
        }
    }
}

Describe 'Windows Update' {
    It 'utilise une recherche Windows Update incluant les mises a jour facultatives' {
        InModuleScope Genesis {
            $criterion = Get-GenesisWindowsUpdateSearchCriterion
            $criterion | Should -Match "DeploymentAction='OptionalInstallation'"
            $criterion | Should -Match "DeploymentAction='Installation'"
            $criterion | Should -Match 'IsHidden=0'

        }
    }

    It 'retourne la version courante et la derniere version proposee dans le statut de la checklist' {
        InModuleScope Genesis {
            Mock Get-GenesisWindowsVersionStatus {
                [pscustomobject]@{
                    Current = 'Windows 11 24H2 (build 26100.7462)'
                    Latest = 'Feature update to Windows 11, version 25H2'
                    AvailableCount = 3
                    ScanSucceeded = $true
                    Error = $null
                }
            }
            $status = Get-GenesisStepCompletion -StepId 'windows-update'
            $status.Done | Should -BeFalse
            $status.CurrentVersion | Should -Be 'Windows 11 24H2 (build 26100.7462)'
            $status.LatestVersion | Should -Be 'Feature update to Windows 11, version 25H2'
            $status.Detail | Should -Match '3 mise'
        }
    }

    It 'journalise une machine deja a jour sans lancer d installation' -Tag Windows {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Set-GenesisStepProgress {}
            $searcher = [pscustomobject]@{}
            Add-Member -InputObject $searcher -MemberType ScriptMethod -Name Search -Value {
                param([string]$Criteria)
                if ($Criteria -notmatch "DeploymentAction='OptionalInstallation'") { throw 'Critère de recherche inattendu.' }
                [pscustomobject]@{ Updates = @() }
            }
            $session = [pscustomobject]@{ Searcher = $searcher }
            Add-Member -InputObject $session -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { return $this.Searcher }
            $result = Invoke-GenesisWindowsUpdate -RunDirectory $Root -Session $session
            $result.Status | Should -Be 'Completed'
            $journal = Get-Content (Join-Path $Root 'windows-update.json') -Raw | ConvertFrom-Json
            $journal.SearchCriteria | Should -Match "DeploymentAction='OptionalInstallation'"
            $journal.PendingReboot | Should -BeFalse
        }
    }
}

Describe 'Mise a niveau de version Windows' {
    BeforeAll {
        $script:UpgradeCategory = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'
        $script:SecurityCategory = '0fa1201d-4330-4fa8-8ae9-b877473b6441'
    }

    It 'separe les correctifs de la mise a niveau de version' {
        InModuleScope Genesis -Parameters @{ Upgrade = $script:UpgradeCategory; Security = $script:SecurityCategory } {
            param($Upgrade, $Security)
            $updates = @(
                [pscustomobject]@{ Title = 'Windows 11, version 26H2'; IsInstalled = $false; IsHidden = $false; Categories = @([pscustomobject]@{ CategoryID = $Upgrade }) }
                [pscustomobject]@{ Title = '2026-10 Correctif de sécurité'; IsInstalled = $false; IsHidden = $false; Categories = @([pscustomobject]@{ CategoryID = $Security }) }
                [pscustomobject]@{ Title = 'Pilote sans catégorie'; IsInstalled = $false; IsHidden = $false }
            )
            @(Select-GenesisWindowsUpdate -Updates $updates -Scope Feature).Title | Should -Be @('Windows 11, version 26H2')
            @(Select-GenesisWindowsUpdate -Updates $updates -Scope Quality).Title | Should -Be @('2026-10 Correctif de sécurité', 'Pilote sans catégorie')
        }
    }

    It 'propose la mise a niveau decochee par defaut dans la checklist' {
        InModuleScope Genesis {
            Test-GenesisStepSelectedByDefault -StepId 'windows-feature-update' | Should -BeFalse
            Test-GenesisStepSelectedByDefault -StepId 'windows-update' | Should -BeTrue
        }
        $windowsProfile = Get-Content (Join-Path $script:Repository 'profiles/windows.json') -Raw | ConvertFrom-Json
        $windowsProfile.steps[-3] | Should -Be 'windows-update'
        $windowsProfile.steps[-2] | Should -Be 'windows-feature-update'
        $windowsProfile.steps[-1] | Should -Be 'fog-capture'
    }

    It 'affiche la version proposee dans la checklist' {
        InModuleScope Genesis {
            Mock Get-GenesisWindowsVersionStatus {
                [pscustomobject]@{ Current = 'Windows 11 25H2 (build 26200.9711)'; Latest = 'Windows 11, version 26H2'; FeatureUpdate = 'Windows 11, version 26H2'; AvailableCount = 0; ScanSucceeded = $true; Error = $null }
            }
            $status = Get-GenesisStepCompletion -StepId 'windows-feature-update'
            $status.Done | Should -BeFalse
            $status.Detail | Should -Match '26H2'
            $status.LatestVersion | Should -Be 'Windows 11, version 26H2'
        }
    }

    It 'installe uniquement la mise a niveau et journalise le redemarrage' -Tag Windows {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive; Upgrade = $script:UpgradeCategory; Security = $script:SecurityCategory } {
            param($Root, $Upgrade, $Security)
            Mock Set-GenesisStepProgress {}
            $script:Installed = @()
            Mock New-GenesisWindowsUpdateCollection { , (New-Object System.Collections.ArrayList) }
            $upgrade = [pscustomobject]@{ Title = 'Windows 11, version 26H2'; IsInstalled = $false; IsHidden = $false; EulaAccepted = $true; Categories = @([pscustomobject]@{ CategoryID = $Upgrade }) }
            $patch = [pscustomobject]@{ Title = 'Correctif'; IsInstalled = $false; IsHidden = $false; EulaAccepted = $true; Categories = @([pscustomobject]@{ CategoryID = $Security }) }
            $session = [pscustomobject]@{ Updates = @($upgrade, $patch) }
            Add-Member -InputObject $session -MemberType ScriptMethod -Name CreateUpdateSearcher -Value {
                $searcher = [pscustomobject]@{ Updates = $this.Updates }
                Add-Member -InputObject $searcher -MemberType ScriptMethod -Name Search -Value { [pscustomobject]@{ Updates = $this.Updates } }
                $searcher
            }
            Add-Member -InputObject $session -MemberType ScriptMethod -Name CreateUpdateDownloader -Value {
                $downloader = [pscustomobject]@{ Updates = $null }
                Add-Member -InputObject $downloader -MemberType ScriptMethod -Name Download -Value { [pscustomobject]@{ ResultCode = 2 } }
                $downloader
            }
            Add-Member -InputObject $session -MemberType ScriptMethod -Name CreateUpdateInstaller -Value {
                $installer = [pscustomobject]@{ Updates = $null }
                Add-Member -InputObject $installer -MemberType ScriptMethod -Name Install -Value { $script:Installed = @($this.Updates | ForEach-Object Title); [pscustomobject]@{ ResultCode = 2; RebootRequired = $true } }
                $installer
            }
            $result = Invoke-GenesisWindowsUpdate -RunDirectory $Root -Session $session -Scope Feature
            $result.Status | Should -Be 'NeedsAttention'
            $script:Installed | Should -Be @('Windows 11, version 26H2')
            $journal = Get-Content (Join-Path $Root 'windows-feature-update.json') -Raw | ConvertFrom-Json
            $journal.Scope | Should -Be 'Feature'
            $journal.PendingReboot | Should -BeTrue
        }
    }
}

Describe 'Etat courant affiche dans la checklist' {
    It 'considere NetBird configure sans sonder ni lancer une connexion' {
        InModuleScope Genesis {
            Mock Get-GenesisNetBirdPath { 'C:\Program Files\NetBird\netbird.exe' }
            Mock Test-GenesisNetBirdManagementConfigured { $true }
            Mock Invoke-GenesisNativeCommand { throw 'NetBird ne doit pas être interrogé pour cette vérification.' }
            $status = Get-GenesisStepCompletion -StepId 'netbird'
            $status.Done | Should -BeTrue
            $status.Detail | Should -Match 'aucune connexion'
            Should -Invoke Invoke-GenesisNativeCommand -Exactly -Times 0
        }
    }

    It 'utilise une coche ASCII pour une action deja faite' {
        InModuleScope Genesis {
            Get-GenesisMenuDoneMarker -Done $true | Should -Be '[v]'
            Get-GenesisMenuDoneMarker -Done $false | Should -Be '[ ]'
        }
    }

    It 'marque une action comme faite quand sa valeur effective est deja appliquee' {
        InModuleScope Genesis {
            Mock Get-GenesisRegistryValue {
                param([string]$Path, [string]$Name)
                if ($Path -eq 'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover' -and $Name -eq 'ExcludeExplicitO365Endpoint') {
                    return [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 1 }
                }
                [pscustomobject]@{ Exists = $false; KeyExists = $false; Kind = ''; Data = $null }
            }
            $status = Get-GenesisStepCompletion -StepId 'outlook-autodiscover'
            $status.Done | Should -BeTrue
            $status.Label | Should -Be 'Fait'
        }
    }

    It 'marque une action comme non faite quand une valeur attendue manque' {
        InModuleScope Genesis {
            Mock Get-GenesisRegistryValue {
                [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 1 }
            }
            $status = Get-GenesisStepCompletion -StepId 'windows-suggestions'
            $status.Done | Should -BeFalse
            $status.Label | Should -Be 'Non fait'
        }
    }
}

Describe 'Menu technicien principal' {
    It 'ne conserve que les actions de preparation, la desinstallation et la sortie' {
        InModuleScope Genesis {
            $entries = @(Get-GenesisMainMenuEntry)
            @($entries.Id) | Should -Be @('1', '2', '3', '4', '5', '0')
            ($entries.Label -join ' | ') | Should -Not -Match 'Inventaire|Plan du profil|Catalogue|Reprendre|Afficher le tableau'
        }
    }

    It 'desinstalle Genesis en supprimant ses traces sans toucher aux personnalisations' {
        InModuleScope Genesis {
            $root = Join-Path $TestDrive 'GenesisData'
            New-Item -ItemType Directory -Path (Join-Path $root 'runs') -Force | Out-Null
            Mock Assert-GenesisAdministrator {}
            Mock Open-GenesisRunLock { [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Dispose -Value {} -PassThru }
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Genesis - reprise Windows Update' } }
            Mock Unregister-GenesisUpdateContinuation {}
            Mock Get-CimInstance { @() }
            Mock Get-GenesisRegistryValue { [pscustomobject]@{ Exists = $false; KeyExists = $false; Kind = ''; Data = $null } }
            Mock Get-GenesisPortablePath { $null }
            Mock Remove-ItemProperty {}
            $result = Uninstall-GenesisFootprint -DataRoot $root -Confirm:$false
            Test-Path -LiteralPath $root | Should -BeFalse
            Should -Invoke Unregister-GenesisUpdateContinuation -Exactly -Times 1
            Should -Invoke Remove-ItemProperty -Exactly -Times 0
            $result.Failed.Count | Should -Be 0
        }
    }

    It 'demande OUI avant de desinstaller Genesis' {
        InModuleScope Genesis {
            Mock Write-Host {}
            Mock Get-GenesisFootprint { @([pscustomobject]@{ Kind = 'Folder'; Path = 'C:\ProgramData\Genesis'; Label = 'Données' }) }
            Mock Read-Host { 'oui' }
            Mock Uninstall-GenesisFootprint {}
            Show-GenesisUninstall | Should -BeFalse
            Should -Invoke Uninstall-GenesisFootprint -Exactly -Times 0
        }
    }

    It 'efface la console avant de quitter par le choix zero' {
        $source = Get-Content (Join-Path $script:Repository 'modules/Genesis/Genesis.psm1') -Raw
        $source | Should -Match "(?s)'0'\s*\{\s*Clear-Host"
    }
}

Describe 'Choix des preparations pour Reverse' {
    It 'liste chaque preparation avec son profil, son etat et les actions correspondantes' {
        InModuleScope Genesis {
            $root = Join-Path $TestDrive 'reverse-candidates'
            $runId = '0123456789abcdef0123456789abcdef'
            $directory = Join-Path (Join-Path $root 'runs') $runId
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
            $state = [pscustomobject]@{
                SchemaVersion = 1
                GenesisVersion = $script:GenesisVersion
                RunId = $runId
                MachineId = 'machine-fictive'
                UserSid = 'S-1-5-21-test'
                ProfileId = 'windows'
                CreatedAt = '2026-10-13T08:00:00Z'
                FinishedAt = '2026-10-13T08:05:00Z'
                Status = 'Completed'
                Choices = [pscustomobject]@{ browser = 'Chrome'; 'pdf-reader' = 'Acrobat' }
                Steps = @(
                    [pscustomobject]@{ Id = 'inventory'; Status = 'Completed'; Percent = 100; Message = 'Inventaire enregistré'; UndoStatus = 'NotAvailable' }
                    [pscustomobject]@{ Id = 'windows-suggestions'; Status = 'Completed'; Percent = 100; Message = 'Conseils désactivés'; UndoStatus = 'Available' }
                )
            }
            $profileObject = [pscustomobject]@{
                schemaVersion = 1
                id = 'windows'
                name = 'Personnalisations Windows'
                steps = @('inventory', 'windows-suggestions')
            }
            Write-GenesisJson -Path (Join-Path $directory 'state.json') -Value $state
            Write-GenesisJson -Path (Join-Path $directory 'profile.json') -Value $profileObject
            Write-GenesisJson -Path (Join-Path $directory 'windows-suggestions.registry.json') -Value ([pscustomobject]@{})
            Write-GenesisJson -Path (Join-Path $directory 'inventory.json') -Value ([pscustomobject]@{ SchemaVersion = 1 })

            $candidates = @(Get-GenesisReverseCandidate -DataRoot $root)

            $candidates.Count | Should -Be 1
            $candidates[0].RunId | Should -Be $runId
            $candidates[0].ProfileName | Should -Be 'Personnalisations Windows'
            $candidates[0].Status | Should -Be 'Completed'
            $candidates[0].ActionCount | Should -Be 2
            $candidates[0].ReversibleCount | Should -Be 1
            $candidates[0].ActionSummary | Should -Match 'Désactiver les conseils'
            $candidates[0].CanUndo | Should -BeTrue
        }
    }
}

Describe 'Preparation et reprise' {
    BeforeEach {
        Mock Get-GenesisMachineId -ModuleName Genesis { 'machine-fictive' }
        Mock Get-GenesisInventory -ModuleName Genesis {
            [pscustomobject]@{ SchemaVersion = 1; Computer = @{ Manufacturer = 'Autre marque'; Model = 'PC generique' } }
        }
        $script:DataRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'enregistre une execution terminee avec inventaire et journal' {
        $run = Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot
        $run.Status | Should -Be 'Completed'
        $run.Steps[0].Attempts | Should -Be 1
        $directory = Join-Path (Join-Path $script:DataRoot 'runs') $run.RunId
        (Join-Path $directory 'inventory.json') | Should -Exist
        $events = Get-Content (Join-Path $directory 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        $events.Event | Should -Contain 'run_completed'
        (Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot).Status | Should -Be 'Completed'
    }

    It 'ne rejoue pas une execution deja terminee' {
        $run = Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot
        $resumed = Resume-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot
        $resumed.Status | Should -Be 'Completed'
        Should -Invoke Get-GenesisInventory -ModuleName Genesis -Exactly -Times 1
    }

    It 'conserve un echec puis reprend uniquement les operations a terminer' {
        Mock Get-GenesisInventory -ModuleName Genesis { throw 'Panne fictive avec contenu prive' }
        { Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot } | Should -Throw
        $directory = Get-ChildItem (Join-Path $script:DataRoot 'runs') -Directory | Select-Object -First 1
        $failed = Get-GenesisRun -RunId $directory.Name -DataRoot $script:DataRoot
        $failed.Status | Should -Be 'Failed'
        $failed.Steps[0].Status | Should -Be 'Failed'
        Get-Content (Join-Path $directory.FullName 'state.json') -Raw | Should -Not -Match 'contenu prive'
        (Get-GenesisProgress -State $failed).Rows[0].Detail | Should -Match 'Panne fictive'
        Mock Get-GenesisInventory -ModuleName Genesis { [pscustomobject]@{ SchemaVersion = 1 } }
        $resumed = Resume-GenesisRun -RunId $directory.Name -DataRoot $script:DataRoot
        $resumed.Status | Should -Be 'Completed'
        $resumed.Steps[0].Attempts | Should -Be 2
    }

    It 'reprend une operation interrompue avant son point de controle' {
        $run = Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot
        $path = Join-Path (Join-Path (Join-Path $script:DataRoot 'runs') $run.RunId) 'state.json'
        $state = Get-Content $path -Raw | ConvertFrom-Json
        $state.Status = 'Running'
        $state.Steps[0].Status = 'Running'
        $state | ConvertTo-Json -Depth 12 | Set-Content $path
        $resumed = Resume-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot
        $resumed.Status | Should -Be 'Completed'
        $resumed.Steps[0].Attempts | Should -Be 2
    }

    It 'refuse de reprendre un etat provenant dun autre ordinateur' {
        $run = Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot
        Mock Get-GenesisMachineId -ModuleName Genesis { 'autre-machine' }
        { Resume-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot } | Should -Throw '*ordinateur*'
    }

    It 'refuse une seconde execution lorsque le repertoire est verrouille' -Tag Windows {
        New-Item $script:DataRoot -ItemType Directory -Force | Out-Null
        $lock = [System.IO.File]::Open((Join-Path $script:DataRoot '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            { Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot } | Should -Throw '*déjà en cours*'
        }
        finally {
            $lock.Dispose()
        }
    }

    It 'distingue un repertoire de donnees absent dun verrou occupe' {
        $missingRoot = Join-Path $TestDrive 'genesis-root-absent'
        { Resume-GenesisRun -RunId ('a' * 32) -DataRoot $missingRoot } | Should -Throw '*répertoire de données Genesis*'
    }

    It 'indique quand Genesis doit etre lance en administrateur' {
        Mock Test-GenesisAdministrator -ModuleName Genesis { $false }
        { Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot } | Should -Throw '*administrateur*'
    }

    It 'refuse un identifiant permettant de sortir du repertoire des executions' {
        { Get-GenesisRun -RunId '../outside' -DataRoot $script:DataRoot } | Should -Throw
    }

    It 'ne presente pas comme termine un diagnostic dont linventaire a disparu' {
        $run = Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot
        $directory = Join-Path (Join-Path $script:DataRoot 'runs') $run.RunId
        Remove-Item (Join-Path $directory 'inventory.json')
        { Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot } | Should -Throw '*inventaire*'
    }

    It 'refuse un statut global inconnu dans un etat endommage' {
        $run = Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot
        $path = Join-Path (Join-Path (Join-Path $script:DataRoot 'runs') $run.RunId) 'state.json'
        $state = Get-Content $path -Raw | ConvertFrom-Json
        $state.Status = 'Unrecognized'
        $state | ConvertTo-Json -Depth 12 | Set-Content $path
        { Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot } | Should -Throw '*statut*'
    }

    It 'refuse un etat termine contenant une operation encore en attente' {
        $run = Start-GenesisRun -ProfilePath $script:BaseProfile -DataRoot $script:DataRoot
        $path = Join-Path (Join-Path (Join-Path $script:DataRoot 'runs') $run.RunId) 'state.json'
        $state = Get-Content $path -Raw | ConvertFrom-Json
        $state.Steps[0].Status = 'Pending'
        $state | ConvertTo-Json -Depth 12 | Set-Content $path
        { Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot } | Should -Throw '*incoherent*'
    }

    It 'utilise un menu dans la fenetre PowerShell sans interface externe' {
        $source = Get-Content (Join-Path $script:Repository 'modules/Genesis/Genesis.psm1') -Raw
        $source | Should -Match 'GENESIS v'
        $source | Should -Not -Match 'Interface\.ps1'
        (Get-Command Show-GenesisInterface -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    It 'genere une ligne de tableau par action avec son pourcentage' {
        InModuleScope Genesis {
            $row = [pscustomobject]@{ Id = 'time-sync'; State = 'En cours'; Status = 'Running'; Percent = 50; Undo = 'Non'; Detail = 'Une opération très longue qui doit rester sur une seule ligne du tableau' }
            $line = ConvertTo-GenesisConsoleProgressRow -Row $row -DetailWidth 20
            $line | Should -Match 'time-sync'
            $line | Should -Match '50%'
            $line | Should -Match 'En cours'
            $line | Should -Not -Match '█'
            $line | Should -Not -Match "`n"
            $line.Length | Should -Be (Get-GenesisConsoleTableBorder -DetailWidth 20).Length
            $pending = [pscustomobject]@{ Id = 'power-ac'; State = 'À faire'; Status = 'Pending'; Percent = 0; Undo = 'Non'; Detail = '' }
            { ConvertTo-GenesisConsoleProgressRow -Row $pending -DetailWidth 20 } | Should -Not -Throw
        }
    }

    It 'coupe les barres de progression et redessine le tableau apres chaque action' {
        $source = Get-Content (Join-Path $script:Repository 'modules/Genesis/Genesis.psm1') -Raw
        $body = [regex]::Match($source, '(?s)function Invoke-GenesisRunExecution \{.*?\n\}').Value
        $body | Should -Match "\`$ProgressPreference = 'SilentlyContinue'"
        ([regex]::Matches($body, 'Request-GenesisConsoleRedraw')).Count | Should -Be 2
        InModuleScope Genesis {
            $script:GenesisConsoleTable = [pscustomobject]@{ Ids = 'a' }
            $script:GenesisConsoleTableDirty = $false
            Request-GenesisConsoleRedraw
            $script:GenesisConsoleTableDirty | Should -BeTrue
            $script:GenesisConsoleTable = $null
            $script:GenesisConsoleTableDirty = $false
        }
    }

    It 'met a jour les lignes du tableau en place au lieu d ecraser l action precedente' {
        $source = Get-Content (Join-Path $script:Repository 'modules/Genesis/Progress.ps1') -Raw
        $source | Should -Match 'RowTops'
        $source | Should -Match '\[Console\]::SetCursorPosition'
        $source | Should -Match 'Initialize-GenesisConsoleProgressSurface'
        $source | Should -Not -Match 'ConvertTo-GenesisProgressBarLine'
    }

    It 'garde les colonnes du tableau d avancement alignees et replie le detail' {
        InModuleScope Genesis {
            $table = ConvertTo-GenesisFixedAsciiTable -Headers @('ID', 'État', '%', 'Reverse', 'Détail') -ColumnWidths @(12, 12, 6, 8, 40) -Rows @(
                ,@('browser', 'À vérifier', '90%', 'Non', 'Windows protège le choix par défaut et demande une validation dans les paramètres.')
            )
            $lengths = @($table -split "`r?`n" | ForEach-Object { $_.Length } | Select-Object -Unique)
            $lengths.Count | Should -Be 1
            $table | Should -Match 'Windows protège le choix'
            $table | Should -Match '\| browser\s+\| À vérifier\s+\| 90%\s+\| Non\s+\|'
        }
    }

    It 'valide les choix exclusifs du navigateur et du lecteur PDF' {
        InModuleScope Genesis {
            $choices = Assert-GenesisChoice -Choices @{ browser = 'Firefox'; 'pdf-reader' = 'PDFCraft' }
            $choices.browser | Should -Be 'Firefox'
            $choices.'pdf-reader' | Should -Be 'PDFCraft'
            (Get-GenesisChoiceValue -Choices $choices -Name 'browser') | Should -Be 'Firefox'
            { Assert-GenesisChoice -Choices @{ browser = 'Edge' } } | Should -Throw '*invalide*'
        }
    }

    It 'construit un profil avec uniquement les operations cochees' {
        InModuleScope Genesis {
            $testProfile = [pscustomobject]@{ schemaVersion = 1; id = 'test'; name = 'Test'; steps = @('inventory', 'browser', 'pdf-reader') }
            $selected = New-GenesisSelectedProfile -ProfileObject $testProfile -SelectedIds @('inventory', 'pdf-reader')
            $selected.steps | Should -Be @('inventory', 'pdf-reader')
        }
    }

    It 'persiste les choix radio pour une reprise sans nouvelle question' {
        InModuleScope Genesis -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-GenesisMachineId { 'machine-radio' }
            Mock Get-GenesisUserSid { 'user-radio' }
            Mock Invoke-GenesisCustomization {
                param($StepId)
                [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = $StepId }
            }
            $testProfile = [pscustomobject]@{ schemaVersion = 1; id = 'radio'; name = 'Radio'; steps = @('browser', 'pdf-reader') }
            $choices = [ordered]@{ browser = 'Firefox'; 'pdf-reader' = 'PDFCraft' }
            $run = Start-GenesisRun -ProfileObject $testProfile -Choices $choices -DataRoot $Root
            $run.Choices.browser | Should -Be 'Firefox'
            $run.Choices.'pdf-reader' | Should -Be 'PDFCraft'
        }
    }
}

Describe 'Inventaire independant du constructeur' {
    It 'normalise les donnees dun PC sans imposer une marque' {
        InModuleScope Genesis {
            $inventory = ConvertTo-GenesisInventory -Computer ([pscustomobject]@{
                Name = 'FICTIF'; Manufacturer = 'Constructeur quelconque'; Model = 'Modele quelconque'; TotalPhysicalMemory = 17179869184
            }) -OperatingSystem ([pscustomobject]@{
                Caption = 'Microsoft Windows 11'; Version = '10.0.26100'; BuildNumber = '26100'; OSArchitecture = '64-bit'; LastBootUpTime = [datetime]'2026-01-01'
            }) -Bios ([pscustomobject]@{ SerialNumber = 'FICTIF'; SMBIOSBIOSVersion = '1.0' }) -Processors @(
                [pscustomobject]@{ Name = 'CPU quelconque'; NumberOfCores = 4; NumberOfLogicalProcessors = 8; Architecture = 9 }
            ) -Disks @() -NetworkAdapters @() -ProblemDevices @()
            $inventory.Computer.Manufacturer | Should -Be 'Constructeur quelconque'
            $inventory.Computer.MemoryGiB | Should -Be 16
            $inventory.Processors[0].Architecture | Should -Be 'x64'
            $inventory.Disks.Count | Should -Be 0
            $inventory.OperatingSystem.IsWindows11 | Should -BeTrue
        }

    }

    It 'distingue la RAM installee de la memoire accessible a Windows' {
        InModuleScope Genesis {
            $inventory = ConvertTo-GenesisInventory -Computer ([pscustomobject]@{
                Name = 'FICTIF'; Manufacturer = 'Autre marque'; Model = 'Generique'; TotalPhysicalMemory = 12884901888
            }) -OperatingSystem ([pscustomobject]@{
                Caption = 'Windows 11'; Version = '10.0.26100'; BuildNumber = '26100'; OSArchitecture = '64-bit'; LastBootUpTime = [datetime]'2026-01-01'
            }) -Bios ([pscustomobject]@{ SerialNumber = 'FICTIF'; SMBIOSBIOSVersion = '1.0' }) -MemoryModules @(
                [pscustomobject]@{ Capacity = 8589934592 }, [pscustomobject]@{ Capacity = 8589934592 }
            )
            $inventory.Computer.InstalledMemoryGiB | Should -Be 16
            $inventory.Computer.MemoryGiB | Should -Be 12
        }
    }

    It 'identifie ARM64 sans le traiter comme un processeur x64' {
        InModuleScope Genesis {
            Get-GenesisArchitecture -Code 12 | Should -Be 'arm64'
        }
    }

    It 'formate linventaire en tableau ASCII lisible' {
        InModuleScope Genesis {
            $inventory = [pscustomobject]@{
                Computer = [ordered]@{ Name = 'FICTIF'; Manufacturer = 'Constructeur'; Model = 'Modele'; SerialNumber = 'SER123'; BiosVersion = '1.0'; MemoryGiB = 16; InstalledMemoryGiB = 16 }
                OperatingSystem = [ordered]@{ Name = 'Windows 11 Pro'; Version = '10.0.26100'; Build = '26100'; Architecture = '64-bit'; LastBoot = '2026-01-01T00:00:00Z'; IsWindows11 = $true }
                Processors = @([ordered]@{ Name = 'CPU'; Cores = 4; LogicalProcessors = 8; Architecture = 'x64' })
                Disks = @([ordered]@{ Model = 'SSD'; SizeGiB = 512; Interface = 'NVMe' })
                NetworkAdapters = @([ordered]@{ Name = 'Ethernet'; MacAddress = '02-00-00-00-00-01'; Addresses = @('198.51.100.10') })
                ProblemDevices = @()
            }
            $table = Format-GenesisInventoryAscii -Inventory $inventory
            $table | Should -Match '\+[-+]+\+'
            $table | Should -Match 'Constructeur'
            $table | Should -Match 'Windows 11 Pro'
            $table | Should -Match '198\.51\.100\.10'
            $table | Should -Match '\| CPU\s+\| 4\s+\| 8\s+\| x64\s+\|'
            $table | Should -Match '\| SSD\s+\| 512\s+\| NVMe\s+\|'
        }
    }
}

Describe 'Imprimantes reseau et pilotes' {
    It 'transforme un peripherique WSD decouvert en imprimante disponible' {
        InModuleScope Genesis {
            $device = [pscustomobject]@{
                Id = 'DAFWSDProvider#urn:uuid:12345678-1234-1234-1234-1234567890ab#http://printer.example.test/PrintService'
                Name = 'Imprimante Exemple WSD'
                Properties = [ordered]@{
                    'System.ItemNameDisplay' = 'Imprimante Exemple WSD'
                    'System.Devices.Aep.DeviceAddress' = '203.0.113.75'
                    'System.Devices.Aep.Manufacturer' = 'Constructeur Exemple'
                    'System.Devices.Aep.ModelName' = 'Modele Exemple WSD'
                    'System.Devices.Aep.Category' = @('PrintFax.Printer.MFP', 'Imaging.Scanner')
                    'System.Devices.AepService.ServiceId' = 'DAFWSDProvider#urn:uuid:12345678-1234-1234-1234-1234567890ab#http://printer.example.test/PrintService'
                }
            }
            $record = ConvertTo-GenesisDiscoveredPrinterRecord -Device $device
            $record.Name | Should -Be 'Imprimante Exemple WSD'
            $record.Address | Should -Be '203.0.113.75'
            $record.DeviceUUID | Should -Be '12345678-1234-1234-1234-1234567890ab'
            $record.Status | Should -Be 'Available'
            $record.Installed | Should -BeFalse
            $record.CanAdd | Should -BeTrue
        }
    }

    It 'fusionne une imprimante decouverte avec une file deja installee' {
        InModuleScope Genesis {
            Mock Get-GenesisRawPrinterPort { @([pscustomobject]@{ Name = 'WSD-1'; PrinterHostAddress = '203.0.113.75'; Protocol = 1 }) }
            Mock Get-GenesisRawPrinterQueue { @([pscustomobject]@{ Name = 'Imprimante Exemple WSD'; PortName = 'WSD-1'; DriverName = 'Pilote Exemple'; Type = 'Local'; Network = $false }) }
            Mock Get-GenesisRawPrinterDevice {
                @([pscustomobject]@{
                    Name = 'Imprimante Exemple WSD'
                    Address = '203.0.113.75'
                    DeviceUUID = '12345678-1234-1234-1234-1234567890ab'
                    DeviceURL = ''
                    DriverName = ''
                    Manufacturer = 'Constructeur Exemple'
                    ModelName = 'Modele Exemple WSD'
                })
            }
            $records = @(Get-GenesisNetworkPrinter)
            $records.Count | Should -Be 1
            $records[0].Installed | Should -BeTrue
            $records[0].Status | Should -Be 'Installed'
            $records[0].DeviceUUID | Should -Be '12345678-1234-1234-1234-1234567890ab'
            $records[0].CanAdd | Should -BeFalse
        }
    }

    It 'ajoute une imprimante WSD puis verifie la file' -Tag Windows {
        InModuleScope Genesis {
            Mock Add-Printer {}
            Mock Get-GenesisRawPrinterQueue { @([pscustomobject]@{ Name = 'Imprimante Exemple Ajout' }) }
            $result = Add-GenesisPrinter -Printer ([pscustomobject]@{
                Name = 'Imprimante Exemple Ajout'; Installed = $false; DeviceUUID = '12345678-1234-1234-1234-1234567890ab'; DeviceURL = ''
            })
            $result.Status | Should -Be 'Completed'
            Should -Invoke Add-Printer -Exactly -Times 1 -ParameterFilter { $Name -eq 'Imprimante Exemple Ajout' -and $DeviceUUID -eq '12345678-1234-1234-1234-1234567890ab' }
        }
    }

    It 'retient une file TCP IP et ignore une imprimante locale' {
        InModuleScope Genesis {
            $network = ConvertTo-GenesisNetworkPrinterRecord -Printer ([pscustomobject]@{
                Name = 'Imprimante Exemple TCP'; PortName = 'IP_192.0.2.50'; DriverName = 'Pilote Exemple TCP'; Type = 'Local'; Network = $false
            }) -Port ([pscustomobject]@{ Name = 'IP_192.0.2.50'; PrinterHostAddress = '192.0.2.50'; Protocol = 1 })
            $network.Name | Should -Be 'Imprimante Exemple TCP'
            $network.Address | Should -Be '192.0.2.50'
            $network.PortName | Should -Be 'IP_192.0.2.50'

            $local = ConvertTo-GenesisNetworkPrinterRecord -Printer ([pscustomobject]@{
                Name = 'Microsoft Print to PDF'; PortName = 'PORTPROMPT:'; DriverName = 'Microsoft'; Type = 'Local'; Network = $false
            }) -Port ([pscustomobject]@{ Name = 'PORTPROMPT:'; PrinterHostAddress = ''; Protocol = 0 })
            $local | Should -BeNullOrEmpty
        }
    }

    It 'identifie une file partagee et prepare une requete Google drivers' {
        InModuleScope Genesis {
            $printer = ConvertTo-GenesisNetworkPrinterRecord -Printer ([pscustomobject]@{
                Name = '\\PRINT-EXAMPLE\ExampleQueue'; PortName = 'Ne01:'; DriverName = 'Pilote generique'; Type = 'Connection'; Network = $true
            }) -Port $null
            $printer.Address | Should -Be 'PRINT-EXAMPLE'
            $url = New-GenesisPrinterDriverSearchUrl -PrinterName $printer.Name
            $url | Should -Be 'https://www.google.com/search?q=%5C%5CPRINT-EXAMPLE%5CExampleQueue%20drivers'
        }
    }

    It 'ouvre la recherche du pilote de limprimante selectionnee' -Tag Windows {
        InModuleScope Genesis {
            Mock Start-Process {}
            $result = Open-GenesisPrinterDriverSearch -Printer ([pscustomobject]@{ Name = 'Imprimante Exemple Pilote'; Address = '192.0.2.60' })
            $result.Status | Should -Be 'Opened'
            $result.Url | Should -Match 'Imprimante%20Exemple%20Pilote%20drivers'
            Should -Invoke Start-Process -Exactly -Times 1
        }
    }
}

Describe 'Reprise de Windows Update apres redemarrage' {
    BeforeAll {
        function New-ContinuationRun {
            param([string]$Root, [string]$RunStatus = 'NeedsAttention', [string]$UpdateStatus = 'NeedsAttention', [int]$Reboots = 0)
            $runId = [guid]::NewGuid().ToString('N')
            $directory = Join-Path (Join-Path $Root 'runs') $runId
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
            $state = [pscustomobject]@{
                SchemaVersion = 1; GenesisVersion = (Get-Module Genesis).Version.ToString(); RunId = $runId
                MachineId = 'machine-fictive'; UserSid = 'S-1-5-21-technicien'; ProfileId = 'windows'
                CreatedAt = '2026-10-19T08:00:00Z'; FinishedAt = '2026-10-19T08:30:00Z'; Status = $RunStatus; Choices = [ordered]@{}
                Steps = @(
                    [pscustomobject]@{ Id = 'windows-update'; Status = $UpdateStatus; Attempts = 1; StartedAt = $null; FinishedAt = $null; ErrorType = $null; Percent = 100; Message = 'Redémarrage requis'; UndoStatus = 'NotAvailable' }
                    [pscustomobject]@{ Id = 'explorer-home'; Status = 'Completed'; Attempts = 1; StartedAt = $null; FinishedAt = $null; ErrorType = $null; Percent = 100; Message = ''; UndoStatus = 'Available' }
                )
            }
            $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $directory 'state.json') -Encoding UTF8
            [pscustomobject]@{ SchemaVersion = 1; RunId = $runId; MachineId = 'machine-fictive'; Reboots = $Reboots; MaxReboots = 8; RegisteredAt = '2026-10-19T08:30:00Z'; FinishedAt = $null; Outcome = 'Scheduled' } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'update-continuation.json') -Encoding UTF8
            [pscustomobject]@{ RunId = $runId; Directory = $directory }
        }
    }

    BeforeEach {
        $script:DataRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Get-GenesisMachineId -ModuleName Genesis { 'machine-fictive' }
        Mock Restart-GenesisComputer -ModuleName Genesis {}
        Mock Unregister-GenesisUpdateContinuation -ModuleName Genesis {}
        Mock Send-GenesisSessionMessage -ModuleName Genesis {}
        Mock Test-GenesisUpdateRebootPending -ModuleName Genesis { $false }
    }

    It 'redemarre tant que Windows Update demande un redemarrage' {
        $run = New-ContinuationRun -Root $script:DataRoot
        Mock Invoke-GenesisWindowsUpdate -ModuleName Genesis { [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 100; Message = 'Redémarrage requis.' } }
        $result = Invoke-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot -RetryDelaySeconds 0
        $result.Outcome | Should -Be 'Rebooting'
        $result.Reboots | Should -Be 1
        Should -Invoke Restart-GenesisComputer -ModuleName Genesis -Exactly -Times 1
        Should -Invoke Unregister-GenesisUpdateContinuation -ModuleName Genesis -Exactly -Times 0
        (Get-Content (Join-Path $run.Directory 'update-continuation.json') -Raw | ConvertFrom-Json).Reboots | Should -Be 1
        (Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot).Steps[0].Message | Should -Match '1/8'
    }

    It 'termine la preparation et supprime la tache quand Windows est a jour' {
        $run = New-ContinuationRun -Root $script:DataRoot -Reboots 2
        Mock Invoke-GenesisWindowsUpdate -ModuleName Genesis { [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Windows est à jour.' } }
        $result = Invoke-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot -RetryDelaySeconds 0
        $result.Outcome | Should -Be 'Completed'
        Should -Invoke Restart-GenesisComputer -ModuleName Genesis -Exactly -Times 0
        Should -Invoke Unregister-GenesisUpdateContinuation -ModuleName Genesis -Exactly -Times 1
        Should -Invoke Send-GenesisSessionMessage -ModuleName Genesis -Exactly -Times 1 -ParameterFilter { $Message -match 'terminées après 2' }
        $state = Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot
        $state.Status | Should -Be 'Completed'
        $state.Steps[0].Status | Should -Be 'Completed'
    }

    It 'reprend les correctifs puis la mise a niveau de version' {
        $run = New-ContinuationRun -Root $script:DataRoot -UpdateStatus 'Completed'
        $statePath = Join-Path $run.Directory 'state.json'
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.Steps = @($state.Steps[0], [pscustomobject]@{ Id = 'windows-feature-update'; Status = 'NeedsAttention'; Attempts = 1; StartedAt = $null; FinishedAt = $null; ErrorType = $null; Percent = 100; Message = 'Redémarrage requis'; UndoStatus = 'NotAvailable' }, $state.Steps[1])
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
        $script:Scopes = @()
        Mock Invoke-GenesisWindowsUpdate -ModuleName Genesis {
            $script:Scopes += $Scope
            [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'À jour.' }
        }
        $result = Invoke-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot -RetryDelaySeconds 0
        $result.Outcome | Should -Be 'Completed'
        $script:Scopes | Should -Be @('Quality', 'Feature')
        $state = Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot
        @($state.Steps | Where-Object Id -eq 'windows-feature-update')[0].Status | Should -Be 'Completed'
        $state.Status | Should -Be 'Completed'
    }

    It 'redemarre avant la mise a niveau si les correctifs le demandent' {
        $run = New-ContinuationRun -Root $script:DataRoot
        $statePath = Join-Path $run.Directory 'state.json'
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.Steps = @($state.Steps[0], [pscustomobject]@{ Id = 'windows-feature-update'; Status = 'Pending'; Attempts = 0; StartedAt = $null; FinishedAt = $null; ErrorType = $null; Percent = 0; Message = ''; UndoStatus = 'NotAvailable' })
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
        $script:Scopes = @()
        Mock Invoke-GenesisWindowsUpdate -ModuleName Genesis {
            $script:Scopes += $Scope
            [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 100; Message = 'Redémarrage requis.' }
        }
        $result = Invoke-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot -RetryDelaySeconds 0
        $result.Outcome | Should -Be 'Rebooting'
        $script:Scopes | Should -Be @('Quality')
        Should -Invoke Restart-GenesisComputer -ModuleName Genesis -Exactly -Times 1
    }

    It 'arrete apres le nombre maximal de redemarrages' {
        $run = New-ContinuationRun -Root $script:DataRoot -Reboots 8
        Mock Invoke-GenesisWindowsUpdate -ModuleName Genesis { [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 100; Message = 'Redémarrage requis.' } }
        $result = Invoke-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot -RetryDelaySeconds 0
        $result.Outcome | Should -Be 'MaxReboots'
        Should -Invoke Restart-GenesisComputer -ModuleName Genesis -Exactly -Times 0
        Should -Invoke Unregister-GenesisUpdateContinuation -ModuleName Genesis -Exactly -Times 1
        (Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot).Status | Should -Be 'NeedsAttention'
    }

    It 'reessaie puis abandonne si Windows Update reste indisponible' {
        $run = New-ContinuationRun -Root $script:DataRoot
        Mock Invoke-GenesisWindowsUpdate -ModuleName Genesis { throw [System.Net.WebException]::new('Réseau indisponible') }
        $result = Invoke-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot -RetryDelaySeconds 0
        $result.Outcome | Should -Be 'Failed'
        Should -Invoke Invoke-GenesisWindowsUpdate -ModuleName Genesis -Exactly -Times 3
        Should -Invoke Restart-GenesisComputer -ModuleName Genesis -Exactly -Times 0
        Should -Invoke Unregister-GenesisUpdateContinuation -ModuleName Genesis -Exactly -Times 1
        $state = Get-GenesisRun -RunId $run.RunId -DataRoot $script:DataRoot
        $state.Steps[0].Status | Should -Be 'Failed'
        $state.Steps[0].ErrorType | Should -Be 'System.Net.WebException'
    }

    It 'ne relance rien pour une preparation restauree' {
        $run = New-ContinuationRun -Root $script:DataRoot -RunStatus 'Restored'
        Mock Invoke-GenesisWindowsUpdate -ModuleName Genesis { throw 'ne doit pas être appelé' }
        $result = Invoke-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot -RetryDelaySeconds 0
        $result.Outcome | Should -Be 'Stopped'
        Should -Invoke Invoke-GenesisWindowsUpdate -ModuleName Genesis -Exactly -Times 0
        Should -Invoke Unregister-GenesisUpdateContinuation -ModuleName Genesis -Exactly -Times 1
    }

    It 'supprime la tache si la preparation est illisible' {
        $run = New-ContinuationRun -Root $script:DataRoot
        Set-Content -LiteralPath (Join-Path $run.Directory 'state.json') -Value '{ invalide'
        { Invoke-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot -RetryDelaySeconds 0 } | Should -Throw
        Should -Invoke Unregister-GenesisUpdateContinuation -ModuleName Genesis -Exactly -Times 1
    }

    It 'exige le programme portable pour programmer la reprise' {
        $run = New-ContinuationRun -Root $script:DataRoot
        { Register-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot } | Should -Throw '*Genesis-Portable.ps1*'
    }

    It 'redemarre automatiquement, sans question, seulement si Windows Update est en attente' {
        InModuleScope Genesis {
            Mock Read-Host { 'N' }
            Mock Write-Host {}
            Mock Get-GenesisPortablePath { 'C:\Genesis\Genesis-Portable.ps1' }
            Mock Register-GenesisUpdateContinuation {}
            Mock Restart-GenesisComputer {}
            $done = [pscustomobject]@{ RunId = ('a' * 32); Steps = @([pscustomobject]@{ Id = 'windows-update'; Status = 'Completed' }) }
            Request-GenesisUpdateRestart -State $done
            Should -Invoke Restart-GenesisComputer -Exactly -Times 0
            $pending = [pscustomobject]@{ RunId = ('a' * 32); Steps = @([pscustomobject]@{ Id = 'windows-update'; Status = 'NeedsAttention' }) }
            Request-GenesisUpdateRestart -State $pending
            Should -Invoke Read-Host -Exactly -Times 0
            Should -Invoke Register-GenesisUpdateContinuation -Exactly -Times 1 -ParameterFilter { $RunId -eq ('a' * 32) }
            Should -Invoke Restart-GenesisComputer -Exactly -Times 1
        }
    }

    It 'ne redemarre pas si la reprise automatique ne peut pas etre programmee' {
        InModuleScope Genesis {
            Mock Write-Host {}
            Mock Get-GenesisPortablePath { 'C:\Genesis\Genesis-Portable.ps1' }
            Mock Register-GenesisUpdateContinuation { throw 'Tache refusee' }
            Mock Restart-GenesisComputer {}
            $pending = [pscustomobject]@{ RunId = ('a' * 32); Steps = @([pscustomobject]@{ Id = 'windows-update'; Status = 'NeedsAttention' }) }
            Request-GenesisUpdateRestart -State $pending
            Should -Invoke Restart-GenesisComputer -Exactly -Times 0
        }
    }

    It 'propose le nettoyage du menu Demarrer et la barre des taches a gauche' {
        $windowsProfile = Get-Content (Join-Path $script:Repository 'profiles/windows.json') -Raw | ConvertFrom-Json
        $windowsProfile.steps | Should -Contain 'start-cleanup'
        $windowsProfile.steps | Should -Contain 'taskbar-left'
        InModuleScope Genesis {
            (Get-GenesisStepCatalog | Where-Object Id -eq 'start-cleanup').Reversible | Should -BeFalse
            (Get-GenesisStepCatalog | Where-Object Id -eq 'taskbar-left').Reversible | Should -BeTrue
            $names = @($script:GenesisStartCleanupPackages.Keys)
            foreach ($expected in @('Microsoft.OutlookForWindows', 'Microsoft.GamingApp', 'Microsoft.MicrosoftSolitaireCollection', '5319275A.WhatsAppDesktop', '7EE7776C.LinkedInforWindows')) {
                $names | Should -Contain $expected
            }
            $names | Should -Not -Contain 'Microsoft.XboxIdentityProvider'
            { Assert-GenesisRegistryTarget -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' } | Should -Not -Throw
        }
    }

    It 'desinstalle les applications du menu Demarrer et les retire des nouveaux comptes' {
        InModuleScope Genesis {
            Mock Set-GenesisStepProgress {}
            Mock Get-AppxPackage { @([pscustomobject]@{ Name = 'Microsoft.OutlookForWindows'; PackageFullName = 'outlook_1'; NonRemovable = $false }, [pscustomobject]@{ Name = 'Microsoft.WindowsCalculator'; PackageFullName = 'calc_1'; NonRemovable = $false }) }
            Mock Remove-AppxPackage {}
            Mock Get-AppxProvisionedPackage { @([pscustomobject]@{ DisplayName = 'Microsoft.GamingApp'; PackageName = 'gaming_1' }) }
            Mock Remove-AppxProvisionedPackage {}
            Mock Remove-GenesisStartPin { '2 épingle(s) retirée(s) du menu Démarrer.' }
            $result = Invoke-GenesisStartCleanup -RunDirectory $TestDrive
            Should -Invoke Remove-AppxPackage -Exactly -Times 1 -ParameterFilter { $Package -eq 'outlook_1' }
            Should -Invoke Remove-AppxProvisionedPackage -Exactly -Times 1 -ParameterFilter { $PackageName -eq 'gaming_1' }
            $result.Message | Should -Match 'Outlook \(new\)'
            Should -Invoke Remove-GenesisStartPin -Exactly -Times 1
        }
    }

    It 'detecte Office Starter 2010, les Office MSI et les Office Demarrer en un clic anciens' {
        InModuleScope Genesis {
            Mock Get-GenesisUninstallEntry {
                [pscustomobject]@{ Key = 'Office14.Click2Run'; Name = 'Microsoft Office Démarrer en un clic 2010'; Version = '14.0'; UninstallString = '"C:\PROGRA~2\COMMON~1\MICROS~1\VIRTUA~1\CVHBS.EXE" /removeall'; SystemComponent = $false }
                [pscustomobject]@{ Key = '{90140011-0066-040C-0000-0000000FF1CE}'; Name = 'Microsoft Office Starter 2010 - Français'; Version = '14.0'; UninstallString = 'C:\Program Files (x86)\Common Files\microsoft shared\virtualization handler\cvhbs.exe /uninstall {90140011-0066-040C-0000-0000000FF1CE}'; SystemComponent = $false }
                [pscustomobject]@{ Key = '{90140000-006D-040C-1000-0000000FF1CE}'; Name = 'Microsoft Office Démarrer en un clic 2010'; Version = '14.0'; UninstallString = 'MsiExec.exe /I{90140000-006D-040C-1000-0000000FF1CE}'; SystemComponent = $true }
                [pscustomobject]@{ Key = '{90160000-0011-0000-1000-0000000FF1CE}'; Name = 'Microsoft Office Professionnel Plus 2016'; Version = '16.0'; UninstallString = 'MsiExec.exe /X{90160000-0011-0000-1000-0000000FF1CE}'; SystemComponent = $false }
                [pscustomobject]@{ Key = 'Mozilla Firefox'; Name = 'Mozilla Firefox'; Version = '140'; UninstallString = 'helper.exe'; SystemComponent = $false }
            }
            Mock Get-ItemProperty { [pscustomobject]@{ ProductReleaseIds = 'O365HomePremRetail,Standard2024Volume' } } -ParameterFilter { $LiteralPath -like '*ClickToRun\Configuration' }
            $items = @(Get-GenesisLegacyOffice)
            @($items | Where-Object Kind -eq 'Starter2010').Count | Should -Be 1
            @($items | Where-Object Kind -eq 'Starter2010')[0].UninstallString | Should -Match '/removeall'
            @($items | Where-Object Kind -eq 'Starter2010')[0].Name | Should -Be 'Microsoft Office Starter 2010 - Français'
            @($items | Where-Object Kind -eq 'Msi').Name | Should -Be 'Microsoft Office Professionnel Plus 2016'
            @($items | Where-Object Kind -eq 'ClickToRun').Name | Should -Match 'O365HomePremRetail'
            @($items | Where-Object Kind -eq 'ClickToRun').Name | Should -Not -Match 'Standard2024Volume'
        }
    }

    It 'conserve l ancien Office sans installer Office 2024 si le technicien le choisit' {
        InModuleScope Genesis {
            Mock Get-GenesisOfficeInstallationStatus { @() }
            Mock Get-GenesisLegacyOffice { @([pscustomobject]@{ Kind = 'Starter2010'; Name = 'Office Starter 2010'; UninstallString = 'x' }) }
            Mock Remove-GenesisOfficeStarter2010 {}
            Mock Save-GenesisDownload { throw 'ne doit pas telecharger' }
            $result = Install-GenesisOffice2024 -RunDirectory $TestDrive -LegacyChoice 'KeepLegacy'
            $result.Status | Should -Be 'NeedsAttention'
            $result.Message | Should -Match 'Office Starter 2010'
            Should -Invoke Remove-GenesisOfficeStarter2010 -Exactly -Times 0
            { Assert-GenesisChoice -Choices @{ 'office-2024' = 'RemoveLegacy' } } | Should -Not -Throw
            { Assert-GenesisChoice -Choices @{ 'office-2024' = 'Autre' } } | Should -Throw
        }
    }

    It 'refuse un desinstalleur Office Starter 2010 hors de son emplacement Microsoft' {
        InModuleScope Genesis {
            Mock Invoke-GenesisNativeCommand { throw 'ne doit pas executer' }
            { Remove-GenesisOfficeStarter2010 -Item ([pscustomobject]@{ UninstallString = '"C:\Temp\cvhbs.exe" /removeall' }) } | Should -Throw '*inattendu*'
        }
    }

    It 'place Windows Update et la mise a niveau en dernier' {
        InModuleScope Genesis {
            $ordered = @(Get-GenesisStepOrder -Steps @('windows-feature-update', 'windows-update', 'explorer-home', 'power-ac'))
            ($ordered -join ',') | Should -Be 'explorer-home,power-ac,windows-update,windows-feature-update'
            $catalog = @(Get-GenesisStepCatalog | ForEach-Object { $_.Id })
            $catalog[-3] | Should -Be 'windows-update'
            $catalog[-2] | Should -Be 'windows-feature-update'
            $catalog[-1] | Should -Be 'fog-capture'
            $objects = @(Get-GenesisStepOrder -Steps @([pscustomobject]@{ Id = 'windows-update' }, [pscustomobject]@{ Id = 'time-sync' }))
            $objects[0].Id | Should -Be 'time-sync'
        }
    }

    It 'programme une tache SYSTEM au demarrage qui relance la copie protegee' -Tag Windows {
        $run = New-ContinuationRun -Root $script:DataRoot
        $script:TestPortable = Join-Path $TestDrive 'Genesis-Portable.ps1'
        Set-Content -LiteralPath $script:TestPortable -Value '# portable fictif'
        Mock Get-GenesisPortablePath -ModuleName Genesis { $script:TestPortable }
        Mock Register-ScheduledTask -ModuleName Genesis { $script:RegisteredTask = $PSBoundParameters }
        Register-GenesisUpdateContinuation -RunId $run.RunId -DataRoot $script:DataRoot | Out-Null
        $copy = Join-Path (Join-Path $script:DataRoot 'bin') 'Genesis-Portable.ps1'
        Test-Path -LiteralPath $copy | Should -BeTrue
        Should -Invoke Register-ScheduledTask -ModuleName Genesis -Exactly -Times 1 -ParameterFilter {
            ([System.Security.Principal.NTAccount]$Principal.UserId).Translate([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-18' -and $Principal.RunLevel -eq 'Highest' -and
            $Trigger[0].CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and
            $Action[0].Arguments -like ('*-File "' + $copy + '" -Action ContinueUpdates -RunId ' + $run.RunId + '*')
        }
        (Get-Content (Join-Path $run.Directory 'update-continuation.json') -Raw | ConvertFrom-Json).Outcome | Should -Be 'Scheduled'
    }
}

Describe 'Capture FOG dans une preparation' {
    BeforeEach {
        $script:DataRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Get-GenesisMachineId -ModuleName Genesis { 'machine-fictive' }
        Mock Get-GenesisUserSid -ModuleName Genesis { 'S-1-5-21-technicien' }
        Mock Protect-GenesisSecretText -ModuleName Genesis { 'CHIFFRE-FICTIF' }
        Mock Uninstall-GenesisFootprint -ModuleName Genesis { [pscustomobject]@{ Removed = @(); Failed = @(); Message = '' } }
        Mock Restart-GenesisComputer -ModuleName Genesis {}
        $script:FogSettings = [pscustomobject]@{ Server = 'fog.example.test'; ApiToken = 'cle-api-fictive'; UserToken = 'cle-user-fictive'; ImageName = 'Win11-Ref' }
    }

    It 'nest jamais cochee par defaut et passe apres les mises a jour' {
        InModuleScope Genesis {
            Test-GenesisStepSelectedByDefault -StepId 'fog-capture' | Should -BeFalse
            @(Get-GenesisStepOrder -Steps @('fog-capture', 'windows-update', 'explorer-home')) | Should -Be @('explorer-home', 'windows-update', 'fog-capture')
        }
    }

    It 'attend la fin des mises a jour Windows avant de generaliser' {
        Mock Invoke-GenesisCustomization -ModuleName Genesis {
            param($StepId)
            if ($StepId -eq 'windows-update') { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 100; Message = 'Redémarrage requis' } }
            [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Fait' }
        }
        $profileObject = [pscustomobject]@{ schemaVersion = 1; id = 'capture'; name = 'Capture'; steps = @('windows-update', 'fog-capture') }
        $run = Start-GenesisRun -ProfileObject $profileObject -FogSettings $script:FogSettings -DataRoot $script:DataRoot
        Should -Invoke Invoke-GenesisCustomization -ModuleName Genesis -Exactly -Times 0 -ParameterFilter { $StepId -eq 'fog-capture' }
        $capture = $run.Steps | Where-Object Id -eq 'fog-capture'
        $capture.Status | Should -Be 'Pending'
        $capture.Message | Should -Match 'mises à jour'
        Should -Invoke Restart-GenesisComputer -ModuleName Genesis -Exactly -Times 0
    }

    It 'garde les cles FOG hors de state.json puis efface Genesis et redemarre apres la capture' {
        Mock Invoke-GenesisCustomization -ModuleName Genesis { [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Capture programmée' } }
        $profileObject = [pscustomobject]@{ schemaVersion = 1; id = 'capture'; name = 'Capture'; steps = @('explorer-home', 'fog-capture') }
        $run = Start-GenesisRun -ProfileObject $profileObject -FogSettings $script:FogSettings -DataRoot $script:DataRoot
        $directory = Join-Path (Join-Path $script:DataRoot 'runs') $run.RunId
        (Get-Content (Join-Path $directory 'state.json') -Raw) | Should -Not -Match 'cle-api-fictive|cle-user-fictive'
        (Get-Content (Join-Path $directory 'fog-capture.protected') -Raw).Trim() | Should -Be 'CHIFFRE-FICTIF'
        Should -Invoke Protect-GenesisSecretText -ModuleName Genesis -Exactly -Times 1 -ParameterFilter { $Text -match 'http://fog\.example\.test' }
        Should -Invoke Uninstall-GenesisFootprint -ModuleName Genesis -Exactly -Times 1
        Should -Invoke Restart-GenesisComputer -ModuleName Genesis -Exactly -Times 1
    }

    It 'lance la capture depuis la reprise une fois Windows a jour' {
        $runId = [guid]::NewGuid().ToString('N')
        $directory = Join-Path (Join-Path $script:DataRoot 'runs') $runId
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
        $state = [pscustomobject]@{
            SchemaVersion = 1; GenesisVersion = (Get-Module Genesis).Version.ToString(); RunId = $runId
            MachineId = 'machine-fictive'; UserSid = 'S-1-5-21-technicien'; ProfileId = 'windows'
            CreatedAt = '2026-10-19T08:00:00Z'; FinishedAt = $null; Status = 'NeedsAttention'; Choices = [ordered]@{}
            Steps = @(
                [pscustomobject]@{ Id = 'windows-update'; Status = 'NeedsAttention'; Attempts = 1; StartedAt = $null; FinishedAt = $null; ErrorType = $null; Percent = 100; Message = 'Redémarrage requis'; UndoStatus = 'NotAvailable' }
                [pscustomobject]@{ Id = 'fog-capture'; Status = 'Pending'; Attempts = 0; StartedAt = $null; FinishedAt = $null; ErrorType = $null; Percent = 0; Message = ''; UndoStatus = 'NotAvailable' }
            )
        }
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $directory 'state.json') -Encoding UTF8
        [pscustomobject]@{ SchemaVersion = 1; RunId = $runId; MachineId = 'machine-fictive'; Reboots = 1; MaxReboots = 8; RegisteredAt = '2026-10-19T08:30:00Z'; FinishedAt = $null; Outcome = 'Scheduled' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'update-continuation.json') -Encoding UTF8
        Mock Unregister-GenesisUpdateContinuation -ModuleName Genesis {}
        Mock Send-GenesisSessionMessage -ModuleName Genesis {}
        Mock Invoke-GenesisWindowsUpdate -ModuleName Genesis { [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'À jour.' } }
        Mock Invoke-GenesisCustomization -ModuleName Genesis { [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Capture programmée' } }
        $result = Invoke-GenesisUpdateContinuation -RunId $runId -DataRoot $script:DataRoot -RetryDelaySeconds 0
        $result.Outcome | Should -Be 'Completed'
        Should -Invoke Invoke-GenesisCustomization -ModuleName Genesis -Exactly -Times 1 -ParameterFilter { $StepId -eq 'fog-capture' }
        Should -Invoke Send-GenesisSessionMessage -ModuleName Genesis -Exactly -Times 1 -ParameterFilter { $Message -match 'Capture FOG programmée' }
        Should -Invoke Uninstall-GenesisFootprint -ModuleName Genesis -Exactly -Times 1
        Should -Invoke Restart-GenesisComputer -ModuleName Genesis -Exactly -Times 1
    }
}
