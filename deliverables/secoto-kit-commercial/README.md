# Kit commercial PDF SECOTO

Ce kit traduit l’offre réelle de l’application en trois documents B2B cohérents,
sans statistiques, témoignages ni garanties inventées.

## Livrables

1. **`SECOTO_Fiche_Commerciale_Pro.pdf` — 2 pages**
   - Usage : premier contact, e-mail, WhatsApp, LinkedIn.
   - Objectif : faire comprendre la promesse en moins de deux minutes.

2. **`SECOTO_Dossier_Solution_Entreprises.pdf` — 7 pages**
   - Usage : après un échange ou un rendez-vous.
   - Objectif : installer la valeur de la coordination, traiter le choix
     convoyage/plateau et apporter la preuve produit.

3. **`SECOTO_Modele_Proposition_Commerciale.pdf` — 5 pages**
   - Usage : closing après qualification du besoin.
   - Objectif : personnaliser le contexte, le périmètre, les responsabilités,
     le prix client et la mission pilote.
   - Les zones orange indiquent les éléments à adapter au prospect et au devis.

## Angle de conversion retenu

SECOTO ne se présente pas comme le transporteur physique. La promesse est :

> Un seul espace pour demander, suivre et documenter chaque transport de véhicule.

La valeur mise en avant est la continuité opérationnelle :

- demande structurée ;
- coordination par SECOTO ;
- devis et signature dans l’application ;
- suivi mis à jour aux étapes clés ;
- états des lieux et photos rattachés à la mission ;
- historique et documents centralisés ;
- convoyage ou plateau, selon le véhicule et le besoin.

## Règles de rédaction respectées

- Pas de GPS continu annoncé : on parle de **suivi par étapes**.
- Pas de prix, délai, ROI ou taux de satisfaction inventé.
- Pas de coût partenaire ni de marge SECOTO dans les documents clients.
- Le convoyage et le plateau sont clairement séparés.
- Les captures sont signalées comme démonstrations produit.
- Le rôle de coordinateur logistique et d’intermédiaire est précisé.

## Régénérer les fichiers

Les sources HTML/CSS restent modifiables dans `sources/`.

Depuis PowerShell :

```powershell
.\generate-pdfs.ps1
node .\validate-pdfs.mjs
```

Utiliser `.\generate-pdfs.ps1 -SkipPreviews` pour ne produire que les PDF.

La direction artistique reprend la marque de l’application : bleu nuit
`#060B16`, orange `#FF6A1A`, blanc froid, gris acier, bouclier SECOTO et
tracés d’itinéraire.
