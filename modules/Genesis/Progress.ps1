$script:GenesisConsoleProgressRow = $null
$script:GenesisConsoleProgressSurfaceReady = $false

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

function ConvertTo-GenesisProgressBarLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [ValidateRange(0, 100)][int]$Percent,
        [ValidateRange(10, 120)][int]$Width = 24,
        [ValidateRange(12, 80)][int]$LabelWidth = 38
    )
    $filled = [math]::Floor($Width * $Percent / 100)
    $empty = $Width - $filled
    $bar = (('█' * $filled) -join '') + (('░' * $empty) -join '')
    $safeLabel = ConvertTo-GenesisConsoleLabel -Text $Label -Width $LabelWidth
    return ("{0,-$LabelWidth} |{1}| {2,3}%" -f $safeLabel, $bar, $Percent)
}

function Test-GenesisInteractiveConsole {
    try { return ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) }
    catch { return $false }
}

function Initialize-GenesisConsoleProgressSurface {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Initialisation de la surface de progression console du technicien.')]
    param()
    if ($script:GenesisConsoleProgressSurfaceReady) { return }
    if (-not (Test-GenesisInteractiveConsole)) { return }
    try {
        Clear-Host
        Write-GenesisBanner
        Write-Host 'Exécution Genesis — progression des tâches' -ForegroundColor Cyan
        $script:GenesisConsoleProgressRow = [Console]::CursorTop
        [Console]::WriteLine()
        $script:GenesisConsoleProgressSurfaceReady = $true
    }
    catch {
        $script:GenesisConsoleProgressRow = $null
        $script:GenesisConsoleProgressSurfaceReady = $false
        Write-Verbose ('Surface de progression indisponible : ' + $_.Exception.Message)
    }
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

function Complete-GenesisConsoleProgressLine {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Nettoyage de la ligne de progression console du technicien.')]
    param()
    $cursor = Get-GenesisConsoleCursor
    if ($null -ne $cursor -and $null -ne $script:GenesisConsoleProgressRow -and $script:GenesisConsoleProgressLineLength -gt 0) {
        $row = [int]$script:GenesisConsoleProgressRow
        if (Set-GenesisConsoleCursor -Left 0 -Top $row) {
            [Console]::Write((' ' * $script:GenesisConsoleProgressLineLength))
            $restoreRow = [int]$cursor.Top
            if ($restoreRow -le $row) { $restoreRow = $row + 1 }
            Set-GenesisConsoleCursor -Left 0 -Top $restoreRow | Out-Null
        }
    }
    elseif ($script:GenesisConsoleProgressLineLength -gt 0) {
        [Console]::Write("`r" + (' ' * $script:GenesisConsoleProgressLineLength) + "`r")
    }
    $script:GenesisConsoleProgressStepId = $null
    $script:GenesisConsoleProgressLineLength = 0
}

function Write-GenesisConsoleProgress {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Barre de progression console du technicien.')]
    param([Parameter(Mandatory)]$State)
    $view = Get-GenesisProgress -State $State
    $active = @($view.Rows | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 1)
    if ($active.Count -eq 0) {
        Complete-GenesisConsoleProgressLine
        return
    }
    if ($script:GenesisConsoleProgressStepId -ne $active[0].Id) {
        Complete-GenesisConsoleProgressLine
        $script:GenesisConsoleProgressStepId = $active[0].Id
    }
    $consoleWidth = Get-GenesisConsoleWidth
    $labelWidth = 38
    $barWidth = [math]::Max(16, [math]::Min(32, $consoleWidth - $labelWidth - 10))
    $line = ConvertTo-GenesisProgressBarLine -Label $active[0].Name -Percent $active[0].Percent -Width $barWidth -LabelWidth $labelWidth
    $oldLength = [int]$script:GenesisConsoleProgressLineLength
    $cursor = Get-GenesisConsoleCursor
    $targetRow = $script:GenesisConsoleProgressRow
    if ($null -ne $cursor -and $null -eq $targetRow) { $targetRow = [int]$cursor.Top; $script:GenesisConsoleProgressRow = $targetRow }
    if ($null -ne $cursor -and $null -ne $targetRow -and (Set-GenesisConsoleCursor -Left 0 -Top $targetRow)) {
        $clearLength = [math]::Max($oldLength, $line.Length)
        [Console]::Write((' ' * $clearLength))
        Set-GenesisConsoleCursor -Left 0 -Top $targetRow | Out-Null
        [Console]::Write($line)
        $restoreRow = [int]$cursor.Top
        if ($restoreRow -le $targetRow) { $restoreRow = $targetRow + 1 }
        Set-GenesisConsoleCursor -Left 0 -Top $restoreRow | Out-Null
    }
    else {
        if ($oldLength -gt 0) { [Console]::Write("`r" + (' ' * $oldLength) + "`r") }
        [Console]::Write($line)
    }
    $script:GenesisConsoleProgressLineLength = $line.Length
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
