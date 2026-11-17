# SECOTO — Guide pour les assistants de code (ChatGPT, Codex, Claude…)

Ce fichier dit tout ce qu'il faut savoir pour aider Nawfal (fondateur de SECOTO,
seul développeur) sans rien casser. Lis-le en entier avant toute modification.
Langue : **français**, toujours. Ton : direct, concret, chiffré, sans jargon inutile.

---

## 1. L'entreprise

- **SECOTO** : plateforme de coordination de transport de véhicules (auto, moto,
  utilitaire, France et Europe). SECOTO **ne transporte pas** : elle confie chaque
  course à un **transporteur partenaire indépendant validé par SECOTO** et se
  rémunère par sa **marge** (prix client − rémunération transporteur).
- Statut : **EI en franchise de TVA** — mention obligatoire « TVA non applicable,
  article 293 B du CGI ». Les prix affichés sont des prix finaux.
- Deux métiers :
  - **Convoyage** : un convoyeur conduit le véhicule (roulant, immatriculé, avec clé).
  - **Plateau** : camion VL (1-2 véhicules) ou PL porte-voitures (6-8 véhicules).
    Plateau « prestige » (camion fermé) : seulement les VL/PL approuvés par SECOTO.
- Rôles dans l'app : **client**, **transporteur** (types `convoyeur`, `vl`, `pl`),
  **admin** (Nawfal). Comptes de démonstration (vérification Apple) :
  `contact.secoto+demo-client@gmail.com`, `contact.secoto+demo-transporteur@gmail.com`
  (mots de passe : demander à Nawfal, ne jamais les écrire dans le code).
- Signature de tout message client : **« L'Équipe SECOTO »** — jamais un prénom.
  Bouton de contact futur du chatbot : « Parler à l'Équipe SECOTO ».

## 2. Règles métier en vigueur (ne pas les contredire)

- **Prix instantané, plus aucun devis manuel** (migration 105) : le barème calcule
  toujours un prix ; contraintes (+60 € client / +45 € transporteur), prestige +30 %,
  délai court +20 %, hors zone +30 %, Corse +30 %, marge minimale garantie.
- **Trois offres** (099) : Express, Standard (recommandée), Éco.
- **Règlement à l'arrivée** (100, interrupteur `reglement_arrivee` ALLUMÉ) :
  la carte est **enregistrée à 0 €** (Stripe SetupIntent) à la réservation, **rien
  n'est débité**, le débit a lieu **après la livraison**. Modes de règlement :
  carte, Klarna (particuliers seulement, voir § 9), virement, espèces
  (**1 000 € maximum**, payées au transporteur). `transport_orders.mode_reglement`,
  recopié dans `missions.payment_method` (synchronisé par la migration 111).
- **Téléphone ou e-mail demandé juste avant le prix** pour un visiteur sans compte (090).
- **Diffusion** (107) : chaque course part à **tous** les transporteurs du bon type
  (convoyage → convoyeurs ; plateau standard → VL + PL ; prestige → VL/PL approuvés),
  à condition d'être actifs, validés, documents en règle, sans marge impayée en retard.
  (Projet futur : l'offre Éco réservée aux PL — SQL prêt, pas activé.)
- **Missions manuelles** (101) : pastille URGENT ; plateau = le transporteur propose
  UN prix et UNE date ; convoyage = il accepte la date ou en propose une autre.
- **Relances automatiques** des devis non réservés : 2 h, 24 h, 72 h (106, corrigé en 109).
- **Notifications admin** (108) : « Nouvelle demande · client inscrit », « Réservation
  confirmée », « Nouveau contact devis » ; elles ouvrent l'écran « À la demande ».
- **Entonnoir anonyme** du formulaire (110) : table `entonnoir_etapes`, tableau dans
  Admin → À traiter.

## 3. Interdits absolus (sécurité et argent réel)

1. **Ne lance AUCUN prélèvement, débit, remboursement ou transfert Stripe réel.**
   Pas de script qui appelle Stripe en production. Tester uniquement avec des
   simulations (voir les tests existants qui simulent Stripe).
2. **Ne pousse jamais directement sur `main`.** Travaille sur une branche, ouvre une
   pull request ; Nawfal fusionne lui-même.
3. **N'écris jamais de secret** (clés Stripe, Supabase service_role, Resend, mots de
   passe) dans le code, un commit, un SQL ou une réponse.
