"""Construit un paquet public reproductible, sans donnees de preparation."""

import argparse
import hashlib
import json
import re
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

RELEASE_FILES = (
    "Genesis.ps1",
    "modules/Genesis/Genesis.psd1",
    "modules/Genesis/Genesis.psm1",
    "modules/Genesis/Customization.ps1",
    "modules/Genesis/Progress.ps1",
    "profiles/base.json",
    "profiles/windows.json",
    "install.ps1",
    "README.md",
    "CHANGELOG.md",
)

PORTABLE_PROFILE_FILES = {
    "base": "profiles/base.json",
    "windows": "profiles/windows.json",
}
PORTABLE_FILENAME = "Genesis-Portable.ps1"
DEFAULT_ARCHIVE = "dist/genesis.zip"
DEFAULT_PORTABLE = PORTABLE_FILENAME
DEFAULT_MANIFEST = "public-manifest.json"


def _public_path(source: Path, relative: str) -> Path:
    source = source.resolve()
    path = source / relative
    if any(parent.is_symlink() for parent in (path, *path.parents) if parent != source):
        raise ValueError(f"Lien symbolique interdit dans le paquet : {relative}")
    if not path.resolve().is_relative_to(source):
        raise ValueError(f"Fichier hors du repertoire source : {relative}")
    return path


def _read_utf8(source: Path, relative: str) -> str:
    return _public_path(source, relative).read_text(encoding="utf-8-sig")


def _flatten_module(source: Path) -> str:
    """Retourne le code du module sans chargement de fichiers externes."""
    core = _read_utf8(source, "modules/Genesis/Genesis.psm1")
    for statement in (
        ". (Join-Path $PSScriptRoot 'Customization.ps1')",
        ". (Join-Path $PSScriptRoot 'Progress.ps1')",
    ):
        if statement not in core:
            raise ValueError(f"Instruction de module introuvable : {statement}")
        core = core.replace(statement, "")
    core, count = re.subn(
        r"(?ms)^\s*Export-ModuleMember -Function .*?\r?\n?$",
        "",
        core,
        count=1,
    )
    if count != 1:
        raise ValueError("Export-ModuleMember introuvable dans le module Genesis")
    return core.strip() + "\n"


def build_portable_script(source: Path) -> bytes:
    """Construit le script unique qui embarque le code et les profils publics."""
    source = source.resolve()
    profiles: dict[str, str] = {}
    for profile_id, relative in PORTABLE_PROFILE_FILES.items():
        profiles[profile_id] = _read_utf8(source, relative).strip()
        if "@'" in profiles[profile_id] or "'@" in profiles[profile_id]:
            raise ValueError(f"Profil incompatible avec le here-string PowerShell : {relative}")

    profile_blocks = []
    for profile_id, content in profiles.items():
        profile_blocks.append(
            f"    {profile_id} = ConvertFrom-Json -InputObject @'\n{content}\n'@"
        )
    header = """#requires -Version 5.1
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
        'ConfirmTaskbar', 'ContinueUpdates', 'UpdateWorker'
    )]
    [string]$Action = 'Menu',
    [ValidateSet('base', 'windows')]
    [string]$ProfileId = 'windows',
    [string]$ProfilePath,
    [string]$DataRoot,
    [string]$RunId,
    [ValidateSet('Quality', 'Feature')]
    [string]$UpdateScope = 'Quality'
)

$ErrorActionPreference = 'Stop'
$script:GenesisEmbeddedProfiles = @{
__PROFILE_BLOCKS__
}

""".replace("__PROFILE_BLOCKS__", "\n".join(profile_blocks))
    dispatch = r"""
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
    'UpdateWorker' {
        $worker = Invoke-GenesisUpdateWorker -RunId $RunId -DataRoot $DataRoot -Scope $UpdateScope
        $worker | ConvertTo-Json -Depth 8
    }
}
"""
    content = header + _flatten_module(source)
    content += _read_utf8(source, "modules/Genesis/Customization.ps1").strip() + "\n"
    content += _read_utf8(source, "modules/Genesis/Progress.ps1").strip() + "\n"
    content += dispatch.lstrip()
    return content.encode("utf-8-sig")


def write_portable_script(source: Path, output: Path) -> Path:
    if output.suffix.lower() != ".ps1":
        raise ValueError("Le livrable portable doit avoir une extension .ps1")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(build_portable_script(source))
    return output


def get_version(source: Path) -> str:
    manifest = _read_utf8(source, "modules/Genesis/Genesis.psd1")
    match = re.search(r"ModuleVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'", manifest)
    if match is None:
        raise ValueError("Version de Genesis introuvable")
    return match[1]


def write_public_manifest(source: Path, output: Path) -> Path:
    manifest = {
        "schemaVersion": 1,
        "version": get_version(source),
        "sha256": {PORTABLE_FILENAME: hashlib.sha256(build_portable_script(source)).hexdigest()},
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output


def build_package(source: Path, output: Path, *, include_portable: bool = False) -> Path:
    """Inclut uniquement les fichiers explicitement autorises pour la livraison."""
    source = source.resolve()
    entries: dict[str, bytes] = {}
    for name in RELEASE_FILES:
        entries[name] = _public_path(source, name).read_bytes()
    if include_portable:
        entries[PORTABLE_FILENAME] = build_portable_script(source)
    manifest = {
        "schemaVersion": 1,
        "version": get_version(source) if include_portable else None,
        "sha256": {name: hashlib.sha256(data).hexdigest() for name, data in entries.items()},
    }
    entries["manifest.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    if output.suffix.lower() != ".zip":
        raise ValueError("Le paquet doit avoir une extension .zip")
    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            entry = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, default=Path(DEFAULT_ARCHIVE))
    parser.add_argument("--manifest-output", type=Path, default=Path(DEFAULT_MANIFEST))
    parser.add_argument(
        "--portable-output",
        type=Path,
        default=Path(DEFAULT_PORTABLE),
    )
    arguments = parser.parse_args()
    print(write_portable_script(arguments.source, arguments.portable_output))
    print(write_public_manifest(arguments.source, arguments.manifest_output))
    print(build_package(arguments.source, arguments.output, include_portable=True))


if __name__ == "__main__":
    main()
