# SECOTO — Récapitulatif d'intégration

## ⚠️ Action requise AVANT de déployer : re-jouer le SQL
Tu as déjà exécuté une première version du SQL. La version corrigée branche le
barème sur ta **vraie** colonne `missions.type` (au lieu d'une colonne `kind`
redondante). Elle est idempotente et gère la transition automatiquement.

➡️ **Ré-ouvre `migration_secoto.sql` et relance-le une dernière fois** dans le
SQL Editor Supabase (même méthode : Bloc-notes → tout copier → coller → Run).
Résultat attendu : « Success. No rows returned ». Sans ça, le prix client
calculé en base restera vide.

## Ce qui est fait et vérifié (build OK)

**Chantier 1 — Barème automatique** ✅
- `src/lib/pricing.js` : source unique (plateau ×1,20 sans plancher ;
  convoyage 1,00 / 0,55 / 0,45 €/km ; frais neutres).
- Formulaire mission admin : champ « Coût transporteur » (plateau) + encadré
  « Tarification automatique » affichant prix client / rémunération / marge.
- Calcul aussi garanti **en base** (colonnes générées depuis `type`).

**Chantier 2 — Frais réels** ✅
- `src/lib/frais.js` + `src/FraisPanel.jsx`.
- Transporteur : onglet « Mes frais » (montant + upload justificatif → bucket
  `justificatifs`, statut visible, total remboursable).
- Admin : onglet « Frais réels » (aperçu justificatif, Valider / Refuser + motif).
- Statuts en base : `en_attente` → `valide` | `refuse`.

**Chantier 3 — Documents** ✅ (génération) / ⏳ (signature & archivage)
- `src/lib/documents.js` + `src/lib/templateEngine.js` : rendu strict des 3
  maquettes (devis / bon de mission / facture), cloisonnement + garde-fou
  anti-fuite (le prix client ne peut pas apparaître sur le bon de mission).
- Admin : boutons « Devis / Bon de mission / Facture » (aperçu imprimable A4)
  sur chaque mission.
- **Reste à faire** : signature électronique dans l'app (canvas + horodatage),
  émission définitive (numéro atomique via `secoto_next_doc_number`, archivage
  PDF dans le bucket `documents-pdf`, verrouillage immuable). La base et les
  fonctions sont déjà prêtes ; il manque l'écran de signature.

**Chantier 4 — Correctifs iPhone** ✅
- Safe-area iOS (`env(safe-area-inset-*)`) sur le shell — le logo n'est plus
  masqué par la Dynamic Island.
- Header mobile sur 2 lignes (burger + actions, puis titre complet) → plus de
  « Direction S… » tronqué ni de chevauchement.
- Bouton thème en icône seule sur mobile.
- Hauteur plein écran `100dvh` + flux flex (plus de vide en bas).
- Grille de stats : déjà en `auto-fit` (pas d'orpheline).

## Fichiers créés / modifiés
Créés : `src/lib/pricing.js`, `templateEngine.js`, `documents.js`, `frais.js`,
`src/FraisPanel.jsx`, `templates/*.html`, `migration_secoto.sql`, `push.ps1`.
Modifiés : `src/App.jsx`, `src/lib/mappers.js`, `src/index.css`.

## Vérifications
- `npm run build` : OK.
- Barème testé (plateau 100→120 marge 20 ; convoyage 200 km → 200/110/90).
- Bon de mission rendu : prix client (120 €) **absent** confirmé.
- `npm run lint` : 8 erreurs PRÉ-EXISTANTES dans `App.jsx` (règle
  react-hooks, non liées à ce travail) ; aucune dans les fichiers ajoutés.
  Le lint ne fait pas partie du build Netlify.

## Ordre de déploiement
1. **Ré-exécuter `migration_secoto.sql`** dans Supabase (voir haut de page).
2. **Pousser le code** : PowerShell → `cd C:\Users\33651\secoto-app` →
   `./push.ps1 -DryRun` (test) puis `./push.ps1`. Netlify reconstruit seul.
3. Tester sur iPhone (SE, 15 Pro), Android, en clair et sombre.

## Points de vigilance
- ⚠️ Ton dossier contenait déjà des modifs non commitées (App.jsx, netlify.toml,
  supabaseClient.js, manifest.json) faites hors de cette session. `push.ps1`
  (`git add -A`) les enverrait aussi — vérifie-les avant de pousser.
- Bundle : les 3 maquettes HTML sont incluses dans le JS (≈670 kB). Fonctionnel,
  mais optimisable plus tard (charger les templates à la demande).
- Réglages bancaires (facture) : renseigner IBAN/BIC dans `app_settings`
  (table créée) — sinon la facture affiche des champs vides.
