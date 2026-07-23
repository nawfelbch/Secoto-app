# SECOTO — Guide de publication (de A à Z)

Suis les sections dans l'ordre. Coche au fur et à mesure.

---

## ÉTAT ACTUEL (déjà fait)
- App web (React/Vite) + backend Supabase : OK, en ligne sur app.secoto-transport.fr.
- Capacitor installé, plateformes **Android** et **iOS** créées, **icônes générées**.
- L'app tourne sur l'émulateur Android.
- Correctifs UI + suppression de compte + autocomplétion adresses + contact : faits dans le code.

---

## ÉTAPE 1 — Finaliser et déployer le code (à faire MAINTENANT)

### 1.1 Base de données (Supabase → SQL Editor)
Colle et lance ces fichiers, dans cet ordre (tous idempotents, rejouables) :
1. `patch_secoto_v2.sql`  (mode de règlement + IBAN + contact + **suppression de compte**)
2. `patch_mission_requests.sql`  (colonnes manquantes → corrige l'erreur de création de mission)

Résultat attendu à chaque fois : « Success. No rows returned ».

### 1.2 Recompiler le web dans l'app native
Dans un terminal, dossier `secoto-app` :
```
npm run cap:sync
```

### 1.3 Sauvegarder / déployer
```
./push.ps1
```
Ça déploie le site web ET sauvegarde `android/`, `ios/`, `assets/`, la config Capacitor.

### 1.4 Tester l'app Android
Dans Android Studio → **▶ Run** → teste : connexion, création de mission, frais, contact, cloche, suppression de compte.

---

## ÉTAPE 2 — Permissions natives (OBLIGATOIRE avant soumission)

### 2.1 iOS — fichier `ios/App/App/Info.plist`
Ajoute ces lignes juste avant la dernière balise `</dict>` :
```xml
<key>NSCameraUsageDescription</key>
<string>SECOTO utilise l'appareil photo pour vos états des lieux et justificatifs.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>SECOTO accède à vos photos pour joindre états des lieux et justificatifs.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>SECOTO enregistre des photos liées à vos missions.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>SECOTO utilise votre position pour le suivi de mission en temps réel.</string>
```

### 2.2 Android — fichier `android/app/src/main/AndroidManifest.xml`
Ajoute ces lignes dans `<manifest>`, juste avant `<application>` (INTERNET est souvent déjà là) :
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
```

> Astuce : si finalement tu n'utilises pas la caméra/localisation natives, tu peux au contraire retirer les plugins (`npm uninstall @capacitor/camera @capacitor/geolocation`) pour éviter d'avoir à justifier ces permissions à Apple.

---

## ÉTAPE 3 — Compte de démonstration pour Apple/Google (IMPORTANT)
Les testeurs Apple DOIVENT pouvoir se connecter. Crée 3 comptes de test réels dans l'app :
- 1 **admin**, 1 **transporteur** (validé), 1 **client**.

Tu fourniras leurs identifiants dans App Store Connect → *App Review Information* (jamais dans la description publique). Garde-les actifs pendant toute la revue.

---

## ÉTAPE 4 — ANDROID (Google Play) — le plus rapide

### 4.1 Compte développeur
- Crée un compte **Organisation** (25 $ une fois) → il faut un **numéro D-U-N-S** (gratuit, ~1 à 4 semaines). **Demande le D-U-N-S dès aujourd'hui**, c'est le plus long.
- (Un compte perso évite le D-U-N-S mais impose 12 testeurs pendant 14 jours avant publication.)

### 4.2 Générer le fichier à publier (.aab)
Android Studio → **Build → Generate Signed App Bundle / APK → Android App Bundle**
→ crée une **clé de signature (keystore)** et **SAUVEGARDE-LA + son mot de passe** (perdue = tu ne peux plus mettre à jour l'app).
→ tu obtiens un fichier `.aab`.

### 4.3 Play Console
1. Crée l'application, uploade le `.aab`.
2. Remplis la fiche : titre (≤30 car), description courte + longue, **icône 512** (dans `assets/`), **bandeau 1024×500**, **2-4 captures d'écran** (fais-les depuis l'émulateur).
3. **URL de confidentialité** : `https://app.secoto-transport.fr/politique-confidentialite.html`
4. Questionnaire **classification de contenu** + formulaire **Sécurité des données** (déclare : identité, contact, localisation, photos ; hébergeurs Supabase + Netlify ; pas de vente de données).
5. Envoie en revue (première revue : quelques jours).

---

## ÉTAPE 5 — iOS (App Store, via Codemagic, sans Mac)

### 5.1 Prérequis
- Compte **Apple Developer** (Organisation recommandée, 99 $/an).
- Dans le portail Apple Developer : enregistre le **Bundle ID** `fr.secototransport.app`.
- Dans **App Store Connect** : crée l'app (même Bundle ID).

### 5.2 Codemagic
1. Le fichier `codemagic.yaml` est déjà dans le repo.
2. Codemagic → *Teams/Personal → Integrations → App Store Connect* : ajoute une **clé API** (générée dans App Store Connect → *Users and Access → Integrations*), nomme-la exactement **`SECOTO_ASC`**.
3. Lance le workflow **SECOTO iOS**. Codemagic compile sur Mac cloud (Xcode récent) et envoie sur **TestFlight**.

### 5.3 App Store Connect (fiche)
Mêmes éléments que Google (nom, sous-titre, description, mots-clés sans marques concurrentes, captures iPhone réelles, classification d'âge, **App Privacy** déclarant les données + Supabase/Netlify, URL de confidentialité, URL de support, e-mail de support).
Ajoute le **compte de démonstration** (étape 3) dans *App Review Information*.
Puis **Submit for Review**.

---

## ÉTAPE 6 — Points Apple déjà en ordre (rien à faire)
- ✅ Suppression de compte en un clic (Profil).
- ✅ Politique de confidentialité accessible dans l'app + URL.
- ✅ Notifications non obligatoires et désactivables.
- ✅ Pas de « Se connecter avec Apple » requis (email/mot de passe uniquement).
- ✅ Pas d'achat intégré Apple requis (le convoyage est un service physique payé hors app → paiement externe autorisé).
- ✅ HTTPS partout, clé secrète service_role jamais dans l'app.

---

## ÉTAPE 7 — Après publication
- Garde les serveurs Supabase/Netlify actifs (surtout pendant la revue).
- Corrige vite les bugs, mets à jour la confidentialité si les données changent.
- Réponds honnêtement à un éventuel refus Apple (ils expliquent toujours la raison).

---

## Récap des fichiers utiles dans le repo
- `patch_secoto_v2.sql`, `patch_mission_requests.sql` → à lancer dans Supabase.
- `push.ps1` → déployer le web + sauvegarder.
- `GUIDE-CAPACITOR.md` → détails Capacitor.
- `capacitor.config.json`, `codemagic.yaml` → config native.
- `assets/` → icônes sources (regénérer : `npx @capacitor/assets generate`).

## Les 2 seules choses qui te bloqueront (anticipe-les)
1. **Le D-U-N-S** (Google org + Apple org) : long → demande-le en premier.
2. **Le compte Apple Developer** validé : sans lui, pas de build iOS Codemagic.

Bon courage — l'app est prête, il ne reste que l'administratif des stores. 💪
