# SECOTO — Packaging Capacitor (Android + iOS)

Ce que j'ai déjà fait dans le repo :
- Installé Capacitor 8 + plugins natifs (caméra, géolocalisation, push, status bar, clavier).
- Créé `capacitor.config.json` (appId `fr.secototransport.app`, nom « SECOTO », `webDir: dist`).
- Ajouté les scripts npm : `cap:sync`, `cap:android`, `cap:ios`.

Toi, tu dois : installer les logiciels, générer les plateformes, régler les permissions, compiler.

---

## 1. Logiciels à installer (Windows)

| Logiciel | Pour quoi | Lien |
|---|---|---|
| **Node.js LTS** | déjà installé (tu build déjà l'app) | nodejs.org |
| **Android Studio** | compiler et tester l'app **Android** localement (inclut le JDK et le SDK Android) | developer.android.com/studio |
| **Compte Codemagic** (gratuit au début) | compiler l'app **iOS sans Mac** (build sur des Mac dans le cloud) | codemagic.io |

> Tu n'as pas de Mac → **iOS se fera via Codemagic** (ou un autre build cloud). Android se fait sur ton PC avec Android Studio.

---

## 2. Préparer le projet (une fois)

Dans un terminal, dans le dossier `secoto-app` :

```
npm install                      # installe Capacitor et tout le reste
```

Crée un fichier **`.env`** à la racine (pour que le build local connaisse Supabase) :

```
VITE_SUPABASE_URL=https://znnigxmzacukpfueqfrh.supabase.co
VITE_SUPABASE_ANON_KEY=  (ta clé anon Supabase, la même que sur Netlify)
VITE_VAPID_PUBLIC_KEY=   (ta clé publique VAPID, si tu l'as configurée)
```

La clé anon est publique (protégée par les règles RLS), tu peux la mettre là sans risque.

---

## 3. ANDROID (le plus rapide)

```
npx cap add android              # crée le dossier /android (une seule fois)
npm run cap:android              # build web + sync + ouvre Android Studio
```

Dans **Android Studio** :
1. Laisse-le télécharger ce qu'il propose (SDK, Gradle) à la première ouverture.
2. **Build > Generate Signed Bundle / APK > Android App Bundle (.aab)** → crée une clé de signature (garde-la précieusement) → génère le `.aab`.
3. Ce `.aab` est le fichier à uploader sur **Google Play Console**.

Icône et nom : je peux te générer les icônes Android/iOS à partir de ton logo (dis-le-moi).

---

## 4. iOS (via Codemagic, sans Mac)

1. Crée le dossier iOS (fonctionne aussi sous Windows, il sera compilé dans le cloud) :
   ```
   npx cap add ios
   ```
2. Commite et pousse le repo (le dossier `ios/` doit partir sur GitHub).
3. Sur **codemagic.io** : connecte ton dépôt GitHub `nawfelbch/Secoto-app`.
4. Choisis le workflow **Capacitor / iOS**. Codemagic compile sur un Mac cloud avec Xcode récent.
5. Renseigne ton **compte Apple Developer** dans Codemagic (signature automatique). Codemagic envoie le build directement sur **App Store Connect / TestFlight**.

> Codemagic gère Xcode 26 / SDK iOS 26 (exigence Apple depuis avril 2026) — tu n'as rien à installer.

---

## 5. Permissions (obligatoire pour Apple)

Ton app utilise **appareil photo**, **photos** et **localisation**. Apple **refuse** si les textes d'explication manquent. À ajouter :

**iOS** — dans `ios/App/App/Info.plist` (après `cap add ios`) :
```
<key>NSCameraUsageDescription</key>
<string>SECOTO utilise l'appareil photo pour vos états des lieux et justificatifs.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>SECOTO accède à vos photos pour joindre états des lieux et justificatifs.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>SECOTO utilise votre position pour le suivi de mission en temps réel.</string>
```

**Android** — dans `android/app/src/main/AndroidManifest.xml` : les permissions caméra/localisation/notifications (je te donnerai les lignes exactes au moment voulu).

---

## 6. Étape suivante (je m'en occupe côté code)

Une fois le shell qui tourne, je branche les **fonctions natives** (sinon Apple juge que c'est un simple site web) :
- Caméra native (au lieu du `<input type=file>`) pour les photos terrain.
- Notifications push natives (APNs/FCM) via `@capacitor/push-notifications`.
- Barre de statut / safe-area natives, et demande de permission au bon moment.

Dis-moi quand tu as installé Android Studio et créé ton compte Codemagic — on avance étape par étape.
