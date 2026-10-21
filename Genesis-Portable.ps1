#requires -Version 5.1
<#
.SYNOPSIS
    Genesis portable : socle complet dans un seul fichier PowerShell.
.DESCRIPTION
    Les profils base et windows sont embarqués. Les journaux et sauvegardes
    sont écrits dans DataRoot pendant une exécution, mais aucun fichier source
    externe n'est requis pour démarrer le programme.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet(
        'Menu', 'Gui', 'Inventory', 'Plan', 'Run', 'Resume', 'Status', 'Catalog', 'Undo',
        'ConfirmTaskbar', 'ContinueUpdates'
    )]
    [string]$Action = 'Menu',
    [ValidateSet('base', 'windows')]
    [string]$ProfileId = 'windows',
    [string]$ProfilePath,
    [string]$DataRoot,
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$script:GenesisEmbeddedProfiles = @{
    base = ConvertFrom-Json -InputObject @'
{
    "schemaVersion": 1,
    "id": "base",
    "name": "Diagnostic initial MSP",
    "steps": ["inventory"]
}
'@
    windows = ConvertFrom-Json -InputObject @'
{
    "schemaVersion": 1,
    "id": "windows",
    "name": "Personnalisations Windows",
    "steps": ["explorer-home", "windows-suggestions", "tray-icons", "taskbar-controls", "taskbar-left", "start-cleanup", "time-sync", "office-2024", "browser", "pdf-reader", "outlook-autodiscover", "power-ac", "local-user", "netbird", "taskbar-pins", "windows-update", "windows-feature-update", "fog-capture"]
}
'@
}

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
function Get-GenesisUserSid {
    if ($env:OS -eq 'Windows_NT') { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    return 'local:' + [Environment]::UserName
}

function Assert-GenesisRegistryTarget {
    param([string]$Path, [string]$Name)
    $allowed = @{
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' = @('LaunchTo', 'TaskbarDa', 'ShowTaskViewButton', 'TaskbarAl')
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' = @('SearchboxTaskbarMode')
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' = @('SubscribedContent-338389Enabled')
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' = @('ScoobeSystemSettingEnabled')
        'HKCU:\Software\Policies\Microsoft\Windows\Explorer' = @('StartLayoutFile', 'LockedStartLayout')
        'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' = @('AllowNewsAndInterests')
        'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' = @('Type')
        'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient' = @('Enabled')
        'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover' = @('ExcludeExplicitO365Endpoint')
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserSwitch' = @('Enabled')
        'HKLM:\SOFTWARE\Policies\NetBird' = @('ManagementURL')
    }
    if ($allowed.ContainsKey($Path) -and $Name -in $allowed[$Path]) { return }
    if ($Path -match '^HKCU:\\Control Panel\\NotifyIconSettings\\[a-zA-Z0-9{}-]+$' -and $Name -eq 'IsPromoted') { return }
    throw 'Cible de registre non autorisée par Genesis.'
}

function Get-GenesisRegistryValue {
    param([string]$Path, [string]$Name)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key -or $Name -notin $key.GetValueNames()) {
        return [pscustomobject]@{ Exists = $false; KeyExists = ($null -ne $key); Kind = ''; Data = $null }
    }
    $kind = $key.GetValueKind($Name).ToString()
    $data = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($kind -eq 'Binary') { $data = [Convert]::ToBase64String($data) }
    [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = $kind; Data = $data }
}

function Set-GenesisRegistryValue {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$Name, [Parameter(Mandatory)]$Record)
    if (-not $PSCmdlet.ShouldProcess($Path + '\' + $Name, 'Modifier la valeur')) { return }
    if ($Path -notmatch '^HK(CU|LM):\\(.+)$') { throw 'Ruche de registre non autorisée.' }
    $hive = [Microsoft.Win32.RegistryHive]::CurrentUser
    if ($Matches[1] -eq 'LM') { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
    $relative = $Matches[2]
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
    $key = $null
    try {
        # Get-Item expose une clé en lecture seule sous Windows PowerShell 5.1.
        $key = $baseKey.OpenSubKey($relative, $true)
        if (-not $Record.Exists) {
            if ($null -ne $key) {
                $key.DeleteValue($Name, $false)
                if (-not $Record.KeyExists -and $key.GetValueNames().Count -eq 0 -and $key.GetSubKeyNames().Count -eq 0) {
                    $key.Dispose(); $key = $null
                    $baseKey.DeleteSubKey($relative, $false)
                }
            }
            return
        }
        if ($null -eq $key) { $key = $baseKey.CreateSubKey($relative) }
        $data = $Record.Data
        switch ($Record.Kind) {
            'Binary' { $data = [Convert]::FromBase64String($data) }
            'DWord' { $data = [int]$data }
            'QWord' { $data = [long]$data }
            'MultiString' { $data = [string[]]$data }
        }
        $key.SetValue($Name, $data, ([Microsoft.Win32.RegistryValueKind]$Record.Kind))
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        $baseKey.Dispose()
    }
}

function Test-GenesisRegistryRecord {
    param($Left, $Right)
    if ($Left.Exists -ne $Right.Exists) { return $false }
    if (-not $Left.Exists) { return $true }
    return ($Left.Kind -eq $Right.Kind -and ($Left.Data | ConvertTo-Json -Compress -Depth 8) -ceq ($Right.Data | ConvertTo-Json -Compress -Depth 8))
}

function Test-GenesisRestoredRegistryRecord {
    param([string]$Path, [string]$Name, $Current, $Before)
    if (Test-GenesisRegistryRecord -Left $Current -Right $Before) { return $true }
    # Explorer peut recréer immédiatement IsPromoted=0 après suppression.
    return ($Path -match '^HKCU:\\Control Panel\\NotifyIconSettings\\[a-zA-Z0-9{}-]+$' -and $Name -eq 'IsPromoted' -and -not $Before.Exists -and $Current.Exists -and $Current.Kind -eq 'DWord' -and $Current.Data -eq 0)
}

function Invoke-GenesisRegistryTransaction {
    param([array]$Changes, [string]$SnapshotPath)
    foreach ($change in $Changes) { Assert-GenesisRegistryTarget -Path $change.Path -Name $change.Name }
    if (Test-Path -LiteralPath $SnapshotPath) {
        $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-GenesisSnapshotOwner -Snapshot $snapshot
    }
    else {
        $snapshot = [pscustomobject]@{
            SchemaVersion = 1; MachineId = Get-GenesisMachineId; UserSid = Get-GenesisUserSid
            Changes = @($Changes | ForEach-Object {
                [pscustomobject]@{
                    Path = $_.Path; Name = $_.Name
                    Before = Get-GenesisRegistryValue -Path $_.Path -Name $_.Name
                    After = [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = $_.Kind; Data = $_.Data }
                    Restored = $false
                }
            })
        }
        Write-GenesisJson -Path $SnapshotPath -Value $snapshot
    }
    foreach ($change in $snapshot.Changes) {
        Assert-GenesisRegistryTarget -Path $change.Path -Name $change.Name
        $current = Get-GenesisRegistryValue -Path $change.Path -Name $change.Name
        if (Test-GenesisRegistryRecord -Left $current -Right $change.After) { continue }
        if (-not (Test-GenesisRegistryRecord -Left $current -Right $change.Before)) { throw 'Le réglage a changé depuis sa sauvegarde : intervention requise.' }
        Set-GenesisRegistryValue -Path $change.Path -Name $change.Name -Record $change.After
        if (-not (Test-GenesisRegistryRecord -Left (Get-GenesisRegistryValue -Path $change.Path -Name $change.Name) -Right $change.After)) { throw 'Vérification du réglage impossible.' }
    }
}

function Assert-GenesisSnapshotOwner {
    param($Snapshot)
    if ($Snapshot.SchemaVersion -ne 1 -or $Snapshot.MachineId -cne (Get-GenesisMachineId)) { throw 'Sauvegarde incompatible avec cet ordinateur.' }
    if ($Snapshot.UserSid -cne (Get-GenesisUserSid)) { throw 'Sauvegarde incompatible avec cet utilisateur.' }
}

function Undo-GenesisRegistryTransaction {
    param([string]$SnapshotPath)
    $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-GenesisSnapshotOwner -Snapshot $snapshot
    $conflicts = @()
    foreach ($change in @($snapshot.Changes)[($snapshot.Changes.Count - 1)..0]) {
        Assert-GenesisRegistryTarget -Path $change.Path -Name $change.Name
        if ($change.Restored) { continue }
        $current = Get-GenesisRegistryValue -Path $change.Path -Name $change.Name
        if (Test-GenesisRestoredRegistryRecord -Path $change.Path -Name $change.Name -Current $current -Before $change.Before) { $change.Restored = $true }
        elseif (Test-GenesisRegistryRecord -Left $current -Right $change.After) {
            Set-GenesisRegistryValue -Path $change.Path -Name $change.Name -Record $change.Before
            if (-not (Test-GenesisRestoredRegistryRecord -Path $change.Path -Name $change.Name -Current (Get-GenesisRegistryValue -Path $change.Path -Name $change.Name) -Before $change.Before)) { throw 'Vérification de la restauration impossible.' }
            $change.Restored = $true
        }
        else { $conflicts += $change.Name }
        Write-GenesisJson -Path $SnapshotPath -Value $snapshot
    }
    [pscustomobject]@{ ConflictCount = $conflicts.Count; Conflicts = $conflicts }
}

function Get-GenesisRegistryChange {
    param([string]$StepId)
    switch ($StepId) {
        'explorer-home' {
            [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Kind = 'DWord'; Data = 1 }
        }
        'windows-suggestions' {
            [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Kind = 'DWord'; Data = 0 }
            [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Kind = 'DWord'; Data = 0 }
        }
        'taskbar-controls' {
            [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Kind = 'DWord'; Data = 0 }
            [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Kind = 'DWord'; Data = 0 }
            $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
            if ($edition -match '^(Professional|Enterprise|Education)') {
                [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Kind = 'DWord'; Data = 0 }
            }
            else {
                [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Kind = 'DWord'; Data = 0 }
            }
        }
        'tray-icons' {
            Get-ChildItem -LiteralPath 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ Path = 'HKCU:\Control Panel\NotifyIconSettings\' + $_.PSChildName; Name = 'IsPromoted'; Kind = 'DWord'; Data = 1 }
            }
        }
        'outlook-autodiscover' {
            [pscustomobject]@{
                Path = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover'
                Name = 'ExcludeExplicitO365Endpoint'
                Kind = 'DWord'
                Data = 1
            }
        }
    }
}

function Get-GenesisOfficeApp {
    $executables = @('WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE', 'OUTLOOK.EXE')
    foreach ($exe in $executables) {
        $found = $null
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $base) { continue }
            foreach ($relative in @('Microsoft Office\root\Office16', 'Microsoft Office\Office16')) {
                $path = Join-Path (Join-Path $base $relative) $exe
                if (Test-Path -LiteralPath $path) { $found = $path; break }
            }
            if ($found) { break }
        }
        if ($found) { [pscustomobject]@{ Executable = $exe; Path = $found } }
    }
}

function New-GenesisTaskbarXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateCount(4, 4)][string[]]$Links)
    $entries = @('<taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer"/>')
    foreach ($link in $Links) {
        $entries += '<taskbar:DesktopApp DesktopApplicationLinkPath="' + [Security.SecurityElement]::Escape($link) + '"/>'
    }
    return '<?xml version="1.0" encoding="utf-8"?><LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1"><CustomTaskbarLayoutCollection PinListPlacement="Replace"><defaultlayout:TaskbarLayout><taskbar:TaskbarPinList>' + ($entries -join '') + '</taskbar:TaskbarPinList></defaultlayout:TaskbarLayout></CustomTaskbarLayoutCollection></LayoutModificationTemplate>'
}

function Get-GenesisTaskbarState {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    $values = @()
    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($key) {
        $values = @($key.GetValueNames() | Sort-Object | ForEach-Object { [pscustomobject]@{ Name = $_; Record = Get-GenesisRegistryValue -Path $path -Name $_ } })
    }
    $folder = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) }
    })
    [pscustomobject]@{ Values = $values; Files = $files }
}

function Set-GenesisTaskbarLayout {
    param([string]$RunDirectory)
    $apps = @(Get-GenesisOfficeApp)
    if ($apps.Count -ne 4) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Office requis : Word, Excel, PowerPoint et Outlook classique. Épingles conservées.' }
    }
    $backupPath = Join-Path $RunDirectory 'taskbar-state.json'
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Write-GenesisJson -Path $backupPath -Value ([pscustomobject]@{
            SchemaVersion = 1; MachineId = Get-GenesisMachineId; UserSid = Get-GenesisUserSid
            Before = Get-GenesisTaskbarState; After = $null
        })
    }
    $folder = Join-Path $env:LOCALAPPDATA ('Genesis\Taskbar\' + (Split-Path -Leaf $RunDirectory))
    New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $labels = @('Word', 'Excel', 'PowerPoint', 'Outlook classique')
    $links = @()
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $path = Join-Path $folder ($labels[$i] + '.lnk')
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = $apps[$i].Path
        $shortcut.Save()
        $links += $path
    }
    $xmlPath = Join-Path $folder 'TaskbarLayout.xml'
    [IO.File]::WriteAllText($xmlPath, (New-GenesisTaskbarXml -Links $links), (New-Object Text.UTF8Encoding($false)))
    $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
    if ($edition -match '^(Professional|Enterprise|Education)') {
        $changes = @(
            [pscustomobject]@{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'StartLayoutFile'; Kind = 'ExpandString'; Data = $xmlPath },
            [pscustomobject]@{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'LockedStartLayout'; Kind = 'DWord'; Data = 1 }
        )
        Invoke-GenesisRegistryTransaction -Changes $changes -SnapshotPath (Join-Path $RunDirectory 'taskbar-pins.registry.json')
    }
    [pscustomobject]@{ Status = 'AwaitingSession'; Percent = 80; Message = 'Disposition préparée. Vérifier les 5 épingles dans la session ; retirer les anciennes épingles utilisateur puis valider.' }
}

# Applications retirées par le nettoyage du menu Démarrer (noms de paquets Appx).
$script:GenesisStartCleanupPackages = [ordered]@{
    'Microsoft.OutlookForWindows' = 'Outlook (new)'
    'Microsoft.GamingApp' = 'Xbox'
    'Microsoft.XboxApp' = 'Xbox'
    'Microsoft.XboxGamingOverlay' = 'Xbox Game Bar'
    'Microsoft.XboxGameOverlay' = 'Xbox Game Bar'
    'Microsoft.XboxSpeechToTextOverlay' = 'Xbox Game Bar'
    'Microsoft.Xbox.TCUI' = 'Xbox'
    'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire'
    '5319275A.WhatsAppDesktop' = 'WhatsApp'
    '7EE7776C.LinkedInforWindows' = 'LinkedIn'
}

function Get-GenesisStartCleanupInstalled {
    $names = @($script:GenesisStartCleanupPackages.Keys)
    @(Get-AppxPackage -ErrorAction Stop | Where-Object { $_.Name -in $names -and -not $_.NonRemovable })
}

function Get-GenesisStartCleanupPin {
    # Épingles du menu Démarrer visées par le nettoyage (y compris les raccourcis « à installer »).
    $path = Join-Path ([IO.Path]::GetTempPath()) ('genesis-start-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Export-StartLayout -Path $path -ErrorAction Stop
        $pattern = '^(' + ((@($script:GenesisStartCleanupPackages.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')_'
        @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).pinnedList | Where-Object { $_.PSObject.Properties.Name -contains 'packagedAppId' -and [string]$_.packagedAppId -match $pattern } | ForEach-Object {
            $script:GenesisStartCleanupPackages[([string]$_.packagedAppId -split '_')[0]]
        } | Select-Object -Unique)
    }
    catch { @() }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Remove-GenesisStartPin {
    param([Parameter(Mandatory)][string]$RunDirectory)
    # Les raccourcis « à installer » (WhatsApp, LinkedIn…) n'ont pas de commande Désépingler :
    # on réapplique une seule fois la liste actuelle sans eux (ConfigureStartPins + applyOnce), puis on retire la stratégie.
    $key = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
    $existing = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($null -ne $existing -and ($existing.PSObject.Properties.Name -contains 'ConfigureStartPins' -or $existing.PSObject.Properties.Name -contains 'ConfigureStartPinsJSON')) {
        return 'Épingles gérées par une stratégie existante : non modifiées.'
    }
    $folder = Join-Path $env:LOCALAPPDATA ('Genesis\StartPins\' + (Split-Path -Leaf $RunDirectory))
    New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $before = Join-Path $folder 'avant.json'
    Export-StartLayout -Path $before -ErrorAction Stop
    $layout = Get-Content -LiteralPath $before -Raw -Encoding UTF8 | ConvertFrom-Json
    $pattern = '^(' + ((@($script:GenesisStartCleanupPackages.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')_'
    $all = @($layout.pinnedList)
    $kept = @($all | Where-Object { -not ($_.PSObject.Properties.Name -contains 'packagedAppId' -and [string]$_.packagedAppId -match $pattern) })
    if ($kept.Count -eq $all.Count) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue; return 'Aucune épingle à retirer du menu Démarrer.' }
    $pinsPath = Join-Path $folder 'epingles.json'
    $json = [pscustomobject]@{ applyOnce = $true; pinnedList = $kept } | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText($pinsPath, $json, (New-Object Text.UTF8Encoding($false)))
    try {
        New-Item -Path $key -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $key -Name 'ConfigureStartPins' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $key -Name 'ConfigureStartPinsJSON' -PropertyType ExpandString -Value $pinsPath -Force -ErrorAction Stop | Out-Null
        Get-Process -Name StartMenuExperienceHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }
    finally {
        Remove-ItemProperty -LiteralPath $key -Name 'ConfigureStartPins', 'ConfigureStartPinsJSON' -ErrorAction SilentlyContinue
        Get-Process -Name StartMenuExperienceHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    $after = Join-Path $folder 'apres.json'
    Export-StartLayout -Path $after -ErrorAction Stop
    $left = @((Get-Content -LiteralPath $after -Raw -Encoding UTF8 | ConvertFrom-Json).pinnedList | Where-Object { $_.PSObject.Properties.Name -contains 'packagedAppId' -and [string]$_.packagedAppId -match $pattern })
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    if ($left.Count -gt 0) { throw 'Les épingles du menu Démarrer n''ont pas pu être retirées.' }
    return ('{0} épingle(s) retirée(s) du menu Démarrer.' -f ($all.Count - $kept.Count))
}

function Invoke-GenesisStartCleanup {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $names = @($script:GenesisStartCleanupPackages.Keys)
    $installed = @(Get-GenesisStartCleanupInstalled)
    $removed = @(); $failed = @()
    $index = 0
    foreach ($package in $installed) {
        $index++
        $label = $script:GenesisStartCleanupPackages[$package.Name]
        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'start-cleanup' -Percent ([int](10 + 60 * $index / [math]::Max(1, $installed.Count))) -Message ('Désinstallation : ' + $label)
        try { Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop; $removed += $label }
        catch { $failed += $label; Write-Verbose ('Désinstallation impossible : ' + $package.Name + ' : ' + $_.Exception.Message) }
    }
    # Retrait des applications préinstallées : les comptes créés ensuite ne les reçoivent plus.
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'start-cleanup' -Percent 80 -Message 'Retrait des applications préinstallées pour les nouveaux comptes'
    foreach ($provisioned in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -in $names })) {
        try { Remove-AppxProvisionedPackage -Online -PackageName $provisioned.PackageName -ErrorAction Stop | Out-Null }
        catch { $failed += $script:GenesisStartCleanupPackages[$provisioned.DisplayName]; Write-Verbose ('Retrait préinstallé impossible : ' + $provisioned.DisplayName) }
    }
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'start-cleanup' -Percent 90 -Message 'Retrait des épingles WhatsApp, LinkedIn et des applications désinstallées'
    $pinText = try { ' ' + (Remove-GenesisStartPin -RunDirectory $RunDirectory) } catch { $failed += 'épingles'; ' Épingles du menu Démarrer à retirer à la main : ' + $_.Exception.Message }
    $remaining = @(Get-GenesisStartCleanupInstalled | ForEach-Object { $script:GenesisStartCleanupPackages[$_.Name] } | Select-Object -Unique)
    $removedText = if ($removed.Count -gt 0) { 'Désinstallé : ' + ((@($removed) | Select-Object -Unique) -join ', ') + '.' } else { 'Aucune de ces applications n''était installée.' }
    if ($remaining.Count -gt 0) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 90; Message = $removedText + ' Toujours présent : ' + ($remaining -join ', ') + '.' + $pinText }
    }
    if ($failed -contains 'épingles') { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 90; Message = $removedText + $pinText } }
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = $removedText + $pinText + ' Non réversible : réinstaller depuis le Microsoft Store si besoin.' }
}

