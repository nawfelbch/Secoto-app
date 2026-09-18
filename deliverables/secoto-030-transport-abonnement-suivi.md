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
| `supabase/migrations/202609180033_correctif_droits_helpers.sql` | **correctif** : rétablit les droits d'exécution retirés par erreur (comptes inaccessibles le 17/09) |
| `supabase/migrations/202609180034_bareme_secoto_2026.sql` | barème commercial du 18/09/2026 (voir § 4) |
| `supabase/migrations/202609180035_parcours_commande_final.sql` | parcours de commande définitif (voir § 4) |
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

## 4. Le barème et le parcours décidés le 18/09/2026

### Prix client

| Mode | Catégorie | Prix client | Rémunération transporteur |
|---|---|---|---|
| Plateau | Voiture | **1,12 €/km** | 0,97 €/km |
| Plateau | Moto | **1,00 €/km**, le prix ne dépasse jamais **400 €** | 0,85 €/km (340 € au plafond) |
| Plateau | Utilitaire, VL, camionnette, caravane | **1,25 €/km** | 1,10 €/km |
| Plateau | Véhicule non roulant | **+ 80 €** | + 60 € |
| Convoyage | Toutes catégories | **1,00 €/km**, tout compris | 0,55 €/km — **0,65 €/km** en utilitaire |
| Les deux | Plancher | **115 €** | 115 € × le rapport de la catégorie |

Exemples produits par le moteur, vérifiés à chaque installation de la migration :
voiture 500 km = **560,00 €** (transporteur 485,00) · moto 300 km = **300,00 €** (255,00) ·
moto 800 km = **400,00 €** (340,00) · utilitaire 200 km = **250,00 €** (220,00) ·
50 km = **115,00 €** (99,60) · voiture non roulante 500 km = **640,00 €** (545,00) ·
convoyage 400 km = **400,00 €** (convoyeur 220,00, utilitaire 260,00).

**SECOTO encaisse la totalité**, dans les deux modes, puis règle le transporteur.
Plus aucun transport n'est payé en direct au transporteur. Les missions créées
**avant** la bascule gardent exactement leurs montants : aucune mission en cours
n'est modifiée.

Hors du domaine du barème (prestige, contraintes particulières, plus de 1 500 km,
itinéraire introuvable), le prix n'est pas inventé : la demande part en **devis
personnalisé** et vous fixez le prix vous-même.

### Parcours client

1. Le client saisit ses adresses, décrit le véhicule, choisit sa date. Le prix
   s'affiche immédiatement.
2. Il paie par **Apple Pay, Google Pay ou carte**. Le paiement est **encaissé tout
   de suite** et **gardé en réserve 48 heures**. C'est écrit à l'écran, avant et
   après le paiement.
3. La **facture** part automatiquement par e-mail dès l'encaissement, avec le
   détail du prix et la mention « TVA non applicable, article 293 B du CGI ».
4. La demande est proposée à **tous les transporteurs vérifiés compatibles**,
   pendant **48 heures**, en **un seul tour**.
5. Le premier qui accepte emporte la mission. Les autres voient
   « Mission déjà attribuée ».
6. **Si personne n'accepte** : la commande s'arrête et le **remboursement intégral**
   est demandé automatiquement, annoncé au client **sous 24 heures**.
7. **Annulation client** : remboursement intégral **jusqu'à 24 heures avant** la
   prise en charge, même si un transporteur a confirmé ; au-delà, **50 % sont
   retenus**. Le montant exact est annoncé à l'écran avant de valider.
