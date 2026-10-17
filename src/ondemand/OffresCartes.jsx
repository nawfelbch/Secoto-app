import { OFFRE_LIBELLE, fenetreLibelle, formatCents, transporteursLibelle } from "../lib/orderCopy";
import { BADGE_STANDARD } from "../lib/offres";

// ============================================================================
// SECOTO 099 — Trois offres sur l'écran du prix (Express, Standard, Éco).
// ----------------------------------------------------------------------------
// Tout vient du devis calculé en base : prix, fenêtre de prise en charge,
// nombre réel de transporteurs vérifiés. Rien n'est promis : une fenêtre, pas
// un délai garanti ; aucune confirmation dans la fenêtre = aucun débit.
// Cartes côte à côte sur ordinateur, empilées sur téléphone. Sélection au
// clavier comme au doigt (boutons radio natifs, accessibles partout).
// ============================================================================


const ACCROCHE = {
  express: "Diffusée en priorité à tous les transporteurs vérifiés",
  standard: "Le meilleur équilibre prix / délai",
  eco: "Porte-voitures en groupage, pour qui peut attendre",
};

export default function OffresCartes({ offres, choix, onChoix, disabled = false }) {
  if (!offres?.length) return null;
  return (
    <fieldset className="od-offres" disabled={disabled}>
      <legend className="sr-only">Choisissez votre offre</legend>
      <div className="od-offres-grille" role="radiogroup" aria-label="Choisissez votre offre">
        {offres.map((o) => {
          const actif = choix === o.cle;
          return (
            <label key={o.cle} className={`od-offre${actif ? " is-actif" : ""}${o.recommande ? " is-recommande" : ""}`}>
              <input type="radio" name="od-offre" value={o.cle} checked={actif} onChange={() => onChoix?.(o.cle)} />
              {o.recommande && <span className="od-offre-badge">{BADGE_STANDARD}</span>}
              <span className="od-offre-nom">{o.libelle || OFFRE_LIBELLE[o.cle] || o.cle}</span>
              <strong className="od-offre-prix">{formatCents(o.client_cents)}</strong>
              <span className="od-offre-fenetre">Prise en charge {fenetreLibelle(o.fenetre_h)}</span>
              <span className="od-offre-detail">À domicile · {ACCROCHE[o.cle] || ""}</span>
              <span className="od-offre-transporteurs">{transporteursLibelle(o.transporteurs)}</span>
            </label>
          );
        })}
      </div>
    </fieldset>
  );
}

// Sous le bouton de réservation, en petit : décomposition et rôle de SECOTO.
export function OffreDecomposition({ offre }) {
  if (!offre) return null;
  return (
    <div className="muted od-decomposition od-offre-decompo">
      <div>Dont prix réservé au transporteur : {formatCents(offre.partenaire_cents)}</div>
      <div>Commission de mise en relation SECOTO : {formatCents(offre.commission_cents)}</div>
      <div>Aucun transporteur ne confirme {fenetreLibelle(offre.fenetre_h).replace("sous", "dans les")} : aucun débit, la demande est annulée automatiquement.</div>
      <div>SECOTO agit en tant qu’intermédiaire ; le transport est exécuté par un transporteur professionnel indépendant.</div>
    </div>
  );
}
