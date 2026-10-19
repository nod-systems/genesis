# Genesis

Outil PowerShell de préparation Windows, avec menu de sélection, progression,
inventaire local, sauvegardes et retour arrière des réglages compatibles.
Version actuelle : **0.5.20**.

## Démarrer depuis Internet

Ouvrir PowerShell dans la session du compte à préparer et exécuter :

```powershell
irm https://raw.githubusercontent.com/nod-systems/genesis/main/install.ps1 | iex
```

Le lanceur récupère le dernier commit de `main`, télécharge le programme portable
et son manifeste depuis ce même commit, puis vérifie son empreinte SHA-256.
Il ouvre Windows PowerShell avec une demande UAC lorsque les droits
administrateur sont nécessaires. Le menu Genesis apparaît directement ; choisir
les opérations avant de lancer une préparation.

Aucun compte GitHub, Python, Git, ZIP à extraire ou module PowerShell à installer
n'est nécessaire sur le poste. Internet doit permettre l'accès à GitHub et aux
sources des logiciels choisis. Windows PowerShell 5.1 et .NET sont requis.
Les réglages ciblent principalement Windows 11 Pro et Famille ; les installateurs
x64 ne constituent pas une validation sur ARM64 ou sur Windows 32 bits.

L'empreinte vérifie la cohérence des fichiers publiés. Le dépôt GitHub est la
source de confiance du lanceur ; les installateurs téléchargés (Office, Chrome,
Firefox, PDFCraft, NetBird) ont aussi la signature de leur éditeur vérifiée avant
exécution. Les stratégies de sécurité de l'organisation restent applicables.

## Téléchargement manuel

