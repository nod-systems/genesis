Set-StrictMode -Version Latest
$script:GenesisVersion = '1.1.0'

function Get-GenesisStepCatalog {
    [CmdletBinding()]
    param()
    foreach ($entry in @(
        @('inventory', 'Identifier le matériel et Windows', 'Machine', $false, $false),
        @('explorer-home', 'Ouvrir l''Explorateur sur Ce PC', 'Utilisateur', $true, $true),
        @('windows-suggestions', 'Désactiver les conseils et suggestions Windows', 'Utilisateur', $true, $true),
        @('tray-icons', 'Afficher les icônes de notification présentes', 'Utilisateur', $true, $true),
        @('taskbar-controls', 'Masquer Recherche, Widgets et Vue des tâches', 'Machine et utilisateur', $true, $true),
        @('taskbar-left', 'Barre des tâches à gauche, sans Edge ni Microsoft Store', 'Utilisateur', $true, $true),
        @('start-cleanup', 'Nettoyer le menu Démarrer : Outlook (new), Xbox, Solitaire, WhatsApp, LinkedIn', 'Machine et utilisateur', $true, $false),
        @('time-sync', 'Mettre Windows à l''heure', 'Machine', $true, $true),
        @('office-2024', 'Installer et vérifier Office Standard 2024 LTSC français', 'Machine', $true, $false),
        @('browser', 'Installer Chrome ou Firefox et préparer le navigateur par défaut', 'Machine et utilisateur', $true, $false),
        @('pdf-reader', 'Installer Acrobat Reader, SumatraPDF ou PDFCraft', 'Machine et utilisateur', $true, $false),
        @('outlook-autodiscover', 'Exclure le point de terminaison Microsoft 365 dans Outlook classique', 'Utilisateur', $true, $true),
        @('power-ac', 'Mise en veille sur secteur : Jamais', 'Machine', $true, $true),
        @('local-user', 'Proposer la création d''une session utilisateur locale', 'Machine et utilisateur', $true, $true),
        @('netbird', 'Télécharger NetBird et configurer son serveur (sans connexion)', 'Machine', $true, $false),
        @('taskbar-pins', 'Épingler Explorateur, Word, Excel, PowerPoint, Outlook classique', 'Utilisateur', $true, $true),
        @('windows-update', 'Mettre à jour Windows + les mises à jour facultatives', 'Machine', $true, $false),
        @('windows-feature-update', 'Mettre à niveau Windows vers la dernière version proposée (ex. 26H2)', 'Machine', $true, $false),
        @('fog-capture', 'Généraliser Windows (Sysprep) et capturer l''image dans FOG', 'Machine', $true, $false)
    )) {
        [pscustomobject]@{ Id = $entry[0]; Name = $entry[1]; Context = $entry[2]; ChangesMachine = $entry[3]; Reversible = $entry[4] }
    }
}

function Get-GenesisStepOrder {
    param([AllowEmptyCollection()][object[]]$Steps = @())
    # Windows Update et la mise à niveau sont très longs et peuvent redémarrer le poste : toujours en dernier.
    # La capture FOG généralise Windows : elle passe après tout le reste.
    $updateIds = @('windows-update', 'windows-feature-update', 'fog-capture')
    $idOf = { param($item) if ($item -is [string]) { $item } else { [string]$item.Id } }
    $others = @($Steps | Where-Object { (& $idOf $_) -notin $updateIds })
    $updates = foreach ($id in $updateIds) { $Steps | Where-Object { (& $idOf $_) -ceq $id } }
    return @($others) + @($updates)
}

function Assert-GenesisProfileObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProfileObject)

    $genesisProfile = $ProfileObject
    if ($null -eq $genesisProfile -or $genesisProfile -is [array]) {
        throw 'Le profil doit être un objet JSON.'
    }
    $names = @($genesisProfile.PSObject.Properties.Name)
    $allowed = @('schemaVersion', 'id', 'name', 'steps')
    foreach ($name in $names) {
        if ($name -cnotin $allowed) { throw "Profil invalide : champ '$name' non autorisé." }
    }
    foreach ($name in $allowed) {
        if ($name -cnotin $names) { throw "Profil invalide : champ '$name' manquant." }
    }
    if (($genesisProfile.schemaVersion -isnot [int] -and $genesisProfile.schemaVersion -isnot [long]) -or $genesisProfile.schemaVersion -ne 1) {
        throw 'Version du schema de profil non prise en charge.'
    }
    if ($genesisProfile.id -isnot [string] -or $genesisProfile.id -cnotmatch '^[a-z][a-z0-9-]{0,63}$') {
        throw 'Identifiant du profil invalide.'
    }
    if ($genesisProfile.name -isnot [string] -or [string]::IsNullOrWhiteSpace($genesisProfile.name)) {
        throw 'Nom du profil invalide.'
    }
    if ($genesisProfile.steps -isnot [array] -or $genesisProfile.steps.Count -eq 0) {
        throw "Le profil doit contenir une liste non vide d'opérations."
    }
    $known = @(Get-GenesisStepCatalog).Id
    $seen = @{}
    foreach ($step in $genesisProfile.steps) {
        if ($step -isnot [string] -or $step -cnotin $known) { throw 'Opération inconnue dans le profil.' }
        if ($seen.ContainsKey($step)) { throw 'Opération en double dans le profil.' }
        $seen[$step] = $true
    }
    return $genesisProfile
}

function Get-GenesisProfile {
    [CmdletBinding()]
    param(
        [string]$Path,
        [object]$ProfileObject
    )

    if ($null -ne $ProfileObject) {
        return Assert-GenesisProfileObject -ProfileObject $ProfileObject
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Indiquer un chemin de profil ou un profil embarqué.' }
    $genesisProfile = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    return Assert-GenesisProfileObject -ProfileObject $genesisProfile
}

function Get-GenesisPlan {
    [CmdletBinding()]
    param(
        [string]$ProfilePath,
        [object]$ProfileObject
    )
    $genesisProfile = Get-GenesisProfile -Path $ProfilePath -ProfileObject $ProfileObject
    $catalog = @(Get-GenesisStepCatalog)
    $steps = @(Get-GenesisStepOrder -Steps @($genesisProfile.steps) | ForEach-Object {
        $id = $_
        $catalog | Where-Object { $_.Id -ceq $id }
    })
    [pscustomobject]@{
        GenesisVersion = $script:GenesisVersion
        ProfileId = $genesisProfile.id
        ProfileName = $genesisProfile.name
        Steps = $steps
    }
}

function Get-GenesisArchitecture {
    param([int]$Code)
    switch ($Code) {
        0 { 'x86' }
        5 { 'arm' }
        9 { 'x64' }
        12 { 'arm64' }
        default { 'unknown' }
    }
}

function ConvertTo-GenesisInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Computer,
        [Parameter(Mandatory)]$OperatingSystem,
        [Parameter(Mandatory)]$Bios,
        [AllowEmptyCollection()][array]$MemoryModules = @(),
        [AllowEmptyCollection()][array]$Processors = @(),
        [AllowEmptyCollection()][array]$Disks = @(),
        [AllowEmptyCollection()][array]$NetworkAdapters = @(),
        [AllowEmptyCollection()][array]$ProblemDevices = @()
    )
    $installedBytes = 0L
    foreach ($memoryModule in $MemoryModules) { $installedBytes += [long]$memoryModule.Capacity }
    $installedMemory = $null
    if ($installedBytes -gt 0) { $installedMemory = [math]::Round($installedBytes / 1GB, 2) }
    [pscustomobject]@{
        SchemaVersion = 1
        CollectedAt = [datetime]::UtcNow.ToString('o')
        Computer = [ordered]@{
            Name = $Computer.Name
            Manufacturer = $Computer.Manufacturer
            Model = $Computer.Model
            SerialNumber = $Bios.SerialNumber
            BiosVersion = $Bios.SMBIOSBIOSVersion
            MemoryGiB = [math]::Round($Computer.TotalPhysicalMemory / 1GB, 2)
            InstalledMemoryGiB = $installedMemory
        }
        OperatingSystem = [ordered]@{
            Name = $OperatingSystem.Caption
            Version = $OperatingSystem.Version
            Build = $OperatingSystem.BuildNumber
            Architecture = $OperatingSystem.OSArchitecture
            LastBoot = $OperatingSystem.LastBootUpTime.ToUniversalTime().ToString('o')
            IsWindows11 = ($OperatingSystem.Version -like '10.0.*' -and [int]$OperatingSystem.BuildNumber -ge 22000 -and $OperatingSystem.Caption -notmatch 'Server')
        }
        Processors = @($Processors | ForEach-Object {
            [ordered]@{
                Name = ([string]$_.Name).Trim()
                Cores = $_.NumberOfCores
                LogicalProcessors = $_.NumberOfLogicalProcessors
                Architecture = Get-GenesisArchitecture -Code $_.Architecture
            }
        })
        Disks = @($Disks | ForEach-Object {
            [ordered]@{ Model = $_.Model; SizeGiB = [math]::Round($_.Size / 1GB, 2); Interface = $_.InterfaceType }
        })
        NetworkAdapters = @($NetworkAdapters | ForEach-Object {
            [ordered]@{ Name = $_.Description; MacAddress = $_.MACAddress; Addresses = @($_.IPAddress) }
        })
        ProblemDevices = @($ProblemDevices | ForEach-Object {
            [ordered]@{ Name = $_.Name; DeviceId = $_.PNPDeviceID; ErrorCode = $_.ConfigManagerErrorCode }
        })
    }
}

function Get-GenesisInventory {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { throw "L'inventaire Genesis doit être exécuté sur Windows." }
    $arguments = @{
        Computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        Bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        MemoryModules = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
        Processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        Disks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)
        NetworkAdapters = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction Stop)
        ProblemDevices = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop)
    }
    ConvertTo-GenesisInventory @arguments
}

function ConvertTo-GenesisAsciiTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Headers,
        [AllowEmptyCollection()][object[]]$Rows = @()
    )
    $columnCount = $Headers.Count
    if ($columnCount -eq 0) { return '' }
    $normalizedRows = @()
    foreach ($row in @($Rows)) {
        $cells = @($row)
        $normalizedRows += ,(@(for ($index = 0; $index -lt $columnCount; $index++) {
            $value = if ($index -lt $cells.Count) { [string]$cells[$index] } else { '' }
            $value = $value -replace '[\r\n\t]+', ' '
            if ($value.Length -gt 60) { $value = $value.Substring(0, 57) + '...' }
            $value.Trim()
        }))
    }
    $widths = @($Headers | ForEach-Object { [string]$_ | ForEach-Object { $_.Length } })
    foreach ($row in $normalizedRows) {
        for ($index = 0; $index -lt $columnCount; $index++) {
            if ($row[$index].Length -gt $widths[$index]) { $widths[$index] = $row[$index].Length }
        }
    }
    $makeBorder = '+' + (($widths | ForEach-Object { [string]::new('-', $_ + 2) }) -join '+') + '+'
    $lines = @($makeBorder)
    $headerCells = @()
    for ($index = 0; $index -lt $columnCount; $index++) {
        $headerCells += (' ' + ([string]$Headers[$index]).PadRight($widths[$index]) + ' ')
    }
    $lines += '|' + ($headerCells -join '|') + '|'
    $lines += $makeBorder
    foreach ($row in $normalizedRows) {
        $cells = @()
        for ($index = 0; $index -lt $columnCount; $index++) {
            $cells += (' ' + $row[$index].PadRight($widths[$index]) + ' ')
        }
        $lines += '|' + ($cells -join '|') + '|'
    }
    $lines += $makeBorder
    return ($lines -join [Environment]::NewLine)
}