4. **Ne supprime ni ne modifie de données de production** sans montrer d'abord un
   SQL de vérification (`select …`) et attendre l'accord explicite de Nawfal.
5. **N'invente aucune garantie, assurance, contrôle ou délai** dans les textes
   clients (pas de « assuré », « garanti » non vérifié). Les transporteurs sont
   « validés par SECOTO », pas « assurés par SECOTO ».
6. Ne publie jamais les justificatifs personnels des transporteurs.
7. Ne modifie pas les anciennes migrations déjà appliquées : on **ajoute** une
   nouvelle migration.
8. **Apple, règle 2.5.19 (fonctions dormantes)** — décision de Nawfal, 12/11/2026 :
   les fonctions présentes mais désactivées (`subscriptions`,
   `plateau_paiement_direct`, `commission_client` dans `secoto_feature_flags`)
   ne doivent **jamais** être activées en production sans qu'une version iOS les
   présentant ait d'abord été soumise et validée par Apple. Ne propose ni SQL ni
   code qui les active sans le rappeler. Même règle pour toute nouvelle fonction
   cachée derrière un drapeau.

## 4. Pile technique

- **Front** : React 19 + Vite, un gros `src/App.jsx` (écrans client / transporteur /
  admin), modules `src/ondemand/*` (réservation, admin à la demande), `src/lib/*`
  (logique pure testable). CSS : `src/index.css`, `src/App.css`, `src/ondemand/ondemand.css`.
- **Mobile** : Capacitor 8 (iOS + Android), plugin `@capacitor-community/stripe`
  (PaymentSheet, Apple Pay sur iOS, merchant `merchant.fr.secoto.app`).
  Le web est **embarqué** dans l'app : une modif front n'arrive sur iPhone/Android
  qu'avec un **nouveau build** (Codemagic). Tout ce qui est SQL ou fonctions Netlify
  s'applique sans build.
- **Back** : **Supabase** (PostgreSQL, RLS, fonctions `SECURITY DEFINER` avec
  `set search_path = ''`, schéma privé `secoto_private`). Projet de production :
  `znnigxmzacukpfueqfrh`.
- **Fonctions serveur** : Netlify Functions (`netlify/functions/*`, librairies
  `netlify/lib/*`). `od-maintenance.js` tourne **chaque minute** (expirations,
  diffusion, relances, règlements, versements, rattrapage des cartes).
- **Paiement** : Stripe (SetupIntent, Checkout, PaymentSheet, débit hors session à
  la livraison, Connect pour certains transporteurs). Webhook : `stripe-webhook.js`
  (abonné à `setup_intent.succeeded` et `checkout.session.completed`).
- **E-mails** : table `email_outbox` (envoi par Resend). **Push** : `notifications`
  → `push_outbox` → `send-mission-notifications.js` (APNs / FCM / Web Push).
- **Itinéraires** : `computeRoute` (ORS → Geoapify → OSRM public), adresses :
  API Adresse (à migrer un jour vers la Géoplateforme IGN `data.geopf.fr/geocodage`).
- **Hébergement** : Netlify, déploiement automatique à chaque push sur `main`.
  Site : `https://app.secoto-transport.fr`.
- **Build mobile** : `codemagic.yaml` (`IOS_MARKETING_VERSION`, numéro de build
  incrémenté automatiquement). Version iOS actuelle : **2.5.2** (2.4 prête pour la distribution ;
  Apple exige une vidéo de démo Apple Pay à chaque soumission).

## 5. Conventions de code

- Code et commentaires **en français**, comme le code existant. Densité de
  commentaires modérée : on explique le *pourquoi*, avec le numéro de migration
  (ex. `// 108 : …`).
- Plusieurs fichiers sont en **fins de ligne CRLF** (`src/App.jsx`,
  `src/index.css`, `src/lib/payments.js`, `src/platform/runtime.js`,
  `src/lib/deepLinks.js`…) : **préserve le format existant** du fichier.
