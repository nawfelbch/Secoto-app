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
  carte, Klarna (plusieurs fois, sous réserve d'acceptation), virement, espèces
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
  incrémenté automatiquement). Version iOS actuelle : **2.3.7** (en vérification Apple ;
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
  le dernier (actuel : **111** → prochaine : **112**). Toujours **rejouable**
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

- `npm test` → tests unitaires (`tests/*.test.js`, ~533 tests, tous verts).
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
