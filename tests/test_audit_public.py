import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("audit_public", ROOT / "tools/audit_public.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


@pytest.mark.parametrize(
    "name",
    [".local/ssh/id_ed25519", "profiles/private/site.json", "data/run.json", "old/source.ps1"],
)
def test_publication_rejects_files_outside_the_allowlist(name):
    assert MODULE.audit_paths([name])


def test_publication_allows_only_the_current_public_sources_and_artifacts():
    assert MODULE.audit_paths(MODULE.PUBLIC_FILES) == []


@pytest.mark.parametrize(
    "content",
    [
        "-" * 5 + "BEGIN OPENSSH PRIVATE KEY" + "-" * 5,
        "ghp_" + "a" * 36,
        "https" + "://admin:example-password@example.test/path",
        "https" + "://example.test/path?access_token=example",
        "address = '10.25." + "14.9'",
        "https" + "://customer-internal.invalid/control",
    ],
)
def test_publication_detects_credentials_network_addresses_and_unknown_servers(content):
    assert MODULE.audit_text("source.ps1", content)


def test_publication_accepts_documentation_addresses_and_official_sources():
    content = """
https://raw.githubusercontent.com/nod-systems/genesis/main/install.ps1
https://download.microsoft.com/download/example.exe
https://example.invalid/package.msi
https://management.example.test:443
192.0.2.50 198.51.100.10 203.0.113.75
"""
    assert MODULE.audit_text("source.ps1", content) == []


def test_publication_does_not_confuse_a_package_version_with_an_address():
    command = "Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force"
    assert MODULE.audit_text("validate.yml", command) == []


def test_publication_rejects_symlinks_even_to_an_allowed_file(tmp_path):
    for name in MODULE.PUBLIC_FILES:
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("public example", encoding="utf-8")
    path = tmp_path / "README.md"
    path.unlink()
    path.symlink_to(tmp_path / "Genesis.ps1")
    assert any("symbolique" in problem for problem in MODULE.audit_tree(tmp_path))