- Logique pure dans `src/lib/*` (testable sous Node), composants dans `src/*.jsx`.
- Un fichier `.jsx` qui exporte des composants ne doit pas exporter de constantes
  (règle eslint react-refresh).
- **Migrations SQL** : `supabase/migrations/AAAAMMJJNNNN_nom.sql`, numéro suivant
  le dernier (actuel : **152** → prochaine : **153**). Toujours **rejouable**
  (`create or replace`, `if not exists`, `on conflict do nothing`), en-tête qui
  explique le pourquoi. Pour patcher une fonction existante par repère :
  `secoto_private.mig074_patch('schema.fonction(args)'::regprocedure, 'ancien texte exact', 'nouveau texte')`
  (échoue proprement si le repère est absent ou ambigu ; attention, ne pas
  commenter le `;` qui suit le repère).
- Chaque migration a une **copie à coller** dans `deliverables/SECOTO-<num>-<sujet>-a-coller-dans-Supabase.sql`.
  Nawfal colle lui-même le SQL dans Supabase → SQL Editor.
- Notifications : `secoto_private.notify_event(compte, type, titre, texte, mission_id, ecran, cle_unique, ref_id)`
  et `secoto_private.notify_admins_event(...)`. Types autorisés : `mission_offer`,
  `order_update`, `live_tracking`, `subscription`, `payment`, `payment_failed`,
  `cancellation`, `course_assigned`, `new_request`. Écrans : `courses`, `documents`,
  `frais`, `available`, `assigned`, `applications`, `requests`, `paiement`,
  `transporters`, `offre`, `suivi`, `abonnement`.

## 6. Tests et vérifications (obligatoires avant de proposer un push)

- `npm test` → tests unitaires (`tests/*.test.js`, ~611 tests, tous verts).
- `npx eslint <fichiers modifiés>` (des erreurs anciennes existent dans App.jsx).
- `VITE_SUPABASE_URL=https://x.supabase.co VITE_SUPABASE_ANON_KEY=x npx vite build`
  (le build refuse de tourner sans ces deux variables).
- Tests de base de données : `tests/db/*.dbtest.mjs` sur une **base PostgreSQL 16
  jetable** (jamais la production) : `PGURL=postgres://… node --test tests/db/X.dbtest.mjs`.
  La base se reconstruit avec `tests/db/00_supabase_stub.sql`,
  `tests/db/01_secoto_baseline.sql`, puis toutes les migrations dans l'ordre
  (retirer le bloc `$rewire$` de la migration 202608170009). 4 tests anciens de
  `od-subscription-live` échouent (barème obsolète) : connu, sans rapport.
- Ajoute un test pour chaque correction ou fonctionnalité.

## 7. Comment Nawfal travaille

- Il fusionne sur son PC Windows avec **PowerShell**, dossier `C:\Users\33651\secoto-app` :
  ```powershell
  cd C:\Users\33651\secoto-app
  git fetch origin
  git checkout main
  git pull origin main
  git merge origin/<branche> -m "Merge <sujet>"
  git push origin main
  ```
  Netlify publie ensuite tout seul (1-2 min). Il colle les SQL dans Supabase.
- Il travaille souvent depuis son **téléphone** : réponses courtes, étapes
  numérotées, SQL et commandes prêts à copier.
- Toujours terminer par : ce qui a été fait, comment c'est vérifié, ce qu'il doit
  faire (SQL à coller, PowerShell, build ou non).
- Être honnête : si quelque chose n'est pas vérifié ou pas certain, le dire.
  Ne jamais annoncer un prix de transport sans certitude de le tenir.

## 8. Pièges connus

- Les données de production sont réelles (clients, transporteurs, paiements).
- Une déconnexion désactive l'appareil pour les notifications push : il faut
  réappuyer sur « Activer les notifications ».
- Dans une condition SQL, PostgreSQL n'évalue pas les clauses dans l'ordre : ne pas
  convertir (`::int`) un texte qui peut ne pas être un nombre (bug corrigé en 109).
