# SECOTO — Audit technique : envoi des photos d'état des lieux & fin de mission

Date : 02/09/2026 · Périmètre : `src/App.jsx`, `src/lib/*`, `src/platform/runtime.js`,
`supabase/migrations/202607260002_transactional_api.sql`, `202607260003_rls_storage_lockdown.sql`,
`202608290021_pilotage_manuel_missions.sql`.
**Aucune modification n'a été commitée. Ce document est une liste de décisions à prendre.**

---

## 1. Ce qui casse aujourd'hui

### A. Blocages durs — l'envoi échoue réellement

**A1 — Le pilotage manuel admin (021) casse le parcours terrain du transporteur. ⛔ Le plus grave.**

`secoto_finalize_tracking_event` (migration 0002, l.347+) impose une séquence rigide :

- `missions.status` doit valoir **exactement** `assigned` ;
- prise en charge : `progress_status` doit valoir **exactement** `assigned_pending` et aucun event `pickup_inspection` ne doit exister ;
- incident **et livraison** : un event `pickup_inspection` doit exister en base.

Or `secoto_admin_set_mission_stage` (021, l.455-496) laisse l'admin écrire librement `status` et
`progress_status`, **sans créer d'event de suivi**. Conséquences immédiates :

| Geste admin | Ce que vit le transporteur |
|---|---|
| L'admin passe l'étape à « prise en charge faite » | Impossible de valider la livraison : *« La prise en charge doit etre finalisee en premier. »* — impasse définitive |
| L'admin passe l'étape à autre chose que `assigned_pending` | *« Prise en charge deja finalisee ou hors sequence. »* |
| L'admin clôture la mission (`status=completed`) | *« Mission terrain non autorisee. »* et, avant même le RPC, **l'upload Storage renvoie 403** |

Le 403 vient de `secoto_private.can_upload_tracking_file` (0003, l.176-192) qui exige aussi
`status = 'assigned'`. Le message affiché est le brut « Upload refusé (403). » : ni le transporteur
ni l'admin ne peuvent comprendre.

C'est la cause n°1 candidate du « l'app est dysfonctionnelle à l'envoi des états des lieux et à la fin de mission »,
et elle est apparue avec la 021 (29/08).

**Correctifs :**
1. `secoto_admin_set_mission_stage` doit créer un event de suivi *administratif* (`source='admin'`)
   quand elle avance l'étape, pour que la séquence serveur reste cohérente.
2. Assouplir la garde du RPC : accepter `status in ('assigned','in_progress')`, et pour la livraison
   accepter « pickup event **ou** `progress_status >= pickup_completed` ».
3. Ajouter une **remise en état** admin : « rouvrir la mission pour le transporteur » qui remet
   `status='assigned'` et l'étape cohérente.
4. Réécrire les 6 messages d'exception en français lisible et actionnable.

**A2 — Upload sans délai maximum ni annulation.**
`uploadOnce` (`src/lib/privateFiles.js`) ouvre un `XMLHttpRequest` **sans `xhr.timeout`**, et aucun
`AbortController` n'est branché depuis l'écran. En zone blanche, parking souterrain, ascenseur de
parking étagé — le quotidien d'un convoyeur — la requête reste pendante indéfiniment : le bouton reste
grisé (`actionLoading`), rien ne se passe, aucune sortie possible sauf tuer l'app. Et les fichiers
partent **en série** : jusqu'à 10 × 12 Mo.
**Correctif :** `xhr.timeout = 45000` + `ontimeout`, bouton « Annuler l'envoi », 2 uploads en parallèle,
progression par fichier (« photo 3/6 »).

