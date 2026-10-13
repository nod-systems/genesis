import hashlib
import importlib.util
import json
from pathlib import Path
from zipfile import ZipFile

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "package_genesis", ROOT / "tools" / "package_genesis.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def make_source(root: Path) -> None:
    for name in MODULE.RELEASE_FILES:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("source fictive", encoding="utf-8")


def test_package_excludes_private_data_and_verifies_every_file(tmp_path):
    source = tmp_path / "source"
    make_source(source)
    for name in (".local/ssh/key", "data/client.json", "profiles/private.json"):
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("donnee fictive a exclure", encoding="utf-8")
    archive = MODULE.build_package(source, tmp_path / "release.zip")
    with ZipFile(archive) as package:
        assert set(package.namelist()) == {*MODULE.RELEASE_FILES, "manifest.json"}
        manifest = json.loads(package.read("manifest.json"))
        for name, digest in manifest["sha256"].items():
            assert hashlib.sha256(package.read(name)).hexdigest() == digest


def test_package_is_reproducible(tmp_path):
    source = tmp_path / "source"
    make_source(source)
    first = MODULE.build_package(source, tmp_path / "first.zip")
    second = MODULE.build_package(source, tmp_path / "second.zip")
    assert first.read_bytes() == second.read_bytes()


def test_package_rejects_a_symlink_to_private_data(tmp_path):
    source = tmp_path / "source"
    make_source(source)
    private = tmp_path / "private"
    private.write_text("fictif", encoding="utf-8")
    entry = source / MODULE.RELEASE_FILES[0]
    entry.unlink()
    entry.symlink_to(private)
    with pytest.raises(ValueError, match="symbolique"):
        MODULE.build_package(source, tmp_path / "release.zip")


def test_package_rejects_an_incomplete_release(tmp_path):
    with pytest.raises(FileNotFoundError):
        MODULE.build_package(tmp_path, tmp_path / "release.zip")


def test_portable_script_embeds_profiles_and_has_no_external_module_dependency():
    script = MODULE.build_portable_script(ROOT).decode("utf-8-sig")
    assert "GenesisEmbeddedProfiles" in script
    assert "ExcludeExplicitO365Endpoint" in script
    assert "Import-Module" not in script
    assert ". (Join-Path $PSScriptRoot 'Customization.ps1')" not in script
    assert ". (Join-Path $PSScriptRoot 'Progress.ps1')" not in script
    assert "modules/Genesis" not in script


def test_delivery_package_can_include_the_portable_script(tmp_path):
    archive = MODULE.build_package(ROOT, tmp_path / "delivery.zip", include_portable=True)
    with ZipFile(archive) as package:
        assert MODULE.PORTABLE_FILENAME in package.namelist()
        portable = package.read(MODULE.PORTABLE_FILENAME).decode("utf-8-sig")
        assert "GenesisEmbeddedProfiles" in portable
        assert "Import-Module" not in portable


def test_public_delivery_uses_stable_filenames():
    assert MODULE.PORTABLE_FILENAME == "Genesis-Portable.ps1"
    assert MODULE.DEFAULT_ARCHIVE == "dist/genesis.zip"
    assert MODULE.DEFAULT_PORTABLE == "Genesis-Portable.ps1"


def test_public_manifest_checks_the_exact_generated_script(tmp_path):
    output = tmp_path / "public-manifest.json"
    MODULE.write_public_manifest(ROOT, output)
    manifest = json.loads(output.read_text())
    assert manifest["schemaVersion"] == 1
    assert manifest["version"] == MODULE.get_version(ROOT)
    assert manifest["sha256"][MODULE.PORTABLE_FILENAME] == hashlib.sha256(
        MODULE.build_portable_script(ROOT)
    ).hexdigest()