function Format-GenesisInventoryAscii {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)
    $lines = @('GENESIS - INVENTAIRE MATERIEL ET WINDOWS', '')
    $computer = $Inventory.Computer
    $os = $Inventory.OperatingSystem
    $computerRows = @(
        @('Nom', $computer.Name), @('Constructeur', $computer.Manufacturer), @('Modèle', $computer.Model),
        @('Numéro de série', $computer.SerialNumber), @('BIOS', $computer.BiosVersion),
        @('RAM accessible (GiB)', $computer.MemoryGiB), @('RAM installée (GiB)', $computer.InstalledMemoryGiB)
    )
    $osRows = @(
        @('Édition', $os.Name), @('Version', $os.Version), @('Build', $os.Build),
        @('Architecture', $os.Architecture), @('Dernier démarrage UTC', $os.LastBoot), @('Windows 11', $os.IsWindows11)
    )
    $lines += 'ORDINATEUR'; $lines += ConvertTo-GenesisAsciiTable -Headers @('Champ', 'Valeur') -Rows $computerRows
    $lines += ''; $lines += 'SYSTEME'; $lines += ConvertTo-GenesisAsciiTable -Headers @('Champ', 'Valeur') -Rows $osRows
    $processorRows = @($Inventory.Processors | ForEach-Object { ,@($_.Name, $_.Cores, $_.LogicalProcessors, $_.Architecture) })
    $lines += ''; $lines += 'PROCESSEURS'; $lines += ConvertTo-GenesisAsciiTable -Headers @('Nom', 'Coeurs', 'Logiques', 'Architecture') -Rows $processorRows
    $diskRows = @($Inventory.Disks | ForEach-Object { ,@($_.Model, $_.SizeGiB, $_.Interface) })
    $lines += ''; $lines += 'DISQUES'; $lines += ConvertTo-GenesisAsciiTable -Headers @('Modele', 'Taille GiB', 'Interface') -Rows $diskRows
    $networkRows = @($Inventory.NetworkAdapters | ForEach-Object { ,@($_.Name, $_.MacAddress, (@($_.Addresses) -join ', ')) })
    $lines += ''; $lines += 'RESEAU'; $lines += ConvertTo-GenesisAsciiTable -Headers @('Interface', 'MAC', 'Adresses') -Rows $networkRows
    $problemRows = @($Inventory.ProblemDevices | ForEach-Object { ,@($_.Name, $_.ErrorCode, $_.DeviceId) })
    $lines += ''; $lines += 'PERIPHERIQUES EN ERREUR'; $lines += ConvertTo-GenesisAsciiTable -Headers @('Nom', 'Code', 'Identifiant') -Rows $problemRows
    return ($lines -join [Environment]::NewLine)
}

function ConvertTo-GenesisFixedAsciiTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Headers,
        [AllowEmptyCollection()][object[]]$Rows = @(),
        [Parameter(Mandatory)][ValidateCount(1, 20)][int[]]$ColumnWidths
    )
    if ($Headers.Count -ne $ColumnWidths.Count) { throw 'Le nombre de colonnes et de largeurs doit être identique.' }
    $columnCount = $Headers.Count
    $makeBorder = '+' + (($ColumnWidths | ForEach-Object { '-' * ($_ + 2) }) -join '+') + '+'
    $lines = @($makeBorder)
    $headerCells = @()
    for ($index = 0; $index -lt $columnCount; $index++) {
        $header = ConvertTo-GenesisConsoleLabel -Text $Headers[$index] -Width $ColumnWidths[$index]
        $headerCells += (' ' + $header.PadRight($ColumnWidths[$index]) + ' ')
    }
    $lines += '|' + ($headerCells -join '|') + '|'
    $lines += $makeBorder
    foreach ($row in @($Rows)) {
        $cells = @($row)
        $cellLines = @()
        $height = 1
        for ($index = 0; $index -lt $columnCount; $index++) {
            $value = if ($index -lt $cells.Count) { [string]$cells[$index] } else { '' }
            $parts = @(ConvertTo-GenesisWrappedLine -Text $value -Width $ColumnWidths[$index])
            $cellLines += ,$parts
            if ($parts.Count -gt $height) { $height = $parts.Count }
        }
        for ($lineIndex = 0; $lineIndex -lt $height; $lineIndex++) {
            $outputCells = @()
            for ($index = 0; $index -lt $columnCount; $index++) {
                $part = if ($lineIndex -lt $cellLines[$index].Count) { $cellLines[$index][$lineIndex] } else { '' }
                $outputCells += (' ' + $part.PadRight($ColumnWidths[$index]) + ' ')
            }
            $lines += '|' + ($outputCells -join '|') + '|'
        }
    }
    $lines += $makeBorder
    return ($lines -join [Environment]::NewLine)
}

function ConvertTo-GenesisWrappedLine {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Width)
    $value = ($Text -replace '[\r\n\t]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return @('') }
    $result = @()
    while ($value.Length -gt $Width) {
        $cut = $value.LastIndexOf(' ', $Width - 1)
        if ($cut -le 0) { $cut = $Width }
        $result += $value.Substring(0, $cut).Trim()
        $value = $value.Substring($cut).TrimStart()
    }
    $result += $value
    return $result
}

function Get-GenesisMachineId {
    if ($env:OS -eq 'Windows_NT') {
        return (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
    }
    return [System.Environment]::MachineName
}

function Test-GenesisAdministrator {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { return $true }
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Assert-GenesisAdministrator {
    [CmdletBinding()]
    param()
    if (-not (Test-GenesisAdministrator)) {
        throw 'Genesis doit être lancé dans une fenêtre PowerShell exécutée en tant qu''administrateur.'
    }
}

function Resolve-GenesisDataRoot {
    param([string]$DataRoot)
    if (-not [string]::IsNullOrWhiteSpace($DataRoot)) { return [System.IO.Path]::GetFullPath($DataRoot) }
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { throw 'Indiquer -DataRoot pour les tests hors Windows.' }
    return Join-Path $env:ProgramData 'Genesis'
}

function Initialize-GenesisDataRoot {
    param([Parameter(Mandatory)][string]$DataRoot)
    if (-not (Test-Path -LiteralPath $DataRoot)) {
        New-Item -Path $DataRoot -ItemType Directory -ErrorAction Stop | Out-Null
        if ($env:OS -eq 'Windows_NT') {
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $DataRoot -AclObject $acl -ErrorAction Stop
        }
    }
}

function Protect-GenesisDataRoot {
    param([Parameter(Mandatory)][string]$DataRoot, [string]$LockPath)
    if ($env:OS -ne 'Windows_NT') { return }
    $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $root = New-Object System.IO.DirectoryInfo([System.IO.Path]::GetFullPath($DataRoot))
    $pending = New-Object System.Collections.Generic.Queue[System.IO.FileSystemInfo]
    $pending.Enqueue($root)
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Lien ou jonction interdit dans le répertoire de données Genesis : $($item.FullName)"
        }
        if ($LockPath -and $item.FullName -eq $LockPath) { continue }
        try {
            $security = $item.GetAccessControl()
            $security.SetOwner($administrators)
            foreach ($rule in @($security.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
                [void]$security.RemoveAccessRuleSpecific($rule)
            }
            if ($item -eq $root) {
                # Racine : seules les règles SYSTEM et Administrateurs, sans héritage de ProgramData.
                $security.SetAccessRuleProtection($true, $false)
                foreach ($identity in @($system, $administrators)) {
                    $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
                }
            }
            else { $security.SetAccessRuleProtection($false, $false) }
            $item.SetAccessControl($security)
        }
        catch {
            throw "Le répertoire de données Genesis n'a pas pu être protégé ($($item.FullName)) : $($_.Exception.Message). Le supprimer ou corriger ses droits avant de relancer Genesis."
        }
        if ($item -is [System.IO.DirectoryInfo]) {
            foreach ($child in $item.GetFileSystemInfos()) { $pending.Enqueue($child) }
        }
    }
}

function Write-GenesisJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = ($Value | ConvertTo-Json -Depth 16) + [System.Environment]::NewLine
        [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [System.IO.File]::Move($temporary, $Path) }
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Add-GenesisEvent {
    param([string]$RunDirectory, [string]$EventName, [string]$StepId = '', [string]$ErrorType = '')
    $record = [ordered]@{
        Timestamp = [datetime]::UtcNow.ToString('o')
        Event = $EventName
        StepId = $StepId
        ErrorType = $ErrorType
    }
    $line = ($record | ConvertTo-Json -Compress) + [System.Environment]::NewLine
    [System.IO.File]::AppendAllText((Join-Path $RunDirectory 'events.jsonl'), $line, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-GenesisRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
        [string]$DataRoot
    )
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    $path = Join-Path (Join-Path (Join-Path $root 'runs') $RunId) 'state.json'
    $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($state.SchemaVersion -ne 1 -or $state.RunId -cne $RunId -or $state.Steps -isnot [array] -or $state.Steps.Count -eq 0) {
        throw 'Etat de preparation invalide.'
    }
    if ($state.Status -cnotin @('Pending', 'Running', 'Completed', 'Failed', 'NeedsAttention', 'Skipped', 'AwaitingSession', 'Restoring', 'Restored', 'RestoreConflict')) {
        throw 'Statut global invalide dans la preparation.'
    }
    if ($state.PSObject.Properties.Name -contains 'Choices') { Assert-GenesisChoice -Choices $state.Choices | Out-Null }
    $known = @(Get-GenesisStepCatalog).Id
    foreach ($step in $state.Steps) {
        if ($step.Id -cnotin $known -or $step.Status -notin @('Pending', 'Running', 'Completed', 'Failed', 'NeedsAttention', 'Skipped', 'AwaitingSession', 'Restoring', 'Restored', 'RestoreConflict')) {
            throw "Opération ou statut invalide dans l'état de préparation."
        }
        if ($state.Status -eq 'Completed' -and $step.Status -ne 'Completed') {
            throw 'Etat de preparation incoherent.'
        }
        if ($step.Status -eq 'Completed' -and $step.Id -eq 'inventory') {
            $inventoryPath = Join-Path (Split-Path -Parent $path) 'inventory.json'
            try {
                $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($inventory.SchemaVersion -ne 1) { throw 'Schema invalide.' }
            }
            catch { throw 'Inventaire absent ou invalide pour cette preparation.' }
        }
    }
    return $state
}

function Get-GenesisReverseCandidate {
    [CmdletBinding()]
    param([string]$DataRoot)

    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    $runsRoot = Join-Path $root 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) { return @() }

    $catalog = @(Get-GenesisStepCatalog)
    $statusLabels = @{
        Pending = 'À faire'; Running = 'En cours'; Completed = 'Fait'; Failed = 'Échec'
        NeedsAttention = 'À vérifier'; Skipped = 'Ignoré'; AwaitingSession = 'À vérifier'
        Restoring = 'Restauration'; Restored = 'Restauré'; RestoreConflict = 'Conflit'
    }
    $records = foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($directory.Name -notmatch '^[a-f0-9]{32}$') { continue }
        try {
            $state = Get-GenesisRun -RunId $directory.Name -DataRoot $root
            $profileName = [string]$state.ProfileId
            $profilePath = Join-Path $directory.FullName 'profile.json'
            if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
                try {
                    $profileRecord = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $profileRecord = Assert-GenesisProfileObject -ProfileObject $profileRecord
                    $profileName = [string]$profileRecord.name
                }
                catch { Write-Verbose ('Profil de la préparation illisible : ' + $directory.Name) }
            }

            $steps = @($state.Steps)
            $stepNames = @($steps | ForEach-Object {
                    $stepId = [string]$_.Id
                    $definition = $catalog | Where-Object { $_.Id -ceq $stepId } | Select-Object -First 1
                    if ($null -eq $definition) { $stepId } else { [string]$definition.Name }
                })
            $reversibleSteps = @($steps | Where-Object {
                    $_.UndoStatus -ne 'Restored' -and (Test-GenesisUndoAvailable -StepId ([string]$_.Id) -RunDirectory $directory.FullName)
                })
            $choiceSummary = @()
            $browserChoice = Get-GenesisChoiceValue -Choices $state.Choices -Name 'browser'
            if (-not [string]::IsNullOrWhiteSpace($browserChoice)) { $choiceSummary += 'Navigateur : ' + $browserChoice }
            $pdfChoice = Get-GenesisChoiceValue -Choices $state.Choices -Name 'pdf-reader'
            if (-not [string]::IsNullOrWhiteSpace($pdfChoice)) { $choiceSummary += 'PDF : ' + $pdfChoice }
            $createdAt = [string]$state.CreatedAt
            $finishedAt = [string]$state.FinishedAt
            $createdLabel = $createdAt
            try { $createdLabel = ([datetime]$state.CreatedAt).ToLocalTime().ToString('dd/MM/yyyy HH:mm') } catch { Write-Verbose 'Date de préparation illisible.' }
            $finishedLabel = $finishedAt
            if (-not [string]::IsNullOrWhiteSpace($finishedAt)) {
                try { $finishedLabel = ([datetime]$state.FinishedAt).ToLocalTime().ToString('dd/MM/yyyy HH:mm') } catch { Write-Verbose 'Date de fin illisible.' }
            }
            [pscustomobject]@{
                RunId = [string]$state.RunId
                ShortRunId = ([string]$state.RunId).Substring(0, 8)
                GenesisVersion = [string]$state.GenesisVersion
                VersionCompatible = ([string]$state.GenesisVersion -ceq $script:GenesisVersion)
                ProfileId = [string]$state.ProfileId
                ProfileName = $profileName
                Status = [string]$state.Status
                StatusLabel = if ($statusLabels.ContainsKey([string]$state.Status)) { $statusLabels[[string]$state.Status] } else { [string]$state.Status }
                CreatedAt = $createdAt
                CreatedLabel = $createdLabel
                FinishedAt = $finishedAt
                FinishedLabel = $finishedLabel
                ActionCount = $steps.Count
                CompletedCount = @($steps | Where-Object { $_.Status -eq 'Completed' }).Count
                ReversibleCount = $reversibleSteps.Count
                CanUndo = ($reversibleSteps.Count -gt 0 -and [string]$state.GenesisVersion -ceq $script:GenesisVersion)
                ReverseReason = if ($reversibleSteps.Count -eq 0) { 'Aucune sauvegarde restaurable.' } elseif ([string]$state.GenesisVersion -cne $script:GenesisVersion) { 'Version Genesis différente.' } else { 'Prêt' }
                ActionIds = @($steps | ForEach-Object { [string]$_.Id })
                ActionNames = $stepNames
                ActionSummary = if ($stepNames.Count -gt 0) { $stepNames -join ', ' } else { 'Aucune action enregistrée.' }
                ChoiceSummary = $choiceSummary
                Directory = $directory.FullName
            }
        }
        catch { Write-Verbose ('Préparation ignorée car invalide ou inaccessible : ' + $directory.Name) }
    }
    @($records | Sort-Object @{ Expression = { if ($_.CanUndo) { 0 } else { 1 } }; Ascending = $true }, @{ Expression = { try { [datetime]$_.CreatedAt } catch { [datetime]::MinValue } }; Descending = $true })
}

