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
        $windowsProfile.steps[0] | Should -Be 'windows-update'
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
            Get-GenesisWindowsUpdateSearchCriterion | Should -Be "IsInstalled=0 and IsHidden=0"
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
                if ($Criteria -ne 'IsInstalled=0 and IsHidden=0') { throw 'Critère de recherche inattendu.' }
                [pscustomobject]@{ Updates = @() }
            }
            $session = [pscustomobject]@{ Searcher = $searcher }
            Add-Member -InputObject $session -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { return $this.Searcher }
            $result = Invoke-GenesisWindowsUpdate -RunDirectory $Root -Session $session
            $result.Status | Should -Be 'Completed'
            $journal = Get-Content (Join-Path $Root 'windows-update.json') -Raw | ConvertFrom-Json
            $journal.SearchCriteria | Should -Be 'IsInstalled=0 and IsHidden=0'
            $journal.PendingReboot | Should -BeFalse
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
    It 'ne conserve que les quatre actions de preparation et la sortie' {
        InModuleScope Genesis {
            $entries = @(Get-GenesisMainMenuEntry)
            @($entries.Id) | Should -Be @('1', '2', '3', '4', '0')
            ($entries.Label -join ' | ') | Should -Not -Match 'Inventaire|Plan du profil|Catalogue|Reprendre|Afficher le tableau'
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
                GenesisVersion = '0.5.19'
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

    It 'genere une barre console pour une etape active' {
        InModuleScope Genesis {
            $line = ConvertTo-GenesisProgressBarLine -Label 'Initialisation' -Percent 50 -Width 20
            $line | Should -Match 'Initialisation'
            $line | Should -Match '50%'
            $line | Should -Match '█'
            $longLine = ConvertTo-GenesisProgressBarLine -Label 'Une opération très longue qui doit rester dans la colonne du libellé' -Percent 10 -Width 20 -LabelWidth 30
            $longLine.Length | Should -Be ($longLine.TrimEnd().Length)
        }
    }

    It 'ancre la progression sur une ligne fixe au lieu d ajouter une ligne par mise a jour' {
        $source = Get-Content (Join-Path $script:Repository 'modules/Genesis/Progress.ps1') -Raw
        $source | Should -Match 'GenesisConsoleProgressRow'
        $source | Should -Match '\[Console\]::SetCursorPosition'
        $source | Should -Match 'Initialize-GenesisConsoleProgressSurface'
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