function Get-GenesisTaskbarPinnedApp {
    param([Parameter(Mandatory)][string[]]$Names)
    # Le verbe « Désépingler de la barre des tâches » n'est proposé que pour les applications épinglées.
    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}')
    if ($null -eq $folder) { return @() }
    foreach ($item in @($folder.Items())) {
        if ([string]$item.Name -notin $Names) { continue }
        $verb = @($item.Verbs()) | Where-Object { ([string]$_.Name -replace '&', '') -match '^(Désépingler de la barre des tâches|Unpin from taskbar)$' } | Select-Object -First 1
        if ($null -ne $verb) { [pscustomobject]@{ Name = [string]$item.Name; Verb = $verb } }
    }
}

function Set-GenesisTaskbarLeft {
    param([Parameter(Mandatory)][string]$RunDirectory)
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'taskbar-left' -Percent 20 -Message 'Sauvegarde et alignement de la barre des tâches à gauche'
    $change = [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAl'; Kind = 'DWord'; Data = 0 }
    Invoke-GenesisRegistryTransaction -Changes @($change) -SnapshotPath (Join-Path $RunDirectory 'taskbar-left.registry.json')
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'taskbar-left' -Percent 50 -Message 'Retrait des épingles Edge et Microsoft Store'
    $names = @('Microsoft Edge', 'Microsoft Store')
    foreach ($pin in @(Get-GenesisTaskbarPinnedApp -Names $names)) {
        try { $pin.Verb.DoIt() } catch { Write-Verbose ('Désépinglage impossible : ' + $pin.Name) }
    }
    Start-Sleep -Milliseconds 800
    $remaining = @(Get-GenesisTaskbarPinnedApp -Names $names | ForEach-Object { $_.Name })
    if ($remaining.Count -gt 0) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 70; Message = 'Barre à gauche. Toujours épinglé : ' + ($remaining -join ', ') + ' (clic droit > Désépingler), puis reprendre.' }
    }
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Barre des tâches à gauche, sans Edge ni Microsoft Store. Reverse rétablit l''alignement.' }
}

function ConvertFrom-GenesisNtpPacket {
    param([byte[]]$Packet, [byte[]]$Origin)
    if ($Packet.Length -lt 48 -or (($Packet[0] -shr 6) -eq 3) -or ($Packet[0] -band 7) -ne 4 -or $Packet[1] -lt 1 -or $Packet[1] -gt 15) { throw 'Réponse NTP invalide ou non synchronisée.' }
    for ($i = 0; $i -lt 8; $i++) { if ($Packet[24 + $i] -ne $Origin[$i]) { throw 'Réponse NTP étrangère à la requête.' } }
    $seconds = 0L; $fraction = 0L
    for ($i = 0; $i -lt 4; $i++) {
        $seconds = ($seconds -shl 8) + $Packet[40 + $i]
        $fraction = ($fraction -shl 8) + $Packet[44 + $i]
    }
    if ($seconds -eq 0) { throw 'Horodatage NTP vide.' }
    return ([datetime]'1900-01-01T00:00:00Z').ToUniversalTime().AddSeconds($seconds + $fraction / 4294967296.0)
}

function Get-GenesisNetworkTime {
    param([string]$Server)
    $hostName = ($Server -split ',')[0]
    $address = [Net.Dns]::GetHostAddresses($hostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
    if ($null -eq $address) { throw 'Serveur horaire IPv4 introuvable.' }
    $client = New-Object Net.Sockets.UdpClient
    try {
        $client.Client.ReceiveTimeout = 4000
        $client.Connect($address, 123)
        $request = New-Object byte[] 48
        $request[0] = 35
        $origin = [guid]::NewGuid().ToByteArray()[0..7]
        [Array]::Copy($origin, 0, $request, 40, 8)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $client.Send($request, $request.Length) | Out-Null
        $peer = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $reply = $client.Receive([ref]$peer)
        $timer.Stop()
        $utc = ConvertFrom-GenesisNtpPacket -Packet $reply -Origin $origin
        return $utc.AddMilliseconds($timer.Elapsed.TotalMilliseconds / 2)
    }
    finally { $client.Close() }
}

function Invoke-GenesisNativeCommand {
    param([string]$FilePath, [string]$Arguments, [int]$TimeoutSeconds = 20, [string]$WorkingDirectory, [hashtable]$Environment)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath; $info.Arguments = $Arguments
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $info.WorkingDirectory = $WorkingDirectory }
    if ($null -ne $Environment) {
        foreach ($entry in $Environment.GetEnumerator()) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.Key)) {
                $info.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
            }
        }
    }
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        $process.Start() | Out-Null
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); throw 'Délai de la commande Windows dépassé.' }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Result; ErrorOutput = $errorOutput.Result }
    }
    finally { $process.Dispose() }
}

function Get-GenesisWindowsUpdateSearchCriterion {
    [CmdletBinding()]
    param()
    # Sans DeploymentAction explicite, Windows Update ne renvoie que les installations
    # obligatoires : les mises à jour facultatives et les mises à niveau (ex. 26H2) sont
    # proposées en OptionalInstallation.
    return "IsInstalled=0 and IsHidden=0 and DeploymentAction='Installation' or IsInstalled=0 and IsHidden=0 and DeploymentAction='OptionalInstallation'"
}

# Catégorie Windows Update « Upgrades » : mises à niveau de version de Windows.
$script:GenesisFeatureUpdateCategoryId = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'

function Test-GenesisFeatureUpdate {
    param([Parameter(Mandatory)]$Update)
    $categories = try { @($Update.Categories) } catch { @() }
    foreach ($category in $categories) {
        if ([string]$category.CategoryID -eq $script:GenesisFeatureUpdateCategoryId) { return $true }
    }
    return $false
}

function Select-GenesisWindowsUpdate {
    param([AllowEmptyCollection()][object[]]$Updates = @(), [ValidateSet('Quality', 'Feature')][string]$Scope = 'Quality')
    @($Updates | Where-Object {
            -not [bool]$_.IsInstalled -and -not [bool]$_.IsHidden -and
            ((Test-GenesisFeatureUpdate -Update $_) -eq ($Scope -eq 'Feature'))
        })
}

function New-GenesisWindowsUpdateCollection {
    [CmdletBinding()]
    param()
    return New-Object -ComObject Microsoft.Update.UpdateColl
}

function Get-GenesisWindowsUpdateSession {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { throw 'Windows Update est disponible sur Windows uniquement.' }
    $service = Get-Service -Name wuauserv -ErrorAction Stop
    if ($service.Status -ne 'Running') { Start-Service -Name wuauserv -ErrorAction Stop }
    return New-Object -ComObject Microsoft.Update.Session
}

function Get-GenesisWindowsUpdateResultCode {
    param([Parameter(Mandatory)]$Result)
    try { return [int]$Result.ResultCode } catch { return -1 }
}

function Get-GenesisWindowsCurrentVersion {
    [CmdletBinding()]
    param()
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $release = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $displayVersion = [string]$release.DisplayVersion
    if ([string]::IsNullOrWhiteSpace($displayVersion)) { $displayVersion = [string]$release.ReleaseId }
    if ([string]::IsNullOrWhiteSpace($displayVersion)) { $displayVersion = 'Version inconnue' }
    $build = [string]$release.CurrentBuild
    if ([string]::IsNullOrWhiteSpace($build)) { $build = [string]$os.BuildNumber }
    $ubr = $null
    if ($release.PSObject.Properties.Name -contains 'UBR') { $ubr = [string]$release.UBR }
    $buildLabel = if ([string]::IsNullOrWhiteSpace($ubr)) { $build } else { $build + '.' + $ubr }
    [pscustomobject]@{
        Caption = [string]$os.Caption
        DisplayVersion = $displayVersion
        Build = $buildLabel
        Label = ('{0} {1} (build {2})' -f [string]$os.Caption, $displayVersion, $buildLabel).Trim()
    }
}

function Get-GenesisWindowsVersionStatus {
    [CmdletBinding()]
    param([object]$Session)
    # La checklist interroge cet état pour deux opérations : une seule recherche suffit.
    $cache = Get-Variable -Scope Script -Name GenesisWindowsVersionStatusCache -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $Session -and $null -ne $cache -and ([datetime]::UtcNow - $cache.At).TotalMinutes -lt 5) { return $cache.Status }
    $current = Get-GenesisWindowsCurrentVersion
    $latest = $current.Label
    $availableCount = 0
    $featureTitle = $null
    $scanSucceeded = $false
    $scanError = $null
    try {
        if ($null -eq $Session) { $Session = Get-GenesisWindowsUpdateSession }
        $searcher = $Session.CreateUpdateSearcher()
        $result = $searcher.Search((Get-GenesisWindowsUpdateSearchCriterion))
        $updates = @($result.Updates)
        $availableCount = @(Select-GenesisWindowsUpdate -Updates $updates -Scope Quality).Count
        $features = @(Select-GenesisWindowsUpdate -Updates $updates -Scope Feature)
        $scanSucceeded = $true
        if ($features.Count -gt 0) {
            $featureTitle = [string](@($features | Sort-Object @{ Expression = {
                            if ([string]$_.Title -match '(?i)version\s+(\d{2})H(\d)') { [int]($Matches[1] + $Matches[2]) } else { 0 }
                        }; Descending = $true
                    } | Select-Object -First 1).Title)
            $latest = $featureTitle
        }
        elseif ($availableCount -eq 0) { $latest = 'Aucune mise à jour proposée par Windows Update' }
        else { $latest = 'Aucune nouvelle version de Windows détectée' }
    }
    catch {
        $scanError = $_.Exception.Message
        $latest = 'Recherche Windows Update indisponible'
    }
    $status = [pscustomobject]@{
        Current = $current.Label
        CurrentVersion = $current.DisplayVersion
        CurrentBuild = $current.Build
        Latest = $latest
        LatestVersion = $latest
        AvailableCount = $availableCount
        FeatureUpdate = $featureTitle
        ScanSucceeded = $scanSucceeded
        Error = $scanError
    }
    if ($scanSucceeded) { $script:GenesisWindowsVersionStatusCache = [pscustomobject]@{ At = [datetime]::UtcNow; Status = $status } }
    return $status
}

function Invoke-GenesisWindowsUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [object]$Session,
        [ValidateRange(1, 5)][int]$MaxPasses = 3,
        [ValidateSet('Quality', 'Feature')][string]$Scope = 'Quality'
    )
    if ($env:OS -ne 'Windows_NT') { throw 'Windows Update est disponible sur Windows uniquement.' }
    if ($null -eq $Session) { $Session = Get-GenesisWindowsUpdateSession }
    $stepId = if ($Scope -eq 'Feature') { 'windows-feature-update' } else { 'windows-update' }
    $label = if ($Scope -eq 'Feature') { 'mise à niveau de Windows' } else { 'mise(s) à jour' }
    $criteria = Get-GenesisWindowsUpdateSearchCriterion
    $logPath = Join-Path $RunDirectory ($stepId + '.json')
    $journal = [ordered]@{
        SchemaVersion = 1
        Scope = $Scope
        SearchCriteria = $criteria
        StartedAt = [datetime]::UtcNow.ToString('o')
        FinishedAt = $null
        Passes = @()
        PendingReboot = $false
        AvailableAtEnd = $null
    }
    Write-GenesisJson -Path $logPath -Value ([pscustomobject]$journal)
    for ($passNumber = 1; $passNumber -le $MaxPasses; $passNumber++) {
        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $stepId -Percent 10 -Message ("Recherche Windows Update (passe {0}/{1})" -f $passNumber, $MaxPasses)
        $searcher = $Session.CreateUpdateSearcher()
        $searchResult = $searcher.Search($criteria)
        $available = @(Select-GenesisWindowsUpdate -Updates @($searchResult.Updates) -Scope $Scope)
        if ($available.Count -eq 0) {
            $journal.AvailableAtEnd = 0
            $journal.FinishedAt = [datetime]::UtcNow.ToString('o')
            Write-GenesisJson -Path $logPath -Value ([pscustomobject]$journal)
            if ($Scope -eq 'Feature') {
                Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $stepId -Percent 100 -Message 'Aucune mise à niveau de Windows proposée.'
                return [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Windows est à la dernière version proposée.' }
            }
            Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $stepId -Percent 100 -Message 'Windows est à jour ; aucune mise à jour facultative disponible.'
            return [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Windows et les mises à jour facultatives sont à jour.' }
        }

        $updates = New-GenesisWindowsUpdateCollection
        $titles = @()
        foreach ($update in $available) {
            if ($update.PSObject.Properties.Name -contains 'EulaAccepted' -and -not [bool]$update.EulaAccepted) { $update.AcceptEula() }
            [void]$updates.Add($update)
            $titles += [string]$update.Title
        }
        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $stepId -Percent 30 -Message ("{0} {1} détectée(s) ; téléchargement" -f $available.Count, $label)
        $downloader = $Session.CreateUpdateDownloader()
        $downloader.Updates = $updates
        $downloadResult = $downloader.Download()
        $downloadCode = Get-GenesisWindowsUpdateResultCode -Result $downloadResult
        if ($downloadCode -notin @(2, 3)) { throw ("Téléchargement Windows Update échoué (code {0})." -f $downloadCode) }

        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $stepId -Percent 65 -Message ("Installation : {0}" -f ($titles -join ', '))
        $installer = $Session.CreateUpdateInstaller()
        $installer.Updates = $updates
        $installResult = $installer.Install()
        $installCode = Get-GenesisWindowsUpdateResultCode -Result $installResult
        $rebootRequired = [bool]$installResult.RebootRequired
        $journal.Passes += [pscustomobject]@{
            Number = $passNumber
            UpdateCount = $available.Count
            Titles = $titles
            DownloadResultCode = $downloadCode
            InstallResultCode = $installCode
            RebootRequired = $rebootRequired
        }
        $journal.PendingReboot = $rebootRequired
        Write-GenesisJson -Path $logPath -Value ([pscustomobject]$journal)
        if ($installCode -notin @(2, 3)) { throw ("Installation Windows Update échouée (code {0})." -f $installCode) }
        if ($rebootRequired) {
            $journal.FinishedAt = [datetime]::UtcNow.ToString('o')
            Write-GenesisJson -Path $logPath -Value ([pscustomobject]$journal)
            Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $stepId -Percent 100 -Message 'Redémarrage requis ; redémarrer puis reprendre Genesis.'
            return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 100; Message = 'Windows Update demande un redémarrage. Redémarrer puis utiliser Resume Genesis.' }
        }
    }
    $journal.FinishedAt = [datetime]::UtcNow.ToString('o')
    $journal.AvailableAtEnd = $null
    Write-GenesisJson -Path $logPath -Value ([pscustomobject]$journal)
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $stepId -Percent 100 -Message 'Plusieurs passes exécutées ; reprendre pour rechercher les mises à jour restantes.'
    [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 100; Message = 'Des mises à jour restent proposées après plusieurs passes ; reprendre Genesis.' }
}

$script:GenesisOfficeDeploymentToolPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=49117'
$script:GenesisPdfCraftReleaseUri = 'https://api.github.com/repos/storytold/pdfcraft/releases/latest'
$script:GenesisNetBirdMsiUri = 'https://pkgs.netbird.io/windows/msi/x64'

function Get-GenesisSoftwareDirectory {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $directory = Join-Path $RunDirectory 'software'
    New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    return $directory
}

function Get-GenesisCurlPath {
    $command = Get-Command curl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    return $null
}

function Save-GenesisDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -Path $parent -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($existing.Length -gt 0) {
            $existingHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
            if ([string]::IsNullOrWhiteSpace($ExpectedSha256) -or $existingHash -ceq $ExpectedSha256.Trim().ToUpperInvariant()) {
                return [pscustomobject]@{ Path = $existing.FullName; Name = $existing.Name; Length = $existing.Length; Sha256 = $existingHash; Uri = $Uri.AbsoluteUri; Method = 'Cache' }
            }
        }
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    $partialPath = $Path + '.part'
    $method = 'WebRequest'
    $downloaded = $false
    $curlPath = Get-GenesisCurlPath
    if (-not [string]::IsNullOrWhiteSpace($curlPath)) {
        try {
            $curlArguments = '--location --fail --silent --show-error --retry 5 --retry-delay 2 --retry-connrefused --continue-at - --output "{0}" "{1}"' -f $partialPath, $Uri.AbsoluteUri
            $curlResult = Invoke-GenesisNativeCommand -FilePath $curlPath -Arguments $curlArguments -TimeoutSeconds 7200
            if ($curlResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $partialPath)) {
                $downloaded = $true
                $method = 'curl.exe'
            }
            else { Write-Verbose ('curl.exe a renvoyé le code {0} pour {1}.' -f $curlResult.ExitCode, $Uri.AbsoluteUri) }
        }
        catch { Write-Verbose ('curl.exe indisponible pour {0}, repli HTTP : {1}' -f $Uri.AbsoluteUri, $_.Exception.Message) }
    }
    if (-not $downloaded) {
        $oldProgressPreference = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Uri.AbsoluteUri -OutFile $partialPath -UseBasicParsing -Headers @{ 'User-Agent' = ('Genesis/' + $script:GenesisVersion) } -ErrorAction Stop
        }
        finally { $ProgressPreference = $oldProgressPreference }
    }
    if (-not (Test-Path -LiteralPath $partialPath)) { throw "Téléchargement absent après transfert : $($Uri.AbsoluteUri)" }
    Move-Item -LiteralPath $partialPath -Destination $Path -Force -ErrorAction Stop
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -le 0) { throw "Téléchargement vide : $($Uri.AbsoluteUri)" }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $hash -cne $ExpectedSha256.Trim().ToUpperInvariant()) {
        throw "Empreinte SHA-256 inattendue pour $($file.Name)."
    }
    [pscustomobject]@{ Path = $file.FullName; Name = $file.Name; Length = $file.Length; Sha256 = $hash; Uri = $Uri.AbsoluteUri; Method = $method }
}

function ConvertTo-GenesisNetworkPrinterRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Printer,
        $Port
    )
    $printerProperties = @($Printer.PSObject.Properties.Name)
    $portProperties = if ($null -ne $Port) { @($Port.PSObject.Properties.Name) } else { @() }
    $name = if ('Name' -in $printerProperties) { [string]$Printer.Name } else { '' }
    $portName = if ('PortName' -in $printerProperties) { [string]$Printer.PortName } else { '' }
    $driver = if ('DriverName' -in $printerProperties) { [string]$Printer.DriverName } else { '' }
    $type = if ('Type' -in $printerProperties) { [string]$Printer.Type } else { '' }
    $serverName = if ('ServerName' -in $printerProperties) { [string]$Printer.ServerName } else { '' }
    $networkValue = if ('Network' -in $printerProperties) { $Printer.Network } else { $false }
    $networkFlag = ($networkValue -is [bool] -and $networkValue) -or ([string]$networkValue -match '^(?i:true|yes|1)$')
    $address = ''
    if ($null -ne $Port -and 'PrinterHostAddress' -in $portProperties) { $address = [string]$Port.PrinterHostAddress }
    if ([string]::IsNullOrWhiteSpace($address) -and $name -match '^\\\\(?<server>[^\\]+)') { $address = $Matches['server'] }
    if ([string]::IsNullOrWhiteSpace($address) -and $portName -match '(?i)^IP_(?<ip>\d{1,3}(?:\.\d{1,3}){3})$') { $address = $Matches['ip'] }
    if ([string]::IsNullOrWhiteSpace($address) -and -not [string]::IsNullOrWhiteSpace($serverName)) { $address = $serverName }
    $networkPort = $portName -match '(?i)^(?:IP_|WSD-|TCP|HTTP|HTTPS|IPP|LPR|\d{1,3}(?:\.\d{1,3}){3})'
    $isNetwork = $networkFlag -or (-not [string]::IsNullOrWhiteSpace($address)) -or ($name -match '^\\') -or ($type -match '(?i)connection|network') -or $networkPort
    if (-not $isNetwork -or [string]::IsNullOrWhiteSpace($name)) { return $null }
    [pscustomobject]@{
        Name = $name.Trim()
        Address = $address.Trim()
        PortName = $portName.Trim()
        DriverName = $driver.Trim()
        Type = $type.Trim()
        SearchQuery = ($name.Trim() + ' drivers').Trim()
        Source = 'Windows'
        Status = 'Installed'
        Installed = $true
        CanAdd = $false
        Discovered = $false
        DeviceUUID = ''
        DeviceURL = ''
    }
}

