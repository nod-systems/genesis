#requires -Version 5.1
# Genesis : lance la derniere version publique dans Windows PowerShell.

function Receive-GenesisRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$Commit,
        [Parameter(Mandatory)][string]$Directory
    )
    $baseUri = 'https://raw.githubusercontent.com/nod-systems/genesis/' + $Commit
    $manifest = Invoke-RestMethod -Uri ($baseUri + '/public-manifest.json') -UseBasicParsing -ErrorAction Stop
    if ($null -eq $manifest -or $manifest.schemaVersion -ne 1 -or $null -eq $manifest.sha256) {
        throw 'Le manifeste public Genesis est invalide.'
    }
    $expected = [string]$manifest.sha256.'Genesis-Portable.ps1'
    if ($expected -notmatch '^[a-fA-F0-9]{64}$') { throw 'Le manifeste ne contient pas une empreinte SHA-256 valide.' }
    New-Item -Path $Directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $path = Join-Path $Directory 'Genesis-Portable.ps1'
    try {
        Invoke-WebRequest -Uri ($baseUri + '/Genesis-Portable.ps1') -OutFile $path -UseBasicParsing -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $expected.ToUpperInvariant()) {
            throw 'Verification SHA-256 de Genesis echouee ; programme non execute.'
        }
        return $path
    }
    catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-GenesisBootstrapContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
    $nativeHost = -not ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
    $systemDirectory = if ($nativeHost) { 'System32' } else { 'Sysnative' }
    [pscustomobject]@{
        Administrator = $administrator
        DesktopHost = ($PSVersionTable.PSEdition -eq 'Desktop' -and $nativeHost)
        PowerShell = Join-Path $env:WINDIR ($systemDirectory + '\WindowsPowerShell\v1.0\powershell.exe')
    }
}

function Start-GenesisOnline {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Statut du lanceur avant le menu interactif.')]
    [CmdletBinding()]
    param([ValidatePattern('^[a-f0-9]{40}$')][string]$Commit)

    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'Genesis doit etre lance sur Windows.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([string]::IsNullOrWhiteSpace($Commit)) {
        $head = Invoke-RestMethod -Uri 'https://api.github.com/repos/nod-systems/genesis/commits/main' -Headers @{ 'User-Agent' = 'Genesis' } -UseBasicParsing -ErrorAction Stop
        $Commit = [string]$head.sha
        if ($Commit -notmatch '^[a-f0-9]{40}$') { throw 'La derniere version publique de Genesis est introuvable.' }
    }

    $context = Get-GenesisBootstrapContext
    if (-not $context.Administrator -or -not $context.DesktopHost) {
        if (-not (Test-Path -LiteralPath $context.PowerShell)) { throw 'Windows PowerShell 5.1 est introuvable.' }
        $command = "function Receive-GenesisRelease {`n" + ${function:Receive-GenesisRelease}.ToString() + "`n}`n"
        $command += "function Get-GenesisBootstrapContext {`n" + ${function:Get-GenesisBootstrapContext}.ToString() + "`n}`n"
        $command += "function Start-GenesisOnline {`n" + ${function:Start-GenesisOnline}.ToString() + "`n}`n"
        $command += "Start-GenesisOnline -Commit '$Commit'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $arguments = @{ FilePath = $context.PowerShell; ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded); Wait = $true }
        if (-not $context.Administrator) { $arguments.Verb = 'RunAs' }
        Start-Process @arguments | Out-Null
        return
    }

    $directory = Join-Path $env:TEMP ('Genesis-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Host 'Telechargement de la derniere version de Genesis...' -ForegroundColor Cyan
        $path = Receive-GenesisRelease -Commit $Commit -Directory $directory
        & $path -Action Menu -ProfileId windows
    }
    finally {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Start-GenesisOnline
