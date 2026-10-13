@{
    IncludeDefaultRules = $true
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1')
        }
    }
    ExcludeRules = @('PSUseShouldProcessForStateChangingFunctions')
    # Les commandes publiques Run, Resume, Undo et ConfirmTaskbar gerent ShouldProcess.
    # Les fonctions internes de persistence et les fournisseurs sont controles par ces commandes.
}