function Invoke-GenesisRunExecution {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$RunDirectory)
    $path = Join-Path $RunDirectory 'state.json'
    # Les barres de progression des cmdlets (Appx, téléchargements…) se superposent au tableau :
    # elles sont coupées pendant l'exécution (variable locale, rétablie à la sortie de la fonction).
    $ProgressPreference = 'SilentlyContinue'
    Initialize-GenesisConsoleProgressSurface
    $State.Status = 'Running'
    $State.FinishedAt = $null
    Write-GenesisJson -Path $path -Value $State
    Write-GenesisConsoleProgress -State $State
    Add-GenesisEvent -RunDirectory $RunDirectory -EventName 'run_started'
    # Les préparations créées avant ce changement gardent leur ordre enregistré : on réordonne à l'exécution.
    $State.Steps = @(Get-GenesisStepOrder -Steps @($State.Steps))
    foreach ($step in $State.Steps) {
        if ($step.Status -eq 'Completed') {
            if (Test-GenesisUndoAvailable -StepId $step.Id -RunDirectory $RunDirectory) { $step.UndoStatus = 'Available' }
            continue
        }
        if ($step.Id -eq 'windows-feature-update' -and
            @($State.Steps | Where-Object { $_.Id -eq 'windows-update' -and $_.Status -eq 'NeedsAttention' }).Count -gt 0) {
            # La mise à niveau attend que les correctifs installés soient finalisés par le redémarrage.
            $step.Message = 'En attente du redémarrage des mises à jour Windows.'
            Write-GenesisJson -Path $path -Value $State
            Write-GenesisConsoleProgress -State $State
            continue
        }
        if ($step.Id -eq 'fog-capture') {
            # Sysprep sur un poste incomplet donnerait une image incomplète : la capture attend.
            $blocker = Get-GenesisFogCaptureBlocker -State $State
            if ($null -ne $blocker) {
                $step.Message = $blocker
                Write-GenesisJson -Path $path -Value $State
                Write-GenesisConsoleProgress -State $State
                continue
            }
        }
        $step.Status = 'Running'; $step.Percent = 10; $step.Message = 'Sauvegarde et exécution'
        $step.Attempts += 1; $step.ErrorType = $null
        $script:GenesisStepErrors.Remove($step.Id)
        $step.StartedAt = [datetime]::UtcNow.ToString('o'); $step.FinishedAt = $null
        Write-GenesisJson -Path $path -Value $State
        Write-GenesisConsoleProgress -State $State
        Add-GenesisEvent -RunDirectory $RunDirectory -EventName 'step_started' -StepId $step.Id
        try {
            if ($step.Id -eq 'inventory') {
                $inventory = Get-GenesisInventory
                Write-GenesisJson -Path (Join-Path $RunDirectory 'inventory.json') -Value $inventory
                $step.Status = 'Completed'; $step.Percent = 100; $step.Message = 'Inventaire enregistré'
            }
            else {
                $choices = if ($State.PSObject.Properties.Name -contains 'Choices') { $State.Choices } else { $null }
                $result = Invoke-GenesisCustomization -StepId $step.Id -RunDirectory $RunDirectory -Choices $choices
                $step.Status = $result.Status; $step.Percent = $result.Percent; $step.Message = $result.Message
            }
            $step.FinishedAt = [datetime]::UtcNow.ToString('o')
            if (Test-GenesisUndoAvailable -StepId $step.Id -RunDirectory $RunDirectory) { $step.UndoStatus = 'Available' }
            Write-GenesisJson -Path $path -Value $State
            Request-GenesisConsoleRedraw
            Write-GenesisConsoleProgress -State $State
            Add-GenesisEvent -RunDirectory $RunDirectory -EventName 'step_finished' -StepId $step.Id
        }
        catch {
            $step.Status = 'Failed'; $step.Percent = 0
            $step.Message = 'Échec : consulter les prérequis puis reprendre ou restaurer.'
            # Motif réel affiché à l'écran uniquement : il peut contenir des données privées et n'est jamais écrit dans state.json.
            $reason = ([string]$_.Exception.Message -replace '[\r\n\t]+', ' ').Trim()
            if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 297) + '...' }
            if (-not [string]::IsNullOrWhiteSpace($reason)) { $script:GenesisStepErrors[$step.Id] = 'Échec : ' + $reason }
            $step.FinishedAt = [datetime]::UtcNow.ToString('o')
            $step.ErrorType = $_.Exception.GetType().FullName
            if (Test-GenesisUndoAvailable -StepId $step.Id -RunDirectory $RunDirectory) { $step.UndoStatus = 'Available' }
            $State.Status = 'Failed'
            Write-GenesisJson -Path $path -Value $State
            Request-GenesisConsoleRedraw
            Write-GenesisConsoleProgress -State $State
            Add-GenesisEvent -RunDirectory $RunDirectory -EventName 'step_failed' -StepId $step.Id -ErrorType $step.ErrorType
            if ($step.Id -eq 'inventory') { throw }
        }
    }
    $State.Status = 'Completed'
    if (@($State.Steps | Where-Object { $_.Status -ne 'Completed' }).Count -gt 0) { $State.Status = 'NeedsAttention' }
    $State.FinishedAt = [datetime]::UtcNow.ToString('o')
    Write-GenesisJson -Path $path -Value $State
    Write-GenesisConsoleProgress -State $State
    Add-GenesisEvent -RunDirectory $RunDirectory -EventName ('run_' + $State.Status.ToLowerInvariant())
    return $State
}

function Open-GenesisRunLock {
    param([Parameter(Mandatory)][string]$DataRoot)
    $root = try { [System.IO.Path]::GetFullPath($DataRoot) } catch {
        throw "Le répertoire de données Genesis est inaccessible : $DataRoot"
    }
    try {
        if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction Stop)) {
            throw "Le répertoire de données Genesis est absent ou inaccessible : $root"
        }
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        throw "Le répertoire de données Genesis est absent ou inaccessible : $root"
    }
    $lockPath = Join-Path $root '.lock'
    try {
        $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException -and $exception -is [System.Management.Automation.MethodInvocationException]) {
            $exception = $exception.InnerException
        }
        $win32Error = ($exception.HResult -band 0xFFFF)
        if ($win32Error -in @(32, 33)) {
            throw "Une autre exécution Genesis est déjà en cours (verrou : $lockPath)."
        }
        if ($exception -is [System.UnauthorizedAccessException]) {
            throw "Le répertoire de données Genesis est inaccessible (accès refusé) : $root. Lancez PowerShell en tant qu’administrateur."
        }
        throw "Le verrou Genesis est inaccessible : $lockPath ($($exception.Message))"
    }
    # Les sauvegardes sont relues avec les droits administrateur : le répertoire
    # doit être protégé même s'il a été créé avant Genesis.
    try { Protect-GenesisDataRoot -DataRoot $root -LockPath $lockPath }
    catch {
        $lock.Dispose()
        throw
    }
    return $lock
}

function Start-GenesisRun {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ProfilePath,
        [object]$ProfileObject,
        [object]$Choices,
        [object]$FogSettings,
        [string]$DataRoot,
        [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId
    )
    $genesisProfile = Get-GenesisProfile -Path $ProfilePath -ProfileObject $ProfileObject
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    if (-not $PSCmdlet.ShouldProcess($root, "Exécuter le profil Genesis")) {
        return Get-GenesisPlan -ProfilePath $ProfilePath -ProfileObject $ProfileObject
    }
    Assert-GenesisAdministrator
    Initialize-GenesisDataRoot -DataRoot $root
    $lock = Open-GenesisRunLock -DataRoot $root
    try {
        if (-not $RunId) { $RunId = [guid]::NewGuid().ToString('N') }
        $directory = Join-Path (Join-Path $root 'runs') $runId
        if (Test-Path -LiteralPath $directory) { throw 'Cet identifiant de préparation existe déjà.' }
        New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $state = [pscustomobject]@{
            SchemaVersion = 1
            GenesisVersion = $script:GenesisVersion
            RunId = $runId
            MachineId = Get-GenesisMachineId
            UserSid = Get-GenesisUserSid
            ProfileId = $genesisProfile.id
            CreatedAt = [datetime]::UtcNow.ToString('o')
            FinishedAt = $null
            Status = 'Pending'
            Choices = (Assert-GenesisChoice -Choices $Choices)
            Steps = @(Get-GenesisStepOrder -Steps @($genesisProfile.steps) | ForEach-Object {
                [pscustomobject]@{ Id = $_; Status = 'Pending'; Attempts = 0; StartedAt = $null; FinishedAt = $null; ErrorType = $null; Percent = 0; Message = ''; UndoStatus = 'NotAvailable' }
            })
        }
        Write-GenesisJson -Path (Join-Path $directory 'profile.json') -Value $genesisProfile
        # Les clés FOG restent hors de state.json, chiffrées pour ce poste.
        if ($null -ne $FogSettings -and @($genesisProfile.steps) -contains 'fog-capture') { Save-GenesisFogConfiguration -RunDirectory $directory -Settings $FogSettings }
        Write-GenesisJson -Path (Join-Path $directory 'state.json') -Value $state
        $result = Invoke-GenesisRunExecution -State $state -RunDirectory $directory
    }
    finally { $lock.Dispose() }
    Complete-GenesisFogCapture -State $result -DataRoot $root | Out-Null
    return $result
}

function Resume-GenesisRun {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
        [string]$DataRoot
    )
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Reprendre les actions non terminées')) { return }
    Assert-GenesisAdministrator
    $lock = Open-GenesisRunLock -DataRoot $root
    try {
        $state = Get-GenesisRun -RunId $RunId -DataRoot $root
        if ($state.MachineId -cne (Get-GenesisMachineId)) { throw 'Cette préparation appartient à un autre ordinateur.' }
        if ($state.PSObject.Properties.Name -contains 'UserSid' -and $state.UserSid -cne (Get-GenesisUserSid)) { throw 'Cette préparation appartient à un autre utilisateur.' }
        if ($state.GenesisVersion -cne $script:GenesisVersion) { throw 'La version de Genesis diffère de celle de la préparation.' }
        if ($state.Status -in @('Restored', 'RestoreConflict', 'Restoring')) { throw 'Créer une nouvelle préparation après une restauration.' }
        if ($state.Status -eq 'Completed') { return $state }
        $directory = Join-Path (Join-Path $root 'runs') $RunId
        Add-GenesisEvent -RunDirectory $directory -EventName 'run_resumed'
        $result = Invoke-GenesisRunExecution -State $state -RunDirectory $directory
    }
    finally { $lock.Dispose() }
    Complete-GenesisFogCapture -State $result -DataRoot $root | Out-Null
    return $result
}

$script:GenesisUpdateTaskName = 'Genesis - reprise Windows Update'
$script:GenesisUpdateMaxReboots = 8
$script:GenesisUpdateRestartDelaySeconds = 60

function Get-GenesisPortablePath {
    # Renseigné par Genesis-Portable.ps1 : le mode module n'a pas de fichier unique à relancer.
    return Get-Variable -Scope Script -Name GenesisPortablePath -ValueOnly -ErrorAction SilentlyContinue
}