8. Après la livraison, le transporteur est réglé **sous 48 heures** (échéance
   affichée dans l'espace administration, rappel automatique le jour venu).

### Parcours transporteur

- **Plus de candidature avec prix proposé.** Partout — commandes en ligne comme
  missions créées par vous — il voit sa **rémunération** et **accepte ou refuse**.
- La notification porte le **modèle du véhicule**, la **ville de départ**, la
  **ville d'arrivée**, l'état **roulant / NON ROULANT** et **sa rémunération**.
- Il n'a **rien à régler au préalable** : un transporteur vérifié qui n'a jamais
  touché aux préférences reçoit tout ce qui le concerne. Les préférences (zones,
  catégories, jours) ne filtrent que s'il les a renseignées lui-même.
- **Un refus n'a aucune conséquence** : ni compteur, ni note, ni statut. Il retire
  simplement cette mission-là de son tableau.

### Pilotage

Vous pouvez modifier **toutes les conditions** d'un transport **à tout moment,
même en cours de mission** : prix client, rémunération du transporteur, date de
prise en charge, adresses, véhicule. Le motif est obligatoire, le changement est
tracé, le client et le transporteur sont prévenus, et la mission comme le
versement suivent automatiquement. Si le prix change **après encaissement**, rien
n'est débité ni remboursé tout seul : vous recevez une alerte « Écart de prix à
régulariser ».

---

## 5. Cloisonnement et sécurité (contrôlés en base, pas seulement à l'écran)

- Le transporteur ne voit **ni le prix client ni la marge** — ni dans une offre,
  ni dans le tableau des missions publiées.
- Le client ne voit **pas le coût transporteur**.
- Le prix, la rémunération et la marge sont calculés **en base** : le téléphone
  n'envoie aucun montant, et tout montant qu'il enverrait serait ignoré.
- Chaque société ne voit que ses dossiers ; l'historique importé reste privé.
- Une seule acceptation peut gagner : l'attribution est sérialisée par un verrou
  de ligne. Vérifié par 15 commandes × 3 acceptations simultanées.
- Les webhooks Stripe rejoués ou reçus dans le désordre ne font jamais régresser
  un paiement.

---

## 6. Ce qui reste à décider ou à confirmer

Ces points ont été tranchés par défaut, faute de décision explicite. Ils se
changent en une ligne, sans redéploiement.

| Point | Valeur retenue | Où la changer |
|---|---|---|
| Part du supplément « non roulant » reversée au transporteur | 60 € sur les 80 € facturés | barème plateau, `non_rolling_partner_eur` |
| Convoyage : frais réels (carburant, péages) du convoyeur | **remboursés sur justificatifs**, comme aujourd'hui — le prix client « tout compris » ne change pas ses conditions | barème convoyage, mention `included` |
| Annulation après confirmation : part versée au transporteur | **aucune part automatique** — vous arbitrez, une alerte admin vous prévient | `secoto_od_cancel_order` |
| Distance maximale du prix automatique | 1 500 km | barème, `auto_max_km` |
| Marge minimale avant devis personnalisé | 10 % | barème, `min_margin_pct` |

Tous les délais (48 h d'offre, 24 h de remboursement, 24 h d'annulation gratuite,
50 % de retenue, 48 h de versement) sont dans **une seule ligne de réglage** :
`app_settings` → `dispatch_policy`. Les changer prend effet à la minute suivante.

---

## 7. Mise en ligne

### 7.1 Base de données

Collez **`SECOTO-033-034-035-a-coller-dans-Supabase.sql`** dans le SQL Editor du
projet **SECOTO CONVOYEURS**, en une seule fois. Le fichier est rejouable et
n'active aucun interrupteur. Le chemin a été rejoué à blanc depuis l'état réel de
la production (030-032 déjà installées, y compris le revoke fautif) : les droits
sont rétablis, les deux barèmes sont actifs, la fenêtre passe à 48 heures.

### 7.2 Variables d'environnement

| Variable | Où | Sans elle |
|---|---|---|
| `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` | **build** (Netlify et Codemagic) | **la construction échoue désormais volontairement** (voir ci-dessous) |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Netlify | fonctions serveur en 503 |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PUBLISHABLE_KEY` | Netlify | paiement indisponible |
| `ROUTING_PROVIDER`, `ORS_API_KEY`, `ORS_BASE_URL` | Netlify | aucun itinéraire → devis manuel |
| `VITE_MAP_TILE_URL`, `VITE_MAP_ATTRIBUTION` | build | tuiles OpenStreetMap publiques |
| `VITE_APPLE_PAY_MERCHANT_ID` | build | Apple Pay masqué |
| `STRIPE_TAX_CODE` | Netlify (facultatif) | par défaut `txcd_20030000` (« General - Services ») |
| `STRIPE_AUTOMATIC_TAX` | Netlify (facultatif) | `false` par défaut : franchise en base, aucune TVA ajoutée |
| `STRIPE_MANAGED_PAYMENTS` | Netlify (facultatif) | `false` par défaut : SECOTO reste vendeur et émetteur de la facture |

**Stripe Tax.** Le compte Stripe de SECOTO a le calcul automatique de taxe
activé. Stripe refuse alors toute session de paiement dont l'article n'a pas de
code fiscal (`Invalid line_items[0]: the product tax code is missing`). Les deux
fonctions qui créent une session (`create-payment-intent`, `subscription-checkout`)
fournissent donc `txcd_20030000` et désactivent explicitement le calcul
automatique : SECOTO est en franchise en base, rien ne doit être ajouté au prix
affiché. Le jour où SECOTO sort de la franchise, passer `STRIPE_AUTOMATIC_TAX`
à `true` suffit — la TVA sera alors **comprise** dans le prix annoncé, jamais
ajoutée par-dessus.

**Managed Payments.** Stripe l'active par défaut sur le compte SECOTO. Dans ce
mode, Stripe devient redevable de la taxe et impose `automatic_tax[enabled]=true` :
il ajouterait de la TVA au prix annoncé et deviendrait l'émetteur de la facture,
ce qui est incompatible avec la franchise en base. Les trois créations Stripe
(session de paiement, intention de paiement, abonnement) passent donc
`managed_payments[enabled]=false`. Si un compte refuse ce paramètre, la requête
est rejouée une fois sans lui plutôt que d'échouer. Les deux réglages restent
liés : activer `STRIPE_MANAGED_PAYMENTS` active aussi le calcul de taxe, sans
quoi Stripe refuserait la requête.

**Clés d'idempotence.** Une clé Stripe est liée à vie aux paramètres de son
premier usage. Construite sur le seul identifiant de paiement, elle condamnait
définitivement une commande dès que le montant, le libellé ou la fiscalité
changeaient (`Keys for idempotent requests can only be used with the same
parameters`). Les clés portent désormais l'empreinte des paramètres : un double
appui sur « Payer » reste protégé contre le double encaissement, mais une
modification légitime repart proprement.

**Défaut corrigé au passage.** Si `VITE_SUPABASE_URL` ou `VITE_SUPABASE_ANON_KEY`
manquaient, la construction **réussissait** mais produisait un fichier **sans
l'application** : page blanche en ligne, sans le moindre message d'erreur. La
cause : `src/supabaseClient.js` lève une erreur au chargement, l'optimiseur la
voit devenir inconditionnelle et supprime tout le code qui suit. `vite.config.js`
refuse maintenant de construire dans ce cas, avec un message explicite.
Vérifiez que ces deux variables sont disponibles **dans tous les contextes de
déploiement** Netlify, pas seulement en production.

Événements Stripe à cocher sur le webhook : `payment_intent.amount_capturable_updated`,
`payment_intent.succeeded`, `payment_intent.payment_failed`, `payment_intent.canceled`,
`charge.refunded`, `charge.dispute.created`, `charge.dispute.closed`,
`checkout.session.completed`, `invoice.paid`, `invoice.payment_failed`,
`customer.subscription.deleted`.

### 7.3 Ouverture des interrupteurs

Dans l'ordre, une fois la base à jour et le site déployé :

```sql
update public.secoto_feature_flags set enabled = true, updated_at = now()
 where key in ('auto_pricing', 'od_payments', 'dispatch_notifications', 'live_tracking', 'direct_accept');
notify pgrst, 'reload schema';
```

- `auto_pricing` — le prix s'affiche automatiquement au client.
- `od_payments` — le paiement en ligne s'ouvre.
- `dispatch_notifications` — la diffusion part aux transporteurs (sans lui, c'est
  vous qui attribuez depuis l'administration).
- `live_tracking` — le suivi en direct.
- `direct_accept` — accepter / refuser remplace les candidatures.

`subscriptions` reste **fermé** : les abonnements sont livrés mais pas ouverts.

### 7.4 Retour arrière

- **Immédiat** : remettre les interrupteurs à `false`. L'application reprend son
  comportement d'avant, sans redéploiement.
- **Barème** : réactiver une version archivée avec
  `select public.secoto_admin_activate_grid('<id>')`. Les devis déjà émis gardent
  la version qui les a produits.
- **Délais** : `update public.app_settings set value = value || '{"offer_ttl_minutes": 30}'::jsonb where key = 'dispatch_policy';`
- **Complet** : `supabase/rollback/030-032_rollback.sql`.

---

## 8. Vérifications effectuées

- **183 tests** applicatifs et serveur (dont 17 sur le barème, le parcours et les
  libellés affichés) : verts.
- **24 tests d'intégration** sur une base PostgreSQL réelle, migrations rejouées
  de zéro : concurrence d'attribution, webhooks rejoués et désordonnés, échec de
  capture, absence de transporteur, annulation à 24 h et retenue de 50 %,
  versement à 48 h dans les deux modes, facture et mention de TVA, pilotage admin
  en cours de mission, acceptation directe concurrente, cloisonnement RLS.
- **Rejeu double** de toutes les migrations : aucune erreur, aucun doublon.
- **Chemin de production simulé** : base à l'état réel (030-032 avec le revoke
  fautif) → fichier à coller → droits rétablis et barèmes actifs.
- **Lint** propre, **construction** vérifiée (960 ko, contenant bien l'application).

Ce qui n'a **pas** été fait, volontairement : aucun déploiement, aucun paiement
réel, aucune notification envoyée à un vrai utilisateur, aucun interrupteur ouvert.