function Get-GenesisRawPrinterQueue {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { return @() }
    $command = Get-Command Get-Printer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return @(Get-Printer -ErrorAction SilentlyContinue) }
    return @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
}

function Get-GenesisRawPrinterPort {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { return @() }
    $command = Get-Command Get-PrinterPort -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return @() }
    return @(Get-PrinterPort -ErrorAction SilentlyContinue)
}

function Get-GenesisDeviceProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Device,
        [Parameter(Mandatory)][string]$Name
    )
    $deviceProperties = @($Device.PSObject.Properties.Name)
    if ('Properties' -notin $deviceProperties) { return $null }
    $properties = $Device.Properties
    if ($null -eq $properties) { return $null }
    if ($properties -is [System.Collections.IDictionary]) {
        foreach ($key in $properties.Keys) {
            if ([string]$key -ceq $Name) { return $properties[$key] }
        }
    }
    foreach ($entry in @($properties)) {
        $entryProperties = @($entry.PSObject.Properties.Name)
        if ('Key' -in $entryProperties -and [string]$entry.Key -ceq $Name) { return $entry.Value }
    }
    return $null
}

function Get-GenesisPrinterDeviceUuid {
    [CmdletBinding()]
    param([string[]]$Values)
    foreach ($value in @($Values)) {
        $text = [string]$value
        if ($text -match '(?i)(?:urn:uuid:|uuid:)(?<uuid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            return $Matches['uuid']
        }
    }
    return ''
}

function ConvertTo-GenesisDiscoveredPrinterRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Device)
    $name = [string](Get-GenesisDeviceProperty -Device $Device -Name 'System.ItemNameDisplay')
    if ([string]::IsNullOrWhiteSpace($name) -and 'Name' -in @($Device.PSObject.Properties.Name)) { $name = [string]$Device.Name }
    $address = [string](Get-GenesisDeviceProperty -Device $Device -Name 'System.Devices.Aep.DeviceAddress')
    $manufacturer = [string](Get-GenesisDeviceProperty -Device $Device -Name 'System.Devices.Aep.Manufacturer')
    $model = [string](Get-GenesisDeviceProperty -Device $Device -Name 'System.Devices.Aep.ModelName')
    $categoryValue = Get-GenesisDeviceProperty -Device $Device -Name 'System.Devices.Aep.Category'
    $categories = @($categoryValue | ForEach-Object { [string]$_ })
    $serviceClass = [string](Get-GenesisDeviceProperty -Device $Device -Name 'System.Devices.AepService.ServiceClassId')
    if ([string]::IsNullOrWhiteSpace($name) -or (-not ($categories -match '(?i)printer') -and $serviceClass -notmatch '(?i)65dca7bd-2611-583e-9a12-ad90f47749cf|fb9074da-3d9f-5384-922e-9978ae51ef0c|5d2a7252-d45c-5158-87a4-05212da327e1')) {
        return $null
    }
    $serviceId = [string](Get-GenesisDeviceProperty -Device $Device -Name 'System.Devices.AepService.ServiceId')
    if ([string]::IsNullOrWhiteSpace($serviceId) -and 'Id' -in @($Device.PSObject.Properties.Name)) { $serviceId = [string]$Device.Id }
    $uuid = Get-GenesisPrinterDeviceUuid -Values @($serviceId, [string](Get-GenesisDeviceProperty -Device $Device -Name 'System.Devices.AepService.AepId'), [string](Get-GenesisDeviceProperty -Device $Device -Name 'System.Devices.Aep.AepId'))
    $deviceUrl = ''
    if ($serviceId -match '(?i)#(?<url>https?://[^#\s]+)$') { $deviceUrl = $Matches['url'] }
    $displayName = $name.Trim()
    [pscustomobject]@{
        Name = $displayName
        Address = $address.Trim()
        PortName = ''
        DriverName = ''
        Type = 'WSD'
        SearchQuery = ($displayName + ' drivers').Trim()
        Source = 'WSD'
        Status = 'Available'
        Installed = $false
        CanAdd = (-not [string]::IsNullOrWhiteSpace($uuid))
        Discovered = $true
        DeviceUUID = $uuid
        DeviceURL = $deviceUrl
        Manufacturer = $manufacturer.Trim()
        ModelName = $model.Trim()
        DeviceId = if ('Id' -in @($Device.PSObject.Properties.Name)) { [string]$Device.Id } else { $serviceId }
        ServiceId = $serviceId
    }
}

function Get-GenesisRawPrinterDevice {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { return @() }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $deviceType = [type]::GetType('Windows.Devices.Enumeration.DeviceInformation, Windows, ContentType=WindowsRuntime')
        $kindType = [type]::GetType('Windows.Devices.Enumeration.DeviceInformationKind, Windows, ContentType=WindowsRuntime')
        if ($null -eq $deviceType -or $null -eq $kindType) { return @() }
        $selector = 'System.Devices.AepService.ProtocolId:="{782232aa-a2f9-4993-971b-aedc551346b0}" AND System.Devices.AepService.ServiceClassId:="{65dca7bd-2611-583e-9a12-ad90f47749cf}"'
        $requested = [string[]]@(
            'System.ItemNameDisplay', 'System.Devices.Aep.ProtocolId', 'System.Devices.AepService.ProtocolId',
            'System.Devices.AepService.ServiceClassId', 'System.Devices.AepService.AepId', 'System.Devices.Aep.DeviceAddress',
            'System.Devices.Aep.ModelName', 'System.Devices.Aep.Manufacturer', 'System.Devices.Aep.Category',
            'System.Devices.AepService.ServiceId'
        )
        $kind = [Enum]::Parse($kindType, 'AssociationEndpointService')
        $operation = $deviceType::FindAllAsync($selector, $requested, $kind)
        $findMethod = @($deviceType.GetMethods([Reflection.BindingFlags]'Public,Static') | Where-Object { $_.Name -eq 'FindAllAsync' -and $_.GetParameters().Count -eq 3 -and $_.ReturnType.IsGenericType }) | Select-Object -First 1
        if ($null -eq $findMethod) { return @() }
        $resultType = $findMethod.ReturnType.GetGenericArguments()[0]
        $asTaskMethod = @([System.WindowsRuntimeSystemExtensions].GetMethods([Reflection.BindingFlags]'Public,Static') | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 }) | Select-Object -First 1
        if ($null -eq $asTaskMethod) { return @() }
        $task = $asTaskMethod.MakeGenericMethod($resultType).Invoke($null, [object[]]@($operation))
        $collection = $task.GetAwaiter().GetResult()
        return @($collection | ForEach-Object { ConvertTo-GenesisDiscoveredPrinterRecord -Device $_ } | Where-Object { $null -ne $_ })
    }
    catch {
        Write-Verbose ('Découverte Windows des imprimantes indisponible : ' + $_.Exception.Message)
        return @()
    }
}

function Get-GenesisNetworkPrinter {
    [CmdletBinding()]
    param()
    $ports = @{}
    foreach ($port in @(Get-GenesisRawPrinterPort)) {
        $properties = @($port.PSObject.Properties.Name)
        if ('Name' -in $properties -and -not [string]::IsNullOrWhiteSpace([string]$port.Name)) { $ports[[string]$port.Name] = $port }
    }
    $unique = @{}
    foreach ($printer in @(Get-GenesisRawPrinterQueue)) {
        $properties = @($printer.PSObject.Properties.Name)
        $portName = if ('PortName' -in $properties) { [string]$printer.PortName } else { '' }
        $port = if ($ports.ContainsKey($portName)) { $ports[$portName] } else { $null }
        $record = ConvertTo-GenesisNetworkPrinterRecord -Printer $printer -Port $port
        if ($null -eq $record) { continue }
        $key = ('{0}|{1}' -f $record.Name, $record.Address).ToLowerInvariant()
        if (-not $unique.ContainsKey($key)) { $unique[$key] = $record }
    }
    foreach ($discovered in @(Get-GenesisRawPrinterDevice)) {
        $match = @($unique.GetEnumerator() | ForEach-Object { $_.Value } | Where-Object {
            ([string]::IsNullOrWhiteSpace([string]$discovered.Address) -eq $false -and [string]$_.Address -eq [string]$discovered.Address) -or ([string]$_.Name -eq [string]$discovered.Name)
        }) | Select-Object -First 1
        if ($null -ne $match) {
            $match.Discovered = $true
            $match.DeviceUUID = [string]$discovered.DeviceUUID
            $match.DeviceURL = [string]$discovered.DeviceURL
            $match.CanAdd = $false
            continue
        }
        $key = ('{0}|{1}' -f $discovered.Name, $discovered.Address).ToLowerInvariant()
        if (-not $unique.ContainsKey($key)) { $unique[$key] = $discovered }
    }
    return @($unique.GetEnumerator() | ForEach-Object { $_.Value } | Sort-Object @{ Expression = { if ($_.Installed) { 0 } else { 1 } } }, Name, Address)
}

function Add-GenesisPrinter {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Printer)
    $properties = @($Printer.PSObject.Properties.Name)
    if ('Name' -notin $properties -or [string]::IsNullOrWhiteSpace([string]$Printer.Name)) { throw 'Imprimante invalide.' }
    if ('Installed' -in $properties -and $Printer.Installed) {
        return [pscustomobject]@{ Status = 'AlreadyInstalled'; PrinterName = [string]$Printer.Name; Message = 'Cette imprimante est déjà installée.' }
    }
    if ($env:OS -ne 'Windows_NT') { throw 'L''ajout d''une imprimante doit être exécuté depuis Windows.' }
    if ($null -eq (Get-Command Add-Printer -ErrorAction SilentlyContinue)) { throw 'Add-Printer est indisponible sur cette édition de Windows.' }
    $arguments = @{ Name = [string]$Printer.Name }
    if ('DeviceUUID' -in $properties -and -not [string]::IsNullOrWhiteSpace([string]$Printer.DeviceUUID)) { $arguments.DeviceUUID = [string]$Printer.DeviceUUID }
    if ('DeviceURL' -in $properties -and -not [string]::IsNullOrWhiteSpace([string]$Printer.DeviceURL)) { $arguments.DeviceURL = [string]$Printer.DeviceURL }
    if ($arguments.Keys.Count -eq 1) { throw 'Windows n''a fourni aucun identifiant WSD exploitable pour cette imprimante.' }
    if (-not $PSCmdlet.ShouldProcess([string]$Printer.Name, 'Ajouter l''imprimante réseau')) { return [pscustomobject]@{ Status = 'Skipped'; PrinterName = [string]$Printer.Name; Message = 'Ajout ignoré.' } }
    Add-Printer @arguments -ErrorAction Stop
    $installed = @(Get-GenesisRawPrinterQueue | Where-Object { [string]$_.Name -eq [string]$Printer.Name })
    if ($installed.Count -eq 0) { return [pscustomobject]@{ Status = 'NeedsAttention'; PrinterName = [string]$Printer.Name; Message = 'Windows a lancé l''ajout mais la file n''est pas encore visible ; actualiser.' } }
    [pscustomobject]@{ Status = 'Completed'; PrinterName = [string]$Printer.Name; Message = 'Imprimante ajoutée et vérifiée.' }
}

function New-GenesisPrinterDriverSearchUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PrinterName)
    $query = (($PrinterName.Trim() + ' drivers') -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($PrinterName)) { throw 'Nom d''imprimante vide.' }
    return 'https://www.google.com/search?q=' + [uri]::EscapeDataString($query)
}

function Open-GenesisPrinterDriverSearch {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Printer)
    $properties = @($Printer.PSObject.Properties.Name)
    if ('Name' -notin $properties -or [string]::IsNullOrWhiteSpace([string]$Printer.Name)) { throw 'Imprimante invalide.' }
    $url = New-GenesisPrinterDriverSearchUrl -PrinterName ([string]$Printer.Name)
    if (-not $PSCmdlet.ShouldProcess($url, 'Ouvrir la recherche Google des pilotes')) { return [pscustomobject]@{ Status = 'Skipped'; Url = $url } }
    if ($env:OS -ne 'Windows_NT') { throw 'La recherche Google doit être ouverte depuis Windows.' }
    Start-Process -FilePath $url -ErrorAction Stop | Out-Null
    [pscustomobject]@{ Status = 'Opened'; Url = $url; PrinterName = [string]$Printer.Name }
}

function Get-GenesisInstalledProgram {
    [CmdletBinding()]
    param()
    if ($env:OS -ne 'Windows_NT') { return @() }
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $records = @()
    foreach ($root in $roots) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try { $properties = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction Stop } catch { continue }
            $propertyNames = @($properties.PSObject.Properties | ForEach-Object { [string]$_.Name })
            if ('DisplayName' -notin $propertyNames -or [string]::IsNullOrWhiteSpace([string]$properties.DisplayName)) { continue }
            $systemComponent = if ('SystemComponent' -in $propertyNames) { [int]$properties.SystemComponent } else { 0 }
            $releaseType = if ('ReleaseType' -in $propertyNames) { [string]$properties.ReleaseType } else { '' }
            if ($systemComponent -eq 1 -or $releaseType -match '(?i)^(Hotfix|Security Update|Update)$') { continue }
            $uninstall = if ('UninstallString' -in $propertyNames) { [string]$properties.UninstallString } else { '' }
            $quiet = if ('QuietUninstallString' -in $propertyNames) { [string]$properties.QuietUninstallString } else { '' }
            $version = if ('DisplayVersion' -in $propertyNames) { [string]$properties.DisplayVersion } else { '' }
            $publisher = if ('Publisher' -in $propertyNames) { [string]$properties.Publisher } else { '' }
            $sizeKb = if ('EstimatedSize' -in $propertyNames) { [int64]$properties.EstimatedSize } else { 0 }
            $scope = if ($root -like 'HKCU:*') { 'Utilisateur' } else { 'Ordinateur' }
            $records += [pscustomobject]@{
                Name = ([string]$properties.DisplayName).Trim(); Version = $version.Trim(); Publisher = $publisher.Trim()
                Scope = $scope; RegistryPath = [string]$entry.PSPath; UninstallString = $uninstall.Trim(); QuietUninstallString = $quiet.Trim()
                CanUninstall = (-not [string]::IsNullOrWhiteSpace($quiet) -or -not [string]::IsNullOrWhiteSpace($uninstall))
                SizeMiB = if ($sizeKb -gt 0) { [math]::Round($sizeKb / 1024, 1) } else { $null }
            }
        }
    }
    $unique = @{}
    foreach ($record in ($records | Sort-Object Name, Version, RegistryPath)) {
        $key = ('{0}|{1}|{2}' -f $record.Name, $record.Version, $record.UninstallString).ToLowerInvariant()
        if (-not $unique.ContainsKey($key)) { $unique[$key] = $record }
    }
    $values = @($unique.GetEnumerator() | ForEach-Object { $_.Value })
    return @($values | Sort-Object -Property Name, Version)
}

function ConvertFrom-GenesisUninstallCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command)
    $text = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Commande de désinstallation vide.' }
    $filePath = $null; $arguments = ''
    if ($text -match '^\s*"(?<file>[^"]+)"\s*(?<args>.*)$') {
        $filePath = $Matches['file']; $arguments = $Matches['args']
    }
    elseif ($text -match '^\s*(?<file>\S+)\s*(?<args>.*)$') {
        $filePath = $Matches['file']; $arguments = $Matches['args']
    }
    if ([string]::IsNullOrWhiteSpace($filePath)) { throw 'Exécutable de désinstallation introuvable.' }
    $leaf = [IO.Path]::GetFileName($filePath)
    if ($leaf -match '(?i)^msiexec(?:\.exe)?$') {
        if ($arguments -match '(?i)(^|\s)/i') { $arguments = $arguments -replace '(?i)(^|\s)/i', '$1/X' }
        if ($arguments -notmatch '(?i)(^|\s)/(x|uninstall)(?=\s|$)') { $arguments = '/X ' + $arguments.Trim() }
        if ($arguments -notmatch '(?i)(^|\s)/(q|quiet|qn)(?=\s|$)') { $arguments += ' /qn' }
        if ($arguments -notmatch '(?i)(^|\s)/norestart(?=\s|$)') { $arguments += ' /norestart' }
        $filePath = 'msiexec.exe'
    }
    [pscustomobject]@{ FilePath = $filePath; Arguments = $arguments.Trim(); WorkingDirectory = (Split-Path -Parent $filePath); Command = $text }
}

function Invoke-GenesisProgramUninstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Program)
    $command = if ($Program.PSObject.Properties.Name -contains 'QuietUninstallString' -and -not [string]::IsNullOrWhiteSpace([string]$Program.QuietUninstallString)) { [string]$Program.QuietUninstallString } else { [string]$Program.UninstallString }
    if ([string]::IsNullOrWhiteSpace($command)) { return [pscustomobject]@{ Status = 'NeedsAttention'; Program = $Program.Name; Message = 'Aucune commande de désinstallation disponible.' } }
    $parsed = ConvertFrom-GenesisUninstallCommand -Command $command
    $result = Invoke-GenesisNativeCommand -FilePath $parsed.FilePath -Arguments $parsed.Arguments -WorkingDirectory $parsed.WorkingDirectory -TimeoutSeconds 1800
    $accepted = @(0, 1605, 1614, 1641, 3010) -contains [int]$result.ExitCode
    $remaining = if ($Program.PSObject.Properties.Name -contains 'RegistryPath') { @(Get-GenesisInstalledProgram | Where-Object { $_.RegistryPath -eq $Program.RegistryPath }).Count -gt 0 } else { $false }
    if (-not $accepted) { return [pscustomobject]@{ Status = 'NeedsAttention'; Program = $Program.Name; Message = "Désinstallation terminée avec le code $($result.ExitCode)." } }
    if ($remaining) { return [pscustomobject]@{ Status = 'NeedsAttention'; Program = $Program.Name; Message = 'La clé de désinstallation est encore présente ; vérifier avec le fournisseur.' } }
    [pscustomobject]@{ Status = 'Completed'; Program = $Program.Name; Message = 'Programme désinstallé et vérifié.' }
}

function Get-GenesisExecutablePath {
    param([Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) { return (Get-Item -LiteralPath $candidate).FullName }
    }
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { return $command.Source }
    }
    return $null
}