function Test-GenesisUpdateRebootPending {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $journalPath = Join-Path $RunDirectory 'windows-update.json'
    if (Test-Path -LiteralPath $journalPath) {
        try {
            if ((Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json).PendingReboot -eq $true) { return $true }
        }
        catch { Write-Verbose 'Journal Windows Update illisible.' }
    }
    if ($env:OS -ne 'Windows_NT') { return $false }
    return (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

$script:GenesisUpdateStepIds = @('windows-update', 'windows-feature-update')

function Test-GenesisUpdateContinuationNeeded {
    param([Parameter(Mandatory)]$State)
    # Windows Update ne termine en NeedsAttention que pour un redémarrage ou des mises à jour restantes.
    return (@($State.Steps | Where-Object { $_.Id -in $script:GenesisUpdateStepIds -and $_.Status -eq 'NeedsAttention' }).Count -gt 0)
}

function Restart-GenesisComputer {
    param([ValidateRange(0, 600)][int]$DelaySeconds = 60, [Parameter(Mandatory)][ValidatePattern('^[^"]+$')][string]$Reason)
    $result = Invoke-GenesisNativeCommand -FilePath 'shutdown.exe' -Arguments ('/r /t {0} /d p:2:17 /c "{1}"' -f $DelaySeconds, $Reason)
    if ($result.ExitCode -ne 0) { throw "Redémarrage refusé par Windows (code $($result.ExitCode))." }
}

function Unregister-GenesisUpdateContinuation {
    if ($null -ne (Get-ScheduledTask -TaskName $script:GenesisUpdateTaskName -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $script:GenesisUpdateTaskName -Confirm:$false -ErrorAction Stop
    }
}

function Register-GenesisUpdateContinuation {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
        [string]$DataRoot
    )
    $source = Get-GenesisPortablePath
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw 'La reprise automatique après redémarrage nécessite Genesis-Portable.ps1.'
    }
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Programmer la reprise de Windows Update au démarrage')) { return }
    Assert-GenesisAdministrator
    $lock = Open-GenesisRunLock -DataRoot $root
    try {
        $state = Get-GenesisRun -RunId $RunId -DataRoot $root
        if ($state.MachineId -cne (Get-GenesisMachineId)) { throw 'Cette préparation appartient à un autre ordinateur.' }
        if (-not (Test-GenesisUpdateContinuationNeeded -State $state)) { throw 'Aucune mise à jour Windows en attente dans cette préparation.' }
        $directory = Join-Path (Join-Path $root 'runs') $RunId
        # Le lanceur supprime sa copie temporaire : la tâche démarre une copie du répertoire protégé.
        $binDirectory = Join-Path $root 'bin'
        New-Item -Path $binDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $target = Join-Path $binDirectory 'Genesis-Portable.ps1'
        Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
            throw 'Copie de Genesis incohérente ; reprise automatique non programmée.'
        }
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action ContinueUpdates -RunId {1} -DataRoot "{2}"' -f $target, $RunId, $root
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = 'PT1M'
        $task = @{
            TaskName = $script:GenesisUpdateTaskName
            Description = 'Reprise des mises à jour Windows de la préparation Genesis ' + $RunId
            Action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
            Trigger = $trigger
            Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 8)
        }
        Register-ScheduledTask @task -Force -ErrorAction Stop | Out-Null
        $continuation = [pscustomobject]@{
            SchemaVersion = 1; RunId = $RunId; MachineId = Get-GenesisMachineId
            Reboots = 0; MaxReboots = $script:GenesisUpdateMaxReboots
            RegisteredAt = [datetime]::UtcNow.ToString('o'); FinishedAt = $null; Outcome = 'Scheduled'
        }
        Write-GenesisJson -Path (Join-Path $directory 'update-continuation.json') -Value $continuation
        Add-GenesisEvent -RunDirectory $directory -EventName 'update_continuation_registered' -StepId 'windows-update'
        return $continuation
    }
    finally { $lock.Dispose() }
}

function Send-GenesisSessionMessage {
    param([Parameter(Mandatory)][string]$Message)
    try { Invoke-GenesisNativeCommand -FilePath 'msg.exe' -Arguments ('* /TIME:3600 "{0}"' -f ($Message -replace '"', "'")) | Out-Null }
    catch { Write-Verbose ('Notification de session impossible : ' + $_.Exception.Message) }
}

function Invoke-GenesisUpdateContinuation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
        [string]$DataRoot,
        [ValidateRange(0, 600)][int]$RetryDelaySeconds = 60
    )
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    Assert-GenesisAdministrator
    $restart = $false
    $notice = $null
    $lock = Open-GenesisRunLock -DataRoot $root
    try {
        $directory = Join-Path (Join-Path $root 'runs') $RunId
        $continuationPath = Join-Path $directory 'update-continuation.json'
        $state = Get-GenesisRun -RunId $RunId -DataRoot $root
        $continuation = Get-Content -LiteralPath $continuationPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $updateSteps = @($state.Steps | Where-Object { $_.Id -in $script:GenesisUpdateStepIds })
        $stopReason = $null
        if ($state.MachineId -cne (Get-GenesisMachineId) -or $continuation.MachineId -cne (Get-GenesisMachineId)) { $stopReason = 'Préparation d''un autre ordinateur.' }
        elseif ($state.GenesisVersion -cne $script:GenesisVersion) { $stopReason = 'Version de Genesis différente.' }
        elseif ($state.Status -in @('Restoring', 'Restored', 'RestoreConflict')) { $stopReason = 'Préparation restaurée entre-temps.' }
        elseif (@($updateSteps | Where-Object { $_.Status -ne 'Completed' }).Count -eq 0) { $stopReason = 'Windows Update déjà terminé.' }
        if ($null -ne $stopReason) {
            Unregister-GenesisUpdateContinuation
            $continuation.Outcome = 'Stopped'; $continuation.FinishedAt = [datetime]::UtcNow.ToString('o')
            Write-GenesisJson -Path $continuationPath -Value $continuation
            Add-GenesisEvent -RunDirectory $directory -EventName 'update_continuation_stopped' -StepId 'windows-update'
            return [pscustomobject]@{ RunId = $RunId; Outcome = 'Stopped'; Message = $stopReason; Reboots = $continuation.Reboots }
        }

        $path = Join-Path $directory 'state.json'
        $state.Status = 'Running'; $state.FinishedAt = $null
        Write-GenesisJson -Path $path -Value $state
        Add-GenesisEvent -RunDirectory $directory -EventName 'update_continuation_started' -StepId 'windows-update'
        # Après une mise à niveau, la nouvelle version reçoit ses propres mises à jour de qualité.
        $featurePending = @($updateSteps | Where-Object { $_.Id -eq 'windows-feature-update' -and $_.Status -ne 'Completed' }).Count -gt 0
        $failed = $false
        $remaining = $false
        $lastStep = $null
        foreach ($step in $updateSteps) {
            if ($step.Status -eq 'Completed' -and -not ($step.Id -eq 'windows-update' -and $featurePending)) { continue }
            $lastStep = $step
            $scope = if ($step.Id -eq 'windows-feature-update') { 'Feature' } else { 'Quality' }
            $step.Status = 'Running'; $step.Percent = 10; $step.Message = 'Reprise automatique après redémarrage'
            $step.Attempts += 1; $step.ErrorType = $null
            $step.StartedAt = [datetime]::UtcNow.ToString('o'); $step.FinishedAt = $null
            Write-GenesisJson -Path $path -Value $state
            # Le réseau peut ne pas être prêt juste après le démarrage.
            $result = $null
            for ($attempt = 1; $attempt -le 3 -and $null -eq $result; $attempt++) {
                try { $result = Invoke-GenesisWindowsUpdate -RunDirectory $directory -Scope $scope }
                catch {
                    $step.ErrorType = $_.Exception.GetType().FullName
                    if ($attempt -lt 3) { Start-Sleep -Seconds $RetryDelaySeconds }
                }
            }
            $step.FinishedAt = [datetime]::UtcNow.ToString('o')
            if ($null -eq $result) {
                $step.Status = 'Failed'; $step.Percent = 0
                $step.Message = 'Windows Update a échoué après redémarrage : reprendre Genesis manuellement.'
                $failed = $true
                break
            }
            $step.Status = $result.Status; $step.Percent = $result.Percent; $step.Message = $result.Message; $step.ErrorType = $null
            Write-GenesisJson -Path $path -Value $state
            # Un redémarrage doit précéder la suite : la mise à niveau attend les correctifs en cours.
            if ($result.Status -eq 'NeedsAttention') { $remaining = $true; break }
        }
        if ($failed) { $continuation.Outcome = 'Failed' }
        elseif ($remaining -and [int]$continuation.Reboots -lt [int]$continuation.MaxReboots) {
            $continuation.Reboots = [int]$continuation.Reboots + 1
            $lastStep.Message = 'Redémarrage {0}/{1} pour poursuivre les mises à jour Windows.' -f $continuation.Reboots, $continuation.MaxReboots
            $continuation.Outcome = 'Rebooting'
            $restart = $true
        }
        elseif ($remaining) {
            $lastStep.Message = 'Nombre maximal de redémarrages atteint ; reprendre Genesis manuellement.'
            $continuation.Outcome = 'MaxReboots'
        }
        else { $continuation.Outcome = 'Completed' }
        if (-not $restart) {
            Unregister-GenesisUpdateContinuation
            $continuation.FinishedAt = [datetime]::UtcNow.ToString('o')
            $notice = if ($continuation.Outcome -eq 'Completed') { 'Genesis : mises à jour Windows terminées après {0} redémarrage(s).' -f $continuation.Reboots } else { 'Genesis : mises à jour Windows à vérifier. ' + $lastStep.Message }
            $captureStep = $state.Steps | Where-Object { $_.Id -eq 'fog-capture' -and $_.Status -ne 'Completed' } | Select-Object -First 1
            if ($continuation.Outcome -eq 'Completed' -and $null -ne $captureStep) {
                $captureNotice = Invoke-GenesisContinuationFogCapture -State $state -Step $captureStep -RunDirectory $directory
                $notice = $notice + ' ' + $captureNotice
            }
        }
        $state.Status = 'Completed'
        if (@($state.Steps | Where-Object { $_.Status -ne 'Completed' }).Count -gt 0) { $state.Status = 'NeedsAttention' }
        $state.FinishedAt = [datetime]::UtcNow.ToString('o')
        Write-GenesisJson -Path $path -Value $state
        Write-GenesisJson -Path $continuationPath -Value $continuation
        $errorType = if ($null -ne $lastStep) { [string]$lastStep.ErrorType } else { '' }
        $eventStep = if ($null -ne $lastStep) { [string]$lastStep.Id } else { 'windows-update' }
        Add-GenesisEvent -RunDirectory $directory -EventName ('update_continuation_' + ([string]$continuation.Outcome).ToLowerInvariant()) -StepId $eventStep -ErrorType $errorType
    }
    catch {
        # Une préparation illisible ne doit pas relancer la tâche à chaque démarrage.
        try { Unregister-GenesisUpdateContinuation } catch { Write-Verbose 'Suppression de la tâche de reprise impossible.' }
        throw
    }
    finally { $lock.Dispose() }
    if ($restart) { Restart-GenesisComputer -DelaySeconds 60 -Reason 'Genesis redémarre pour poursuivre les mises à jour Windows.' }
    elseif ($null -ne $notice) {
        Send-GenesisSessionMessage -Message $notice
        Complete-GenesisFogCapture -State $state -DataRoot $root | Out-Null
    }
    $message = if ($null -ne $lastStep) { [string]$lastStep.Message } else { '' }
    return [pscustomobject]@{ RunId = $RunId; Outcome = [string]$continuation.Outcome; Message = $message; Reboots = [int]$continuation.Reboots }
}