**A3 — Des photos valides sont refusées.**
`isAllowedFile` (`src/lib/fileSafety.js`) exige que **le type MIME *et* l'extension du nom** soient
reconnus. Or beaucoup de fichiers issus des galeries Android arrivent avec un nom sans extension, et
iOS peut livrer du HEIC/HEIF. Résultat : *« format refusé (JPG, PNG, WebP) »* sur une photo
parfaitement valide. Le bucket refuse les mêmes MIME côté serveur (0003, l.36), sans conversion.
**Correctif :** ne valider que le MIME (l'extension est réparée par `safeFileName`), et **transcoder
systématiquement en JPEG via canvas** à la sélection — ce qui règle HEIC, l'orientation EXIF et le poids
d'un seul coup.

**A4 — La file d'attente hors-ligne ne se vide jamais.**
`resumePendingTrackingActions` (App.jsx l.3078-3110) : si la re-soumission échoue pour une raison
métier (séquence, droits, brouillon vidé), `submitTrackingEvent` renvoie `false` mais **l'entrée de la
file n'est jamais supprimée**. Aucun compteur de tentatives, aucun backoff, aucun plafond. Le bandeau
« envois en attente » reste à vie, et l'effet se relance à chaque variation de `pendingSyncCount` ou de
`missions.length`.
**Correctif :** compteur `attempts` + backoff exponentiel + abandon explicite après 5 essais avec une
entrée visible « échec — réessayer / supprimer ».

**A5 — `navigator.onLine` n'est pas fiable en WebView.**
Le test de la ligne 2977 renvoie souvent `true` sans connectivité réelle sur iOS : l'app part en upload
au lieu de mettre en file, et se prend le blocage A2. **Correctif :** utiliser `@capacitor/network`
(déjà dans l'écosystème Capacitor) et traiter tout timeout comme un cas hors-ligne.

### B. Performance — le vrai « ça rame / ça plante »

**B1 — Le brouillon chiffré ré-encode TOUTES les photos à chaque frappe. ⛔ Deuxième cause majeure.**
`updateTrackingForm` (App.jsx l.2909-2928) sauvegarde le formulaire complet 350 ms après chaque frappe.
`encodeValue` (`resilienceStore.js` l.79) lit alors l'`arrayBuffer` de **chaque photo**, la convertit en
base64 **de façon synchrone**, sérialise le tout en JSON puis chiffre en AES-GCM — sur le thread principal.
Avec 6 photos (≈ 10 Mo) cela fait ~14 Mo de base64 rechiffrés à chaque pause de saisie dans le champ
commentaire. Sur un Android milieu de gamme : gel de l'interface de plusieurs secondes, clavier qui
saute, et parfois plantage du WebView.
**Correctif :** dissocier le brouillon en deux enregistrements — le texte (quelques octets, sauvegardé à
chaque frappe) et les fichiers (une entrée par fichier, écrite **une seule fois** à l'ajout, référencée
par identifiant). Déporter base64/chiffrement dans un Web Worker.

**B2 — Compression insuffisante.** `compressEvidenceImage` ne se déclenche qu'au-dessus de **2 Mo** et
vise 2400 px. Une photo de 1,9 Mo passe telle quelle : 10 photos = 19 Mo à téléverser en 4G.
**Correctif :** compresser **toujours**, cible 1600 px / qualité 0,75 ≈ 250-400 Ko. Amplement suffisant
pour un état des lieux, et divise le temps d'envoi par 5 à 8.

**B3 — Pas de purge des brouillons.** Ils ne sont supprimés qu'en cas de succès. Aucun TTL, aucun
ramasse-miettes. Après quelques missions interrompues, le quota IndexedDB du WebView est atteint :
« la sauvegarde chiffrée a échoué », puis échecs en cascade.
**Correctif :** TTL 14 jours + purge des brouillons dont la mission est livrée ou annulée.

**B4 — URLs signées de 120 s pour toutes les photos.** `hydrateSignedFileUrls(..., 120)` (App.jsx
l.2306-2366) régénère une URL signée **par photo** à chaque `loadAllData`, jusqu'à 200 photos. Deux
conséquences : jusqu'à 200 appels réseau par rafraîchissement, et surtout **les vignettes cassent au bout
de 2 minutes** sur un écran admin laissé ouvert → « les photos ne s'affichent pas ».
**Correctif :** signer à la demande (au clic / à l'entrée dans le viewport), durée 15 min, et
re-signer automatiquement sur `onerror` de l'image.

**B5 — `limit(200)` global.** `mission_tracking_photos` est chargée triée par date décroissante, toutes
missions confondues. Au-delà de 200 photos sur le compte, les missions anciennes **paraissent** avoir
perdu leurs photos (elles sont bien en base).
**Correctif :** charger les photos par mission, à l'ouverture de la carte.

### C. Parcours terrain

**C1 — Les trois formulaires sont affichés en même temps, en permanence** (App.jsx l.4497-4499) :
« Prise en charge », « Incident », « Livraison ». Aucune notion d'étape côté interface, alors que le
serveur, lui, impose une séquence stricte. Le convoyeur peut donc remplir la livraison avant la prise en
charge (rejet serveur), et le formulaire de prise en charge **reste affiché après validation** (re-remplissage,
rejet). Vu du terrain : « l'app refuse mes photos ».
**Correctif :** une seule action possible à la fois, l'étape franchie bascule en ligne de timeline.

**C2 — Aucune reprise visible.** Pas d'écran « envois en attente » listant ce qui n'est pas parti, avec
Réessayer / Supprimer.

**C3 — Aucune checklist d'état des lieux.** La règle actuelle est « au moins une photo »
(`minFiles: 1`). Une seule photo floue vaut donc état des lieux contradictoire. Pour du transport de
véhicule, c'est le point faible juridique : en cas de litige dommage, c'est votre seule pièce.
**Correctif :** 6 prises guidées obligatoires — avant / arrière / côté gauche / côté droit / compteur /
intérieur-accessoires — avec gabarit à l'écran, plus les photos libres pour les réserves.

**C4 — Aucune signature client à l'enlèvement ni à la livraison.** Le composant `SignaturePad` existe
déjà (utilisé pour les documents, `MyDocumentsPanel.jsx`) mais n'est pas branché sur le terrain. Le PV de
livraison contradictoire signé est la pièce qui protège SECOTO ; aujourd'hui elle n'existe pas.

**C5 — Messages d'erreur métier internes.** Les exceptions SQL sont écrites sans accents et en langage
technique (« Prise en charge deja finalisee ou hors sequence. ») et `humanizeError` les affiche telles
quelles (code P0001). Le transporteur ne sait ni ce qui s'est passé, ni quoi faire.

**C6 — Ergonomie gants/soleil.** Boutons standards, progression globale seulement, pas de reprise
photo par photo. À revoir pour un usage debout, dehors, une main sur le véhicule.

### D. Angles morts côté ADMIN

- **D1** — L'admin ne peut ni corriger un état des lieux raté, ni ajouter/retirer une photo pour le compte du
  transporteur, ni rouvrir une étape proprement (le seul levier, 021, casse le terrain — cf. A1).
- **D2** — Aucun **dossier de preuve exportable** (PDF ou ZIP : photos horodatées, km, carburant, position,
  commentaires, signatures). C'est exactement ce qu'il faut envoyer à l'assurance ou au client en litige.
- **D3** — Aucune vue « missions bloquées » : attribuée depuis > 24 h sans prise en charge, prise en charge
  depuis > 12 h sans livraison, envoi en échec chez un transporteur.
- **D4** — Notification de livraison : elle part bien du RPC (`notify_admins` / `notify_one`) mais dépend de
  la chaîne push (`retry-push-outbox`) déjà identifiée comme fragile. À re-tester rôle par rôle.

---

## 2. Suivi en temps réel de la position des chauffeurs — mon avis

**Oui sur le principe, mais pas sous cette forme, et pas maintenant.**

### Pourquoi c'est justifié
Vous confiez à un tiers un bien de 5 000 à 150 000 €. Le suivi apporte : preuve de trajet en cas de
litige, ETA fiable pour le client, détection d'une immobilisation anormale, sécurité du convoyeur en cas
d'accident ou de panne, et surtout **la fin des appels « il est où ? »** — qui est aujourd'hui votre vrai
coût administratif caché.

### Ce que ça coûte vraiment (et que personne n'anticipe)
1. **Vous avez déclaré le contraire.** L'app affiche noir sur blanc « Aucun suivi en arrière-plan »
   (App.jsx l.3226) et vos fiches App Store / Play sont alignées dessus. Passer au suivi continu impose
   une nouvelle déclaration de confidentialité, une justification de *background location* auprès
   d'Apple (motif exigeant, refus fréquent si le suivi n'est pas visiblement au cœur de la fonction),
   `ACCESS_BACKGROUND_LOCATION` + service au premier plan sur Android, et le formulaire de déclaration
   Google Play. **Comptez une re-review complète des deux stores.**
2. **RGPD.** Géolocaliser des personnes pendant leur travail. Vos convoyeurs sont indépendants, donc hors
   du régime « salariés » de la CNIL, mais les mêmes principes s'appliquent : finalité limitée,
   minimisation, information préalable, base légale documentée (exécution du contrat), durée de
   conservation courte. Un suivi systématique de personnes appelle une **AIPD**.
3. **Batterie et data.** Un suivi mal réglé vide un téléphone en 4 h. Un convoyeur qui perd son téléphone
   en cours de mission, c'est une mission perdue.
4. **Acceptation.** C'est le point sous-estimé : des convoyeurs indépendants peuvent refuser de travailler
   avec vous s'ils se sentent pistés. Le cadrage compte autant que la technique.

### Le design que je recommande : « suivi de mission », pas « suivi de chauffeur »
- **Actif uniquement entre la validation de la prise en charge et la validation de la livraison.** Jamais
  avant, jamais après. Coupure automatique **garantie côté serveur** (rejet des points hors fenêtre).
- **Fréquence adaptative** : 1 point toutes les 2-3 min ou tous les 2 km en roulage, **rien à l'arrêt**.
- **Visibilité totale pour le convoyeur** : bandeau permanent dans l'app + notification persistante
  Android « Suivi de la mission SECOTO actif », et un bouton pour l'arrêter. L'arrêt est tracé et notifie
  l'admin — c'est bien plus solide juridiquement, et bien mieux accepté, qu'un suivi imposé.
- **Consentement au démarrage de mission** + clause dans le contrat de sous-traitance.
- **Cloisonnement** : l'admin voit la carte live et le rejeu du trajet ; le client voit **l'ETA et l'étape**,
  pas la position exacte (option activable mission par mission).
- **Conservation 60 jours** puis purge automatique, en ne gardant que le résumé (distance, durée, horaires).
  Gel en cas de litige déclaré.
- **Dégradé assumé** : permission refusée ⇒ la mission reste réalisable, avec position obligatoire aux
  deux étapes clés.

### Priorité : P2, pas P0
Un état des lieux qui ne part pas vous coûte plus cher aujourd'hui qu'un point GPS manquant. Réparez les
preuves terrain d'abord.

**Le gain intermédiaire à prendre tout de suite (P1, ~2 h de travail) :** la position ponctuelle est déjà
capturée (`getOneTimeLocation`) mais elle est **facultative**. La rendre **obligatoire et non modifiable**
sur la prise en charge et sur la livraison vous donne 80 % de la valeur juridique du GPS, sans aucune
permission d'arrière-plan et sans re-review des stores.

---

## 3. Plan d'action classé, de l'essentiel au facultatif

### P0 — Débloquant (l'app ne fait pas son métier sans ça)

| # | Action | Où | Effet |
|---|---|---|---|
| 1 | Réconcilier pilotage manuel admin ↔ séquence terrain (event admin + gardes assouplies + « rouvrir la mission ») | migration 0002 l.347+, 0003 l.176, 021 l.455 | Débloque les états des lieux et les fins de mission |
| 2 | Dissocier brouillon texte / fichiers, encodage en Web Worker | `resilienceStore.js`, App.jsx l.2909 | Supprime le gel de l'app pendant la saisie |
| 3 | Timeout 45 s + bouton Annuler + progression par fichier | `privateFiles.js`, `SecureFilePicker.jsx` | Plus d'app figée en zone blanche |
| 4 | Validation MIME seule + transcodage JPEG systématique à la sélection | `fileSafety.js` | Fin des « format refusé » injustifiés (HEIC, Android sans extension) |
| 5 | File d'attente : `attempts`, backoff, abandon explicite, écran « envois en attente » | App.jsx l.3078 | Fin du bandeau bloqué à vie |
| 6 | Interface séquentielle : une seule action terrain possible à la fois | App.jsx l.4497 | Fin des rejets serveur incompréhensibles |
| 7 | Réécrire les 6 messages d'erreur SQL en français lisible et actionnable | migration 0002 | L'utilisateur sait quoi faire |

### P1 — Fiabilité et valeur métier (dans la foulée)

| # | Action | Effet |
|---|---|---|
| 8 | Compression systématique 1600 px / ~350 Ko | Envois 5 à 8× plus rapides |
| 9 | URLs signées à la demande, 15 min, re-signature sur erreur d'image | Fin des vignettes cassées côté admin |
| 10 | Charger les photos **par mission** au lieu du `limit(200)` global | Fin des « photos disparues » sur les missions anciennes |
| 11 | **Checklist d'état des lieux en 6 prises guidées** (avant/arrière/G/D/compteur/intérieur) | Dossier de preuve réellement opposable |
| 12 | **Signature client à l'enlèvement et à la livraison** (`SignaturePad` déjà en place) | PV contradictoire — protection juridique n°1 |
| 13 | Position **obligatoire** sur prise en charge et livraison | 80 % de la valeur du GPS, sans permission background |
| 14 | Purge des brouillons (TTL 14 j + missions clôturées) | Fin des saturations IndexedDB |
| 15 | `@capacitor/network` à la place de `navigator.onLine` | Hors-ligne détecté correctement |
| 16 | Admin : correction d'un état des lieux (ajout/retrait de photo, réouverture d'étape) | L'admin cesse d'être bloqué |
| 17 | Admin : vue « missions bloquées » (seuils temporels) | Détection avant l'appel du client |
| 18 | Re-test des notifications rôle par rôle sur l'événement livraison | Le « livré » remonte vraiment |

### P2 — Différenciation (le vrai saut d'expérience)

| # | Action |
|---|---|
| 19 | **Suivi de mission géolocalisé** selon le cadrage de la partie 2 (carte admin + rejeu + ETA client) |
| 20 | **Dossier de preuve exportable** en PDF/ZIP horodaté (photos, km, carburant, position, signatures) |
| 21 | Lien de suivi public pour le client (jeton, sans compte) : étape + ETA + photos de livraison |
| 22 | Comparatif départ / arrivée côté à côté, avec surlignage des dommages ajoutés |
| 23 | Frais de mission (carburant, péage, train retour) saisis dans la foulée de la livraison, justificatif photo |
| 24 | Mode « une main » : boutons XL, retour haptique, mode contraste soleil |

### P3 — Facultatif / plus tard

| # | Action |
|---|---|
| 25 | Reconnaissance automatique de la plaque et du compteur (OCR) pour pré-remplir |
| 26 | Détection automatique des rayures par comparaison départ/arrivée |
| 27 | Scan du permis / de la carte grise à la prise en charge |
| 28 | Notation du convoyeur par le client après livraison |
| 29 | Chat mission (transporteur ↔ admin) intégré, en remplacement des SMS |
| 30 | Génération automatique de la lettre de voiture / CMR à partir de l'état des lieux |

---

## 4. Ce que je recommande de faire en premier, concrètement

Trois interventions, dans cet ordre, avant toute autre chose :

1. **P0-1** — c'est très probablement ce qui casse en production depuis la 021 du 29/08. À vérifier en
   base avant de coder : combien de missions ont un `progress_status` avancé **sans** event de suivi
   correspondant ? Ces missions-là sont aujourd'hui en impasse pour leur transporteur.
2. **P0-2 et P0-3** — le gel pendant la saisie et l'upload sans fin sont ce que le convoyeur ressent
   comme « l'app ne marche pas ».
3. **P1-11 et P1-12** — checklist + signature : c'est ce qui transforme SECOTO d'une app de suivi en
   une app qui vous protège en cas de litige. C'est aussi un argument commercial direct auprès des
   professionnels.

*Aucun code n'a été modifié, aucun commit n'a été fait.*