- `raise exception` à la fin d'un bloc `do $$ … $$` = moyen sûr de tester un SQL
  en production sans rien enregistrer (tout est annulé).
- Les limites : 3 véhicules maximum par réservation dans l'app ; au-delà, mission
  manuelle à un prix négocié (porte-voitures PL).

## 9. Mise à jour du 13-14/11/2026 (migrations 143 à 146) — à lire avant toute modification

### Règles décidées par Nawfal
- **Klarna (CCD2, en vigueur en France le 20/11/2026)** : n'utiliser que les textes
  approuvés par Klarna. Mention générique « Klarna » / « Payez avec Klarna »
  partout. Texte du choix de mode, mot pour mot : « Choisissez Klarna. Payez en 3
  fois. » + « Attention ! Un crédit coûte de l'argent et doit être remboursé. »
  (`KLARNA_3_FOIS`, `KLARNA_AVERTISSEMENT` dans `src/lib/orderCopy.js`).
  Jamais d'exemple « 3 × … € ». **Klarna interdit en B2B** : refusé pour un compte
  `client_type = 'pro'` (base, écrans, `excluded_payment_method_types` Stripe).
- **Rentabilité** : on raisonne en **net SECOTO** = marge − URSSAF (21,2 % de la
  marge) − frais de paiement (5 % Klarna, ~1,5 % + 0,25 € carte, ~0,35 € SEPA).
  Objectif 75 € nets par course particulier.
- **Ne jamais modifier le prix d'une commande existante.**
- **Pas d'e-mail à Auto TC.** Leboncoin : pas de lien, écrire « tapez SECOTO
  transport sur Google ».
- Quand Nawfal est sur téléphone : coller le SQL complet dans la réponse + lien de la PR.

### 143 — Klarna CCD2 et B2B
E-mails de devis/relances (positions `%4$s`, `%6$s` dans `format()`), relance
carte, notification et e-mail de livraison (« Payez avec Klarna »), refus Klarna
pour un pro dans `secoto_od_choisir_reglement`. Facture et CGU : « Klarna » seul.

### 144 — Barème utilitaire, caravane, camping-car (« lourds »)
Réglages `app_settings['bareme_v3'].lourds`. Rémunération transporteur : 375 €
minimum jusqu'à 200 km → 700 € à 345 km → 800 € à 465 km → +1,66 €/km.
Prix client = `ceil(((75 + 0,788 × pay) / 0,738) / 5) × 5` (75 € nets après
URSSAF et 5 % Klarna), jamais sous le minimum du gabarit. Majorations caravane
(+20 % > 3 t, +10 % > 7 m) et non-roulant sur la rémunération. **Express × 1,2,
pas d'Éco.** Exemples : 80 km 505 €, 345 km 850 €, 465 km 960 €, 540 km 1 090 €.
Fonctions : `lourds_transporteur_eur`, `lourds_client_cents`, `est_lourd`.

### 145 — Navette Pro (offre `pro`, comptes pros uniquement)
- Réglages `app_settings['navette_pro']` : prix pro = **prix transporteur + 75 €
  (1 véhicule) ou + 60 € par véhicule (2 et plus, même commande)**. 4x4 = 1,5 place.
- Axes : **Paris – Lyon – Côte d'Azur** (IDF, 89, 21, 71, 69, 01, 38, 26, 84, 13,
  83, 06, Monaco ; 250-1 100 km), transporteur 480 € → **555 €**, 540 €/véhicule
  dès 2 ; **Paris – Belgique – Allemagne** (IDF, 60, 02, 80, 62, 59 ↔ BE/DE ;
  200-1 000 km), transporteur 500 € + 20 € de sécurité = 520 € → **595 €** / 580 €.