function Invoke-GenesisContinuationFogCapture {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Step, [Parameter(Mandatory)][string]$RunDirectory)
    $path = Join-Path $RunDirectory 'state.json'
    $blocker = Get-GenesisFogCaptureBlocker -State $State
    if ($null -ne $blocker) {
        $Step.Message = $blocker
        Write-GenesisJson -Path $path -Value $State
        return ('Capture FOG non lancée : ' + $blocker)
    }
    $Step.Status = 'Running'; $Step.Percent = 5; $Step.Message = 'Capture FOG après les mises à jour Windows'
    $Step.Attempts += 1; $Step.ErrorType = $null
    $Step.StartedAt = [datetime]::UtcNow.ToString('o'); $Step.FinishedAt = $null
    Write-GenesisJson -Path $path -Value $State
    Add-GenesisEvent -RunDirectory $RunDirectory -EventName 'step_started' -StepId 'fog-capture'
    $notice = ''
    try {
        $result = Invoke-GenesisCustomization -StepId 'fog-capture' -RunDirectory $RunDirectory
        $Step.Status = $result.Status; $Step.Percent = $result.Percent; $Step.Message = $result.Message
        $notice = if ($result.Status -eq 'Completed') { 'Capture FOG programmée : redémarrage sur le réseau.' } else { 'Capture FOG à vérifier : ' + $result.Message }
        Add-GenesisEvent -RunDirectory $RunDirectory -EventName 'step_finished' -StepId 'fog-capture'
    }
    catch {
        $Step.Status = 'Failed'; $Step.Percent = 0
        $Step.Message = 'Échec de la capture FOG : reprendre Genesis manuellement.'
        $Step.ErrorType = $_.Exception.GetType().FullName
        # Le motif peut contenir des données privées : affiché dans la session, jamais écrit dans state.json.
        $reason = ([string]$_.Exception.Message -replace '[\r\n\t]+', ' ').Trim()
        if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 297) + '...' }
        $notice = 'Échec de la capture FOG : ' + $reason
        Add-GenesisEvent -RunDirectory $RunDirectory -EventName 'step_failed' -StepId 'fog-capture' -ErrorType $Step.ErrorType
    }
    $Step.FinishedAt = [datetime]::UtcNow.ToString('o')
    Write-GenesisJson -Path $path -Value $State
    return $notice
}

function Request-GenesisUpdateRestart {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Question console du technicien.')]
    param([Parameter(Mandatory)]$State, [string]$DataRoot)
    if (-not (Test-GenesisUpdateContinuationNeeded -State $State)) { return }
    Write-Host ''
    if ([string]::IsNullOrWhiteSpace((Get-GenesisPortablePath))) {
        Write-Host ('Windows Update doit être repris après redémarrage : -Action Resume -RunId ' + $State.RunId) -ForegroundColor Yellow
        return
    }
    # Redémarrage automatique : la reprise est programmée avant, puis Windows redémarre après un délai annulable.
    try { Register-GenesisUpdateContinuation -RunId $State.RunId -DataRoot $DataRoot | Out-Null }
    catch {
        Write-Host ('Reprise automatique impossible : ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('Redémarrer puis reprendre manuellement : -Action Resume -RunId ' + $State.RunId) -ForegroundColor Yellow
        return
    }
    Restart-GenesisComputer -DelaySeconds $script:GenesisUpdateRestartDelaySeconds -Reason 'Genesis redémarre pour poursuivre les mises à jour Windows.'
    Write-Host ('Windows Update demande un redémarrage : redémarrage automatique dans {0} secondes.' -f $script:GenesisUpdateRestartDelaySeconds) -ForegroundColor Green
    Write-Host ('Les mises à jour reprendront seules au démarrage, sans ouverture de session (au plus {0} redémarrages) ; un message s''affichera à la fin.' -f $script:GenesisUpdateMaxReboots) -ForegroundColor Green
    Write-Host 'Pour annuler ce redémarrage : shutdown /a (la reprise aura lieu au prochain démarrage).' -ForegroundColor DarkGray
}

function Write-GenesisBanner {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Bannière console du technicien.')]
    param()
    try { [Console]::Title = 'Genesis v' + $script:GenesisVersion } catch { Write-Verbose 'Titre de console indisponible.' }
    Write-Host ''
    Write-Host '   ██████╗ ███████╗███╗   ██╗███████╗███████╗██╗███████╗' -ForegroundColor DarkGreen
    Write-Host '  ██╔════╝ ██╔════╝████╗  ██║██╔════╝██╔════╝██║██╔════╝' -ForegroundColor DarkGreen
    Write-Host '  ██║  ███╗█████╗  ██╔██╗ ██║█████╗  ███████╗██║███████╗' -ForegroundColor Green
    Write-Host '  ██║   ██║██╔══╝  ██║╚██╗██║██╔══╝  ╚════██║██║╚════██║' -ForegroundColor Green
    Write-Host '  ╚██████╔╝███████╗██║ ╚████║███████╗███████║██║███████║' -ForegroundColor DarkGreen
    Write-Host '   ╚═════╝ ╚══════╝╚═╝  ╚═══╝╚══════╝╚══════╝╚═╝╚══════╝' -ForegroundColor DarkGreen
    Write-Host ("                  Genesis v{0}  |  {1}" -f $script:GenesisVersion, $env:COMPUTERNAME) -ForegroundColor Cyan
    Write-Host '--------------------------------------------------------------------------' -ForegroundColor DarkGray
}

function New-GenesisSelectedProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ProfileObject,
        [Parameter(Mandatory)][string[]]$SelectedIds
    )
    $genesisProfile = Get-GenesisProfile -ProfileObject $ProfileObject
    $selected = @{}
    foreach ($id in $SelectedIds) { $selected[$id] = $true }
    $steps = @($genesisProfile.steps | Where-Object { $selected.ContainsKey($_) })
    if ($steps.Count -eq 0) { throw 'Sélectionner au moins une opération.' }
    return [pscustomobject]@{
        schemaVersion = $genesisProfile.schemaVersion
        id = $genesisProfile.id
        name = $genesisProfile.name + ' (sélection technicien)'
        steps = $steps
    }
}

function Assert-GenesisChoice {
    [CmdletBinding()]
    param([object]$Choices)
    $allowed = @{
        browser = @('Chrome', 'Firefox')
        'pdf-reader' = @('Acrobat', 'SumatraPDF', 'PDFCraft')
    }
    $result = [ordered]@{}
    if ($null -eq $Choices) { return $result }
    $names = if ($Choices -is [System.Collections.IDictionary]) { @($Choices.Keys) } else { @($Choices.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($name in $names) {
        if ($name -notin $allowed.Keys) { throw "Choix Genesis inconnu : '$name'." }
        $value = if ($Choices -is [System.Collections.IDictionary]) { $Choices[$name] } else { $Choices.$name }
        if ($value -notin $allowed[$name]) { throw "Choix Genesis invalide pour '$name'." }
        $result[$name] = [string]$value
    }
    return $result
}

function Get-GenesisChoiceValue {
    param([object]$Choices, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Choices) { return $null }
    if ($Choices -is [System.Collections.IDictionary]) { return [string]$Choices[$Name] }
    if (@($Choices.PSObject.Properties | ForEach-Object { $_.Name }) -contains $Name) { return [string]$Choices.$Name }
    return $null
}

function Test-GenesisCompletionRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Expected)
    $record = Get-GenesisRegistryValue -Path $Path -Name $Name
    return ($record.Exists -and $record.Kind -eq 'DWord' -and [int]$record.Data -eq [int]$Expected)
}

