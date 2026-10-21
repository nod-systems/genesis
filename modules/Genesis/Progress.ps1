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
    param([Parameter(Mandatory)][string[]]$Cells, [Parameter(Mandatory)][int]$DetailWidth)
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
