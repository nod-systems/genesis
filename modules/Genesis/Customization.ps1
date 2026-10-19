function Get-GenesisUserSid {
    if ($env:OS -eq 'Windows_NT') { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    return 'local:' + [Environment]::UserName
}

function Assert-GenesisRegistryTarget {
    param([string]$Path, [string]$Name)
    $allowed = @{
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' = @('LaunchTo', 'TaskbarDa', 'ShowTaskViewButton')
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

function Invoke-GenesisCustomization {
    param([string]$StepId, [string]$RunDirectory, [object]$Choices)
    if ($env:OS -ne 'Windows_NT') { throw 'Personnalisation disponible sur Windows uniquement.' }
    switch ($StepId) {
        'windows-update' { return Invoke-GenesisWindowsUpdateStep -RunDirectory $RunDirectory }
        'windows-feature-update' { return Invoke-GenesisWindowsUpdateStep -RunDirectory $RunDirectory -Scope Feature }
        'time-sync' { return Set-GenesisWindowsTime -RunDirectory $RunDirectory }
        'power-ac' { return Set-GenesisPowerAc -RunDirectory $RunDirectory }
        'local-user' { return New-GenesisLocalUser -RunDirectory $RunDirectory }
        'office-2024' { return Install-GenesisOffice2024 -RunDirectory $RunDirectory }
        'browser' { return Install-GenesisBrowser -RunDirectory $RunDirectory -Choice (Get-GenesisChoiceValue -Choices $Choices -Name 'browser') }
        'pdf-reader' { return Install-GenesisPdfReader -RunDirectory $RunDirectory -Choice (Get-GenesisChoiceValue -Choices $Choices -Name 'pdf-reader') }
        'netbird' { return Install-GenesisNetBird -RunDirectory $RunDirectory }
        'taskbar-pins' { return Set-GenesisTaskbarLayout -RunDirectory $RunDirectory }
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