function Get-GenesisStepCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StepId,
        [string]$DataRoot
    )
    $done = $false
    $detail = 'Contrôle non exécuté.'
    $currentVersion = ''
    $latestVersion = ''
    $availableUpdates = $null
    try {
        switch ($StepId) {
            'inventory' {
                $root = $DataRoot
                if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path $env:ProgramData 'Genesis' }
                $runsPath = Join-Path $root 'runs'
                $latest = @(Get-ChildItem -LiteralPath $runsPath -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
                $done = ($latest.Count -gt 0 -and (Test-Path -LiteralPath (Join-Path $latest[0].FullName 'inventory.json')))
                $detail = if ($done) { 'Inventaire présent dans la dernière préparation.' } else { 'Inventaire à exécuter.' }
            }
            'windows-update' {
                $versionStatus = Get-GenesisWindowsVersionStatus
                $currentVersion = [string]$versionStatus.Current
                $latestVersion = [string]$versionStatus.Latest
                $availableUpdates = [int]$versionStatus.AvailableCount
                $done = ($versionStatus.ScanSucceeded -and $versionStatus.AvailableCount -eq 0)
                if ($versionStatus.ScanSucceeded) {
                    $detail = 'Actuelle : {0} | Dernière proposée : {1} | {2} mise(s) à jour disponible(s).' -f $versionStatus.Current, $versionStatus.Latest, $versionStatus.AvailableCount
                }
                else { $detail = 'Recherche Windows Update indisponible : ' + $versionStatus.Error }
            }
            'windows-feature-update' {
                $versionStatus = Get-GenesisWindowsVersionStatus
                $currentVersion = [string]$versionStatus.Current
                $latestVersion = [string]$versionStatus.Latest
                $done = ($versionStatus.ScanSucceeded -and [string]::IsNullOrWhiteSpace([string]$versionStatus.FeatureUpdate))
                if (-not $versionStatus.ScanSucceeded) { $detail = 'Recherche Windows Update indisponible : ' + $versionStatus.Error }
                elseif ($done) { $detail = 'Aucune mise à niveau proposée ; actuelle : ' + $versionStatus.Current }
                else { $detail = 'Proposée : ' + $versionStatus.FeatureUpdate }
            }
            'explorer-home' {
                $done = Test-GenesisCompletionRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Expected 1
                $detail = if ($done) { 'Explorateur réglé sur Ce PC.' } else { 'Explorateur encore sur Accès rapide ou valeur absente.' }
            }
            'windows-suggestions' {
                $done = (Test-GenesisCompletionRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338389Enabled' -Expected 0) -and
                    (Test-GenesisCompletionRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -Name 'ScoobeSystemSettingEnabled' -Expected 0)
                $detail = if ($done) { 'Conseils et suggestions désactivés.' } else { 'Au moins un réglage de suggestions reste actif.' }
            }
            'tray-icons' {
                $icons = @(Get-ChildItem -LiteralPath 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue)
                $done = ($icons.Count -eq 0) -or (@($icons | ForEach-Object { (Get-GenesisRegistryValue -Path ('HKCU:\Control Panel\NotifyIconSettings\' + $_.PSChildName) -Name 'IsPromoted') } | Where-Object { -not $_.Exists -or $_.Kind -ne 'DWord' -or [int]$_.Data -ne 1 }).Count -eq 0)
                $detail = if ($done) { 'Toutes les icônes actuellement enregistrées sont affichées.' } else { 'Certaines icônes de notification restent masquées.' }
            }
            'taskbar-left' {
                $done = (Test-GenesisCompletionRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' -Expected 0) -and
                    (@(Get-GenesisTaskbarPinnedApp -Names @('Microsoft Edge', 'Microsoft Store')).Count -eq 0)
                $detail = if ($done) { 'Barre à gauche, sans Edge ni Microsoft Store.' } else { 'Barre centrée ou Edge / Microsoft Store encore épinglés.' }
            }
            'start-cleanup' {
                $left = @(Get-GenesisStartCleanupInstalled | ForEach-Object { $script:GenesisStartCleanupPackages[$_.Name] } | Select-Object -Unique)
                $left += @(Get-GenesisStartCleanupPin | ForEach-Object { 'épingle ' + $_ })
                $done = $left.Count -eq 0
                $detail = if ($done) { 'Outlook (new), Xbox, Solitaire, WhatsApp et LinkedIn absents.' } else { 'Encore installé : ' + ($left -join ', ') }
            }
            'taskbar-controls' {
                $widgets = Get-GenesisRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests'
                $widgetsDone = if ($widgets.Exists) { $widgets.Kind -eq 'DWord' -and [int]$widgets.Data -eq 0 } else {
                    Test-GenesisCompletionRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' -Expected 0
                }
                $done = (Test-GenesisCompletionRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -Expected 0) -and
                    (Test-GenesisCompletionRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Expected 0) -and $widgetsDone
                $detail = if ($done) { 'Recherche, Widgets et Vue des tâches masqués.' } else { 'Au moins un contrôle de la barre des tâches reste visible.' }
            }
            'time-sync' {
                $service = Get-Service -Name W32Time -ErrorAction Stop
                $ntpEnabled = Test-GenesisCompletionRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient' -Name 'Enabled' -Expected 1
                $type = Get-GenesisRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -Name 'Type'
                $done = ($service.Status -eq 'Running' -and $ntpEnabled -and $type.Exists -and [string]$type.Data -in @('NTP', 'NT5DS'))
                $detail = if ($done) { 'Windows Time fonctionne avec le client NTP.' } else { 'Service horaire ou configuration NTP à vérifier.' }
            }
            'office-2024' {
                $done = @(Get-GenesisOfficeInstallationStatus).Count -eq 4
                $detail = if ($done) { 'Word, Excel, PowerPoint et Outlook classique détectés.' } else { 'La suite Office attendue n''est pas complète.' }
            }
            'browser' {
                foreach ($browser in @('Chrome', 'Firefox')) {
                    $path = Get-GenesisBrowserPath -Browser $browser
                    if ([string]::IsNullOrWhiteSpace($path)) { continue }
                    $association = Get-GenesisDefaultAssociation -Protocol 'http'
                    $pattern = if ($browser -eq 'Chrome') { 'ChromeHTML|Chrome' } else { 'FirefoxURL|FirefoxHTML|Firefox' }
                    if ($association -match $pattern) { $done = $true; break }
                }
                $detail = if ($done) { 'Chrome ou Firefox est installé et associé par défaut.' } else { 'Navigateur ou association HTTP à vérifier.' }
            }
            'pdf-reader' {
                foreach ($reader in @('Acrobat', 'SumatraPDF', 'PDFCraft')) {
                    $path = Get-GenesisPdfReaderPath -Reader $reader
                    if ([string]::IsNullOrWhiteSpace($path)) { continue }
                    $association = Get-GenesisDefaultAssociation -Protocol 'pdf'
                    $pattern = switch ($reader) { 'Acrobat' { 'AcroExch|Acrobat' }; 'SumatraPDF' { 'SumatraPDF' }; 'PDFCraft' { 'PDFCraft|pdfcraft' } }
                    if ($association -match $pattern) { $done = $true; break }
                }
                $detail = if ($done) { 'Un lecteur PDF est installé et associé.' } else { 'Lecteur PDF ou association à vérifier.' }
            }
            'outlook-autodiscover' {
                $done = Test-GenesisCompletionRegistryValue -Path 'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover' -Name 'ExcludeExplicitO365Endpoint' -Expected 1
                $detail = if ($done) { 'ExcludeExplicitO365Endpoint=1 est présent.' } else { 'Le point de terminaison explicite Microsoft 365 reste autorisé.' }
            }
            'power-ac' {
                $scheme = Get-GenesisPowerSchemeGuid
                $done = (Get-GenesisAcStandbyTime -SchemeGuid $scheme) -eq 0
                $detail = if ($done) { 'Mise en veille secteur réglée sur Jamais.' } else { 'Un délai de veille secteur est encore configuré.' }
            }
            'local-user' {
                if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
                    $done = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $_.Description -eq 'Session créée par Genesis' }).Count -gt 0
                }
                $detail = if ($done) { 'Une session créée par Genesis est visible et active.' } else { 'Aucune session locale Genesis détectée.' }
            }
            'netbird' {
                $path = Get-GenesisNetBirdPath
                $done = (-not [string]::IsNullOrWhiteSpace($path)) -and (Test-GenesisNetBirdManagementConfigured)
                $detail = if ($done) { 'NetBird est installé et son serveur est configuré ; aucune connexion lancée.' } else { 'NetBird absent ou serveur non configuré.' }
            }
            'fog-capture' {
                $done = $false
                $detail = 'À choisir explicitement : généralise Windows puis redémarre sur le réseau pour la capture FOG.'
            }
            'taskbar-pins' {
                $state = Get-GenesisTaskbarState
                $expected = @('Word.lnk', 'Excel.lnk', 'PowerPoint.lnk', 'Outlook classique.lnk')
                $names = @($state.Files | ForEach-Object { [string]$_.Name })
                $done = (@($expected | Where-Object { $_ -in $names }).Count -eq $expected.Count)
                $detail = if ($done) { 'Les quatre raccourcis Office sont préparés dans la session.' } else { 'La disposition de la barre des tâches doit encore être validée.' }
            }
            default { $detail = 'Opération inconnue.' }
        }
    }
    catch {
        $done = $false
        $detail = 'Contrôle indisponible : ' + $_.Exception.Message
    }
    [pscustomobject]@{
        Id = $StepId
        Done = [bool]$done
        Label = if ($done) { 'Fait' } else { 'Non fait' }
        Detail = $detail
        CurrentVersion = $currentVersion
        LatestVersion = $latestVersion
        AvailableUpdates = $availableUpdates
    }
}

function Test-GenesisStepSelectedByDefault {
    param([Parameter(Mandatory)][string]$StepId)
    # Une mise à niveau de version est longue et change Windows : choix explicite du technicien.
    # La capture FOG généralise le poste : jamais cochée d'office.
    return ($StepId -notin @('windows-feature-update', 'fog-capture'))
}

function Get-GenesisMenuDoneMarker {
    param([bool]$Done)
    if ($Done) { return '[v]' }
    return '[ ]'
}

function Show-GenesisTaskChecklist {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Checklist console du technicien.')]
    [CmdletBinding()]
    param(
        [string]$ProfilePath,
        [object]$ProfileObject,
        [string]$DataRoot
    )
    $genesisProfile = Get-GenesisProfile -Path $ProfilePath -ProfileObject $ProfileObject
    $steps = @(Get-GenesisStepCatalog | Where-Object { $_.Id -in @($genesisProfile.steps) })
    $completion = @{}
    foreach ($step in $steps) { $completion[$step.Id] = Get-GenesisStepCompletion -StepId $step.Id -DataRoot $DataRoot }
    $radioDefinitions = @{
        browser = @(
            [pscustomobject]@{ Id = 'Chrome'; Label = 'Chrome' }
            [pscustomobject]@{ Id = 'Firefox'; Label = 'Firefox' }
        )
        'pdf-reader' = @(
            [pscustomobject]@{ Id = 'PDFCraft'; Label = 'PDFCraft' }
            [pscustomobject]@{ Id = 'SumatraPDF'; Label = 'SumatraPDF' }
            [pscustomobject]@{ Id = 'Acrobat'; Label = 'Adobe Acrobat Reader' }
        )
    }
    $rows = @()
    foreach ($step in $steps) {
        $rows += ,([pscustomobject]@{ Kind = 'Step'; Id = $step.Id; ParentId = ''; Name = $step.Name })
        if ($radioDefinitions.ContainsKey($step.Id)) {
            foreach ($choice in $radioDefinitions[$step.Id]) {
                $rows += ,([pscustomobject]@{ Kind = 'Choice'; Id = $choice.Id; ParentId = $step.Id; Name = $choice.Label })
            }
        }
    }
    $checked = @{}
    foreach ($step in $steps) { $checked[$step.Id] = Test-GenesisStepSelectedByDefault -StepId $step.Id }
    $selectedChoices = [ordered]@{}
    if ($checked.ContainsKey('browser')) { $selectedChoices.browser = 'Chrome' }
    if ($checked.ContainsKey('pdf-reader')) { $selectedChoices.'pdf-reader' = 'Acrobat' }
    $cursor = 0
    $cursorWasVisible = $true
    try {
        try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { Write-Verbose 'Curseur console indisponible.' }
        while ($true) {
            Clear-Host
            Write-GenesisBanner
            Write-Host 'Sélection des opérations à exécuter' -ForegroundColor Cyan
            Write-Host 'Flèches haut/bas : déplacer   Espace : cocher/décocher   Entrée : lancer   Échap : annuler' -ForegroundColor DarkGray
            Write-Host 'Les choix indentés sont exclusifs : un seul navigateur et un seul lecteur PDF.' -ForegroundColor DarkGray
            if ($completion.ContainsKey('windows-update') -and -not [string]::IsNullOrWhiteSpace([string]$completion['windows-update'].CurrentVersion)) {
                $updateStatus = $completion['windows-update']
                Write-Host ('Windows actuel  : ' + $updateStatus.CurrentVersion) -ForegroundColor Cyan
                Write-Host ('Dernière dispo. : ' + $updateStatus.LatestVersion + ' | ' + $updateStatus.AvailableUpdates + ' mise(s) à jour') -ForegroundColor Cyan
            }
            Write-Host ''
            Write-Host '    #  Fait   Sel.   Opération / choix' -ForegroundColor DarkGray
            Write-Host '   --- -----  -----  ------------------' -ForegroundColor DarkGray
            $operationNumber = 0
            for ($index = 0; $index -lt $rows.Count; $index++) {
                $row = $rows[$index]
                $prefix = if ($index -eq $cursor) { ' > ' } else { '   ' }
                if ($row.Kind -eq 'Step') {
                    $operationNumber++
                    $doneMarker = Get-GenesisMenuDoneMarker -Done $completion[$row.Id].Done
                    $selectionMarker = if ($checked[$row.Id]) { '[X]' } else { '[ ]' }
                    $color = if ($index -eq $cursor) { 'Yellow' } elseif ($completion[$row.Id].Done) { 'Green' } else { 'DarkGray' }
                    Write-Host ("{0}{1,2}  {2,-5}  {3,-5}  {4}" -f $prefix, $operationNumber, $doneMarker, $selectionMarker, $row.Name) -ForegroundColor $color
                }
                else {
                    $marker = if ($selectedChoices.Contains($row.ParentId) -and $selectedChoices[$row.ParentId] -eq $row.Id) { '(*)' } else { '( )' }
                    $color = if ($index -eq $cursor) { 'Yellow' } elseif ($marker -eq '(*)') { 'Green' } else { 'DarkGray' }
                    Write-Host ("{0}       {1,-5}  {2,-5}  └─ {3}" -f $prefix, '', $marker, $row.Name) -ForegroundColor $color
                }
            }
            Write-Host ''
            $choiceSummary = @()
            if ($selectedChoices.Contains('browser')) { $choiceSummary += 'Navigateur=' + $selectedChoices.browser }
            if ($selectedChoices.Contains('pdf-reader')) { $choiceSummary += 'PDF=' + $selectedChoices.'pdf-reader' }
            $summary = if ($choiceSummary.Count -gt 0) { ' | ' + ($choiceSummary -join ' | ') } else { '' }
            Write-Host ("{0}/{1} opérations sélectionnées{2}" -f @($checked.Values | Where-Object { $_ }).Count, $steps.Count, $summary) -ForegroundColor Cyan
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' { $cursor = ($cursor - 1 + $rows.Count) % $rows.Count }
                'DownArrow' { $cursor = ($cursor + 1) % $rows.Count }
                'Spacebar' {
                    $row = $rows[$cursor]
                    if ($row.Kind -eq 'Choice') {
                        if ($selectedChoices.Contains($row.ParentId) -and $selectedChoices[$row.ParentId] -eq $row.Id) {
                            $selectedChoices.Remove($row.ParentId)
                            $checked[$row.ParentId] = $false
                        }
                        else {
                            $selectedChoices[$row.ParentId] = $row.Id
                            $checked[$row.ParentId] = $true
                        }
                    }
                    elseif ($radioDefinitions.ContainsKey($row.Id)) {
                        $checked[$row.Id] = -not $checked[$row.Id]
                        if (-not $checked[$row.Id]) { $selectedChoices.Remove($row.Id) }
                        elseif (-not $selectedChoices.Contains($row.Id)) { $selectedChoices[$row.Id] = $radioDefinitions[$row.Id][0].Id }
                    }
                    else { $checked[$row.Id] = -not $checked[$row.Id] }
                }
                'Enter' {
                    $selectedIds = @($steps | Where-Object { $checked[$_.Id] } | ForEach-Object { $_.Id })
                    if ($selectedIds.Count -gt 0) {
                        return [pscustomobject]@{
                            Profile = New-GenesisSelectedProfile -ProfileObject $genesisProfile -SelectedIds $selectedIds
                            Choices = Assert-GenesisChoice -Choices $selectedChoices
                        }
                    }
                }
                'Escape' { return $null }
            }
            if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { return $null }
        }
    }
    finally {
        try { [Console]::CursorVisible = $cursorWasVisible } catch { Write-Verbose 'Curseur console indisponible.' }
    }
}

function Show-GenesisReverseMenu {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Menu console de sélection d''une préparation à restaurer.')]
    [CmdletBinding()]
    param([string]$DataRoot)

    $cursor = 0
    $cursorWasVisible = $true
    try {
        try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { Write-Verbose 'Curseur console indisponible.' }
        while ($true) {
            $candidates = @(Get-GenesisReverseCandidate -DataRoot $DataRoot)
            if ($candidates.Count -eq 0) {
                Clear-Host
                Write-GenesisBanner
                Write-Host 'REVERSE — choisir une préparation' -ForegroundColor Magenta
                Write-Host 'Aucune préparation Genesis enregistrée ou restaurable dans ce poste et cette session.' -ForegroundColor Yellow
                Write-Host 'Lancez d''abord une préparation depuis le menu [1].' -ForegroundColor DarkGray
                return $null
            }
            if ($cursor -ge $candidates.Count) { $cursor = $candidates.Count - 1 }

            Clear-Host
            Write-GenesisBanner
            Write-Host 'REVERSE — choisir une préparation' -ForegroundColor Magenta
            Write-Host 'Flèches haut/bas : choisir   Entrée : restaurer   R : actualiser   Échap : retour' -ForegroundColor DarkGray
            Write-Host 'Chaque ligne indique le profil utilisé, son état et le nombre d''actions sauvegardées.' -ForegroundColor DarkGray
            Write-Host ''
            Write-Host '    #  RunId      État           Profil                    Créée            Actions  Reverse' -ForegroundColor DarkGray
            Write-Host '   ---  --------  -------------  ------------------------  ---------------  -------  -------' -ForegroundColor DarkGray
            for ($index = 0; $index -lt $candidates.Count; $index++) {
                $candidate = $candidates[$index]
                $prefix = if ($index -eq $cursor) { ' > ' } else { '   ' }
                $profileLabel = ConvertTo-GenesisConsoleLabel -Text ([string]$candidate.ProfileName) -Width 24
                $reverse = if ($candidate.CanUndo) { 'Oui' } else { 'Non' }
                $color = if ($index -eq $cursor) { 'Yellow' } elseif ($candidate.CanUndo) { 'Gray' } else { 'DarkGray' }
                Write-Host ("{0}{1,3}  {2,-8}  {3,-13}  {4,-24}  {5,-15}  {6,2}/{7,-2}    {8}" -f $prefix, ($index + 1), $candidate.ShortRunId, $candidate.StatusLabel, $profileLabel, $candidate.CreatedLabel, $candidate.ReversibleCount, $candidate.ActionCount, $reverse) -ForegroundColor $color
            }

            $selected = $candidates[$cursor]
            Write-Host ''
            Write-Host 'Correspondance de la sélection :' -ForegroundColor Cyan
            Write-Host ('  RunId complet : ' + $selected.RunId) -ForegroundColor Gray
            Write-Host ('  Profil        : {0} ({1})' -f $selected.ProfileName, $selected.ProfileId) -ForegroundColor Gray
            Write-Host ('  État          : {0} ; créée le {1}' -f $selected.StatusLabel, $selected.CreatedLabel) -ForegroundColor Gray
            $versionState = if ($selected.VersionCompatible) { 'compatible' } else { 'différente de la version courante' }
            Write-Host ('  Version       : {0} ({1})' -f $selected.GenesisVersion, $versionState) -ForegroundColor Gray
            Write-Host ('  Actions       : {0}/{1} disposent d''une sauvegarde exploitable pour le reverse.' -f $selected.ReversibleCount, $selected.ActionCount) -ForegroundColor Gray
            foreach ($actionName in @($selected.ActionNames)) { Write-Host ('    - ' + $actionName) -ForegroundColor DarkGray }
            if (@($selected.ChoiceSummary).Count -gt 0) {
                Write-Host ('  Choix logiciels : ' + (@($selected.ChoiceSummary) -join ' | ')) -ForegroundColor Gray
            }
            if (-not $selected.CanUndo) { Write-Host ('  Reverse indisponible : ' + $selected.ReverseReason) -ForegroundColor Yellow }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' { $cursor = ($cursor - 1 + $candidates.Count) % $candidates.Count }
                'DownArrow' { $cursor = ($cursor + 1) % $candidates.Count }
                'Escape' { return $null }
                'Enter' {
                    if ($selected.CanUndo) { return [string]$selected.RunId }
                    Write-Host 'Aucune sauvegarde restaurable sur cette préparation.' -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 900
                }
            }
            if ($key.KeyChar -eq 'r' -or $key.KeyChar -eq 'R') { $cursor = 0 }
            if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { return $null }
        }
    }
    finally {
        try { [Console]::CursorVisible = $cursorWasVisible } catch { Write-Verbose 'Curseur console indisponible.' }
    }
}

function Show-GenesisProgressTable {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Tableau console du technicien.')]
    param([Parameter(Mandatory)]$State)
    $view = Get-GenesisProgress -State $State
    $status = if ($State.PSObject.Properties.Name -contains 'Status') { $State.Status } else { 'Inconnu' }
    Write-Host ("Etat : {0}    Avancement : {1}% ({2}/{3})" -f $status, $view.Percent, $view.Completed, $view.Total) -ForegroundColor Cyan
    $consoleWidth = Get-GenesisConsoleWidth
    $fixedWidth = 14 + 12 + 6 + 8 + 16
    $detailWidth = [math]::Max(20, [math]::Min(60, $consoleWidth - $fixedWidth))
    $rows = @($view.Rows | ForEach-Object {
        ,@($_.Id, $_.State, ("{0}%" -f $_.Percent), $_.Undo, $_.Detail)
    })
    $table = ConvertTo-GenesisFixedAsciiTable -Headers @('ID', 'État', '%', 'Reverse', 'Détail') -Rows $rows -ColumnWidths @(14, 12, 6, 8, $detailWidth)
    Write-Host $table
}

function Show-GenesisDebloatMenu {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interface console interactive du technicien.')]
    [CmdletBinding()]
    param([string]$DataRoot)
    $programs = @(Get-GenesisInstalledProgram)
    $logPath = $null
    try {
        $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
        Initialize-GenesisDataRoot -DataRoot $root
        $logDirectory = Join-Path $root 'debloat'
        New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $logPath = Join-Path $logDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    }
    catch { Write-Host ('Journal Debloat indisponible : ' + $_.Exception.Message) -ForegroundColor Yellow }
    if ($programs.Count -eq 0) {
        Write-Host 'Aucun programme classique détecté dans les désinstallateurs Windows.' -ForegroundColor Yellow
        return
    }
    $selected = @{}
    $cursor = 0
    $cursorWasVisible = $true
    try {
        try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { Write-Verbose 'Curseur console indisponible.' }
        while ($true) {
            Clear-Host
            Write-GenesisBanner
            Write-Host 'DEBLOAT — programmes installés' -ForegroundColor Red
            Write-Host 'Flèches haut/bas : déplacer   Espace : sélectionner   Entrée : désinstaller   Échap : annuler' -ForegroundColor DarkGray
            Write-Host 'Les composants système et mises à jour masqués ne sont pas proposés.' -ForegroundColor DarkGray
            Write-Host ''
            Write-Host '    #  Sel.  Etat  Programme                                      Version' -ForegroundColor DarkGray
            Write-Host '   --- ----- ----- ----------------------------------------------  --------' -ForegroundColor DarkGray
            for ($index = 0; $index -lt $programs.Count; $index++) {
                $program = $programs[$index]
                $prefix = if ($index -eq $cursor) { ' > ' } else { '   ' }
                $selection = if ($selected.ContainsKey($index)) { '[X]' } else { '[ ]' }
                $availability = if ($program.CanUninstall) { 'OK' } else { '--' }
                $name = ConvertTo-GenesisConsoleLabel -Text ([string]$program.Name) -Width 46
                $version = ConvertTo-GenesisConsoleLabel -Text ([string]$program.Version) -Width 12
                $color = if ($index -eq $cursor) { 'Yellow' } elseif ($selected.ContainsKey($index)) { 'Red' } elseif ($program.CanUninstall) { 'Gray' } else { 'DarkGray' }
                Write-Host ("{0}{1,3}  {2,-5} {3,-5} {4,-46}  {5}" -f $prefix, ($index + 1), $selection, $availability, $name, $version) -ForegroundColor $color
            }
            Write-Host ''
            Write-Host ("{0} programme(s) sélectionné(s)." -f $selected.Count) -ForegroundColor Cyan
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' { $cursor = ($cursor - 1 + $programs.Count) % $programs.Count }
                'DownArrow' { $cursor = ($cursor + 1) % $programs.Count }
                'Spacebar' {
                    if (-not $programs[$cursor].CanUninstall) {
                        Write-Host 'Ce programme n''expose aucune commande de désinstallation.' -ForegroundColor Yellow
                        Start-Sleep -Milliseconds 700
                    }
                    elseif ($selected.ContainsKey($cursor)) { $selected.Remove($cursor) }
                    else { $selected[$cursor] = $true }
                }
                'Escape' { return }
                'Enter' {
                    $chosen = @($selected.Keys | Sort-Object | ForEach-Object { $programs[$_] })
                    if ($chosen.Count -eq 0) { return }
                    Write-Host ''
                    Write-Host 'Désinstallation demandée pour :' -ForegroundColor Yellow
                    $chosen | ForEach-Object { Write-Host (' - ' + $_.Name) }
                    $confirmation = Read-Host 'Confirmer la désinstallation [O/N]'
                    if ($confirmation -notmatch '^[OoYy]$') { return }
                    $results = @()
                    foreach ($program in $chosen) {
                        Write-Host ('Désinstallation : ' + $program.Name) -ForegroundColor Cyan
                        try { $results += Invoke-GenesisProgramUninstall -Program $program }
                        catch { $results += [pscustomobject]@{ Status = 'NeedsAttention'; Program = $program.Name; Message = $_.Exception.Message } }
                    }
                    Write-Host ''
                    $results | Format-Table Status, Program, Message -AutoSize -Wrap | Out-Host
                    if ($logPath) {
                        try { Write-GenesisJson -Path $logPath -Value ([pscustomobject]@{ SchemaVersion = 1; CreatedAt = [datetime]::UtcNow.ToString('o'); Results = $results }) }
                        catch { Write-Verbose ('Ecriture du journal Debloat impossible : ' + $_.Exception.Message) }
                    }
                    return $results
                }
            }
            if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { return }
        }
    }
    finally {
        try { [Console]::CursorVisible = $cursorWasVisible } catch { Write-Verbose 'Curseur console indisponible.' }
    }
}

