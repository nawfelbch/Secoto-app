# SECOTO — Refonte : guide de mise en place

Refonte visuelle **liquid glass** (clair/sombre auto), **rôle client** avec publication directe de courses, **sous-types transporteurs** (convoyeur / VL / PL), **notifications temps réel** + scaffold **web-push**.

## 1. Base de données (à faire une fois)

Dans Supabase → **SQL Editor**, exécuter dans l'ordre :

1. `supabase-migration.sql` — colonnes `transporter_type` / `client_type`, `missions.client_account_id`, tables `notifications` et `push_subscriptions`, policies RLS, activation Realtime.
2. `handle_new_user.sql` — met à jour le trigger d'inscription pour recopier le rôle, le sous-type transporteur et le type client. **Les clients sont actifs immédiatement**, les transporteurs restent en attente de validation SECOTO.

> Les policies fournies sont additives et non destructives. Vérifiez qu'elles cohabitent avec vos policies existantes sur `missions`.

## 2. Lancer / déployer

```bash
npm install      # régénère les binaires natifs (Vite) pour votre OS
npm run dev      # développement
npm run build    # build de production (dossier dist/)
```

Sur Netlify, `npm install` s'exécute automatiquement : le build fonctionne sans intervention.

## 3. Thème clair / sombre

- Suit automatiquement le thème de l'appareil (`prefers-color-scheme`).
- Un bouton **☀︎/☾** dans l'en-tête permet de forcer clair ou sombre (mémorisé sur l'appareil).

## 4. Notifications

- **Temps réel** : actif immédiatement après la migration (aucune config). Cloche + toasts dès qu'une course est postée (transporteurs) ou qu'une étape est remplie (client).
- **Web-push système** (app fermée) : le service worker (`public/sw.js`) et l'abonnement (`src/push.js`) sont déjà en place. Pour l'activer réellement :

  1. Générer une paire de clés VAPID :
     ```bash
     npx web-push generate-vapid-keys
     ```
  2. **Netlify → Site settings → Environment variables** :
     - `VAPID_PUBLIC_KEY`
     - `VAPID_PRIVATE_KEY`
     - `VAPID_SUBJECT` = `mailto:contact.secoto@gmail.com`
     - `SUPABASE_URL`
     - `SUPABASE_SERVICE_ROLE_KEY`
  3. **Variable front** (fichier `.env`, non commité) :
     - `VITE_VAPID_PUBLIC_KEY` = la même clé publique VAPID
  4. Rebuild / redeploy.

  Tant que ces clés ne sont pas fournies, la fonction Netlify répond « skipped » et seule la brique temps réel fonctionne — rien ne casse.

## 5. Ce qui a changé côté code

| Fichier | Rôle |
|---|---|
| `src/index.css` | Design system liquid glass, thème auto clair/sombre |
| `src/lib/mappers.js` | Mappers Supabase + libellés (extraits de App.jsx) |
| `src/App.jsx` | Multi-rôles (client/transporteur/admin), espace client, notifications, badges de type |
| `src/push.js` | Enregistrement SW + abonnement web-push |
| `public/sw.js` | Service worker (push + PWA) |
| `netlify/functions/send-mission-notifications.js` | Envoi push serveur |
| `supabase-migration.sql`, `handle_new_user.sql` | Schéma + trigger |

L'ancien fichier `src/App.txt` (sauvegarde) et `src/App.css` (non importé) peuvent être supprimés.

## 6. Navigation & ergonomie

- **Menu latéral gauche** : fixe sur desktop, tiroir coulissant (bouton hamburger + fond assombri) sur mobile. Catégories rangées par section selon le rôle. L'ancienne barre d'onglets horizontale est supprimée.
- **100 % responsive** : le contenu passe en une colonne sur petit écran, cartes empilées, cibles tactiles ≥ 44px.
- **Bouton flottant (FAB)** « Nouvelle course » pour le client, accessible partout.
- Profil, actualisation et déconnexion regroupés en bas du menu latéral.

## 7. Suppression d'annonces

- **Admin** : bouton « Supprimer l'annonce » sur chaque mission publiée.
- **Client** : bouton « Supprimer ma course » sur ses courses tant qu'elles ne sont pas attribuées.
- Nécessite les policies `missions_delete` / `applications_delete_by_mission_owner` ajoutées dans `supabase-migration.sql` (réexécuter le fichier si déjà passé une première fois).

> Build de production vérifié (`vite build`) : compilation OK.
