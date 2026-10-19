@{
    RootModule = 'Genesis.psm1'
    ModuleVersion = '0.5.20'
    GUID = '33d2e2d1-4f1b-4526-882c-cb90642ff40e'
    Author = 'Genesis contributors'
    Description = 'Socle de preparation Windows Genesis pour les techniciens MSP.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-GenesisProfile', 'Get-GenesisStepCatalog', 'Get-GenesisPlan',
        'Get-GenesisInventory', 'Format-GenesisInventoryAscii', 'Start-GenesisRun', 'Resume-GenesisRun',
        'Get-GenesisRun', 'Show-GenesisMenu', 'Show-GenesisPrinterMenu',
        'Get-GenesisNetworkPrinter', 'New-GenesisPrinterDriverSearchUrl', 'Open-GenesisPrinterDriverSearch', 'Add-GenesisPrinter', 'Get-GenesisProgress',
        'Undo-GenesisRun', 'New-GenesisTaskbarXml', 'Confirm-GenesisTaskbar',
        'Register-GenesisUpdateContinuation', 'Invoke-GenesisUpdateContinuation'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