function Show-GenesisPrinterMenu {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Menu console de recherche de pilotes.')]
    [CmdletBinding()]
    param()
    $cursor = 0
    $cursorWasVisible = $true
    $refresh = $true
    $printers = @()
    try {
        try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { Write-Verbose 'Curseur console indisponible.' }
        while ($true) {
            if ($refresh) {
                Clear-Host
                Write-GenesisBanner
                Write-Host 'Découverte des imprimantes réseau Windows (WSD) en cours...' -ForegroundColor Cyan
                $printers = @(Get-GenesisNetworkPrinter)
                $refresh = $false
            }
            if ($printers.Count -eq 0) { $cursor = 0 }
            elseif ($cursor -ge $printers.Count) { $cursor = $printers.Count - 1 }
            Clear-Host
            Write-GenesisBanner
            Write-Host 'IMPRIMANTES RESEAU — découverte Windows et pilotes' -ForegroundColor Cyan
            Write-Host 'Flèches haut/bas : choisir   Entrée : ajouter / Google   A : ajouter   G : Google   R : actualiser   Échap : retour' -ForegroundColor DarkGray
            Write-Host '[v] = déjà installée    [ ] = trouvée par Windows et prête à ajouter' -ForegroundColor DarkGray
            Write-Host ''
            if ($printers.Count -eq 0) {
                Write-Host 'Aucune imprimante réseau annoncée par Windows.' -ForegroundColor Yellow
                Write-Host 'Vérifiez que le poste et l''imprimante sont sur le même réseau, puis appuyez sur R.' -ForegroundColor DarkGray
            }
            else {
                $availableCount = @($printers | Where-Object { -not $_.Installed }).Count
                $installedCount = @($printers | Where-Object { $_.Installed }).Count
                Write-Host ("{0} trouvée(s) ; {1} installée(s) ; {2} à ajouter" -f $printers.Count, $installedCount, $availableCount) -ForegroundColor Green
                Write-Host '    #  Fait  État        Nom de l''imprimante                         Adresse / source' -ForegroundColor DarkGray
                Write-Host '   ---  ----  ----------  ------------------------------------------  -----------------------' -ForegroundColor DarkGray
                for ($index = 0; $index -lt $printers.Count; $index++) {
                    $printer = $printers[$index]
                    $prefix = if ($index -eq $cursor) { ' > ' } else { '   ' }
                    $done = if ($printer.Installed) { '[v]' } else { '[ ]' }
                    $status = if ($printer.Installed) { 'Installée' } else { 'À ajouter' }
                    $name = ConvertTo-GenesisConsoleLabel -Text ([string]$printer.Name) -Width 42
                    $source = ConvertTo-GenesisConsoleLabel -Text (([string]$printer.Address + ' / ' + [string]$printer.Source).Trim(' /')) -Width 23
                    $color = if ($index -eq $cursor) { 'Yellow' } elseif ($printer.Installed) { 'Gray' } else { 'Green' }
                    Write-Host ("{0}{1,3}  {2,-4}  {3,-10}  {4,-42}  {5}" -f $prefix, ($index + 1), $done, $status, $name, $source) -ForegroundColor $color
                }
            }
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' { if ($printers.Count -gt 0) { $cursor = ($cursor - 1 + $printers.Count) % $printers.Count } }
                'DownArrow' { if ($printers.Count -gt 0) { $cursor = ($cursor + 1) % $printers.Count } }
                'Escape' { return }
                'Enter' {
                    if ($printers.Count -eq 0) { continue }
                    try {
                        $printer = $printers[$cursor]
                        if ($printer.Installed) {
                            $result = Open-GenesisPrinterDriverSearch -Printer $printer
                            Write-Host ('Recherche ouverte : ' + $result.Url) -ForegroundColor Green
                        }
                        else {
                            $result = Add-GenesisPrinter -Printer $printer
                            Write-Host $result.Message -ForegroundColor $(if ($result.Status -eq 'Completed') { 'Green' } else { 'Yellow' })
                            if ($result.Status -eq 'Completed') {
                                $search = Read-Host 'Ouvrir aussi la recherche Google des pilotes [O/N]'
                                if ($search -match '^[OoYy]$') { Open-GenesisPrinterDriverSearch -Printer $printer | Out-Null }
                                $refresh = $true
                            }
                        }
                    }
                    catch { Write-Host ('Ouverture impossible : ' + $_.Exception.Message) -ForegroundColor Red }
                    Read-Host 'Entrée pour revenir au menu imprimantes' | Out-Null
                }
            }
            if ($key.KeyChar -eq 'a' -or $key.KeyChar -eq 'A') {
                if ($printers.Count -gt 0 -and -not $printers[$cursor].Installed) {
                    try {
                        $result = Add-GenesisPrinter -Printer $printers[$cursor]
                        Write-Host $result.Message -ForegroundColor $(if ($result.Status -eq 'Completed') { 'Green' } else { 'Yellow' })
                        if ($result.Status -eq 'Completed') { $refresh = $true }
                    }
                    catch { Write-Host ('Ajout impossible : ' + $_.Exception.Message) -ForegroundColor Red }
                    Read-Host 'Entrée pour revenir au menu imprimantes' | Out-Null
                }
            }
            if ($key.KeyChar -eq 'g' -or $key.KeyChar -eq 'G') {
                if ($printers.Count -gt 0) {
                    try {
                        $result = Open-GenesisPrinterDriverSearch -Printer $printers[$cursor]
                        Write-Host ('Recherche ouverte : ' + $result.Url) -ForegroundColor Green
                    }
                    catch { Write-Host ('Ouverture impossible : ' + $_.Exception.Message) -ForegroundColor Red }
                    Read-Host 'Entrée pour revenir au menu imprimantes' | Out-Null
                }
            }
            if ($key.KeyChar -eq 'r' -or $key.KeyChar -eq 'R') { $cursor = 0; $refresh = $true }
        }
    }
    finally {
        try { [Console]::CursorVisible = $cursorWasVisible } catch { Write-Verbose 'Curseur console indisponible.' }
    }
}