Télécharger [Genesis-Portable.ps1](https://raw.githubusercontent.com/nod-systems/genesis/main/Genesis-Portable.ps1)
et ouvrir une fenêtre Windows PowerShell en administrateur :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Genesis-Portable.ps1
```

Ce fichier unique contient le programme et les deux profils publics. Pour
consulter un plan sans appliquer de réglage :

```powershell
.\Genesis-Portable.ps1 -Action Plan -ProfileId windows
.\Genesis-Portable.ps1 -Action Plan -ProfileId base
```

## Opérations disponibles

| Opération | Comportement |
| --- | --- |
| Windows Update | Rechercher et installer les mises à jour, les mises à jour facultatives et les pilotes proposés ; aucun redémarrage forcé |
| Mise à niveau Windows | Installer la nouvelle version proposée par Windows Update (ex. 26H2) ; décochée par défaut, à choisir explicitement |
| Explorateur | Ouvrir sur Ce PC |
| Suggestions Windows | Masquer les conseils et propositions de finalisation |
| Notification | Afficher les icônes déjà enregistrées dans la session |
| Barre des tâches | Masquer Recherche, Widgets et Vue des tâches |
| Heure | Synchroniser Windows Time en respectant le serveur horaire et les paramètres de domaine existants |
| Office LTSC 2024 | Récupérer ODT depuis Microsoft, vérifier ses signatures et installer Standard 2024 en français depuis le CDN Microsoft ; aucune clé ni activation intégrée |
| Navigateur | Installer Chrome ou Firefox depuis leurs sources officielles et préparer l'association par défaut |
| PDF | Installer Acrobat Reader, SumatraPDF ou PDFCraft et préparer l'association par défaut |
| Outlook classique | Proposer le réglage AutoDiscover qui exclut le point de terminaison Microsoft 365 |
| Veille secteur | Désactiver la veille lorsque le poste est branché |
| Compte local | Demander un nom et un mot de passe dans la console et créer un compte standard ; le mot de passe n'est pas journalisé |
| NetBird | Installer le client officiel et demander son serveur au lancement ; aucun serveur ni secret préconfiguré, aucune connexion automatique |
| Épingles | Préparer Explorateur, Word, Excel, PowerPoint et Outlook classique lorsqu'Office est présent |
| Debloat | Afficher les programmes installés, laisser le technicien sélectionner les désinstallations et vérifier leur résultat |
| Imprimantes réseau | Découvrir les imprimantes WSD, proposer leur ajout et ouvrir une recherche de pilote à la demande |

La checklist sépare l'état constaté (`Fait`) de la sélection à exécuter (`Sel.`).
Utiliser les flèches, `Espace`, `Entrée` et `Échap`. Les navigateurs et lecteurs PDF
forment des groupes de choix exclusifs.

Windows peut demander une validation manuelle pour les applications par défaut,
Widgets et les épingles. Ces opérations restent **À vérifier** ou **À faire** tant
que leur résultat n'a pas été confirmé. Office affiche ses conditions de licence
à l'installation ; la licence et l'activation sont à fournir séparément.
L'exclusion du point de terminaison Microsoft 365 dans Outlook est une option
pour les environnements concernés ; la sélectionner selon la messagerie utilisée.

Les réglages de session portent sur le compte qui exécute Genesis. En cas
d'élévation avec les identifiants d'un autre administrateur, ils portent sur ce
compte administrateur. Une reconnexion peut être nécessaire.

## Reprise et retour arrière

Les journaux, inventaires et sauvegardes restent sur le poste, sous
`C:\ProgramData\Genesis`. Ils peuvent contenir des informations propres à ce
poste et doivent être conservés comme données privées. Genesis n'envoie aucun
inventaire à un service de collecte.

Chaque préparation possède un `RunId`. Après un redémarrage demandé par Windows,
relancer le programme puis reprendre avec cet identifiant :

```powershell
.\Genesis-Portable.ps1 -Action Status -RunId IDENTIFIANT
.\Genesis-Portable.ps1 -Action Resume -RunId IDENTIFIANT
.\Genesis-Portable.ps1 -Action Undo -RunId IDENTIFIANT
.\Genesis-Portable.ps1 -Action ConfirmTaskbar -RunId IDENTIFIANT
```

Quand Windows Update demande un redémarrage à la fin d'une préparation lancée
depuis le menu, Genesis propose de redémarrer et de poursuivre automatiquement.
Une tâche planifiée `Genesis - reprise Windows Update`, exécutée par SYSTEM au
démarrage, relance alors uniquement Windows Update et, si elle est sélectionnée, la mise à niveau de version, depuis une copie du programme
dans `C:\ProgramData\Genesis\bin`, sans ouverture de session. Elle redémarre
le poste tant que des mises à jour restent proposées, au plus 8 fois, puis se
supprime et prévient les sessions ouvertes. Elle s'arrête aussi en cas d'échec
ou si la préparation a été restaurée entre-temps.

Le menu Reverse affiche les préparations restaurables. Les sauvegardes sont
liées à la machine, au compte et à la version de Genesis qui les a créées.
La restauration conserve les modifications faites entre-temps par l'utilisateur
et signale les conflits. Elle restaure les réglages sauvegardés, mais ne
réinstalle pas un logiciel désinstallé et ne désinstalle pas un logiciel ajouté.
L'heure corrigée reste correcte après restauration de la configuration horaire.

## Sources et développement

Le dépôt contient uniquement les sources actuelles, des profils génériques,
des tests avec données fictives, le lanceur et le programme portable généré.
Aucun diagnostic réel, profil client, accès distant, clé privée ou résultat de
préparation ne fait partie de la livraison publique.

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q
.venv/bin/ruff check .
.venv/bin/python tools/package_genesis.py
.venv/bin/python tools/audit_public.py --staged
git diff --check
```

Le packaging produit `Genesis-Portable.ps1`, `public-manifest.json` et
`dist/genesis.zip`. Le ZIP utilise une liste blanche et un manifeste SHA-256.
Le portable et son manifeste doivent être régénérés ensemble à chaque changement
des sources. Le contrôle de publication refuse les fichiers hors liste blanche,
les liens symboliques, les clés privées, les tokens reconnus, les adresses IP
hors plages documentaires et les URL hors sources autorisées. Ce contrôle
complète la revue du code et doit précéder toute publication.

Sous Windows PowerShell 5.1 :

```powershell
Install-Module Pester -RequiredVersion 5.9.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
.\scripts\Test-Genesis.ps1
```

L'intégration continue vérifie Python, Ruff, la génération du portable, l'audit
public, la syntaxe PowerShell 5.1, PSScriptAnalyzer et les tests Pester sous
Windows. Sous PowerShell sur Linux, les tests dépendant des API Windows sont
exclus explicitement. Les fichiers PowerShell contenant du texte français sont
encodés en UTF-8 avec BOM pour Windows PowerShell 5.1.

Références : [déploiement Office LTSC](https://learn.microsoft.com/en-us/office/ltsc/2024/deploy),
[épingles Windows](https://learn.microsoft.com/en-us/windows/configuration/taskbar/pinned-apps),
[Windows Time](https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings),
[PDFCraft](https://github.com/storytold/pdfcraft),
[Pester](https://pester.dev/docs/v5/introduction/installation),
[PSScriptAnalyzer](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/overview).
