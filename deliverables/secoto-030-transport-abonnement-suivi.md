# SECOTO 030-032 — Transport à la demande, abonnement professionnel, suivi en direct

Branche : `feature/secoto-030-transport-abonnement-suivi`
Base : `main` (411812d, version iOS 1.5)
**Tout est livré désactivé** : les cinq interrupteurs (`secoto_feature_flags`) valent `false`
à l'installation. Tant qu'ils ne sont pas activés, l'application se comporte exactement
comme aujourd'hui : aucun nouvel écran n'apparaît, aucune notification nouvelle n'est émise.

---

## 1. Ce qui est livré

### Base de données (additive, rejouable)

| Fichier | Contenu |
|---|---|
| `supabase/migrations/202609170030_transport_a_la_demande.sql` | interrupteurs, journal d'actions, sociétés clientes, barèmes versionnés + moteur de prix, devis, commandes, paiements (autorisation/capture), offres partenaires et attribution atomique, versements partenaires, export comptable |
| `supabase/migrations/202609170031_abonnement_professionnel.sql` | dossiers d'éligibilité, historique importé (privé), propositions simulées au pire cas, abonnements Stripe Billing, quotas réservés atomiquement, extensions |
| `supabase/migrations/202609170032_suivi_gps_mission.sql` | sessions de partage de position, positions, estimation d'arrivée, arrêt automatique, purge |
| `supabase/rollback/030-032_rollback.sql` | retour arrière (niveau 1 : désactivation ; niveau 2 : suppression des objets) |

Trois modifications seulement touchent l'existant, toutes rétro-compatibles :
`payments.mission_id` devient nullable (un paiement de commande précède la mission),
les contraintes `payments_purpose_check` / `payments_status_check` sont élargies,
et `secoto_private.prepare_notification` accepte trois écrans de plus.
`secoto_prepare_delivery_payment` est réécrite avec une garde : sur une mission déjà
prépayée, elle ne facture plus que les frais réels validés (jamais deux fois la prestation).

### Fonctions serveur (Netlify)