function Get-GenesisBrowserPath {
    param([ValidateSet('Chrome', 'Firefox')][string]$Browser)
    switch ($Browser) {
        'Chrome' {
            return Get-GenesisExecutablePath -Names @('chrome.exe') -Candidates @(
                (Join-Path ${env:ProgramFiles} 'Google\Chrome\Application\chrome.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
            )
        }
        'Firefox' {
            return Get-GenesisExecutablePath -Names @('firefox.exe') -Candidates @(
                (Join-Path ${env:ProgramFiles} 'Mozilla Firefox\firefox.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe'),
                (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
            )
        }
    }
}

function Get-GenesisDefaultAssociation {
    param([Parameter(Mandatory)][ValidateSet('http', 'https', 'pdf')][string]$Protocol)
    if ($env:OS -ne 'Windows_NT') { return $null }
    $path = if ($Protocol -eq 'pdf') { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.pdf\UserChoice' } else { "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$Protocol\UserChoice" }
    try { return [string](Get-ItemProperty -LiteralPath $path -Name ProgId -ErrorAction Stop).ProgId }
    catch { return $null }
}

function Open-GenesisDefaultAppSetting {
    try { Start-Process -FilePath 'ms-settings:defaultapps' -ErrorAction Stop | Out-Null; return $true }
    catch { return $false }
}

function Set-GenesisDefaultApplication {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string]$Arguments = '',
        [Parameter(Mandatory)][string]$ExpectedProgIdPattern,
        [Parameter(Mandatory)][string]$Label,
        [ValidateSet('http', 'pdf')][string]$Protocol = 'http'
    )
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        try { Invoke-GenesisNativeCommand -FilePath $Executable -Arguments $Arguments -TimeoutSeconds 45 | Out-Null } catch { Write-Verbose "Association $Label non appliquée automatiquement : $($_.Exception.Message)" }
    }
    $association = Get-GenesisDefaultAssociation -Protocol $Protocol
    if ($association -match $ExpectedProgIdPattern) {
        return [pscustomobject]@{ Status = 'Completed'; Message = "$Label est défini par Windows." }
    }
    [void](Open-GenesisDefaultAppSetting)
    [pscustomobject]@{ Status = 'NeedsAttention'; Message = "Windows protège le choix par défaut : sélectionner $Label dans Paramètres > Applications > Applications par défaut, puis reprendre." }
}

function Read-GenesisSoftwareChoice {
    param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][hashtable]$Choices)
    Complete-GenesisConsoleProgressLine
    try { $value = (Read-Host $Prompt).Trim() } catch { return $null }
    if ($Choices.ContainsKey($value)) { return $Choices[$value] }
    return $null
}

function Get-GenesisOfficeInstallationStatus {
    return @((Get-GenesisOfficeApp))
}

function Get-GenesisOfficeDeploymentToolUri {
    $page = Invoke-WebRequest -Uri $script:GenesisOfficeDeploymentToolPage -UseBasicParsing -ErrorAction Stop
    foreach ($link in @($page.Links)) {
        # Certaines balises <a> de la page n'ont pas de href : le mode strict refuse de lire une propriété absente.
        if ($null -eq $link -or $link.PSObject.Properties.Name -notcontains 'href') { continue }
        $uri = $null
        if ([uri]::TryCreate([string]$link.href, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -eq 'https' -and $uri.Host -eq 'download.microsoft.com' -and
            [string]::IsNullOrWhiteSpace($uri.UserInfo) -and
            $uri.AbsolutePath -match '/officedeploymenttool[^/]*\.exe$') {
            return $uri.AbsoluteUri
        }
    }
    throw 'Téléchargement officiel de l''Office Deployment Tool Microsoft introuvable.'
}

function Assert-GenesisPublisherSignature {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Publisher)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch ('(?:^|,\s*)O=' + [regex]::Escape($Publisher) + '(?:,|$)')) {
        throw "L'installateur $([IO.Path]::GetFileName($Path)) ne possède pas une signature $Publisher valide ; programme non exécuté."
    }
}

function Assert-GenesisMicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)
    try { Assert-GenesisPublisherSignature -Path $Path -Publisher 'Microsoft Corporation' }
    catch { throw 'L''exécutable Office ne possède pas une signature Microsoft valide.' }
}

function Install-GenesisOffice2024 {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $existing = @(Get-GenesisOfficeInstallationStatus)
    if ($existing.Count -eq 4) { return [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Office Word, Excel, PowerPoint et Outlook classique est déjà installé.' } }
    $softwareDirectory = Get-GenesisSoftwareDirectory -RunDirectory $RunDirectory
    $toolPath = Join-Path $softwareDirectory 'officedeploymenttool.exe'
    $download = Save-GenesisDownload -Uri ([uri](Get-GenesisOfficeDeploymentToolUri)) -Path $toolPath
    Assert-GenesisMicrosoftSignature -Path $download.Path
    $toolDirectory = Join-Path $softwareDirectory 'odt'
    New-Item -Path $toolDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'office-2024' -Percent 25 -Message 'Outil Microsoft téléchargé et signature vérifiée'
    $extract = Invoke-GenesisNativeCommand -FilePath $download.Path -Arguments ('/quiet /extract:"{0}"' -f $toolDirectory) -TimeoutSeconds 300
    if ($extract.ExitCode -ne 0) { throw "Extraction ODT impossible (code $($extract.ExitCode))." }
    $setupPath = Join-Path $toolDirectory 'setup.exe'
    Assert-GenesisMicrosoftSignature -Path $setupPath
    $edition = if ([Environment]::Is64BitOperatingSystem) { '64' } else { '32' }
    $configuration = @"
<Configuration>
  <Add OfficeClientEdition="$edition" Channel="PerpetualVL2024">
    <Product ID="Standard2024Volume"><Language ID="fr-fr" /></Product>
  </Add>
  <Display Level="Full" AcceptEULA="FALSE" />
</Configuration>
"@
    $configurationPath = Join-Path $softwareDirectory 'office-2024.xml'
    [IO.File]::WriteAllText($configurationPath, $configuration, (New-Object Text.UTF8Encoding($false)))
    $statePath = Join-Path $RunDirectory 'software-office.json'
    Write-GenesisJson -Path $statePath -Value ([pscustomobject]@{ SchemaVersion = 1; Source = 'Microsoft ODT'; Sha256 = $download.Sha256; Installed = $false })
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'office-2024' -Percent 45 -Message 'Installation Office depuis Microsoft ; suivre les indications du programme'
    $result = Invoke-GenesisNativeCommand -FilePath $setupPath -Arguments ('/configure "{0}"' -f $configurationPath) -WorkingDirectory $toolDirectory -TimeoutSeconds 7200
    if ($result.ExitCode -notin @(0, 3010, 1641)) { throw "Installation Office impossible (code $($result.ExitCode))." }
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'office-2024' -Percent 85 -Message 'Installation terminée ; vérification des exécutables Office'
    $installed = @(Get-GenesisOfficeInstallationStatus)
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $state.Installed = ($installed.Count -eq 4); Write-GenesisJson -Path $statePath -Value $state
    if ($installed.Count -ne 4) { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 85; Message = 'ODT est terminé mais Word, Excel, PowerPoint et Outlook classique n''ont pas tous été détectés.' } }
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Office Standard 2024 LTSC installé et vérifié.' }
}

function Install-GenesisBrowser {
    param([Parameter(Mandatory)][string]$RunDirectory, [string]$Choice)
    $browser = if ($Choice -in @('Chrome', 'Firefox')) { $Choice } else {
        Read-GenesisSoftwareChoice -Prompt 'Navigateur [1] Chrome, [2] Firefox, [0] Ignorer' -Choices @{ '1' = 'Chrome'; '2' = 'Firefox'; '0' = 'Skip' }
    }
    if ($browser -eq 'Skip' -or $null -eq $browser) { return [pscustomobject]@{ Status = 'Skipped'; Percent = 0; Message = 'Aucun navigateur sélectionné.' } }
    $softwareDirectory = Get-GenesisSoftwareDirectory -RunDirectory $RunDirectory
    $uri = if ($browser -eq 'Chrome') { [uri]'https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi' } else { [uri]'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=fr' }
    $extension = if ($browser -eq 'Chrome') { '.msi' } else { '.exe' }
    $download = Save-GenesisDownload -Uri $uri -Path (Join-Path $softwareDirectory ("{0}-latest{1}" -f $browser.ToLowerInvariant(), $extension))
    $publisher = if ($browser -eq 'Chrome') { 'Google LLC' } else { 'Mozilla Corporation' }
    Assert-GenesisPublisherSignature -Path $download.Path -Publisher $publisher
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'browser' -Percent 30 -Message ("{0} téléchargé et signé par {1} ; SHA-256 {2}" -f $browser, $publisher, $download.Sha256)
    $result = if ($browser -eq 'Chrome') {
        Invoke-GenesisNativeCommand -FilePath 'msiexec.exe' -Arguments ('/i "{0}" /qn /norestart' -f $download.Path) -TimeoutSeconds 1800
    }
    else {
        Invoke-GenesisNativeCommand -FilePath $download.Path -Arguments '/S' -TimeoutSeconds 1800
    }
    if ($result.ExitCode -notin @(0, 3010, 1641)) { throw "Installation de $browser impossible (code $($result.ExitCode))." }
    $executable = Get-GenesisBrowserPath -Browser $browser
    if ([string]::IsNullOrWhiteSpace($executable)) { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 70; Message = "$browser installé sans exécutable détectable ; vérifier l''installation." } }
    $pattern = if ($browser -eq 'Chrome') { 'ChromeHTML|Chrome' } else { 'FirefoxURL|FirefoxHTML|Firefox' }
    $default = if ($browser -eq 'Chrome') { Set-GenesisDefaultApplication -Executable $executable -Arguments '--make-default-browser' -ExpectedProgIdPattern $pattern -Label 'Google Chrome' } else { Set-GenesisDefaultApplication -Executable $executable -Arguments '--setDefaultBrowser' -ExpectedProgIdPattern $pattern -Label 'Mozilla Firefox' }
    Write-GenesisJson -Path (Join-Path $RunDirectory 'software-browser.json') -Value ([pscustomobject]@{ SchemaVersion = 1; Browser = $browser; Path = $executable; Uri = $download.Uri; Sha256 = $download.Sha256; DefaultStatus = $default.Status })
    if ($default.Status -ne 'Completed') { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 90; Message = $default.Message } }
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = "$browser installé, vérifié et associé par défaut." }
}

function Get-GenesisPdfCraftAsset {
    [CmdletBinding()]
    param([string]$ChecksumDirectory)
    $release = Invoke-RestMethod -Uri $script:GenesisPdfCraftReleaseUri -Headers @{ 'User-Agent' = ('Genesis/' + $script:GenesisVersion) } -UseBasicParsing -ErrorAction Stop
    $asset = @($release.assets | Where-Object { $_.name -match '(?i)-windows-x64\.msi$' }) | Select-Object -First 1
    if ($null -eq $asset) { throw 'Aucun installateur PDFCraft Windows x64 dans la dernière release.' }
    $digest = [string]$asset.digest
    if ($digest -match '^sha256:(?<hash>.+)$') { $digest = $Matches['hash'] }
    if ([string]::IsNullOrWhiteSpace($digest) -and -not [string]::IsNullOrWhiteSpace($ChecksumDirectory)) {
        $checksumAsset = @($release.assets | Where-Object { $_.name -match '(?i)^SHA256SUMS\.txt$' }) | Select-Object -First 1
        if ($checksumAsset) {
            $checksumPath = Join-Path $ChecksumDirectory 'PDFCraft-SHA256SUMS.txt'
            Invoke-WebRequest -Uri ([string]$checksumAsset.browser_download_url) -OutFile $checksumPath -UseBasicParsing -Headers @{ 'User-Agent' = ('Genesis/' + $script:GenesisVersion) } -ErrorAction Stop
            $line = Get-Content -LiteralPath $checksumPath -ErrorAction Stop | Where-Object { $_ -match ('(?i)^(?<hash>[0-9a-f]{64})\s+\*?' + [regex]::Escape([string]$asset.name) + '\s*$') } | Select-Object -First 1
            if ($line -match '(?i)^(?<hash>[0-9a-f]{64})') { $digest = $Matches['hash'] }
        }
    }
    [pscustomobject]@{ Version = [string]$release.tag_name; Name = [string]$asset.name; Uri = [string]$asset.browser_download_url; Sha256 = $digest }
}

function Install-GenesisWingetPackage {
    param([Parameter(Mandatory)][string]$Id)
    if ($null -eq (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Status = 'NeedsAttention'; Message = 'winget.exe est indisponible ; installer le logiciel depuis sa source officielle.' } }
    $result = Invoke-GenesisNativeCommand -FilePath 'winget.exe' -Arguments ('install --id {0} --exact --silent --accept-package-agreements --accept-source-agreements' -f $Id) -TimeoutSeconds 1800
    # 0x8A150061 : paquet déjà installé ; 0x8A15002B : aucune mise à jour applicable.
    if ($result.ExitCode -in @(-1978335135, -1978335189)) { return [pscustomobject]@{ Status = 'Completed'; Message = "Paquet $Id déjà installé." } }
    if ($result.ExitCode -notin @(0, 3010, 1641)) { throw "winget a renvoyé le code $($result.ExitCode) pour $Id." }
    [pscustomobject]@{ Status = 'Completed'; Message = "Paquet $Id installé." }
}

function Get-GenesisPdfReaderPath {
    param([ValidateSet('Acrobat', 'SumatraPDF', 'PDFCraft')][string]$Reader)
    switch ($Reader) {
        # Le paquet 64 bits installe le lecteur unifié Acrobat.exe ; AcroRd32.exe reste l'ancien lecteur 32 bits.
        'Acrobat' { return Get-GenesisExecutablePath -Names @('Acrobat.exe', 'AcroRd32.exe') -Candidates @((Join-Path ${env:ProgramFiles} 'Adobe\Acrobat DC\Acrobat\Acrobat.exe'), (Join-Path ${env:ProgramFiles} 'Adobe\Acrobat Reader DC\Reader\AcroRd32.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Adobe\Acrobat Reader DC\Reader\AcroRd32.exe')) }
        'SumatraPDF' { return Get-GenesisExecutablePath -Names @('SumatraPDF.exe') -Candidates @((Join-Path ${env:ProgramFiles} 'SumatraPDF\SumatraPDF.exe'), (Join-Path ${env:ProgramFiles(x86)} 'SumatraPDF\SumatraPDF.exe'), (Join-Path $env:LOCALAPPDATA 'SumatraPDF\SumatraPDF.exe')) }
        'PDFCraft' {
            $known = Get-GenesisExecutablePath -Names @('pdfcraft.exe', 'PDFCraft.exe') -Candidates @((Join-Path ${env:ProgramFiles} 'PDFCraft\pdfcraft.exe'), (Join-Path ${env:ProgramFiles(x86)} 'PDFCraft\pdfcraft.exe'))
            if ($known) { return $known }
            foreach ($root in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
                if ($root -and (Test-Path -LiteralPath $root)) {
                    $found = Get-ChildItem -LiteralPath $root -Filter 'pdfcraft.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) { return $found.FullName }
                }
            }
            return $null
        }
    }
}

function Install-GenesisPdfReader {
    param([Parameter(Mandatory)][string]$RunDirectory, [string]$Choice)
    $reader = if ($Choice -in @('Acrobat', 'SumatraPDF', 'PDFCraft')) { $Choice } else {
        Read-GenesisSoftwareChoice -Prompt 'Lecteur PDF [1] Acrobat Reader, [2] SumatraPDF, [3] PDFCraft, [0] Ignorer' -Choices @{ '1' = 'Acrobat'; '2' = 'SumatraPDF'; '3' = 'PDFCraft'; '0' = 'Skip' }
    }
    if ($reader -eq 'Skip' -or $null -eq $reader) { return [pscustomobject]@{ Status = 'Skipped'; Percent = 0; Message = 'Aucun lecteur PDF sélectionné.' } }
    $softwareDirectory = Get-GenesisSoftwareDirectory -RunDirectory $RunDirectory
    $uri = $null; $sha256 = $null; $fileName = $null
    if ($reader -eq 'PDFCraft') {
        $asset = Get-GenesisPdfCraftAsset -ChecksumDirectory $softwareDirectory
        $uri = [uri]$asset.Uri; $sha256 = $asset.Sha256; $fileName = $asset.Name
        if ([string]::IsNullOrWhiteSpace($sha256)) { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 10; Message = 'PDFCraft a été trouvé mais sa release ne fournit pas d''empreinte SHA-256 exploitable.' } }
    }
    else {
        $package = if ($reader -eq 'Acrobat') { 'Adobe.Acrobat.Reader.64-bit' } else { 'SumatraPDF.SumatraPDF' }
        $wingetResult = Install-GenesisWingetPackage -Id $package
        if ($wingetResult.Status -ne 'Completed') { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 15; Message = $wingetResult.Message } }
    }
    if ($reader -eq 'PDFCraft') {
        $download = Save-GenesisDownload -Uri $uri -Path (Join-Path $softwareDirectory $fileName) -ExpectedSha256 $sha256
        Assert-GenesisPublisherSignature -Path $download.Path -Publisher 'Learning Machines Inc'
        $install = Invoke-GenesisNativeCommand -FilePath 'msiexec.exe' -Arguments ('/i "{0}" /qn /norestart INSTALLDESKTOPSHORTCUT=0' -f $download.Path) -TimeoutSeconds 1800
        if ($install.ExitCode -notin @(0, 3010, 1641)) { throw "Installation PDFCraft impossible (code $($install.ExitCode))." }
    }
    $executable = Get-GenesisPdfReaderPath -Reader $reader
    if ([string]::IsNullOrWhiteSpace($executable)) { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 75; Message = "$reader installé sans exécutable détectable ; vérifier l''installation." } }
    $pattern = switch ($reader) { 'Acrobat' { 'AcroExch|Acrobat' }; 'SumatraPDF' { 'SumatraPDF' }; 'PDFCraft' { 'PDFCraft|pdfcraft' } }
    $arguments = if ($reader -eq 'SumatraPDF') { '-register-for-pdf' } else { '' }
    $default = Set-GenesisDefaultApplication -Executable $executable -Arguments $arguments -ExpectedProgIdPattern $pattern -Label $reader -Protocol 'pdf'
    Write-GenesisJson -Path (Join-Path $RunDirectory 'software-pdf.json') -Value ([pscustomobject]@{ SchemaVersion = 1; Reader = $reader; Path = $executable; DefaultStatus = $default.Status })
    if ($default.Status -ne 'Completed') { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 90; Message = $default.Message } }
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = "$reader installé, vérifié et associé aux PDF." }
}

function ConvertTo-GenesisNetBirdManagementUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    $text = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Serveur NetBird non renseigné.' }
    if ($text -notmatch '^[a-z][a-z0-9+.-]*://') { $text = 'https://' + $text }
    $uri = $null
    if (-not [uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) { throw 'URL du serveur NetBird invalide.' }
    if ($uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrWhiteSpace($uri.Host)) { throw 'URL du serveur NetBird invalide.' }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw 'L''URL du serveur NetBird ne doit pas contenir d''identifiants, de requête ou de fragment.'
    }
    $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq 'https') { 443 } else { 80 }
    $hostName = if ($uri.HostNameType -eq [System.UriHostNameType]::IPv6) { '[' + $uri.Host + ']' } else { $uri.Host }
    $path = if ($uri.AbsolutePath -eq '/') { '' } else { $uri.AbsolutePath.TrimEnd('/') }
    return ('{0}://{1}:{2}{3}' -f $uri.Scheme, $hostName, $port, $path)
}

function Read-GenesisNetBirdManagementUrl {
    Complete-GenesisConsoleProgressLine
    try { $value = Read-Host 'Serveur NetBird (URL https://... ; laisser vide pour annuler)' }
    catch { return $null }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    try { return ConvertTo-GenesisNetBirdManagementUrl -Value $value }
    catch { return $null }
}