- Porte à porte (enlèvement chez le pro, livraison à l'adresse de son choix),
  voitures roulantes, fenêtre **7 jours**, proposée seulement si moins chère que
  le Standard (elle devient alors « Recommandée »).
- **Anti-friction** : visible uniquement pour `client_type = 'pro'` (inscription =
  accès immédiat, aucune vérification) ou un compte entreprise ; un pro ne voit
  pas l'Éco ; un particulier ne voit jamais la Navette Pro. Devis rattaché à un
  compte pro après connexion → offres recalculées (`trg_quote_offres`).
- Fonctions : `navette_pro_reglages`, `devis_compte_pro`, `navette_lieu_sur_axe`,
  `offre_navette_pro`, `calculer_offres` (réécrite : accepte plusieurs véhicules
  pour un pro sur axe). Contraintes `offre` / `offre_choisie` : + `'pro'`.
- Écrans : `OFFRE_LIBELLE.pro = "Navette Pro"`, pas de mention Klarna sous les
  prix pour un pro (`clientPro` dans `OnDemandBooking`).

### 146 — Navette Pro sur le site vitrine
`bareme_v3_public_calcul` publie un bloc `navette_pro` (prix client seulement,
jamais la rémunération transporteur) ; le déclencheur du cache inclut
`navette_pro`. App : lien `?compte=pro` → inscription ouverte, profil
« Professionnel » présélectionné (`lienComptePro()` dans `App.jsx`).
Site (dépôt `nawfelbch.github.io`) : page `/professionnels/`, simulateur pro
(SIREN = 9 chiffres, sans autre contrôle, ni envoyé ni enregistré), exemples de
trajets calculés au build, sélecteur « Particulier | Professionnel » sur l'accueil
(aucun prix pro sur l'accueil).

### Pas encore fait (ne pas annoncer comme disponible)
- Prélèvement SEPA + facture mensuelle pour les pros (aujourd'hui : carte/virement).
- Plusieurs adresses de livraison dans une commande.
- Facture au nom du transporteur avec TVA récupérable : le circuit existe (074,
  `partner_invoices`) mais dépend de `plateau_paiement_direct` → règle Apple § 3.8
  + validation de l'expert-comptable ; sa ligne TVA doit porter sur la part
  transporteur seule (à corriger avant activation).
- Prix Standard/Express spécifiques aux pros ; hausse de l'Éco particulier
  (idée : 85 % du Standard, masquée si l'écart < 100 €) — non validée.
- Vagues automatiques de diffusion aux transporteurs (< 24 h) et relance Stripe
  des 71 transporteurs non payables ; pages SEO par trajet/véhicule.


### 147 — Onglet admin « Clients pros »
`public.secoto_admin_clients_pros()` (lecture seule, `assert_admin`) : par compte
pro (client_type 'pro' ou compte entreprise client) identité, SIREN, provenance,
devis, commandes (en cours / livrées / annulées), CA, marge, Navette Pro, trajets
fréquents, 10 dernières commandes. Écran `src/ClientsProsPanel.jsx` (recherche,
tri), logique pure `src/lib/clientsPros.js`. Menu admin → Réseau → Clients pros.

### Médiateur de la consommation (16/11/2026)
SECOTO adhère au **CM2C** (Centre de la médiation de la consommation de
conciliateurs de justice), 49 rue de Ponthieu, 75008 Paris, tél. 01 89 47 00 14,
saisine en ligne sur www.cm2c.net — adhésion valable jusqu'au **16/11/2029**
(convention de 3 ans). Affiché dans `public/cgu.html` (art. 10),
`src/LegalNoticesPanel.jsx` et les mentions légales du site. Ne concerne que les
clients consommateurs (pas les pros).

### Siège social (16/11/2026)
**39 avenue Léon Gambetta, 92120 Montrouge** (adresse de l'attestation CM2C).
Remplace l'ancienne adresse de Fontenay-aux-Roses dans `public/*.html`,
`templates/*.html`, `netlify/lib/facture-pdf.js` et, sur le site,
`src/_data/site.js`. Les adresses « Fontenay-aux-Roses » des tests et de
l'exemple d'import d'historique sont des données de test, pas le siège.

### 148-149 — Grille du 17/11/2026 (« on arrête de casser les prix »)
- **148 (rustine)** : plusieurs véhicules dont un lourd → devis manuel
  (`sur_devis_plusieurs_lourds`). Reste en secours après la 149.
- **149** : utilitaire, caravane, camping-car au km — particulier Standard
  2,20 €/km (min 550 €), Express 2,40 €/km (≥ Standard + 10 %) ; pro Standard
  2,00 €/km (min 500 €), Express 2,20 €/km. Toujours ≥ 75 € nets
  (`lourds_offre_cents`). Transporteur : courbe 144, Express + 10 %.
  Voitures : tranches 0,98 / 0,85 / 0,75 €/km (+3 à 5 %). Motos inchangées.
  Plusieurs véhicules : chaque véhicule au barème v3, −10 % dès le 2e
  (`bareme_v3_groupe`, branché dans `secoto_quote_create`) — l'ancien moteur
  (1,25 €/km, −25 %) n'est plus utilisé pour le plateau multi-véhicules.
- Ligne de Nawfal : prix plus élevés, plus de casse des prix ni de recherche
  systématique de retours à vide ; l'app doit tout automatiser.

### 150 — Éco en groupage seulement (17/11/2026)
L'Éco (barèmes inchangés, `offre_eco_v3`) n'est plus proposée à chaque devis.
Elle se débloque (`eco_debloquee`) : pour une demande à plusieurs véhicules
(Éco = somme par véhicule, `offre_eco_groupe`), ou quand au moins 2 commandes
(en recherche ou confirmées) partent sur le même axe à ± 3 jours
(`eco_meme_axe` : même couloir, même sens, trajets qui se chevauchent — ex.
A6/A7 : 1er Standard, 2e Standard, 3e voit l'Éco). Couloirs, seuil, écart :
`app_settings['bareme_v3'].eco.groupage`. Jamais pour un pro. Site : plus d'Éco
au simulateur (`v3.eco.sur_groupage`).

### 151 — Automatisation (17/11/2026)
`public.secoto_automatisation_tick()` (appelée chaque minute par od-maintenance),
réglages `app_settings['automatisation']` (tout désactivable) :
- commandes sans transporteur : rappel (notif) 4 h après diffusion ; SMS 12 h
  après si départ < 7 j (file `sms_outbox`, envoi Brevo `netlify/lib/sms-brevo.js`,
  clé `BREVO_API_KEY`) ; coup de pouce +10 % une fois, 24 h après, départ < 5 j,
  jamais sous 50 € nets (`pay_max_cents`), pas en paiement direct ; alerte
  admin 18 h après si départ < 3 j ;
- client : point d'étape toutes les 12 h (4 max) tant que personne n'a confirmé ;
- transporteurs sans Stripe ni coordonnées bancaires : relance hebdo (6 max) ;
- pause 21 h – 7 h (sauf alerte admin). Journal : `automatisation_journal`.
Piloter : `TransporteursAAppeler.jsx` (RPC `secoto_admin_transporteurs_a_appeler`,
suivi `od_appels` / `secoto_admin_appel_maj`) + recherche Google
(`netlify/functions/places-transporteurs.js`, clé `GOOGLE_PLACES_API_KEY`).
Facture transporteur avec TVA récupérable : déjà prête (078), activation =
`commission_client` + `plateau_paiement_direct` → règle Apple § 3.8.

### 152 — Politique SMS + transporteurs à appeler pour les missions (17/11/2026)
Règle de Nawfal : **aucun SMS aux transporteurs SECOTO** (e-mail uniquement :
la relance 12 h devient un e-mail `od-relance-mail:*`). Confirmations après
réservation : **e-mail uniquement**. SMS autorisés :
- client : **un seul**, 1 h après le prix obtenu, devis non réservé
  (`devis-sms:<quote>`, lien `?reprendre=`, jamais la nuit, réglage `sms_devis_actif`) ;
- prospects (transporteurs hors SECOTO trouvés sur Google) : invitation à
  s'inscrire, bouton « Inviter par SMS », `secoto_admin_inviter_transporteur_sms`
  (type `marketing`, mention `[STOP CODE]`, une fois par numéro, refusé si inscrit).
Missions manuelles (onglet Publiées) : bloc « Transporteurs à appeler » replié
sur chaque carte (`secoto_admin_transporteurs_a_appeler_mission`, suivi
`mission_appels`), recherche Google par géocodage de l'adresse de départ.