function Get-GenesisFootprint {
    [CmdletBinding()]
    param([string]$DataRoot)
    # Traces propres à Genesis ; les personnalisations appliquées au poste ne sont pas listées.
    $items = @()
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    if (Test-Path -LiteralPath $root) { $items += [pscustomobject]@{ Kind = 'Folder'; Path = $root; Label = 'Données, sauvegardes Reverse, installeurs et journaux' } }
    if ($null -ne (Get-ScheduledTask -TaskName $script:GenesisUpdateTaskName -ErrorAction SilentlyContinue)) {
        $items += [pscustomobject]@{ Kind = 'Task'; Path = $script:GenesisUpdateTaskName; Label = 'Tâche planifiée de reprise Windows Update' }
    }
    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath })
    foreach ($userProfile in $profiles) {
        $folder = Join-Path $userProfile.LocalPath 'AppData\Local\Genesis'
        if (Test-Path -LiteralPath $folder) { $items += [pscustomobject]@{ Kind = 'Folder'; Path = $folder; Label = 'Fichiers de session Genesis' } }
    }
    $policy = Get-GenesisRegistryValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'StartLayoutFile'
    if ($policy.Exists -and [string]$policy.Data -match '\\Genesis\\') {
        $items += [pscustomobject]@{ Kind = 'TaskbarPolicy'; Path = [string]$policy.Data; Label = 'Stratégie de disposition de la barre des tâches pointant vers Genesis' }
    }
    $portable = Get-GenesisPortablePath
    if (-not [string]::IsNullOrWhiteSpace($portable) -and (Test-Path -LiteralPath $portable)) {
        $drive = try { [IO.DriveInfo]::new([IO.Path]::GetPathRoot($portable)) } catch { $null }
        if ($null -eq $drive -or $drive.DriveType -ne [IO.DriveType]::Removable) {
            $items += [pscustomobject]@{ Kind = 'File'; Path = $portable; Label = 'Programme Genesis lancé' }
        }
    }
    return @($items)
}

function Uninstall-GenesisFootprint {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string]$DataRoot)
    Assert-GenesisAdministrator
    $items = @(Get-GenesisFootprint -DataRoot $DataRoot)
    if ($items.Count -eq 0) { return [pscustomobject]@{ Removed = @(); Failed = @(); Message = 'Aucune trace de Genesis sur ce poste.' } }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Supprimer toutes les traces de Genesis')) { return }
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    # Le verrou garantit qu'aucune préparation ni reprise n'est en cours pendant la suppression.
    $lock = $null
    if (Test-Path -LiteralPath $root) { $lock = Open-GenesisRunLock -DataRoot $root }
    $removed = @(); $failed = @()
    try {
        foreach ($item in @($items | Where-Object Kind -eq 'Task')) {
            try { Unregister-GenesisUpdateContinuation; $removed += $item.Label } catch { $failed += $item.Label }
        }
        foreach ($item in @($items | Where-Object Kind -eq 'TaskbarPolicy')) {
            try {
                Remove-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'StartLayoutFile', 'LockedStartLayout' -ErrorAction Stop
                $removed += $item.Label
            }
            catch { $failed += $item.Label }
        }
    }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
    foreach ($item in @($items | Where-Object { $_.Kind -in @('Folder', 'File') })) {
        try {
            Remove-Item -LiteralPath $item.Path -Recurse -Force -ErrorAction Stop
            $removed += ('{0} ({1})' -f $item.Label, $item.Path)
        }
        catch { $failed += ('{0} ({1})' -f $item.Label, $item.Path) }
    }
    $message = if ($failed.Count -eq 0) { 'Genesis a été entièrement retiré de ce poste. Les personnalisations appliquées sont conservées.' } else { 'Genesis a été retiré, sauf : ' + ($failed -join ' ; ') }
    [pscustomobject]@{ Removed = $removed; Failed = $failed; Message = $message }
}

function Show-GenesisUninstall {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Confirmation console du technicien.')]
    param([string]$DataRoot)
    $items = @(Get-GenesisFootprint -DataRoot $DataRoot)
    if ($items.Count -eq 0) { Write-Host 'Aucune trace de Genesis sur ce poste.' -ForegroundColor Green; return $false }
    Write-Host 'Désinstaller Genesis supprimera :' -ForegroundColor Yellow
    foreach ($item in $items) { Write-Host ('  - {0} : {1}' -f $item.Label, $item.Path) -ForegroundColor Yellow }
    Write-Host 'Les personnalisations, logiciels et comptes créés restent en place.' -ForegroundColor DarkGray
    Write-Host 'Attention : les sauvegardes sont supprimées, Reverse ne sera plus possible.' -ForegroundColor Red
    $answer = Read-Host 'Taper OUI pour confirmer'
    if ($answer -cne 'OUI') { Write-Host 'Désinstallation annulée.' -ForegroundColor DarkGray; return $false }
    $result = Uninstall-GenesisFootprint -DataRoot $DataRoot -Confirm:$false
    $color = if ($result.Failed.Count -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host $result.Message -ForegroundColor $color
    return ($result.Failed.Count -eq 0)
}

function Get-GenesisMainMenuEntry {
    [CmdletBinding()]
    param()
    @(
        [pscustomobject]@{ Id = '1'; Label = 'Sélectionner et lancer Genesis (↑/↓, Espace, Entrée ; choix radio indentés)'; Color = 'Green' }
        [pscustomobject]@{ Id = '2'; Label = 'Reverse des personnalisations'; Color = 'Magenta' }
        [pscustomobject]@{ Id = '3'; Label = 'Debloat : afficher et désinstaller des programmes'; Color = 'Red' }
        [pscustomobject]@{ Id = '4'; Label = 'Imprimantes réseau : choisir et rechercher les pilotes Google'; Color = 'Cyan' }
        [pscustomobject]@{ Id = '5'; Label = 'Désinstaller Genesis : supprimer toutes ses traces sur ce poste'; Color = 'DarkYellow' }
        [pscustomobject]@{ Id = '0'; Label = 'Quitter'; Color = 'DarkGray' }
    )
}

function Show-GenesisMenu {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interface console interactive du technicien.')]
    [CmdletBinding()]
    param(
        [string]$ProfilePath,
        [object]$ProfileObject,
        [string]$DataRoot
    )
    do {
        Clear-Host
        Write-GenesisBanner
        foreach ($entry in @(Get-GenesisMainMenuEntry)) {
            Write-Host ('[{0}] {1}' -f $entry.Id, $entry.Label) -ForegroundColor $entry.Color
        }
        $choice = Read-Host 'genesis@powershell >'
        try {
            switch ($choice.ToUpperInvariant()) {
                '1' {
                    $selection = Show-GenesisTaskChecklist -ProfilePath $ProfilePath -ProfileObject $ProfileObject -DataRoot $DataRoot
                    $fogSettings = $null
                    if ($null -ne $selection -and @($selection.Profile.steps) -contains 'fog-capture') {
                        # Questions posées maintenant : la capture peut avoir lieu après redémarrage, sans session.
                        $fogSettings = Read-GenesisFogConfiguration
                        if ($null -eq $fogSettings) {
                            $selection.Profile.steps = @($selection.Profile.steps | Where-Object { $_ -ne 'fog-capture' })
                            Write-Host 'Capture FOG retirée de la sélection.' -ForegroundColor Yellow
                            if ($selection.Profile.steps.Count -eq 0) { $selection = $null }
                        }
                    }
                    if ($null -ne $selection) {
                        $run = Start-GenesisRun -ProfileObject $selection.Profile -Choices $selection.Choices -FogSettings $fogSettings -DataRoot $DataRoot
                        Write-Host ("RunId : {0}" -f $run.RunId) -ForegroundColor Cyan
                        Show-GenesisProgressTable -State $run
                        if (@($run.Steps | Where-Object { $_.Id -eq 'fog-capture' -and $_.Status -eq 'Completed' }).Count -gt 0) {
                            Write-Host ('Capture FOG programmée ; traces Genesis supprimées. Redémarrage sur le réseau dans {0} secondes.' -f $script:GenesisFogRestartDelaySeconds) -ForegroundColor Green
                        }
                        else { Request-GenesisUpdateRestart -State $run -DataRoot $DataRoot }
                    }
                }
                '2' {
                    $runId = Show-GenesisReverseMenu -DataRoot $DataRoot
                    if (-not [string]::IsNullOrWhiteSpace($runId)) {
                        $run = Undo-GenesisRun -RunId $runId -DataRoot $DataRoot
                        Show-GenesisProgressTable -State $run
                    }
                }
                '3' { Show-GenesisDebloatMenu -DataRoot $DataRoot | Out-Host }
                '4' { Show-GenesisPrinterMenu }
                '5' {
                    if (Show-GenesisUninstall -DataRoot $DataRoot) {
                        Read-Host 'Entrée pour quitter' | Out-Null
                        $choice = '0'
                    }
                }
                '0' { Clear-Host }
                default { Write-Host 'Choix invalide.' -ForegroundColor Yellow }
            }
        }
        catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        if ($choice -ne '0') { Read-Host 'Entrée pour revenir au menu' | Out-Null }
    } while ($choice -ne '0')
}

. (Join-Path $PSScriptRoot 'Customization.ps1')
. (Join-Path $PSScriptRoot 'Progress.ps1')

Export-ModuleMember -Function Register-GenesisUpdateContinuation, Invoke-GenesisUpdateContinuation, Get-GenesisProfile, Get-GenesisStepCatalog, Get-GenesisPlan, Get-GenesisInventory, Format-GenesisInventoryAscii, Start-GenesisRun, Resume-GenesisRun, Get-GenesisRun, Show-GenesisMenu, Show-GenesisPrinterMenu, Get-GenesisNetworkPrinter, New-GenesisPrinterDriverSearchUrl, Open-GenesisPrinterDriverSearch, Add-GenesisPrinter, Get-GenesisProgress, Undo-GenesisRun, New-GenesisTaskbarXml, Confirm-GenesisTaskbar