function Get-GenesisNetBirdPath {
    return Get-GenesisExecutablePath -Names @('netbird.exe') -Candidates @(
        (Join-Path ${env:ProgramFiles} 'NetBird\netbird.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'NetBird\netbird.exe')
    )
}

function Get-GenesisNetBirdManagementAuthority {
    param([Parameter(Mandatory)][uri]$Uri)
    $port = if ($Uri.Port -gt 0) { $Uri.Port } elseif ($Uri.Scheme -eq 'https') { 443 } else { 80 }
    $hostName = if ($Uri.HostNameType -eq [System.UriHostNameType]::IPv6) { '[' + $Uri.Host + ']' } else { $Uri.Host }
    return '{0}:{1}' -f $hostName, $port
}

function Set-GenesisNetBirdManagementServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManagementUrl,
        [string]$ConfigRoot
    )
    if ([string]::IsNullOrWhiteSpace($ConfigRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { throw 'ProgramData est indisponible pour configurer NetBird.' }
        $ConfigRoot = Join-Path $env:ProgramData 'NetBird'
    }
    New-Item -Path $ConfigRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $configPath = Join-Path $ConfigRoot 'default.json'
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $configPath) {
        try {
            $existing = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($property in $existing.PSObject.Properties) { $config[$property.Name] = $property.Value }
        }
        catch { throw "Configuration NetBird existante illisible : $configPath" }
    }
    $canonicalUrl = ConvertTo-GenesisNetBirdManagementUrl -Value $ManagementUrl
    $uri = [uri]$canonicalUrl
    $config['ManagementURL'] = [ordered]@{ Scheme = $uri.Scheme; Host = (Get-GenesisNetBirdManagementAuthority -Uri $uri) }
    Write-GenesisJson -Path $configPath -Value ([pscustomobject]$config)

    $policyPath = 'HKLM:\SOFTWARE\Policies\NetBird'
    Set-GenesisRegistryValue -Path $policyPath -Name 'ManagementURL' -Record ([pscustomobject]@{
        Exists = $true; KeyExists = $true; Kind = 'String'; Data = $canonicalUrl
    })
    [pscustomobject]@{
        Configured = $true
        DefaultConfigPath = $configPath
        PolicyPath = $policyPath
    }
}

function Test-GenesisNetBirdManagementConfigured {
    [CmdletBinding()]
    param()
    try {
        $policy = Get-GenesisRegistryValue -Path 'HKLM:\SOFTWARE\Policies\NetBird' -Name 'ManagementURL'
        if ($policy.Exists -and $policy.Kind -eq 'String' -and -not [string]::IsNullOrWhiteSpace([string]$policy.Data)) { return $true }
    }
    catch { Write-Verbose ('Lecture de la stratégie NetBird impossible : ' + $_.Exception.Message) }
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { return $false }
    $configPath = Join-Path (Join-Path $env:ProgramData 'NetBird') 'default.json'
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $management = $config.ManagementURL
        return ($null -ne $management -and -not [string]::IsNullOrWhiteSpace([string]$management.Scheme) -and -not [string]::IsNullOrWhiteSpace([string]$management.Host))
    }
    catch {
        return $false
    }
}

function Install-GenesisNetBird {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $managementUrl = Read-GenesisNetBirdManagementUrl
    if ([string]::IsNullOrWhiteSpace($managementUrl)) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'URL NetBird absente ou invalide ; aucun serveur configuré.' }
    }
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'netbird' -Percent 10 -Message 'Serveur NetBird enregistré ; téléchargement sans connexion'
    $configuration = Set-GenesisNetBirdManagementServer -ManagementUrl $managementUrl
    $softwareDirectory = Get-GenesisSoftwareDirectory -RunDirectory $RunDirectory
    $executable = Get-GenesisNetBirdPath
    $download = $null
    if ([string]::IsNullOrWhiteSpace($executable)) {
        $installerPath = Join-Path $softwareDirectory 'netbird-latest.msi'
        $download = Save-GenesisDownload -Uri ([uri]$script:GenesisNetBirdMsiUri) -Path $installerPath
        Assert-GenesisPublisherSignature -Path $download.Path -Publisher 'NetBird GmbH'
        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'netbird' -Percent 30 -Message 'Installateur NetBird téléchargé ; installation silencieuse'
        $install = Invoke-GenesisNativeCommand -FilePath 'msiexec.exe' -Arguments ('/i "{0}" /quiet /norestart' -f $download.Path) -TimeoutSeconds 1800
        if ($install.ExitCode -notin @(0, 3010, 1641)) { throw "Installation NetBird impossible (code $($install.ExitCode))." }
        $executable = Get-GenesisNetBirdPath
    }
    if ([string]::IsNullOrWhiteSpace($executable)) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 65; Message = 'NetBird est installé mais son exécutable est introuvable ; vérifier l''installation.' }
    }
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'netbird' -Percent 70 -Message 'NetBird installé ; serveur configuré sans connexion'
    $statePath = Join-Path $RunDirectory 'software-netbird.json'
    $state = [pscustomobject]@{
        SchemaVersion = 1; MachineId = Get-GenesisMachineId; UserSid = Get-GenesisUserSid
        Executable = $executable; InstallerSha256 = if ($download) { $download.Sha256 } else { $null }
        Installed = $true; Connected = $false; ManagementUrlConfigured = [bool]$configuration.Configured
        DefaultConfigPath = $configuration.DefaultConfigPath; PolicyPath = $configuration.PolicyPath
    }
    Write-GenesisJson -Path $statePath -Value $state
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'netbird' -Percent 100 -Message 'Serveur NetBird configuré ; aucune connexion lancée'
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'NetBird téléchargé et serveur configuré. Aucune connexion n''a été lancée.' }
}

function Get-GenesisPowerSchemeGuid {
    $result = Invoke-GenesisNativeCommand -FilePath 'powercfg.exe' -Arguments '/getactivescheme'
    if ($result.ExitCode -ne 0) { throw 'Lecture du schéma d''alimentation actif impossible.' }
    $match = [regex]::Match([string]$result.Output, '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
    if (-not $match.Success) { throw 'GUID du schéma d''alimentation introuvable.' }
    return $match.Groups[1].Value
}

function ConvertFrom-GenesisPowerQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Output)
    $patterns = @(
        '(?im)Current\s+AC\s+Power\s+Setting\s+Index\s*:\s*0x([0-9a-f]+)',
        '(?im)Index[^\r\n]*(?:AC|secteur)[^\r\n]*:\s*0x([0-9a-f]+)'
    )
    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Output, $pattern)
        if ($match.Success) { return [Convert]::ToInt64($match.Groups[1].Value, 16) }
    }
    throw 'Délai de mise en veille secteur introuvable dans la réponse powercfg.'
}

function Get-GenesisAcStandbyTime {
    param([Parameter(Mandatory)][string]$SchemeGuid)
    $result = Invoke-GenesisNativeCommand -FilePath 'powercfg.exe' -Arguments ("/query {0} SUB_SLEEP STANDBYIDLE" -f $SchemeGuid)
    if ($result.ExitCode -ne 0) { throw 'Lecture du délai de mise en veille secteur impossible.' }
    return ConvertFrom-GenesisPowerQuery -Output ([string]$result.Output)
}

function Set-GenesisPowerAc {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $path = Join-Path $RunDirectory 'power-ac.json'
    $activeScheme = Get-GenesisPowerSchemeGuid
    $snapshot = $null
    if (Test-Path -LiteralPath $path) {
        $snapshot = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-GenesisSnapshotOwner -Snapshot $snapshot
        if ($snapshot.SchemeGuid -cne $activeScheme) {
            return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Le schéma d''alimentation actif a changé depuis la sauvegarde.' }
        }
        $before = [int64]$snapshot.BeforeAcStandbySeconds
    }
    else {
        $before = Get-GenesisAcStandbyTime -SchemeGuid $activeScheme
        $snapshot = [pscustomobject]@{
            SchemaVersion = 1; MachineId = Get-GenesisMachineId; UserSid = Get-GenesisUserSid
            SchemeGuid = $activeScheme; BeforeAcStandbySeconds = $before; AfterAcStandbySeconds = $null; Restored = $false
        }
        Write-GenesisJson -Path $path -Value $snapshot
    }
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'power-ac' -Percent 35 -Message 'Sauvegarde du délai secteur enregistrée'
    $change = Invoke-GenesisNativeCommand -FilePath 'powercfg.exe' -Arguments '/change standby-timeout-ac 0'
    if ($change.ExitCode -ne 0) { throw 'Désactivation de la mise en veille secteur impossible.' }
    $after = Get-GenesisAcStandbyTime -SchemeGuid $activeScheme
    if ($after -ne 0) { throw 'Vérification de la mise en veille secteur impossible.' }
    $snapshot.AfterAcStandbySeconds = $after
    Write-GenesisJson -Path $path -Value $snapshot
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'power-ac' -Percent 100 -Message 'Mise en veille secteur réglée sur Jamais'
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Mise en veille sur secteur désactivée (Jamais). Reverse restaure le délai initial.' }
}

function ConvertTo-GenesisAccountName {
    param([Parameter(Mandatory)][string]$FirstName, [Parameter(Mandatory)][string]$LastName)
    $value = (($FirstName.Trim() + '.' + $LastName.Trim()).Normalize([Text.NormalizationForm]::FormD))
    $builder = New-Object Text.StringBuilder
    foreach ($character in $value.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }
    $name = $builder.ToString().ToLowerInvariant() -replace '[^a-z0-9._-]+', '.'
    $name = $name.Trim('.')
    if ($name.Length -gt 20) { $name = $name.Substring(0, 20).Trim('.') }
    if ($name -notmatch '^[a-z0-9][a-z0-9._-]{0,19}$') { throw 'Nom de compte local invalide.' }
    return $name
}

function Get-GenesisLocalUserRecord {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) { throw 'Le module LocalAccounts est indisponible dans cette session PowerShell.' }
    return Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
}

function New-GenesisLocalUserNative {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FullName,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [Parameter(Mandatory)][string]$Description
    )
    if (-not (Get-Command New-LocalUser -ErrorAction SilentlyContinue)) { throw 'Le module LocalAccounts est indisponible dans cette session PowerShell.' }
    return New-LocalUser -Name $Name -FullName $FullName -Password $Password -Description $Description -ErrorAction Stop
}

function Get-GenesisBuiltinUsersGroup {
    if (-not (Get-Command Get-LocalGroup -ErrorAction SilentlyContinue)) { throw 'Le module LocalAccounts est indisponible dans cette session PowerShell.' }
    $group = @(Get-LocalGroup -ErrorAction Stop | Where-Object {
        $sid = $_.SID
        $sidValue = if ($sid -and $sid.PSObject.Properties.Name -contains 'Value') { [string]$sid.Value } else { [string]$sid }
        $sidValue -eq 'S-1-5-32-545'
    } | Select-Object -First 1)
    if ($group.Count -eq 0) { throw 'Le groupe local standard Utilisateurs est introuvable.' }
    return $group[0]
}

function Set-GenesisLocalUserVisibility {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command Enable-LocalUser -ErrorAction SilentlyContinue)) { throw 'Le module LocalAccounts est indisponible dans cette session PowerShell.' }
    if (-not (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue) -or -not (Get-Command Add-LocalGroupMember -ErrorAction SilentlyContinue)) {
        throw 'Les commandes de groupes locaux sont indisponibles dans cette session PowerShell.'
    }
    $group = Get-GenesisBuiltinUsersGroup
    $switchPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserSwitch'
    $before = Get-GenesisRegistryValue -Path $switchPath -Name 'Enabled'
    $after = [pscustomobject]@{ Exists = $true; KeyExists = $true; Kind = 'DWord'; Data = 1 }
    $registryChanged = $false
    try {
        Enable-LocalUser -Name $Name -ErrorAction Stop
        $user = Get-GenesisLocalUserRecord -Name $Name
        if ($null -eq $user) { throw "La session '$Name' est introuvable après son activation." }
        $userSid = if ($user.SID -and $user.SID.PSObject.Properties.Name -contains 'Value') { [string]$user.SID.Value } else { [string]$user.SID }
        try { Add-LocalGroupMember -Group ([string]$group.Name) -Member $Name -ErrorAction Stop }
        catch {
            if ($_.Exception.Message -notmatch '(?i)(already\s+(a\s+)?member|déjà\s+membre|déjà.*groupe|existe\s+déjà)') { throw }
        }
        $members = @(Get-LocalGroupMember -Group ([string]$group.Name) -ErrorAction SilentlyContinue)
        $member = @($members | Where-Object {
            $sid = $_.SID
            $sidValue = if ($sid -and $sid.PSObject.Properties.Name -contains 'Value') { [string]$sid.Value } else { [string]$sid }
            $sidValue -eq $userSid
        } | Select-Object -First 1)
        if ($member.Count -eq 0) {
            throw "La session '$Name' n''a pas pu être ajoutée au groupe local Utilisateurs."
        }
        if (-not (Test-GenesisRegistryRecord -Left $before -Right $after)) {
            Set-GenesisRegistryValue -Path $switchPath -Name 'Enabled' -Record $after
            $registryChanged = $true
        }
        if (-not (Test-GenesisRegistryRecord -Left (Get-GenesisRegistryValue -Path $switchPath -Name 'Enabled') -Right $after)) {
            throw 'Vérification de l''affichage des comptes locaux impossible.'
        }
        [pscustomobject]@{
            UsersGroupName = [string]$group.Name
            UserSwitchBefore = $before
            UserSwitchAfter = $after
        }
    }
    catch {
        if ($registryChanged) {
            try { Set-GenesisRegistryValue -Path $switchPath -Name 'Enabled' -Record $before } catch { Write-Verbose 'Restauration UserSwitch impossible après échec.' }
        }
        throw
    }
}

function Restore-GenesisLocalUserVisibility {
    param([Parameter(Mandatory)]$Snapshot)
    $properties = @($Snapshot.PSObject.Properties.Name)
    if ('UserSwitchBefore' -notin $properties -or 'UserSwitchAfter' -notin $properties -or $null -eq $Snapshot.UserSwitchBefore -or $null -eq $Snapshot.UserSwitchAfter) {
        return [pscustomobject]@{ Status = 'Restored'; Message = 'Aucun réglage d''affichage local à restaurer.' }
    }
    $switchPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserSwitch'
    $current = Get-GenesisRegistryValue -Path $switchPath -Name 'Enabled'
    if (Test-GenesisRegistryRecord -Left $current -Right $Snapshot.UserSwitchBefore) {
        return [pscustomobject]@{ Status = 'Restored'; Message = 'Affichage des comptes locaux déjà revenu à sa valeur initiale.' }
    }
    if (-not (Test-GenesisRegistryRecord -Left $current -Right $Snapshot.UserSwitchAfter)) {
        return [pscustomobject]@{ Status = 'Conflict'; Message = 'Le réglage d''affichage des comptes locaux a changé depuis Genesis : restauration suspendue.' }
    }
    Set-GenesisRegistryValue -Path $switchPath -Name 'Enabled' -Record $Snapshot.UserSwitchBefore
    if (-not (Test-GenesisRegistryRecord -Left (Get-GenesisRegistryValue -Path $switchPath -Name 'Enabled') -Right $Snapshot.UserSwitchBefore)) { throw 'Vérification de la restauration de l''affichage des comptes locaux impossible.' }
    [pscustomobject]@{ Status = 'Restored'; Message = 'Affichage des comptes locaux restauré.' }
}

function Remove-GenesisLocalUserNative {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command Remove-LocalUser -ErrorAction SilentlyContinue)) { throw 'Le module LocalAccounts est indisponible dans cette session PowerShell.' }
    Remove-LocalUser -Name $Name -ErrorAction Stop
}

function New-GenesisLocalUser {
    param([Parameter(Mandatory)][string]$RunDirectory)
    try {
        Complete-GenesisConsoleProgressLine
        $lastName = (Read-Host 'Nom').Trim()
        Complete-GenesisConsoleProgressLine
        $firstName = (Read-Host 'Prénom').Trim()
    }
    catch { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Saisie du nom annulée.' } }
    if ([string]::IsNullOrWhiteSpace($lastName) -or [string]::IsNullOrWhiteSpace($firstName)) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Nom et prénom sont nécessaires pour créer la session.' }
    }
    try { $defaultName = ConvertTo-GenesisAccountName -FirstName $firstName -LastName $lastName }
    catch { $defaultName = 'user' }
    Complete-GenesisConsoleProgressLine
    try { $nameInput = Read-Host ("Identifiant Windows [{0}]" -f $defaultName) }
    catch { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Saisie de l''identifiant annulée.' } }
    $name = if ([string]::IsNullOrWhiteSpace($nameInput)) { $defaultName } else { $nameInput.Trim().ToLowerInvariant() }
    if ($name -notmatch '^[a-z0-9][a-z0-9._-]{0,19}$') {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Identifiant invalide : 1 à 20 caractères alphanumériques, point, tiret ou souligné.' }
    }
    if ($name -ieq 'admin' -or $name -ieq [Environment]::UserName) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = "L'identifiant '$name' est protégé par Genesis ; la session d'administration en cours ne sera pas modifiée." }
    }
    try { $existing = Get-GenesisLocalUserRecord -Name $name }
    catch { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = $_.Exception.Message } }
    if ($null -ne $existing) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = "La session '$name' existe déjà ; aucune modification effectuée." }
    }
    $fullName = "$firstName $lastName"
    Complete-GenesisConsoleProgressLine
    try { $confirm = Read-Host ("Créer la session locale '{0}' ({1}) ? [O/N]" -f $name, $fullName) }
    catch { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Confirmation de création annulée.' } }
    if ($confirm -notmatch '^[OoYy]$') {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Création de la session annulée par le technicien.' }
    }
    Complete-GenesisConsoleProgressLine
    try { $password = Read-Host 'Mot de passe de la session (saisie locale, jamais journalisée)' -AsSecureString }
    catch { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Saisie du mot de passe annulée.' } }
    if ($null -eq $password -or $password.Length -eq 0) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Un mot de passe non vide est nécessaire.' }
    }
    try {
        $created = New-GenesisLocalUserNative -Name $name -FullName $fullName -Password $password -Description 'Session créée par Genesis'
    }
    catch {
        $nativeMessage = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($nativeMessage)) { $nativeMessage = $_.Exception.GetType().Name }
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = "Création de la session '$name' impossible : $nativeMessage" }
    }
    if ($null -eq $created) {
        try { $created = Get-GenesisLocalUserRecord -Name $name }
        catch {
            $nativeMessage = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($nativeMessage)) { $nativeMessage = $_.Exception.GetType().Name }
            return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = "Session '$name' créée mais sa vérification est impossible : $nativeMessage" }
        }
    }
    if ($null -eq $created) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = "Session '$name' créée mais sa vérification est impossible." }
    }
    $createdSid = if ($created.SID -and $created.SID.PSObject.Properties.Name -contains 'Value') { [string]$created.SID.Value } else { [string]$created.SID }
    if ([string]::IsNullOrWhiteSpace($createdSid)) { throw 'SID du compte local introuvable après création.' }
    try { $visibility = Set-GenesisLocalUserVisibility -Name $name }
    catch {
        $nativeMessage = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($nativeMessage)) { $nativeMessage = $_.Exception.GetType().Name }
        try { Remove-GenesisLocalUserNative -Name $name } catch { Write-Verbose 'Rollback de la session locale impossible après échec de visibilité.' }
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = "Session '$name' créée mais préparation de l'affichage impossible : $nativeMessage" }
    }
    try {
        Write-GenesisJson -Path (Join-Path $RunDirectory 'local-user.json') -Value ([pscustomobject]@{
            SchemaVersion = 1; MachineId = Get-GenesisMachineId; UserSid = Get-GenesisUserSid
            UserName = $name; FullName = $fullName; CreatedSid = $createdSid; CreatedAt = [datetime]::UtcNow.ToString('o'); Removed = $false
            UsersGroupName = $visibility.UsersGroupName; UserSwitchBefore = $visibility.UserSwitchBefore; UserSwitchAfter = $visibility.UserSwitchAfter
        })
    }
    catch {
        try { Remove-GenesisLocalUserNative -Name $name } catch { Write-Verbose 'Rollback de la session locale impossible.' }
        try { Restore-GenesisLocalUserVisibility -Snapshot $visibility | Out-Null } catch { Write-Verbose 'Rollback du réglage UserSwitch impossible.' }
        throw
    }
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = "Session locale '$name' créée. Le mot de passe n'est pas conservé par Genesis." }
}

