"""Controle la liste blanche et les donnees interdites avant publication publique."""

import argparse
import ipaddress
import re
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

PUBLIC_SOURCE_FILES = (
    ".editorconfig",
    ".gitattributes",
    ".gitignore",
    ".github/workflows/validate.yml",
    "CHANGELOG.md",
    "Genesis.ps1",
    "install.ps1",
    "PSScriptAnalyzerSettings.psd1",
    "README.md",
    "modules/Genesis/Genesis.psd1",
    "modules/Genesis/Genesis.psm1",
    "modules/Genesis/Customization.ps1",
    "modules/Genesis/Progress.ps1",
    "profiles/base.json",
    "profiles/windows.json",
    "pyproject.toml",
    "requirements-dev.txt",
    "scripts/Test-Genesis.ps1",
    "tests/Bootstrap.Tests.ps1",
    "tests/Customization.Tests.ps1",
    "tests/Genesis.Tests.ps1",
    "tests/test_audit_public.py",
    "tests/test_package_genesis.py",
    "tools/audit_public.py",
    "tools/package_genesis.py",
)
PUBLIC_FILES = (*PUBLIC_SOURCE_FILES, "Genesis-Portable.ps1", "public-manifest.json")
PUBLIC_HOSTS = {
    "api.github.com",
    "github.com",
    "raw.githubusercontent.com",
    "download.microsoft.com",
    "www.microsoft.com",
    "learn.microsoft.com",
    "support.microsoft.com",
    "schemas.microsoft.com",
    "dl.google.com",
    "www.google.com",
    "support.google.com",
    "download.mozilla.org",
    "firefox-source-docs.mozilla.org",
    "pkgs.netbird.io",
    "pester.dev",
    "example.com",
    "example.invalid",
}
DOCUMENTATION_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")
)
TOKEN = re.compile(
    r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}"
    r"|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,})\b"
)
PRIVATE_KEY = re.compile(r"-{5}BEGIN [A-Z ]*PRIVATE KEY-{5}")
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
URL = re.compile(r"https?://[^\s\x27\x22<>`){}]+")


def audit_paths(paths: tuple[str, ...] | list[str]) -> list[str]:
    return [f"Fichier non autorise : {name}" for name in paths if name not in PUBLIC_FILES]


def audit_text(name: str, content: str) -> list[str]:
    problems = []
    for lineno, line in enumerate(content.splitlines(), 1):
        prefix = f"{name}:{lineno}"
        if PRIVATE_KEY.search(line) or TOKEN.search(line):
            problems.append(f"{prefix} : cle privee ou token")
        for match in IPV4.finditer(line):
            if re.search(
                r"-(?:MinimumVersion|MaximumVersion|RequiredVersion)\s+$", line[: match.start()]
            ):
                continue
            try:
                address = ipaddress.ip_address(match[0])
            except ValueError:
                continue  # Une version logicielle peut ressembler a une adresse.
            if not any(address in network for network in DOCUMENTATION_NETWORKS):
                problems.append(f"{prefix} : adresse IP hors des plages documentaires")
        for match in URL.finditer(line):
            try:
                uri = urlsplit(match[0])
                host = uri.hostname or ""
            except ValueError:
                problems.append(f"{prefix} : URL invalide")
                continue
            if uri.username is not None or uri.password is not None:
                problems.append(f"{prefix} : identifiants dans une URL")
            if re.search(r"(?i)(?:token|password|secret|key)=", uri.query):
                problems.append(f"{prefix} : parametre sensible dans une URL")
            if host and host != "..." and host not in PUBLIC_HOSTS and not host.endswith(
                (".test", ".example", ".example.invalid")
            ):
                problems.append(f"{prefix} : serveur non autorise")
    return problems


def audit_tree(root: Path) -> list[str]:
    problems = []
    for name in PUBLIC_FILES:
        path = root / name
        if any(parent.is_symlink() for parent in (path, *path.parents) if parent != root):
            problems.append(f"Lien symbolique interdit : {name}")
        elif not path.is_file():
            problems.append(f"Fichier public manquant : {name}")
        else:
            problems.extend(audit_text(name, path.read_text(encoding="utf-8-sig")))
    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--staged", action="store_true", help="Controle aussi tout l'index Git")
    arguments = parser.parse_args()
    root = arguments.source.resolve()
    problems = audit_tree(root)
    if arguments.staged:
        result = subprocess.run(
            ["git", "ls-files", "--cached", "-z"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        paths = [name for name in result.stdout.split("\0") if name]
        problems.extend(audit_paths(paths))
        for name in paths:
            staged = subprocess.run(
                ["git", "show", f":{name}"], cwd=root, check=True, capture_output=True
            )
            problems.extend(audit_text(name, staged.stdout.decode("utf-8-sig")))
            if staged.stdout != (root / name).read_bytes():
                problems.append(f"Index different de la version controlee : {name}")
    if problems:
        raise SystemExit("\n".join(problems))
    print(f"Audit public : {len(PUBLIC_FILES)} fichiers autorises, aucun signal detecte.")


if __name__ == "__main__":
    main()
