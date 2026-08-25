# Son de notification SECOTO — provenance et préparation

## Fichier livré
`secoto_cash_register.wav` — présent en deux exemplaires **identiques** :

| Plateforme | Emplacement | Rôle |
|---|---|---|
| iOS | `ios/App/App/secoto_cash_register.wav` | référencé dans `project.pbxproj`, embarqué dans le bundle |
| Android | `android/app/src/main/res/raw/secoto_cash_register.wav` | référencé sans extension par le canal `secoto-cash-register-v1` |

```
SHA-256  766a7f3c4d14f9d3c1fa9aff3ffde9864dd7ea3d14f364650c9957e5d8816042
format   WAV PCM 16 bits, mono, 44 100 Hz
durée    1,292 s
pic      -1,70 dBFS, aucun écrêtage
```

Le CI vérifie cette empreinte : toute modification du fichier sans mise à jour
de ce document arrête le build.

## Source
Enregistrement réel fourni par SECOTO, conservé ici tel quel :
`source-cash-register-kaching.mp3` (3,19 s, MP3 stéréo 256 kb/s).

Nom d'origine du fichier :
`modestas123123-cash-register-kaching-sound-effect-125042.mp3`

> **⚠ À compléter par SECOTO avant publication sur les stores :** URL de la
> page de téléchargement et intitulé exact de la licence. Une licence
> autorisant l'usage **commercial** est obligatoire — l'application est
> distribuée sur l'App Store et Google Play. Les licences « non commercial »
> ou « no derivatives » sont exclues, cette dernière parce que le fichier est
> recadré et normalisé ci-dessous.
>
> - Source (URL) : _à renseigner_
> - Licence : _à renseigner_
> - Attribution requise : _oui / non_ — si oui, la mentionner dans l'écran
>   Informations légales de l'application.

## Préparation appliquée à la source
Traitement effectué une fois, à la main ; le WAV versionné en est le résultat.
Il n'a pas besoin d'être rejoué, et n'est volontairement pas automatisé en CI
(cela imposerait ffmpeg aux machines de build).

1. **Conversion** en mono 44 100 Hz PCM 16 bits.
   Les deux canaux d'origine sont corrélés à 0,98 : le passage en mono ne
   retire rien d'audible et divise le poids par deux.
2. **Recadrage** de 0,469 s à 1,761 s. La source commence par **0,48 s de
   silence numérique** : conservée telle quelle, la notification aurait paru
   muette une demi-seconde, ce qui la fait passer pour cassée. La coupe part
   8 ms avant le premier échantillon utile pour ne pas entamer l'attaque, et
   se termine 30 ms après le passage de la queue sous -60 dBFS.
   La montée mécanique des 200 premières ms est **conservée** : ce n'est pas
   du bruit de fond mais le mécanisme qui s'enclenche.
3. **Fondus** de 2 ms à l'attaque et 35 ms en fin, pour supprimer les clics de
   coupe.
4. **Normalisation** du pic à -1,70 dBFS. La source plafonnait à -4,0 dBFS
   avec un RMS de 0,021 : trop discrète sur un haut-parleur de téléphone.

## Contraintes des plateformes, vérifiées par le CI
- **APNs** n'accepte que du PCM linéaire (ou µLaw, aLaw, IMA4) de **30 s
  maximum**. Un fichier hors format est ignoré *sans erreur* : iOS joue alors
  le son par défaut, et le bug est invisible côté serveur.
- **Android** exige un nom en minuscules, chiffres et underscores dans
  `res/raw`. Un nom invalide fait échouer `aapt2` très tard dans Gradle.
- Le son n'existe que dans un **build natif** : un téléphone qui garde une
  version antérieure de l'application entendra le son par défaut jusqu'à sa
  mise à jour.

## Remplacer le son plus tard
1. Déposer le nouveau fichier source ici et mettre à jour cette page.
2. Rejouer la préparation ci-dessus, écrire le résultat aux deux emplacements.
3. Mettre à jour l'empreinte SHA-256 ici **et** dans `codemagic.yaml`.
4. **Incrémenter le canal Android** (`secoto-cash-register-v2`) dans
   `src/push.js` et `netlify/functions/send-mission-notifications.js` : un
   canal Android est immuable, changer le fichier sans changer d'identifiant
   de canal ne produirait **aucun** effet sur les téléphones déjà installés.