function Undo-GenesisPowerAc {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $path = Join-Path $RunDirectory 'power-ac.json'
    $snapshot = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-GenesisSnapshotOwner -Snapshot $snapshot
    $current = Get-GenesisAcStandbyTime -SchemeGuid ([string]$snapshot.SchemeGuid)
    $before = [int64]$snapshot.BeforeAcStandbySeconds
    if ($current -eq $before) { return [pscustomobject]@{ Status = 'Restored'; Message = 'Délai secteur déjà revenu à sa valeur d''origine.' } }
    if ($null -ne $snapshot.AfterAcStandbySeconds -and $current -ne [int64]$snapshot.AfterAcStandbySeconds) {
        return [pscustomobject]@{ Status = 'Conflict'; Message = 'Le délai secteur a été modifié depuis Genesis : restauration suspendue.' }
    }
    $restore = Invoke-GenesisNativeCommand -FilePath 'powercfg.exe' -Arguments ("/setacvalueindex {0} SUB_SLEEP STANDBYIDLE {1}" -f $snapshot.SchemeGuid, $before)
    if ($restore.ExitCode -ne 0 -or (Get-GenesisAcStandbyTime -SchemeGuid ([string]$snapshot.SchemeGuid)) -ne $before) { throw 'Vérification de la restauration du délai secteur impossible.' }
    $snapshot.Restored = $true
    Write-GenesisJson -Path $path -Value $snapshot
    [pscustomobject]@{ Status = 'Restored'; Message = 'Délai de mise en veille secteur restauré.' }
}

function Undo-GenesisLocalUser {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $path = Join-Path $RunDirectory 'local-user.json'
    $snapshot = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-GenesisSnapshotOwner -Snapshot $snapshot
    if ([string]$snapshot.UserName -ieq 'admin' -or [string]$snapshot.UserName -ieq [Environment]::UserName) {
        return [pscustomobject]@{ Status = 'Conflict'; Message = "La session '$($snapshot.UserName)' est protégée ; Genesis ne peut pas la supprimer." }
    }
    $current = Get-GenesisLocalUserRecord -Name ([string]$snapshot.UserName)
    if ($null -eq $current) {
        $visibility = Restore-GenesisLocalUserVisibility -Snapshot $snapshot
        if ($visibility.Status -eq 'Conflict') { return $visibility }
        $snapshot.Removed = $true
        Write-GenesisJson -Path $path -Value $snapshot
        return [pscustomobject]@{ Status = 'Restored'; Message = 'La session créée par Genesis est déjà absente ; affichage des comptes locaux restauré.' }
    }
    $currentSid = if ($current.SID -and $current.SID.PSObject.Properties.Name -contains 'Value') { [string]$current.SID.Value } else { [string]$current.SID }
    if ($currentSid -cne [string]$snapshot.CreatedSid) {
        return [pscustomobject]@{ Status = 'Conflict'; Message = 'Le SID du compte ne correspond plus à celui créé par Genesis.' }
    }
    $visibility = Restore-GenesisLocalUserVisibility -Snapshot $snapshot
    if ($visibility.Status -eq 'Conflict') { return $visibility }
    Remove-GenesisLocalUserNative -Name ([string]$snapshot.UserName)
    if ($null -ne (Get-GenesisLocalUserRecord -Name ([string]$snapshot.UserName))) { throw 'Vérification de la suppression de la session impossible.' }
    $snapshot.Removed = $true
    Write-GenesisJson -Path $path -Value $snapshot
    [pscustomobject]@{ Status = 'Restored'; Message = "Session locale '$($snapshot.UserName)' supprimée après vérification du SID." }
}

function Set-GenesisWindowsTime {
    param([string]$RunDirectory)
    $path = Join-Path $RunDirectory 'time-service.json'
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='W32Time'" -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $path)) {
        Write-GenesisJson -Path $path -Value ([pscustomobject]@{
            SchemaVersion = 1; MachineId = Get-GenesisMachineId; UserSid = Get-GenesisUserSid
            StartMode = $service.StartMode; Running = ((Get-Service W32Time).Status -eq 'Running')
            ClockBeforeUtc = [datetime]::UtcNow.ToString('o'); ClockReversible = $false
        })
    }
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $changes = @([pscustomobject]@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'; Name = 'Enabled'; Kind = 'DWord'; Data = 1 })
    if (-not $computer.PartOfDomain) {
        $changes += [pscustomobject]@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'; Name = 'Type'; Kind = 'String'; Data = 'NTP' }
    }
    Invoke-GenesisRegistryTransaction -Changes $changes -SnapshotPath (Join-Path $RunDirectory 'time-sync.registry.json')
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'time-sync' -Percent 30 -Message 'Sauvegarde enregistrée ; activation du service horaire'
    Set-Service -Name W32Time -StartupType Automatic -ErrorAction Stop
    Start-Service -Name W32Time -ErrorAction Stop
    $config = Invoke-GenesisNativeCommand -FilePath 'w32tm.exe' -Arguments '/config /update'
    if ($config.ExitCode -ne 0) { throw 'Actualisation du service horaire impossible.' }
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'time-sync' -Percent 50 -Message 'Synchronisation Windows en cours'
    $sync = Invoke-GenesisNativeCommand -FilePath 'w32tm.exe' -Arguments '/resync /rediscover'
    if ($computer.PartOfDomain) {
        if ($sync.ExitCode -ne 0) { throw 'Synchronisation par le domaine impossible.' }
        $peer = (Invoke-GenesisNativeCommand -FilePath 'w32tm.exe' -Arguments '/query /source').Output.Trim()
    }
    else {
        $peer = ((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters').NtpServer -split '\s+')[0]
        if ([string]::IsNullOrWhiteSpace($peer)) { throw 'Aucun serveur horaire configuré.' }
    }
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'time-sync' -Percent 75 -Message 'Vérification indépendante de la référence NTP'
    $reference = Get-GenesisNetworkTime -Server $peer
    $referenceTimer = [Diagnostics.Stopwatch]::StartNew()
    $difference = [math]::Abs(([datetime]::UtcNow - $reference).TotalSeconds)
    if ($difference -gt 5 -and -not $computer.PartOfDomain) { Set-Date -Date $reference.ToLocalTime() -ErrorAction Stop | Out-Null }
    $reference = $reference.AddMilliseconds($referenceTimer.Elapsed.TotalMilliseconds)
    if ([math]::Abs(([datetime]::UtcNow - $reference).TotalSeconds) -gt 5) { throw 'Lheure reste décalée par rapport à la référence NTP.' }
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Heure vérifiée par NTP. Reverse restaure le service, sans rétablir une heure erronée.' }
}

# --- Capture FOG -------------------------------------------------------------
# FOG ne capture pas un Windows en marche : Genesis nettoie et généralise le poste,
# programme la capture par l'API FOG puis redémarre une seule fois sur le réseau (PXE).
$script:GenesisFogSettingsFileName = 'fog-capture.protected'
$script:GenesisFogCaptureTaskTypeId = 2
$script:GenesisFogRestartDelaySeconds = 15
$script:GenesisFogDecryptTimeoutMinutes = 720

function ConvertTo-GenesisFogServerUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $text = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Serveur FOG non renseigné.' }
    if ($text -notmatch '^[a-z][a-z0-9+.-]*://') { $text = 'http://' + $text }
    $uri = $null
    if (-not [uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) { throw 'Adresse du serveur FOG invalide.' }
    if ($uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrWhiteSpace($uri.Host)) { throw 'Adresse du serveur FOG invalide.' }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw 'L''adresse du serveur FOG ne doit pas contenir d''identifiants, de requête ou de fragment.'
    }
    # L'API est servie sous /fog/... : on accepte aussi l'adresse de l'interface web.
    $path = $uri.AbsolutePath.TrimEnd('/')
    if ($path -match '(?i)^(.*?)/fog(?:/.*)?$') { $path = $Matches[1] }
    $hostName = if ($uri.HostNameType -eq [System.UriHostNameType]::IPv6) { '[' + $uri.Host + ']' } else { $uri.Host }
    $port = if ($uri.IsDefaultPort) { '' } else { ':' + $uri.Port }
    return ('{0}://{1}{2}{3}' -f $uri.Scheme, $hostName, $port, $path)
}

function ConvertTo-GenesisFogMac {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $hex = ($Value -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
    if ($hex.Length -ne 12) { throw 'Adresse MAC invalide.' }
    return (($hex -split '(..)' | Where-Object { $_ }) -join ':')
}

function ConvertFrom-GenesisSecureInput {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [securestring]) { return [System.Net.NetworkCredential]::new('', $Value).Password }
    return [string]$Value
}

function Protect-GenesisSecretText {
    param([Parameter(Mandatory)][string]$Text)
    if ($env:OS -ne 'Windows_NT') { throw 'La protection des clés FOG nécessite Windows.' }
    Add-Type -AssemblyName System.Security
    # Portée machine : la reprise après redémarrage tourne sous SYSTEM.
    $bytes = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Text), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($bytes)
}

function Unprotect-GenesisSecretText {
    param([Parameter(Mandatory)][string]$Text)
    if ($env:OS -ne 'Windows_NT') { throw 'La lecture des clés FOG nécessite Windows.' }
    Add-Type -AssemblyName System.Security
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Text), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Assert-GenesisFogConfiguration {
    param([Parameter(Mandatory)]$Settings)
    foreach ($name in @('Server', 'ApiToken', 'UserToken', 'ImageName')) {
        if (@($Settings.PSObject.Properties.Name) -notcontains $name -or [string]::IsNullOrWhiteSpace([string]$Settings.$name)) {
            throw "Paramètre FOG manquant : $name."
        }
    }
    foreach ($name in @('ApiToken', 'UserToken')) {
        if ([string]$Settings.$name -notmatch '^\S{8,1024}$') { throw 'Clé d''API FOG invalide.' }
    }
    return [pscustomobject]@{
        Server = ConvertTo-GenesisFogServerUrl -Value ([string]$Settings.Server)
        ApiToken = [string]$Settings.ApiToken
        UserToken = [string]$Settings.UserToken
        ImageName = ([string]$Settings.ImageName).Trim()
    }
}

function Save-GenesisFogConfiguration {
    param([Parameter(Mandatory)][string]$RunDirectory, [Parameter(Mandatory)]$Settings)
    $clean = Assert-GenesisFogConfiguration -Settings $Settings
    $protected = Protect-GenesisSecretText -Text ($clean | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText((Join-Path $RunDirectory $script:GenesisFogSettingsFileName), $protected, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-GenesisFogConfigurationFile {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $path = Join-Path $RunDirectory $script:GenesisFogSettingsFileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $json = Unprotect-GenesisSecretText -Text ([System.IO.File]::ReadAllText($path).Trim())
    return Assert-GenesisFogConfiguration -Settings ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Remove-GenesisFogConfigurationFile {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $path = Join-Path $RunDirectory $script:GenesisFogSettingsFileName
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
}

function Invoke-GenesisFogApi {
    param(
        [Parameter(Mandatory)]$Settings,
        [ValidateSet('GET', 'POST', 'PUT')][string]$Method = 'GET',
        [Parameter(Mandatory)][ValidatePattern('^/fog/[a-z0-9/]+$')][string]$Path,
        [object]$Body
    )
    $request = @{
        Uri = $Settings.Server + $Path
        Method = $Method
        Headers = @{ 'fog-api-token' = $Settings.ApiToken; 'fog-user-token' = $Settings.UserToken }
        TimeoutSec = 30
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Depth 6 -Compress
        $request.ContentType = 'application/json'
    }
    try { $response = Invoke-RestMethod @request }
    catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
        if ($status -in @(401, 403)) {
            throw 'FOG refuse les clés d''API : vérifier la clé FOG, la clé utilisateur et que l''API est activée dans FOG.'
        }
        $reason = ([string]$_.Exception.Message -replace '[\r\n\t]+', ' ').Trim()
        throw ('Réponse FOG refusée ou serveur injoignable ({0} {1}) : {2}' -f $Method, $Path, $reason)
    }
    # API désactivée ou clés inconnues : FOG redirige vers sa page de connexion au lieu de répondre en JSON.
    if ($response -is [string] -and $response -match '(?i)<html|<!doctype') {
        throw 'FOG répond par sa page web au lieu de l''API : cocher FOG_API_ENABLED (FOG Configuration > FOG Settings > API System) et « API Enabled » de l''utilisateur (User Management > API Settings), enregistrer, puis vérifier les deux clés.'
    }
    return $response
}

function Get-GenesisFogItem {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][ValidateSet('host', 'image', 'macaddressassociation')][string]$Kind)
    $response = Invoke-GenesisFogApi -Settings $Settings -Path ('/fog/' + $Kind)
    $property = $Kind + 's'
    if ($null -eq $response -or @($response.PSObject.Properties.Name) -notcontains $property) {
        throw "Réponse inattendue de l'API FOG pour /fog/$Kind."
    }
    return @($response.$property | Where-Object { $null -ne $_ })
}

function Get-GenesisFogImage {
    param([Parameter(Mandatory)]$Settings)
    $images = @(Get-GenesisFogItem -Settings $Settings -Kind 'image' | Where-Object { [string]$_.name -eq $Settings.ImageName })
    if ($images.Count -eq 0) {
        throw ('Image FOG « {0} » introuvable : la créer dans FOG (Image Management) avant la capture.' -f $Settings.ImageName)
    }
    if ($images.Count -gt 1) { throw ('Plusieurs images FOG portent le nom « {0} ».' -f $Settings.ImageName) }
    return $images[0]
}

function Register-GenesisFogHost {
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][string]$Mac,
        [Parameter(Mandatory)][int]$ImageId,
        [AllowEmptyString()][string]$Name = ''
    )
    $wanted = ConvertTo-GenesisFogMac -Value $Mac
    $hostId = $null
    foreach ($association in @(Get-GenesisFogItem -Settings $Settings -Kind 'macaddressassociation')) {
        try { $known = ConvertTo-GenesisFogMac -Value ([string]$association.mac) } catch { continue }
        if ($known -eq $wanted) { $hostId = [int]$association.hostID; break }
    }
    $hosts = @(Get-GenesisFogItem -Settings $Settings -Kind 'host')
    if ($null -eq $hostId) {
        foreach ($fogHost in $hosts) {
            if (@($fogHost.PSObject.Properties.Name) -notcontains 'primac') { continue }
            try { $known = ConvertTo-GenesisFogMac -Value ([string]$fogHost.primac) } catch { continue }
            if ($known -eq $wanted) { $hostId = [int]$fogHost.id; break }
        }
    }
    if ($null -ne $hostId) {
        $existing = $hosts | Where-Object { [int]$_.id -eq $hostId } | Select-Object -First 1
        if ($null -eq $existing -or [int]$existing.imageID -ne $ImageId) {
            Invoke-GenesisFogApi -Settings $Settings -Method PUT -Path "/fog/host/$hostId/edit" -Body @{ imageID = $ImageId } | Out-Null
        }
        return [pscustomobject]@{ Id = $hostId; Created = $false }
    }
    # Nom d'hôte FOG : 15 caractères au plus et unique sur le serveur.
    $hostName = ($Name -replace '[^A-Za-z0-9-]', '')
    if ($hostName.Length -gt 15) { $hostName = $hostName.Substring(0, 15) }
    if ([string]::IsNullOrWhiteSpace($hostName) -or @($hosts | Where-Object { [string]$_.name -eq $hostName }).Count -gt 0) {
        $hostName = 'G' + ($wanted -replace ':', '').ToUpperInvariant()
    }
    $created = Invoke-GenesisFogApi -Settings $Settings -Method POST -Path '/fog/host/create' -Body @{ name = $hostName; macs = @($wanted); imageID = $ImageId }
    if ($null -eq $created -or @($created.PSObject.Properties.Name) -notcontains 'id' -or [int]$created.id -le 0) {
        throw 'FOG n''a pas confirmé l''enregistrement du poste.'
    }
    return [pscustomobject]@{ Id = [int]$created.id; Created = $true }
}

function New-GenesisFogCaptureTask {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][int]$HostId)
    $body = @{ taskTypeID = $script:GenesisFogCaptureTaskTypeId; shutdown = $false; wol = $false }
    Invoke-GenesisFogApi -Settings $Settings -Method POST -Path "/fog/host/$HostId/task" -Body $body | Out-Null
}

function Read-GenesisFogConfiguration {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Questions console du technicien avant la préparation.')]
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host 'Capture FOG : en fin de préparation, Windows sera généralisé (Sysprep) puis le poste' -ForegroundColor Yellow
    Write-Host 'redémarrera sur le réseau pour envoyer son image au serveur FOG. Il ne sera plus' -ForegroundColor Yellow
    Write-Host 'utilisable tel quel : au démarrage suivant, Windows repartira sur l''installation (OOBE).' -ForegroundColor Yellow
    Write-Host 'Prérequis FOG : API activée, image déjà créée (Image Management), démarrage PXE fonctionnel.' -ForegroundColor DarkGray
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $server = Read-Host 'Serveur FOG (adresse IP ou URL ; laisser vide pour retirer la capture)'
        if ([string]::IsNullOrWhiteSpace($server)) { return $null }
        try { $server = ConvertTo-GenesisFogServerUrl -Value $server }
        catch { Write-Host $_.Exception.Message -ForegroundColor Red; continue }
        $apiToken = ConvertFrom-GenesisSecureInput (Read-Host 'Clé API FOG (FOG Configuration > FOG Settings > API System)' -AsSecureString)
        $userToken = ConvertFrom-GenesisSecureInput (Read-Host 'Clé API de l''utilisateur FOG (User Management > API Settings)' -AsSecureString)
        $imageName = Read-Host 'Nom de l''image FOG qui recevra la capture'
        try {
            $settings = Assert-GenesisFogConfiguration -Settings ([pscustomobject]@{ Server = $server; ApiToken = $apiToken; UserToken = $userToken; ImageName = $imageName })
            $image = Get-GenesisFogImage -Settings $settings
            Write-Host ('Serveur FOG joint ; image « {0} » trouvée (n° {1}).' -f $image.name, $image.id) -ForegroundColor Green
        }
        catch { Write-Host $_.Exception.Message -ForegroundColor Red; continue }
        $answer = Read-Host 'Généraliser et capturer ce poste en fin de préparation [O/N]'
        if ($answer -match '^(?i)o(ui)?$') { return $settings }
        return $null
    }
    Write-Host 'Paramètres FOG non validés après trois essais.' -ForegroundColor Red
    return $null
}

function Get-GenesisDefaultRouteAdapter {
    # Carte qui porte la passerelle IPv4 : c'est par elle que le poste joint FOG.
    $configuration = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_.IPv4DefaultGateway -and $null -ne $_.NetAdapter -and [string]$_.NetAdapter.Status -eq 'Up' } |
        Sort-Object { [int]$_.NetIPv4Interface.InterfaceMetric } | Select-Object -First 1
    if ($null -eq $configuration) { return $null }
    return $configuration.NetAdapter
}

function Get-GenesisFogNetworkAdapter {
    $adapter = Get-GenesisDefaultRouteAdapter
    if ($null -eq $adapter) { throw 'Aucune connexion réseau active : brancher le poste au réseau du serveur FOG.' }
    if ([string]$adapter.PhysicalMediaType -match '(?i)802\.11|wireless|native 802' -or [string]$adapter.NdisPhysicalMedium -eq '9') {
        throw 'Le poste est connecté en Wi-Fi : la capture FOG exige un câble réseau.'
    }
    return [pscustomobject]@{ Name = [string]$adapter.Name; Mac = ConvertTo-GenesisFogMac -Value ([string]$adapter.MacAddress) }
}

function ConvertFrom-GenesisFirmwareBootList {
    param([AllowEmptyString()][string]$Text)
    foreach ($block in @($Text -split '(?:\r?\n){2,}')) {
        $id = [regex]::Match($block, '(?im)^(?:identifier|identificateur|bezeichner)\s+(\{[^}\s]+\})')
        if (-not $id.Success) { continue }
        $description = [regex]::Match($block, '(?im)^description\s+(.+?)\s*$')
        [pscustomobject]@{ Id = $id.Groups[1].Value; Description = if ($description.Success) { $description.Groups[1].Value } else { '' } }
    }
}

