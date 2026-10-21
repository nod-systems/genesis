#requires -Version 5.1
<#
.SYNOPSIS
    Menu et commandes de preparation de poste Genesis.
.DESCRIPTION
    Inventaire, personnalisations Windows, progression et restauration.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Menu', 'Gui', 'Inventory', 'Plan', 'Run', 'Resume', 'Status', 'Catalog', 'Undo', 'ConfirmTaskbar', 'ContinueUpdates')]
    [string]$Action = 'Menu',
    [string]$ProfilePath = (Join-Path $PSScriptRoot 'profiles/windows.json'),
    [string]$DataRoot,
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'modules/Genesis/Genesis.psd1') -Force -ErrorAction Stop

switch ($Action) {
    'Menu' { Show-GenesisMenu -ProfilePath $ProfilePath -DataRoot $DataRoot }
    'Gui' { Show-GenesisMenu -ProfilePath $ProfilePath -DataRoot $DataRoot }
    'Inventory' { Format-GenesisInventoryAscii -Inventory (Get-GenesisInventory) }
    'Plan' { Get-GenesisPlan -ProfilePath $ProfilePath | ConvertTo-Json -Depth 8 }
    'Catalog' { @(Get-GenesisStepCatalog) | ConvertTo-Json -Depth 8 }
    'Run' {
        $arguments = @{ ProfilePath = $ProfilePath; DataRoot = $DataRoot }
        if ($RunId) { $arguments.RunId = $RunId }
        if ($PSBoundParameters.ContainsKey('WhatIf')) { $arguments.WhatIf = $PSBoundParameters.WhatIf }
        Start-GenesisRun @arguments | ConvertTo-Json -Depth 16
    }
    'Resume' { Resume-GenesisRun -RunId $RunId -DataRoot $DataRoot -WhatIf:$WhatIfPreference | ConvertTo-Json -Depth 16 }
    'Status' { Get-GenesisRun -RunId $RunId -DataRoot $DataRoot | ConvertTo-Json -Depth 16 }
    'Undo' { Undo-GenesisRun -RunId $RunId -DataRoot $DataRoot -WhatIf:$WhatIfPreference | ConvertTo-Json -Depth 16 }
    'ConfirmTaskbar' { Confirm-GenesisTaskbar -RunId $RunId -DataRoot $DataRoot -WhatIf:$WhatIfPreference | ConvertTo-Json -Depth 16 }
    'ContinueUpdates' { Invoke-GenesisUpdateContinuation -RunId $RunId -DataRoot $DataRoot | ConvertTo-Json -Depth 8 }
}
