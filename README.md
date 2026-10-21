# Genesis

Outil PowerShell de préparation Windows, avec menu de sélection, progression,
inventaire local, sauvegardes et retour arrière des réglages compatibles.
Version actuelle : **1.1.0** ([historique des versions](CHANGELOG.md)).

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
| Explorateur | Ouvrir sur Ce PC |
| Suggestions Windows | Masquer les conseils et propositions de finalisation |
| Notification | Afficher les icônes déjà enregistrées dans la session |
| Barre des tâches | Masquer Recherche, Widgets et Vue des tâches |
| Barre à gauche | Aligner la barre des tâches à gauche et retirer les épingles Edge et Microsoft Store ; Reverse rétablit l'alignement |
| Menu Démarrer | Désinstaller Outlook (new), Xbox, Solitaire, WhatsApp et LinkedIn et les retirer des nouveaux comptes ; non réversible |
| Heure | Synchroniser Windows Time en respectant le serveur horaire et les paramètres de domaine existants |
| Office LTSC 2024 | Récupérer ODT depuis Microsoft, vérifier ses signatures et installer Standard 2024 en français depuis le CDN Microsoft ; aucune clé ni activation intégrée |
| Navigateur | Installer Chrome ou Firefox depuis leurs sources officielles et préparer l'association par défaut |
| PDF | Installer Acrobat Reader, SumatraPDF ou PDFCraft et préparer l'association par défaut |
| Outlook classique | Proposer le réglage AutoDiscover qui exclut le point de terminaison Microsoft 365 |
| Veille secteur | Régler la mise en veille sur secteur sur « Jamais » ; Reverse restaure le délai initial |
| Compte local | Demander un nom et un mot de passe dans la console et créer un compte standard ; le mot de passe n'est pas journalisé |
| NetBird | Installer le client officiel et demander son serveur au lancement ; aucun serveur ni secret préconfiguré, aucune connexion automatique |
| Windows Update | Rechercher et installer les mises à jour, les mises à jour facultatives et les pilotes proposés ; exécuté en dernier, redémarre et reprend seul si Windows le demande |
| Mise à niveau Windows | Installer la nouvelle version proposée par Windows Update (ex. 26H2) après les correctifs ; décochée par défaut, à choisir explicitement |
| Capture FOG | Nettoyer et généraliser Windows (Sysprep), programmer la capture dans FOG puis redémarrer sur le réseau ; décochée par défaut, voir plus bas |
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

Chaque préparation possède un `RunId`. Windows Update reprend seul après
redémarrage (voir plus bas). Pour consulter, reprendre manuellement ou restaurer
une préparation, utiliser cet identifiant :

```powershell
.\Genesis-Portable.ps1 -Action Status -RunId IDENTIFIANT
.\Genesis-Portable.ps1 -Action Resume -RunId IDENTIFIANT
.\Genesis-Portable.ps1 -Action Undo -RunId IDENTIFIANT
.\Genesis-Portable.ps1 -Action ConfirmTaskbar -RunId IDENTIFIANT
```

Windows Update et la mise à niveau s'exécutent après toutes les autres opérations.
Quand Windows Update demande un redémarrage à la fin d'une préparation lancée
depuis le menu, Genesis redémarre le poste après 60 secondes, sans question
(`shutdown /a` annule ce redémarrage ; la reprise aura lieu au prochain démarrage).
Une tâche planifiée `Genesis - reprise Windows Update`, exécutée par SYSTEM au
démarrage, relance alors uniquement Windows Update et, si elle est sélectionnée, la mise à niveau de version, depuis une copie du programme
dans `C:\ProgramData\Genesis\bin`, sans ouverture de session. Elle redémarre
le poste tant que des mises à jour restent proposées, au plus 8 fois, puis se
supprime et prévient les sessions ouvertes. Elle s'arrête aussi en cas d'échec
ou si la préparation a été restaurée entre-temps.