function Select-GenesisPxeBootEntry {
    param([AllowEmptyCollection()][object[]]$Entries = @())
    $network = @($Entries | Where-Object {
            $_.Id -ne '{fwbootmgr}' -and $_.Description -match '(?i)pxe|network|r.seau|ipv4|ipv6|\bnic\b|\blan\b|ethernet'
        })
    $ipv4 = @($network | Where-Object { $_.Description -notmatch '(?i)ipv6' })
    if ($ipv4.Count -gt 0) { return $ipv4[0] }
    if ($network.Count -gt 0) { return $network[0] }
    return $null
}

function Get-GenesisPxeBootEntry {
    $result = Invoke-GenesisNativeCommand -FilePath 'bcdedit.exe' -Arguments '/enum firmware'
    if ($result.ExitCode -ne 0) { throw 'Liste de démarrage UEFI illisible : la capture FOG automatique nécessite un poste en mode UEFI.' }
    $entry = Select-GenesisPxeBootEntry -Entries @(ConvertFrom-GenesisFirmwareBootList -Text ([string]$result.Output))
    if ($null -eq $entry) {
        throw 'Aucune entrée de démarrage réseau (PXE) dans le microprogramme : activer la pile réseau / le démarrage PXE dans le BIOS, puis reprendre.'
    }
    return $entry
}

function Set-GenesisNextBootEntry {
    param([Parameter(Mandatory)][ValidatePattern('^\{[^}\s"]+\}$')][string]$Id)
    $result = Invoke-GenesisNativeCommand -FilePath 'bcdedit.exe' -Arguments ('/set {fwbootmgr} bootsequence ' + $Id)
    if ($result.ExitCode -ne 0) { throw "Démarrage réseau unique refusé par Windows (code $($result.ExitCode))." }
}

function Test-GenesisWindowsGeneralized {
    $state = Get-GenesisRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name 'ImageState'
    return ($state.Exists -and [string]$state.Data -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE')
}

function Get-GenesisSysprepBlocker {
    param([Parameter(Mandatory)][string]$RunDirectory)
    if (Test-Path -LiteralPath 'HKLM:\SYSTEM\Setup\Upgrade') {
        return 'Windows a été mis à niveau sur place (ex. mise à niveau de version) : Sysprep refuse de généraliser ce poste. Capturer un poste installé directement dans la version voulue.'
    }
    if ((Test-GenesisUpdateRebootPending -RunDirectory $RunDirectory) -or
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        return 'Un redémarrage est en attente : redémarrer le poste puis reprendre Genesis avant la capture.'
    }
    return $null
}

function Get-GenesisSystemVolumeEncryption {
    $volume = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) -ErrorAction SilentlyContinue
    if ($null -eq $volume) { return $null }
    $status = Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus -ErrorAction Stop
    return [pscustomobject]@{ Volume = $volume; ConversionStatus = [int]$status.ConversionStatus; EncryptionPercentage = [int]$status.EncryptionPercentage }
}

function Disable-GenesisSystemEncryption {
    param([Parameter(Mandatory)][string]$RunDirectory, [int]$PollSeconds = 30)
    # 0 : déchiffré ; 3 : déchiffrement en cours ; autre : chiffré, en cours ou en pause.
    $encryption = Get-GenesisSystemVolumeEncryption
    if ($null -eq $encryption -or $encryption.ConversionStatus -eq 0) { return $false }
    $deadline = [datetime]::UtcNow.AddMinutes($script:GenesisFogDecryptTimeoutMinutes)
    while ($encryption.ConversionStatus -ne 0) {
        if ($encryption.ConversionStatus -ne 3) {
            $call = Invoke-CimMethod -InputObject $encryption.Volume -MethodName Decrypt -ErrorAction Stop
            if ([int]$call.ReturnValue -ne 0) { throw ('Windows refuse de déchiffrer le disque système (code {0}) : désactiver BitLocker puis reprendre.' -f $call.ReturnValue) }
        }
        if ([datetime]::UtcNow -gt $deadline) { throw 'Déchiffrement BitLocker trop long : attendre sa fin puis reprendre Genesis.' }
        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'fog-capture' -Percent 20 -Message ('Déchiffrement BitLocker du disque système : {0} % restant' -f $encryption.EncryptionPercentage)
        Start-Sleep -Seconds $PollSeconds
        $encryption = Get-GenesisSystemVolumeEncryption
        if ($null -eq $encryption) { break }
    }
    return $true
}

function Clear-GenesisNetBirdIdentity {
    # La clé WireGuard du poste ne doit pas être clonée ; NetBird en recrée une au démarrage.
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { return $false }
    $directory = Join-Path $env:ProgramData 'Netbird'
    $files = @('config.json', 'state.json' | ForEach-Object { Join-Path $directory $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($files.Count -eq 0) { return $false }
    $service = Get-Service -Name 'netbird' -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne 'Stopped') { Stop-Service -Name 'netbird' -Force -ErrorAction Stop }
    foreach ($file in $files) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
    return $true
}

function Get-GenesisSysprepBlockingAppx {
    # Sysprep échoue sur une application du Store installée pour un compte sans être provisionnée.
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { [string]$_.DisplayName })
    @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object {
            -not $_.IsFramework -and -not $_.NonRemovable -and [string]$_.SignatureKind -ne 'System' -and [string]$_.Name -notin $provisioned
        })
}

function Remove-GenesisSysprepBlockingAppx {
    $removed = 0
    foreach ($package in @(Get-GenesisSysprepBlockingAppx)) {
        try { Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop; $removed++ }
        catch { Write-Verbose ('Application non retirée avant Sysprep : ' + $package.Name) }
    }
    return $removed
}

function Get-GenesisSysprepPath {
    $system = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    return (Join-Path $env:WINDIR ($system + '\Sysprep\sysprep.exe'))
}

function Get-GenesisSysprepError {
    param([datetime]$Since)
    $log = Join-Path $env:WINDIR 'System32\Sysprep\Panther\setuperr.log'
    if (-not (Test-Path -LiteralPath $log -PathType Leaf) -or (Get-Item -LiteralPath $log).LastWriteTime -lt $Since) { return 'Aucun détail dans setuperr.log.' }
    $lines = @(Get-Content -LiteralPath $log -Tail 4 -ErrorAction SilentlyContinue | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() } | Where-Object { $_ })
    $text = $lines -join ' | '
    if ($text.Length -gt 400) { $text = $text.Substring($text.Length - 400) }
    return ('Journal : ' + $text)
}

function Invoke-GenesisSysprep {
    $path = Get-GenesisSysprepPath
    $started = Get-Date
    # /quit plutôt que /reboot : Genesis vérifie le résultat avant de programmer la capture.
    $result = Invoke-GenesisNativeCommand -FilePath $path -Arguments '/generalize /oobe /quit /quiet' -TimeoutSeconds 3600 -WorkingDirectory (Split-Path -Parent $path)
    if (-not (Test-GenesisWindowsGeneralized)) {
        throw ('Sysprep n''a pas généralisé Windows (code {0}). {1}' -f $result.ExitCode, (Get-GenesisSysprepError -Since $started))
    }
}

function Get-GenesisFogCaptureBlocker {
    param([Parameter(Mandatory)]$State)
    $others = @($State.Steps | Where-Object { $_.Id -ne 'fog-capture' })
    if (@($others | Where-Object { $_.Id -in @('windows-update', 'windows-feature-update') -and $_.Status -ne 'Completed' }).Count -gt 0) {
        return 'En attente de la fin des mises à jour Windows.'
    }
    $blocking = @($others | Where-Object { $_.Status -in @('Failed', 'Pending', 'Running') } | ForEach-Object { [string]$_.Id })
    if ($blocking.Count -gt 0) { return ('En attente : corriger puis reprendre ' + ($blocking -join ', ') + ' avant la capture.') }
    return $null
}

function Invoke-GenesisFogCapture {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $settings = Read-GenesisFogConfigurationFile -RunDirectory $RunDirectory
    if ($null -eq $settings) {
        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = 'Paramètres FOG absents : lancer la capture depuis le menu Genesis.' }
    }
    $generalized = Test-GenesisWindowsGeneralized
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'fog-capture' -Percent 5 -Message 'Contrôles avant capture : réseau, démarrage PXE, serveur FOG'
    if (-not $generalized) {
        $blocker = Get-GenesisSysprepBlocker -RunDirectory $RunDirectory
        if ($null -ne $blocker) { return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 0; Message = $blocker } }
    }
    # Tout ce qui peut échouer sans dommage est vérifié avant de toucher au poste.
    $adapter = Get-GenesisFogNetworkAdapter
    $bootEntry = Get-GenesisPxeBootEntry
    $image = Get-GenesisFogImage -Settings $settings
    $fogHost = Register-GenesisFogHost -Settings $settings -Mac $adapter.Mac -ImageId ([int]$image.id) -Name $env:COMPUTERNAME
    if (-not $generalized) {
        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'fog-capture' -Percent 15 -Message 'Vérification du chiffrement BitLocker'
        Disable-GenesisSystemEncryption -RunDirectory $RunDirectory | Out-Null
        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'fog-capture' -Percent 40 -Message 'Nettoyage : veille prolongée, identité NetBird, applications non provisionnées'
        $hibernate = Invoke-GenesisNativeCommand -FilePath 'powercfg.exe' -Arguments '/hibernate off'
        if ($hibernate.ExitCode -ne 0) { throw "Désactivation de la veille prolongée impossible (code $($hibernate.ExitCode))." }
        Clear-GenesisNetBirdIdentity | Out-Null
        Remove-GenesisSysprepBlockingAppx | Out-Null
        Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'fog-capture' -Percent 55 -Message 'Sysprep : généralisation de Windows (plusieurs minutes)'
        Invoke-GenesisSysprep
    }
    Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId 'fog-capture' -Percent 85 -Message 'Programmation de la capture dans FOG'
    try { New-GenesisFogCaptureTask -Settings $settings -HostId $fogHost.Id }
    catch {
        throw ('Windows est généralisé mais la capture n''a pas été programmée ; ne pas redémarrer sur Windows. Créer la tâche Capture dans FOG pour {0} puis démarrer sur le réseau. {1}' -f $adapter.Mac, $_.Exception.Message)
    }
    try { Set-GenesisNextBootEntry -Id $bootEntry.Id }
    catch { throw ('Capture programmée dans FOG, mais le démarrage réseau n''a pas pu être forcé : redémarrer en choisissant « {0} » dans le menu de démarrage. {1}' -f $bootEntry.Description, $_.Exception.Message) }
    Remove-GenesisFogConfigurationFile -RunDirectory $RunDirectory
    $hostLabel = if ($fogHost.Created) { 'poste enregistré dans FOG' } else { 'poste déjà connu de FOG' }
    [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = ('Windows généralisé ; capture vers l''image « {0} » programmée ({1}). Redémarrage sur le réseau.' -f $settings.ImageName, $hostLabel) }
}

function Complete-GenesisFogCapture {
    param([Parameter(Mandatory)]$State, [string]$DataRoot)
    if (@($State.Steps | Where-Object { $_.Id -eq 'fog-capture' -and $_.Status -eq 'Completed' }).Count -eq 0) { return $false }
    # Les journaux, sauvegardes et la tâche de reprise ne doivent pas partir dans l'image.
    Uninstall-GenesisFootprint -DataRoot $DataRoot -Confirm:$false | Out-Null
    Restart-GenesisComputer -DelaySeconds $script:GenesisFogRestartDelaySeconds -Reason 'Genesis redémarre sur le réseau pour la capture FOG.'
    return $true
}

function Invoke-GenesisCustomization {
    param([string]$StepId, [string]$RunDirectory, [object]$Choices)
    if ($env:OS -ne 'Windows_NT') { throw 'Personnalisation disponible sur Windows uniquement.' }
    switch ($StepId) {
        'windows-update' { return Invoke-GenesisWindowsUpdate -RunDirectory $RunDirectory }
        'windows-feature-update' { return Invoke-GenesisWindowsUpdate -RunDirectory $RunDirectory -Scope Feature }
        'time-sync' { return Set-GenesisWindowsTime -RunDirectory $RunDirectory }
        'power-ac' { return Set-GenesisPowerAc -RunDirectory $RunDirectory }
        'local-user' { return New-GenesisLocalUser -RunDirectory $RunDirectory }
        'office-2024' { return Install-GenesisOffice2024 -RunDirectory $RunDirectory }
        'browser' { return Install-GenesisBrowser -RunDirectory $RunDirectory -Choice (Get-GenesisChoiceValue -Choices $Choices -Name 'browser') }
        'pdf-reader' { return Install-GenesisPdfReader -RunDirectory $RunDirectory -Choice (Get-GenesisChoiceValue -Choices $Choices -Name 'pdf-reader') }
        'netbird' { return Install-GenesisNetBird -RunDirectory $RunDirectory }
        'fog-capture' { return Invoke-GenesisFogCapture -RunDirectory $RunDirectory }
        'taskbar-pins' { return Set-GenesisTaskbarLayout -RunDirectory $RunDirectory }
        'start-cleanup' { return Invoke-GenesisStartCleanup -RunDirectory $RunDirectory }
        'taskbar-left' { return Set-GenesisTaskbarLeft -RunDirectory $RunDirectory }
        default {
            $changes = @(Get-GenesisRegistryChange -StepId $StepId)
            Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $StepId -Percent 30 -Message 'Lecture et sauvegarde des réglages existants'
            if ($changes.Count -gt 0) {
                try { Invoke-GenesisRegistryTransaction -Changes $changes -SnapshotPath (Join-Path $RunDirectory ($StepId + '.registry.json')) }
                catch {
                    if ($StepId -eq 'taskbar-controls' -and $changes.Name -contains 'TaskbarDa' -and $_.Exception.InnerException -is [UnauthorizedAccessException]) {
                        return [pscustomobject]@{ Status = 'NeedsAttention'; Percent = 67; Message = 'Recherche et Vue des tâches masquées. Widgets protégé par Windows : désactiver dans Paramètres > Personnalisation > Barre des tâches, puis reprendre.' }
                    }
                    throw
                }
            }
            Set-GenesisStepProgress -RunDirectory $RunDirectory -StepId $StepId -Percent 90 -Message 'Réglages appliqués ; vérification terminée'
            return [pscustomobject]@{ Status = 'Completed'; Percent = 100; Message = 'Valeurs appliquées et relues. Actualiser la session pour le rendu visuel.' }
        }
    }
}

function Undo-GenesisCustomization {
    param([string]$StepId, [string]$RunDirectory)
    if ($StepId -eq 'power-ac') { return Undo-GenesisPowerAc -RunDirectory $RunDirectory }
    if ($StepId -eq 'local-user') { return Undo-GenesisLocalUser -RunDirectory $RunDirectory }
    if ($StepId -eq 'time-sync') {
        $backup = Get-Content (Join-Path $RunDirectory 'time-service.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-GenesisSnapshotOwner -Snapshot $backup
        $current = Get-CimInstance -ClassName Win32_Service -Filter "Name='W32Time'"
        if ($current.StartMode -notin @('Auto', $backup.StartMode)) { return [pscustomobject]@{ Status = 'Conflict'; Message = 'Le démarrage du service horaire a changé depuis.' } }
    }
    $file = Join-Path $RunDirectory ($StepId + '.registry.json')
    if (Test-Path -LiteralPath $file) {
        $result = Undo-GenesisRegistryTransaction -SnapshotPath $file
        if ($result.ConflictCount -gt 0) { return [pscustomobject]@{ Status = 'Conflict'; Message = 'Réglage modifié depuis : restauration suspendue pour ces valeurs.' } }
    }
    if ($StepId -eq 'time-sync') {
        if (-not $backup.Running) { Stop-Service -Name W32Time -ErrorAction Stop }
        elseif ((Get-Service W32Time).Status -ne 'Running') { Start-Service -Name W32Time -ErrorAction Stop }
        $mode = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Disabled' }[$backup.StartMode]
        Set-Service -Name W32Time -StartupType $mode -ErrorAction Stop
        if ((Get-CimInstance -ClassName Win32_Service -Filter "Name='W32Time'").StartMode -ne $backup.StartMode -or ((Get-Service W32Time).Status -eq 'Running') -ne $backup.Running) { throw 'Vérification de la restauration du service impossible.' }
        return [pscustomobject]@{ Status = 'Restored'; Message = 'Configuration horaire restaurée ; heure correcte conservée.' }
    }
    if ($StepId -eq 'taskbar-pins') {
        $backup = Get-Content (Join-Path $RunDirectory 'taskbar-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-GenesisSnapshotOwner -Snapshot $backup
        if ($null -eq $backup.After) {
            if ((Get-GenesisTaskbarState | ConvertTo-Json -Depth 12 -Compress) -cne ($backup.Before | ConvertTo-Json -Depth 12 -Compress)) {
                return [pscustomobject]@{ Status = 'Conflict'; Message = 'Épingles modifiées sans validation : contrôle dans la session requis.' }
            }
        }
        else { return Restore-GenesisTaskbarState -Backup $backup }
    }
    [pscustomobject]@{ Status = 'Restored'; Message = 'Valeurs et types initiaux restaurés et vérifiés.' }
}
$script:GenesisConsoleTable = $null
$script:GenesisConsoleTableDirty = $false
$script:GenesisConsoleProgressSurfaceReady = $false
# Motifs d'échec de la session en cours, gardés en mémoire seulement (jamais dans state.json).
$script:GenesisStepErrors = @{}

function Get-GenesisProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    $catalog = @(Get-GenesisStepCatalog)
    $labels = @{
        Pending = 'À faire'; Running = 'En cours'; Completed = 'Fait'; Failed = 'Échec'; Skipped = 'Ignoré'
        NeedsAttention = 'À faire'; AwaitingSession = 'À vérifier'; Restoring = 'Restauration'
        Restored = 'Restauré'; RestoreConflict = 'Conflit'
    }
    $rows = @($State.Steps | ForEach-Object {
        $step = $_
        $definition = $catalog | Where-Object { $_.Id -eq $step.Id } | Select-Object -First 1
        $percent = 0; $message = ''; $undo = 'Non'
        if ($step.PSObject.Properties.Name -contains 'Percent') { $percent = [int]$step.Percent }
        elseif ($step.Status -eq 'Completed') { $percent = 100 }
        if ($step.PSObject.Properties.Name -contains 'Message') { $message = $step.Message }
        if ($step.Status -eq 'Failed' -and $script:GenesisStepErrors.ContainsKey([string]$step.Id)) { $message = $script:GenesisStepErrors[[string]$step.Id] }
        if ($step.PSObject.Properties.Name -contains 'UndoStatus' -and $step.UndoStatus -eq 'Available') { $undo = 'Oui' }
        if ($step.Id -eq 'time-sync' -and $undo -eq 'Oui') { $undo = 'Configuration' }
        [pscustomobject]@{ Id = $step.Id; Name = $definition.Name; Context = $definition.Context; State = $labels[$step.Status]; Status = $step.Status; Percent = $percent; Detail = $message; Undo = $undo }
    })
    $sum = ($rows | Measure-Object -Property Percent -Sum).Sum
    $percent = 0
    if ($rows.Count -gt 0) { $percent = [int][math]::Floor($sum / $rows.Count) }
    $mode = 'Run'
    $reversible = @($State.Steps | Where-Object { $_.PSObject.Properties.Name -contains 'UndoStatus' -and $_.UndoStatus -in @('Available', 'Conflict', 'Restored') })
    $restored = @($reversible | Where-Object { $_.UndoStatus -eq 'Restored' }).Count
    if ($State.PSObject.Properties.Name -contains 'Status' -and $State.Status -in @('Restoring', 'Restored', 'RestoreConflict')) {
        $mode = 'Undo'; $percent = 100
        if ($reversible.Count -gt 0) { $percent = [int][math]::Floor(100 * $restored / $reversible.Count) }
    }
    [pscustomobject]@{
        Percent = $percent; Total = $rows.Count; Mode = $mode; Restored = $restored; Reversible = $reversible.Count
        Completed = @($State.Steps | Where-Object { $_.Status -eq 'Completed' }).Count
        Rows = $rows
    }
}

function Get-GenesisConsoleWidth {
    try {
        $width = [Console]::WindowWidth
        if ($width -ge 60) { return [int]$width }
    }
    catch { Write-Verbose 'Largeur de console indisponible.' }
    return 80
}

function ConvertTo-GenesisConsoleLabel {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Width)
    $value = ($Text -replace '[\r\n\t]+', ' ').Trim()
    if ($value.Length -gt $Width) {
        if ($Width -le 3) { return $value.Substring(0, $Width) }
        return $value.Substring(0, $Width - 3) + '...'
    }
    return $value
}

