# Historique des versions

## 1.1.0

- Nouvelle opération **Capture FOG** (`fog-capture`), décochée par défaut :
  nettoyage, Sysprep, programmation de la capture par l'API FOG et
  redémarrage réseau unique ; serveur, clés et image demandés au lancement,
  clés chiffrées pour le poste et jamais journalisées.
- Progression affichée en tableau : une ligne par opération, avec état et
  pourcentage mis à jour sur place.
- Office : la recherche du lien ODT ne plante plus sur les liens sans `href`
  de la page Microsoft.
- Windows Update et la mise à niveau s'exécutent en dernier ; la mise à niveau
  attend le redémarrage quand les correctifs en demandent un.
- Redémarrage automatique (60 s, annulable par `shutdown /a`) puis reprise au
  démarrage, sans question au technicien.
- Libellé plus clair pour la veille sur secteur : « Mise en veille sur secteur : Jamais ».
- Nouvelle opération **Nettoyer le menu Démarrer** (`start-cleanup`) : désinstalle
  Outlook (new), Xbox, Solitaire, WhatsApp et LinkedIn, y compris leurs épingles
  « à installer » du menu Démarrer.
- Nouvelle opération **Barre des tâches à gauche** (`taskbar-left`) : alignement à
  gauche et retrait des épingles Edge et Microsoft Store.
- Nouveau choix de menu **Désinstaller Genesis** : supprime toutes les traces de
  Genesis sur le poste après confirmation, sans défaire les personnalisations.

### À savoir pour la mise à jour

Les sauvegardes et les reprises sont liées à la version de Genesis : une
préparation faite avec la 1.0.0 ne peut pas être reprise ni restaurée avec la
1.1.0. Terminer ou restaurer les préparations en cours avant de mettre à jour.

## 1.0.0

Première version stable de Genesis.

### Mises à jour Windows

- Les mises à jour facultatives sont recherchées
  (`DeploymentAction='OptionalInstallation'`) : les mises à niveau de version
  comme la 26H2 n'étaient pas vues.
- Nouvelle opération **Mise à niveau Windows** (`windows-feature-update`),
  séparée des correctifs et décochée par défaut dans la checklist.
- Reprise après redémarrage : quand Windows Update demande un redémarrage,
  Genesis propose de redémarrer puis une tâche planifiée SYSTEM
  `Genesis - reprise Windows Update` poursuit les mises à jour au démarrage,
  sans ouverture de session. Au plus 8 redémarrages ; la tâche se supprime à
  la fin, en cas d'échec ou si la préparation a été restaurée.

### Sécurité

- `C:\ProgramData\Genesis` est protégé à chaque prise du verrou : propriétaire
  Administrateurs, droits limités à SYSTEM et aux administrateurs, refus des
  liens et jonctions, même si le dossier existait avant Genesis.
- Les installateurs téléchargés sont exécutés seulement après vérification de
  la signature de leur éditeur : Google LLC (Chrome), Mozilla Corporation
  (Firefox), NetBird GmbH, Learning Machines Inc (PDFCraft) et Microsoft
  Corporation (Office), y compris pour un installateur déjà en cache.
- Les tâches SYSTEM exécutent uniquement une copie du programme placée dans
  `C:\ProgramData\Genesis\bin`, jamais la copie temporaire du lanceur.

### Corrections

- Acrobat Reader 64 bits est détecté (`Acrobat DC\Acrobat\Acrobat.exe`).
- Les codes winget « déjà installé » et « aucune mise à jour applicable » sont
  traités comme une réussite.
- Le journal Debloat est écrit dans le répertoire de données par défaut.

### À savoir pour la mise à jour

Les sauvegardes sont liées à la version de Genesis qui les a créées : les
préparations faites avec une version 0.5.x ne peuvent pas être restaurées avec
la 1.0.0. Une tâche de reprise programmée par une version antérieure s'arrête
d'elle-même au démarrage suivant.

Validé sur Windows 11 Pro 25H2 et 26H2 : syntaxe Windows PowerShell 5.1,
PSScriptAnalyzer, tests Pester, reprise réelle après redémarrage et passage
réel de 25H2 à 26H2 par la tâche SYSTEM.