Le menu **Désinstaller Genesis** supprime toutes les traces de Genesis : `C:\ProgramData\Genesis`
(préparations, sauvegardes, installeurs, journaux), la tâche de reprise Windows Update,
les dossiers `%LOCALAPPDATA%\Genesis` des profils, la stratégie de barre des tâches qui
pointe vers Genesis et le programme lancé (sauf depuis une clé USB). Les personnalisations,
logiciels et comptes créés restent en place ; Reverse n'est plus possible ensuite.

Le menu Reverse affiche les préparations restaurables. Les sauvegardes sont
liées à la machine, au compte et à la version de Genesis qui les a créées.
La restauration conserve les modifications faites entre-temps par l'utilisateur
et signale les conflits. Elle restaure les réglages sauvegardés, mais ne
réinstalle pas un logiciel désinstallé et ne désinstalle pas un logiciel ajouté.
L'heure corrigée reste correcte après restauration de la configuration horaire.

## Capture FOG

L'opération **Capture FOG** transforme le poste préparé en image de référence
pour un serveur [FOG](https://github.com/FOGProject/fogproject) du réseau local.
FOG ne capture pas un Windows en marche : Genesis prépare le poste, programme
la capture par l'API FOG, puis le poste redémarre une fois sur le réseau (PXE)
et FOG envoie le disque sur le serveur.

Prérequis côté FOG :

- API activée (*FOG Configuration > FOG Settings > API System*) ; noter la clé
  API FOG et la clé API de l'utilisateur (*User Management > API Settings*) ;
- une image dans *Image Management* : si le nom saisi n'existe pas, Genesis
  propose de la créer (Windows, *Single Disk - Resizable*, toutes les
  partitions, groupe de stockage par défaut) ; chaque capture remplace son contenu ;
- démarrage PXE fonctionnel vers ce serveur, poste branché en câble (pas en Wi-Fi).

Au lancement, Genesis demande l'adresse du serveur, les deux clés et le nom de
l'image, vérifie qu'il joint FOG et que l'image existe (ou la crée), puis demande une
confirmation. Les clés ne sont jamais écrites dans `state.json` : elles sont
chiffrées pour ce poste (DPAPI machine) et effacées dès que la capture est programmée.

La capture passe après toutes les autres opérations, y compris Windows Update et
ses redémarrages : si la reprise automatique tourne au démarrage, elle lance
aussi la capture. Elle attend tant qu'une opération est en échec. Déroulement :

1. contrôles sans risque : connexion câblée, entrée de démarrage réseau UEFI,
   serveur FOG, image ; le poste est enregistré dans FOG par son adresse MAC
   (ou retrouvé) et associé à l'image ;
2. nettoyage : déchiffrement BitLocker du disque système (attendu jusqu'au bout),
   veille prolongée désactivée, identité NetBird retirée, applications du Store
   installées pour un compte sans être provisionnées retirées (elles bloquent Sysprep) ;
3. `sysprep /generalize /oobe /quit`, puis vérification que Windows est bien généralisé ;
4. création de la tâche de capture dans FOG et démarrage réseau forcé pour le
   prochain démarrage uniquement ;
5. suppression des traces de Genesis (comme **Désinstaller Genesis**) et
   redémarrage après 15 secondes.

Si Sysprep échoue, rien n'est programmé dans FOG et le motif (extrait de
`setuperr.log`) s'affiche. Si FOG refuse la tâche après Sysprep, ne pas
redémarrer sur Windows : créer la tâche *Capture* dans FOG pour ce poste puis
démarrer sur le réseau.

Limites à connaître :

- Sysprep peut refuser un Windows mis à niveau sur place : Genesis le détecte,
  ne programme rien et affiche le motif ; pour une image de production, capturer
  un poste installé directement dans la version voulue ;
- le démarrage réseau automatique exige un poste UEFI avec une entrée PXE
  visible ; sinon l'opération s'arrête avant toute modification ;
- les réglages de session (barre des tâches, Explorateur, etc.) restent sur les
  comptes déjà présents dans l'image ; les comptes créés au déploiement partent
  du profil par défaut de Windows ;
- les comptes locaux, logiciels et réglages machine font partie de l'image.

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