$script:GenesisConsoleTableColumns = @(14, 12, 6, 8)

function Get-GenesisConsoleTableDetailWidth {
    param([int]$ConsoleWidth = (Get-GenesisConsoleWidth))
    $fixed = ($script:GenesisConsoleTableColumns | Measure-Object -Sum).Sum + (3 * ($script:GenesisConsoleTableColumns.Count + 1)) + 1
    return [int][math]::Max(10, [math]::Min(60, $ConsoleWidth - $fixed - 1))
}

function Get-GenesisConsoleTableBorder {
    param([Parameter(Mandatory)][int]$DetailWidth)
    $widths = @($script:GenesisConsoleTableColumns) + $DetailWidth
    return '+' + (($widths | ForEach-Object { '-' * ($_ + 2) }) -join '+') + '+'
}

function ConvertTo-GenesisConsoleTableRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Cells, [Parameter(Mandatory)][int]$DetailWidth)
    $widths = @($script:GenesisConsoleTableColumns) + $DetailWidth
    $parts = for ($index = 0; $index -lt $widths.Count; $index++) {
        $value = if ($index -lt $Cells.Count) { [string]$Cells[$index] } else { '' }
        ' ' + (ConvertTo-GenesisConsoleLabel -Text $value -Width $widths[$index]).PadRight($widths[$index]) + ' '
    }
    return '|' + ($parts -join '|') + '|'
}

function ConvertTo-GenesisConsoleProgressRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][int]$DetailWidth)
    $state = if ($null -eq $Row.State) { [string]$Row.Status } else { [string]$Row.State }
    return ConvertTo-GenesisConsoleTableRow -Cells @($Row.Id, $state, ('{0}%' -f $Row.Percent), $Row.Undo, $Row.Detail) -DetailWidth $DetailWidth
}

function Get-GenesisConsoleProgressSummary {
    param([Parameter(Mandatory)]$View)
    return ('Avancement : {0,3}% ({1}/{2})' -f $View.Percent, $View.Completed, $View.Total)
}

function Get-GenesisConsoleRowColor {
    param([string]$Status)
    switch ($Status) {
        'Running' { return [ConsoleColor]::Yellow }
        'Restoring' { return [ConsoleColor]::Yellow }
        'Completed' { return [ConsoleColor]::Green }
        'Restored' { return [ConsoleColor]::Green }
        'Failed' { return [ConsoleColor]::Red }
        'RestoreConflict' { return [ConsoleColor]::Red }
        'NeedsAttention' { return [ConsoleColor]::DarkYellow }
        'AwaitingSession' { return [ConsoleColor]::DarkYellow }
        default { return [ConsoleColor]::Gray }
    }
}

function Write-GenesisConsoleLine {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Ligne colorée du tableau de progression console.')]
    param([AllowEmptyString()][string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [int]$PadTo = 0)
    $previous = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = $Color
        [Console]::Write($Text.PadRight($PadTo))
    }
    finally { [Console]::ForegroundColor = $previous }
}

function Test-GenesisInteractiveConsole {
    try { return ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) }
    catch { return $false }
}

function Initialize-GenesisConsoleProgressSurface {
    param()
    $script:GenesisConsoleTable = $null
    $script:GenesisConsoleTableDirty = $false
    $script:GenesisConsoleProgressSurfaceReady = Test-GenesisInteractiveConsole
}

function Get-GenesisConsoleCursor {
    try {
        return [pscustomobject]@{ Left = [Console]::CursorLeft; Top = [Console]::CursorTop }
    }
    catch { return $null }
}

function Set-GenesisConsoleCursor {
    param([int]$Left, [int]$Top)
    try {
        $safeTop = [math]::Max(0, [math]::Min($Top, [Console]::BufferHeight - 1))
        $safeLeft = [math]::Max(0, [math]::Min($Left, [Console]::BufferWidth - 1))
        [Console]::SetCursorPosition($safeLeft, $safeTop)
        return $true
    }
    catch { return $false }
}

function Write-GenesisConsoleProgressTable {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Tableau de progression console du technicien.')]
    param([Parameter(Mandatory)]$View)
    Clear-Host
    Write-GenesisBanner
    Write-Host 'Exécution Genesis — progression des tâches' -ForegroundColor Cyan
    $detailWidth = Get-GenesisConsoleTableDetailWidth
    $border = Get-GenesisConsoleTableBorder -DetailWidth $detailWidth
    $lines = @{}
    [Console]::WriteLine($border)
    [Console]::WriteLine((ConvertTo-GenesisConsoleTableRow -Cells @('ID', 'État', '%', 'Reverse', 'Détail') -DetailWidth $detailWidth))
    [Console]::WriteLine($border)
    foreach ($row in @($View.Rows)) {
        $line = ConvertTo-GenesisConsoleProgressRow -Row $row -DetailWidth $detailWidth
        Write-GenesisConsoleLine -Text $line -Color (Get-GenesisConsoleRowColor -Status $row.Status)
        [Console]::WriteLine()
        $lines[$row.Id] = $line
    }
    [Console]::WriteLine($border)
    $summary = Get-GenesisConsoleProgressSummary -View $View
    Write-GenesisConsoleLine -Text $summary -Color Cyan
    [Console]::WriteLine()
    [Console]::WriteLine()
    # Positions calculées depuis le bas : elles restent justes même si l'écran a défilé pendant le dessin.
    $end = [Console]::CursorTop
    $summaryTop = $end - 2
    $firstRowTop = $summaryTop - 1 - @($View.Rows).Count
    $rowTops = @{}
    $index = 0
    foreach ($row in @($View.Rows)) { $rowTops[$row.Id] = $firstRowTop + $index; $index++ }
    $script:GenesisConsoleTable = [pscustomobject]@{
        Ids = (@($View.Rows | ForEach-Object { $_.Id }) -join ',')
        DetailWidth = $detailWidth
        RowTops = $rowTops
        Lines = $lines
        SummaryTop = $summaryTop
        Summary = $summary
        End = $end
    }
    $script:GenesisConsoleTableDirty = $false
}

function Update-GenesisConsoleProgressTable {
    param([Parameter(Mandatory)]$View)
    $table = $script:GenesisConsoleTable
    $cursor = Get-GenesisConsoleCursor
    if ($null -eq $cursor) { return $false }
    foreach ($row in @($View.Rows)) {
        $line = ConvertTo-GenesisConsoleProgressRow -Row $row -DetailWidth $table.DetailWidth
        if ($table.Lines[$row.Id] -ceq $line) { continue }
        if (-not (Set-GenesisConsoleCursor -Left 0 -Top $table.RowTops[$row.Id])) { return $false }
        Write-GenesisConsoleLine -Text $line -Color (Get-GenesisConsoleRowColor -Status $row.Status)
        $table.Lines[$row.Id] = $line
    }
    $summary = Get-GenesisConsoleProgressSummary -View $View
    if ($summary -cne $table.Summary) {
        if (-not (Set-GenesisConsoleCursor -Left 0 -Top $table.SummaryTop)) { return $false }
        Write-GenesisConsoleLine -Text $summary -Color Cyan -PadTo $table.Summary.Length
        $table.Summary = $summary
    }
    $restoreTop = [math]::Max([int]$cursor.Top, [int]$table.End)
    Set-GenesisConsoleCursor -Left 0 -Top $restoreTop | Out-Null
    return $true
}

function Write-GenesisConsoleProgressAppend {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Journal de progression console du technicien.')]
    param([Parameter(Mandatory)]$View)
    # Console non interactive : une ligne par changement d'état, sans réécriture.
    if ($null -eq $script:GenesisConsoleTable) {
        $script:GenesisConsoleTable = [pscustomobject]@{ DetailWidth = (Get-GenesisConsoleTableDetailWidth -ConsoleWidth 120); States = @{} }
        Write-Host (ConvertTo-GenesisConsoleTableRow -Cells @('ID', 'État', '%', 'Reverse', 'Détail') -DetailWidth $script:GenesisConsoleTable.DetailWidth)
    }
    foreach ($row in @($View.Rows)) {
        if ($script:GenesisConsoleTable.States[$row.Id] -ceq $row.Status) { continue }
        $script:GenesisConsoleTable.States[$row.Id] = $row.Status
        if ($row.Status -eq 'Pending') { continue }
        Write-Host (ConvertTo-GenesisConsoleProgressRow -Row $row -DetailWidth $script:GenesisConsoleTable.DetailWidth)
    }
}

function Complete-GenesisConsoleProgressLine {
    param()
    # Appelée avant une saisie : la saisie s'affiche sous le tableau, qui sera redessiné ensuite.
    if ($null -eq $script:GenesisConsoleTable -or -not $script:GenesisConsoleProgressSurfaceReady) { return }
    $cursor = Get-GenesisConsoleCursor
    if ($null -ne $cursor -and $cursor.Top -lt $script:GenesisConsoleTable.End) {
        Set-GenesisConsoleCursor -Left 0 -Top $script:GenesisConsoleTable.End | Out-Null
    }
    $script:GenesisConsoleTableDirty = $true
}

function Write-GenesisConsoleProgress {
    param([Parameter(Mandatory)]$State)
    $view = Get-GenesisProgress -State $State
    if (-not $script:GenesisConsoleProgressSurfaceReady) {
        Write-GenesisConsoleProgressAppend -View $view
        return
    }
    try {
        $ids = @($view.Rows | ForEach-Object { $_.Id }) -join ','
        $table = $script:GenesisConsoleTable
        if ($null -eq $table -or $script:GenesisConsoleTableDirty -or $table.Ids -cne $ids -or $table.DetailWidth -ne (Get-GenesisConsoleTableDetailWidth)) {
            Write-GenesisConsoleProgressTable -View $view
        }
        elseif (-not (Update-GenesisConsoleProgressTable -View $view)) {
            Write-GenesisConsoleProgressTable -View $view
        }
    }
    catch {
        Write-Verbose ('Tableau de progression indisponible : ' + $_.Exception.Message)
        $script:GenesisConsoleProgressSurfaceReady = $false
        $script:GenesisConsoleTable = $null
        Write-GenesisConsoleProgressAppend -View $view
    }
}

function Set-GenesisStepProgress {
    param([string]$RunDirectory, [string]$StepId, [int]$Percent, [string]$Message)
    $path = Join-Path $RunDirectory 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $step = $state.Steps | Where-Object { $_.Id -eq $StepId } | Select-Object -First 1
    if ($null -eq $step) { return }
    $step.Percent = $Percent; $step.Message = $Message
    Write-GenesisJson -Path $path -Value $state
    Write-GenesisConsoleProgress -State $state
}

function Test-GenesisUndoAvailable {
    param([string]$StepId, [string]$RunDirectory)
    if ($StepId -eq 'inventory') { return $false }
    foreach ($name in @(($StepId + '.registry.json'), 'time-service.json', 'taskbar-state.json', 'power-ac.json', 'local-user.json')) {
        if (($name -eq 'time-service.json' -and $StepId -ne 'time-sync') -or
            ($name -eq 'taskbar-state.json' -and $StepId -ne 'taskbar-pins') -or
            ($name -eq 'power-ac.json' -and $StepId -ne 'power-ac') -or
            ($name -eq 'local-user.json' -and $StepId -ne 'local-user')) { continue }
        if (Test-Path -LiteralPath (Join-Path $RunDirectory $name)) { return $true }
    }
    return $false
}

function Assert-GenesisRunOwner {
    param($State)
    if ($State.MachineId -cne (Get-GenesisMachineId)) { throw 'Préparation liée à un autre ordinateur.' }
    if ($State.GenesisVersion -cne $script:GenesisVersion) { throw 'Version de Genesis différente : utiliser la version de la préparation.' }
    if ($State.UserSid -cne (Get-GenesisUserSid)) { throw 'Préparation liée à un autre utilisateur.' }
}

function Undo-GenesisRun {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId, [string]$DataRoot)
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Restaurer les personnalisations sauvegardées')) { return }
    Assert-GenesisAdministrator
    $lock = Open-GenesisRunLock -DataRoot $root
    try {
        $state = Get-GenesisRun -RunId $RunId -DataRoot $root
        Assert-GenesisRunOwner -State $state
        $directory = Join-Path (Join-Path $root 'runs') $RunId
        $path = Join-Path $directory 'state.json'
        $state.Status = 'Restoring'
        Write-GenesisJson -Path $path -Value $state
        foreach ($step in @($state.Steps)[($state.Steps.Count - 1)..0]) {
            if (-not (Test-GenesisUndoAvailable -StepId $step.Id -RunDirectory $directory) -or $step.UndoStatus -eq 'Restored') { continue }
            $step.Status = 'Restoring'; $step.Percent = 10; $step.Message = 'Contrôle de la sauvegarde'
            Write-GenesisJson -Path $path -Value $state
            try {
                $result = Undo-GenesisCustomization -StepId $step.Id -RunDirectory $directory
                $step.Message = $result.Message
                if ($result.Status -eq 'Conflict') { $step.Status = 'RestoreConflict'; $step.UndoStatus = 'Conflict'; $step.Percent = 0 }
                else { $step.Status = 'Restored'; $step.UndoStatus = 'Restored'; $step.Percent = 100; $step.ErrorType = $null }
            }
            catch {
                $step.Status = 'RestoreConflict'; $step.UndoStatus = 'Conflict'; $step.Percent = 0
                $step.Message = 'Restauration interrompue : sauvegarde conservée.'
                $step.ErrorType = $_.Exception.GetType().FullName
            }
            Write-GenesisJson -Path $path -Value $state
            Add-GenesisEvent -RunDirectory $directory -EventName ('undo_' + $step.UndoStatus.ToLowerInvariant()) -StepId $step.Id
        }
        $state.Status = 'Restored'
        if (@($state.Steps | Where-Object { $_.UndoStatus -eq 'Conflict' }).Count -gt 0) { $state.Status = 'RestoreConflict' }
        Write-GenesisJson -Path $path -Value $state
        return $state
    }
    finally { $lock.Dispose() }
}

function Confirm-GenesisTaskbar {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId, [string]$DataRoot)
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Consigner le contrôle visuel des cinq épingles')) { return }
    Assert-GenesisAdministrator
    $root = Resolve-GenesisDataRoot -DataRoot $DataRoot
    $lock = Open-GenesisRunLock -DataRoot $root
    try {
        $state = Get-GenesisRun -RunId $RunId -DataRoot $root
        Assert-GenesisRunOwner -State $state
        $step = $state.Steps | Where-Object { $_.Id -eq 'taskbar-pins' } | Select-Object -First 1
        if ($null -eq $step -or $step.Status -ne 'AwaitingSession' -or @(Get-GenesisOfficeApp).Count -ne 4) { throw 'Disposition et applications Office requises avant validation.' }
        $directory = Join-Path (Join-Path $root 'runs') $RunId
        $file = Join-Path $directory 'taskbar-state.json'
        $snapshot = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-GenesisSnapshotOwner -Snapshot $snapshot
        $snapshot.After = Get-GenesisTaskbarState
        Write-GenesisJson -Path $file -Value $snapshot
        $step.Status = 'Completed'; $step.Percent = 100; $step.Message = 'Contrôle visuel validé par le technicien'; $step.UndoStatus = 'Available'
        $state.Status = 'Completed'
        if (@($state.Steps | Where-Object { $_.Status -ne 'Completed' }).Count -gt 0) { $state.Status = 'NeedsAttention' }
        Write-GenesisJson -Path (Join-Path $directory 'state.json') -Value $state
        Add-GenesisEvent -RunDirectory $directory -EventName 'taskbar_visual_confirmation' -StepId 'taskbar-pins'
        return $state
    }
    finally { $lock.Dispose() }
}

function Restore-GenesisTaskbarState {
    param($Backup)
    $current = Get-GenesisTaskbarState
    if (($current | ConvertTo-Json -Depth 12 -Compress) -cne ($Backup.After | ConvertTo-Json -Depth 12 -Compress)) {
        return [pscustomobject]@{ Status = 'Conflict'; Message = 'Les épingles ont changé depuis la validation : restauration suspendue.' }
    }
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($session -eq 0) { return [pscustomobject]@{ Status = 'Conflict'; Message = 'Restaurer les épingles depuis linterface dans la session Windows.' } }
    foreach ($file in $Backup.Before.Files) {
        if ([IO.Path]::GetFileName($file.Name) -cne $file.Name -or $file.Name -notlike '*.lnk') { throw 'Nom de raccourci invalide dans la sauvegarde.' }
    }
    $explorers = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
    $explorers | Stop-Process -ErrorAction Stop
    try {
        $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($key) {
            $names = @($key.GetValueNames()); $key.Close()
            foreach ($name in $names) { Set-GenesisRegistryValue -Path $path -Name $name -Record ([pscustomobject]@{ Exists = $false; KeyExists = $true; Kind = ''; Data = $null }) }
        }
        foreach ($value in $Backup.Before.Values) { Set-GenesisRegistryValue -Path $path -Name $value.Name -Record $value.Record }
        $folder = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction Stop
        foreach ($file in $Backup.Before.Files) { [IO.File]::WriteAllBytes((Join-Path $folder $file.Name), [Convert]::FromBase64String($file.Data)) }
        if ((Get-GenesisTaskbarState | ConvertTo-Json -Depth 12 -Compress) -cne ($Backup.Before | ConvertTo-Json -Depth 12 -Compress)) { throw 'Vérification de la restauration des épingles impossible.' }
    }
    finally { Start-Process -FilePath 'explorer.exe' | Out-Null }
    [pscustomobject]@{ Status = 'Restored'; Message = 'Anciennes épingles restaurées ; Explorateur relancé.' }
}
$embeddedProfile = $script:GenesisEmbeddedProfiles[$ProfileId]
$profileArguments = @{}
if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $profileArguments.ProfileObject = $embeddedProfile
}
else {
    $profileArguments.ProfilePath = $ProfilePath
}
$runControlArguments = @{ RunId = $RunId; DataRoot = $DataRoot; WhatIf = $WhatIfPreference }
# La reprise après redémarrage relance ce fichier unique depuis le répertoire protégé.
$script:GenesisPortablePath = $PSCommandPath

switch ($Action) {
    'Menu' { Show-GenesisMenu @profileArguments -DataRoot $DataRoot }
    'Gui' { Show-GenesisMenu @profileArguments -DataRoot $DataRoot }
    'Inventory' { Format-GenesisInventoryAscii -Inventory (Get-GenesisInventory) }
    'Plan' { Get-GenesisPlan @profileArguments | ConvertTo-Json -Depth 8 }
    'Catalog' { @(Get-GenesisStepCatalog) | ConvertTo-Json -Depth 8 }
    'Run' {
        $arguments = @{ DataRoot = $DataRoot }
        foreach ($key in $profileArguments.Keys) { $arguments[$key] = $profileArguments[$key] }
        if ($RunId) { $arguments.RunId = $RunId }
        if ($PSBoundParameters.ContainsKey('WhatIf')) {
            $arguments.WhatIf = $PSBoundParameters.WhatIf
        }
        Start-GenesisRun @arguments | ConvertTo-Json -Depth 16
    }
    'Resume' { Resume-GenesisRun @runControlArguments | ConvertTo-Json -Depth 16 }
    'Status' { Get-GenesisRun -RunId $RunId -DataRoot $DataRoot | ConvertTo-Json -Depth 16 }
    'Undo' { Undo-GenesisRun @runControlArguments | ConvertTo-Json -Depth 16 }
    'ConfirmTaskbar' { Confirm-GenesisTaskbar @runControlArguments | ConvertTo-Json -Depth 16 }
    'ContinueUpdates' {
        Invoke-GenesisUpdateContinuation -RunId $RunId -DataRoot $DataRoot | ConvertTo-Json -Depth 8
    }
}