| Fonction | Rôle |
|---|---|
| `quote-transport` | itinéraire routier serveur puis devis calculé **en base** (le téléphone n'envoie aucun montant) |
| `offer-accept` | acceptation partenaire (verrou atomique) puis capture Stripe ; attribution admin par le même chemin |
| `od-maintenance` (chaque minute) | expiration des devis/offres, nouveaux tours, « aucun partenaire », verrous de capture expirés vérifiés chez Stripe, libérations et remboursements, suspension des abonnements impayés |
| `live-eta` (toutes les 2 min) | heure d'arrivée estimée, notifications d'approche, purge horaire des positions |
| `subscription-checkout` | mise en place et résiliation du prélèvement mensuel |
| `stripe-webhook` (étendu) | nouveaux événements (autorisation, capture, annulation, remboursement, contestation, facturation d'abonnement) ; le traitement historique est inchangé |
| `create-payment-intent` (étendu) | capture manuelle, métadonnées de commande, Apple Pay / Google Pay / carte |
| `send-mission-notifications` (étendu) | notification d'offre, confidentialité d'écran verrouillé, réglage « hors connexion » |
| `retry-refunds` (restreint) | ne traite plus que les paiements historiques |

### Application

`src/ondemand/` : parcours client (trajet → véhicule → mode → dates → prix → paiement),
mes commandes avec les six états distincts, écran partenaire (disponibilité, propositions,
popup temps réel), suivi cartographique, espace abonnement, espace administration.
`src/lib/onDemand.js`, `src/lib/historyImport.js`, `src/lib/liveTracking.js` : logique pure, testée.

---

## 2. Version testable

```bash
git checkout feature/secoto-030-transport-abonnement-suivi
npm ci
npm test          # tests unitaires et de non-régression
npm run lint
npm run build
npm run dev       # http://localhost:5173
```

Base de test jetable (PostgreSQL 17 local, schéma reconstitué) :

```bash
# 1. rejouer le socle puis les migrations 030-032 dans une base vide
psql -f tests/db/00_supabase_stub.sql -f tests/db/01_secoto_baseline.sql   # socle de test
for f in supabase/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -f "$f"; done
# 2. tests d'intégration (concurrence réelle, 20 connexions)
PGURL=postgres://... node --test tests/db/od-subscription-live.dbtest.mjs
```

---

## 3. Variables d'environnement (aucun secret dans le dépôt)

| Variable | Où | Rôle | Sans elle |
|---|---|---|---|
| `ROUTING_PROVIDER` | Netlify | `ors` ou `osrm` | aucun itinéraire → **devis manuel** |
| `ORS_API_KEY` | Netlify | clé openrouteservice | idem |
| `OSRM_URL` | Netlify | instance OSRM auto-hébergée | idem |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PUBLISHABLE_KEY` | Netlify | déjà en place | paiement indisponible |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Netlify | déjà en place | fonctions en 503 |
| `VITE_MAP_TILE_URL`, `VITE_MAP_ATTRIBUTION` | build | fournisseur de tuiles de la carte | tuiles OpenStreetMap publiques, à réserver aux essais |
| `VITE_APPLE_PAY_MERCHANT_ID` | build | déjà en place | Apple Pay masqué |

Événements Stripe à cocher sur le webhook : `payment_intent.amount_capturable_updated`,
`payment_intent.succeeded`, `payment_intent.payment_failed`, `payment_intent.canceled`,
`charge.refunded`, `charge.dispute.created`, `charge.dispute.closed`,
`checkout.session.completed`, `invoice.paid`, `invoice.payment_failed`,
`customer.subscription.deleted`.

---

## 4. Ce qui fonctionne

- **Prix** : barème versionné, calculé côté serveur, jamais modifiable par le client ;
  chaque devis conserve sa version et sa durée de validité. Le barème convoyage initial
  est **exactement** celui de la migration 009 (1,00 / 0,90 / 0,88 €/km, plancher 115 €,
  convoyeur 0,55 €/km, frais réels sur justificatifs). Hors de son domaine de validité
  (utilitaire, plus de 600 km, prestige, véhicule non roulant, contraintes) : devis manuel.
- **Paiement avant diffusion** : autorisation puis capture après attribution quand la prise
  en charge est proche ; encaissement immédiat avec remboursement intégral automatique
  au-delà de la fenêtre d'autorisation. Le comportement réel est écrit à l'écran.
- **Attribution atomique** : une seule acceptation gagne ; les autres voient
  « Mission déjà attribuée » ; un échec de capture ne laisse jamais une mission confirmée.
- **Partenaires** : disponibilité, zones, véhicules, équipements, jours, notifications hors
  connexion, confidentialité de l'écran verrouillé. Aucun refus n'est pénalisé.
- **Abonnement** : questionnaire, import contrôlé (formules jamais évaluées, macros refusées),
  analyse admin, proposition simulée **en utilisation complète** (combinaison autorisée la plus
  coûteuse) — l'envoi est refusé si la marge du pire cas passe sous le seuil ; quotas réservés
  atomiquement, restitués à l'annulation et quand aucun partenaire ne confirme.
- **Suivi** : activé par le partenaire après « Véhicule récupéré », avec consentement ;
  position ancienne signalée comme telle ; arrêt automatique à la livraison, à l'annulation
  et à la réattribution ; conservation limitée (30 j après l'arrêt, 90 j maximum).
- **Cloisonnement** (contrôlé en base, pas seulement à l'écran) : le partenaire ne voit ni le
  prix client ni la marge ; le client ne voit pas le coût partenaire ; chaque société ne voit
  que ses dossiers ; l'historique importé reste privé.

---

## 5. Résultats des tests et limites connues

### Tests exécutés

| Vérification | Où | Résultat |
|---|---|---|
| Suite existante + nouveaux tests unitaires | `npm test` | **166 tests au vert** (153 avant, 13 ajoutés) |
| Lint | `npx eslint .` | propre |
| Build de production | `npm run build` | propre (bundle 956 ko, avertissement de taille connu) |
| Rendu de tous les nouveaux écrans | `tests/smoke/` | 12 écrans rendus sans erreur |
| Intégration base de données (PostgreSQL 17, connexions concurrentes réelles) | `tests/db/od-subscription-live.dbtest.mjs` | **16 tests au vert** |
| Rejeu complet des 19 migrations sur base vierge, deux fois de suite | script de rejeu | aucune erreur (migrations rejouables) |
| Retour arrière puis réapplication | `supabase/rollback/030-032_rollback.sql` | l'état des fonctions redevient identique à l'avant-030 |

Ce que couvrent les tests base de données, point par point :

- 15 commandes × 3 acceptations **simultanées** : un seul gagnant à chaque fois ; aucune
  mission créée tant que le paiement n'est pas capturé ;
- webhook rejoué (même identifiant d'événement) : sans effet ; webhook reçu **dans le désordre**
  (« autorisé » après « encaissé », « autorisé » après « annulé ») : aucun retour en arrière ;
- échec de capture après acceptation : aucune mission confirmée, commande de nouveau
  disponible, paiement marqué « encaissement refusé », partenaire informé sans pénalité ;
- aucun partenaire compatible : fin de diffusion après le nombre de tours prévu, commande
  « aucun partenaire », action de libération du paiement produite pour le serveur ;
- trois réservations simultanées pour deux droits d'abonnement : deux acceptées, une refusée
  avec le message « Droits épuisés » ; annulation → droit restitué → nouvelle réservation possible ;
  plafond kilométrique et distance maximale par trajet refusés avec le motif exact ;
- import d'historique : formule non évaluée, ligne en erreur bloquante, doublon signalé,
  dossier d'un tiers illisible ;
- suivi : activation refusée avant « Véhicule récupéré » et sans consentement, position
  périmée signalée, accès refusé à un autre client et à un autre partenaire, arrêt automatique
  à la livraison et à la réattribution, versement partenaire créé à la livraison ;
- cloisonnement : lecture directe des tables refusée, fonctions d'administration refusées à un
  client et à un partenaire, fonctions serveur refusées à tout compte authentifié, commandes
  d'autrui invisibles, prix client jamais exposé au partenaire, rémunération partenaire jamais
  exposée au client ;
- non-régression : le paiement à la livraison d'une mission historique facture toujours le
  montant complet ; sur une mission prépayée, il ne facture plus que les frais réels validés.

### Ce qui n'a PAS été testé sur appareil (à faire avant activation)

| Sujet | État | Ce qu'il reste à faire |
|---|---|---|
| **Face ID / biométrie** | **non implémenté** | aucun plugin biométrique n'est présent dans le projet ; en l'état, l'ouverture depuis une notification s'appuie sur la session déjà ouverte et, si la session a expiré, la connexion ramène automatiquement à la mission (lien profond mémorisé — mécanisme existant). La confidentialité de l'écran verrouillé repose sur le réglage iOS « Aperçus : si déverrouillé », indiqué dans l'écran partenaire. Les passkeys web ne sont pas disponibles avec l'authentification actuelle. Ajouter un plugin biométrique est une décision à prendre (dépendance native + test sur appareil). |
| **Notifications push réelles** | pipeline existant réutilisé | envoyer une offre de test à un iPhone et un Android : vérifier le texte masqué / détaillé, le son, l'ouverture directe sur la mission, et le cas « application fermée ». |
| **GPS en arrière-plan** | **non disponible** | le partage fonctionne application ouverte (premier plan). Le suivi en arrière-plan demande un plugin dédié, `UIBackgroundModes`, une justification App Store et une nouvelle validation. L'interface le dit explicitement au partenaire, et une position ancienne est signalée comme telle. |
| **Apple Pay / Google Pay avec capture différée** | code en place | régler une commande de test sur iPhone et Android en mode test Stripe. |
| **Stripe** | simulé de bout en bout (RPC + fonctions avec un Stripe factice) | rejouer en **mode test** : paiement accepté, refusé, authentification 3DS, annulation d'autorisation, remboursement, contestation ; rejouer un même événement deux fois depuis le tableau de bord Stripe. |
| **Abonnement récurrent** | code en place | un cycle complet en mode test : mise en place, facture payée, facture en échec, reprise, résiliation à l'échéance. |
| **Estimation d'arrivée** | code en place | nécessite un fournisseur d'itinéraire configuré ; sans lui, aucune estimation n'est affichée (et jamais une distance à vol d'oiseau présentée comme une distance routière). |

Autres limites assumées :

- **Plateau : pas de prix automatique.** Le barème plateau est livré en brouillon non activable
  tant que la rémunération transporteur n'y est pas définie (voir §6). Toute demande plateau
  part en devis manuel.
- **Convoyage : prix automatique borné** aux voitures et à 600 km, marge minimale 15 %,
  conformément à l'analyse SECOTO-025 (barème déficitaire au-delà sur utilitaire).
- **Péages et carburant** ne sont pas estimés : ils restent des frais réels sur justificatifs
  (convoyage) ou inclus dans le tarif plateau. Aucune donnée de péage n'est inventée.
- Le portail client Stripe n'est pas activé : un prélèvement d'abonnement en échec se
  régularise depuis l'e-mail de facture Stripe ou par SECOTO.
- La carte de suivi utilise par défaut les tuiles publiques OpenStreetMap : acceptable pour les
  essais, à remplacer par un fournisseur dédié en production (`VITE_MAP_TILE_URL`).

## 6. Points contractuels, tarifaires et externes qui conditionnent la production

1. **Barème plateau à trancher.** Deux références coexistent dans le projet : la grille
   2,20 €/km (≤ 300 km) puis 1,80 €/km global, et le modèle de l'application « tarif
   transporteur × 1,20 ». La première ne dit pas ce que touche le transporteur. Tant que ce
   point n'est pas fixé, le prix automatique plateau reste fermé.
2. **Révision du barème convoyage.** À 2,25 €/L de gazole, la grille actuelle n'est plus
   tenable au-delà de 600 km ni sur utilitaire. Décision à prendre : majoration utilitaire,
   clause de révision gazole, ou maintien du devis manuel au-delà de 600 km.
3. **Fournisseur d'itinéraire** (openrouteservice ou OSRM auto-hébergé) : compte, clé, quota
   et coût. Sans lui : aucun prix automatique.
4. **Fournisseur de tuiles cartographiques** pour la production.
5. **Stripe** : activer les événements listés au §3 sur le webhook de production, et confirmer
   la durée de validité des autorisations avec votre compte (la fenêtre est paramétrée à
   144 h dans `app_settings.dispatch_policy`). Aucun compte Connect n'est nécessaire : sur
   plateau, SECOTO n'encaisse que sa commission, le transport est réglé au transporteur.
6. **Conditions générales** : clauses d'abonnement (droits non reportés, annulation,
   résiliation, extension), prix ferme après acceptation du devis, et renonciation au droit de
   rétractation pour un convoyage prépayé à date déterminée — à faire valider juridiquement.
7. **RGPD** : la géolocalisation partenaire est une nouvelle donnée. À mettre à jour : registre
   des traitements, politique de confidentialité, information du partenaire (déjà affichée dans
   l'application) et du client, durées de conservation (30 jours après la fin du partage,
   90 jours maximum — paramétrables dans `app_settings.live_tracking_policy`).
8. **Stores** : les textes de localisation d'`Info.plist` ont été mis à jour (suivi de mission au
   premier plan). La fiche de confidentialité App Store doit déclarer la localisation liée à
   l'identité, usage « fonctionnement de l'app ».

## 7. Déploiement et retour arrière

### Déploiement

1. **Sauvegarde PITR** du projet Supabase et export des tables `payments` et `missions`.
2. Appliquer, dans l'ordre, dans le SQL Editor (ou `supabase db push`) :
   `202609170030`, `202609170031`, `202609170032`. Chaque fichier est une transaction unique,
   additive et rejouable ; aucune réécriture de table, exécution de l'ordre de quelques secondes.
3. Contrôler : `select key, enabled from public.secoto_feature_flags;` → **tout à false**.
   `select mode, version, status from public.pricing_grids;` → convoyage v1 active, plateau v1 draft.
4. Déployer la branche sur Netlify (déploiement de prévisualisation d'abord), ajouter les
   variables du §3, puis ajouter les événements Stripe au webhook.
5. Vérifier que les deux nouvelles tâches planifiées tournent : `od-maintenance` (chaque minute)
   et `live-eta` (toutes les deux minutes) — journal Netlify.
6. **Activation progressive**, un interrupteur à la fois, en observant l'écran « À la demande » :
   `auto_pricing` (les devis se calculent, rien n'est payable) → `od_payments` avec Stripe en
   mode test → `dispatch_notifications` sur un compte partenaire de test → `live_tracking` →
   `subscriptions`.
7. Publier l'application mobile seulement après validation sur le web : les écrans partenaires
   et le suivi utilisent les capacités natives (notifications, localisation).

### Retour arrière

- **Immédiat, sans perte** : `update public.secoto_feature_flags set enabled = false;`
  Les parcours existants (candidatures, documents, paiement plateau, frais, terrain) ne
  dépendent d'aucun objet des migrations 030-032.
- **Code** : redéployer le commit précédent sur Netlify ; les migrations restent en place sans
  effet (tout est fermé par les interrupteurs).
- **Suppression complète** : `supabase/rollback/030-032_rollback.sql` — à n'exécuter qu'après
  export, et seulement si aucun paiement de commande n'est en cours (requête de contrôle en
  tête du fichier). Le fichier restaure `prepare_notification` et `secoto_prepare_delivery_payment`
  dans leur version antérieure et laisse intactes les colonnes ajoutées aux tables existantes.
