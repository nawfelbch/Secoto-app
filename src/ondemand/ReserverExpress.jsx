// SECOTO — Bloc « Réserver » sous le prix, pour le visiteur sans compte.
// Nom + e-mail, une case si les conditions sont actives, un bouton. Le compte
// client est créé en arrière-plan (src/lib/compteExpress.js) et l'app ouvre
// directement le paiement au prix affiché.
import { useEffect, useState } from "react";
import { supabase } from "../supabaseClient";
import { ConditionsSentence } from "../ConditionsGate";
import { conditionsLinks, termsPublic } from "../lib/conditions";
import { creerCompteExpress, verifierSaisie } from "../lib/compteExpress";
import { contactMemorise, memoriserContact } from "../lib/contactDevis";
import { attributionPourEnvoi } from "../lib/attribution";
import { consentementPub, evenement } from "../lib/consentement";
import { getAuthRedirectUrl, getPlatform, openExternal } from "../platform/runtime";
import { humanizeError } from "../lib/humanError";

export default function ReserverExpress({ onConnexion }) {
  const memo = contactMemorise();
  const [nom, setNom] = useState("");
  const [email, setEmail] = useState(() => memo?.email || "");
  const [conditions, setConditions] = useState(null);
  const [coche, setCoche] = useState(false);
  const [etat, setEtat] = useState("saisie"); // saisie | envoi | ouverture | confirmation
  const [erreur, setErreur] = useState("");

  useEffect(() => {
    let vivant = true;
    termsPublic().then((c) => { if (vivant) setConditions(c?.active && c?.version ? c : null); }).catch(() => {});
    return () => { vivant = false; };
  }, []);

  async function reserver(e) {
    e.preventDefault();
    setErreur("");
    const probleme = verifierSaisie({ nom, email });
    if (probleme) { setErreur(probleme); return; }
    if (conditions && !coche) { setErreur("Cochez la case pour accepter les conditions."); return; }
    setEtat("envoi");
    // L'e-mail sert aussi à pré-remplir la connexion si le compte existe déjà.
    memoriserContact({ phone: memo?.phone || "", email: email.trim().toLowerCase() });
    try {
      const r = await creerCompteExpress({
        supabase,
        nom,
        email,
        telephone: memo?.phone || "",
        termsVersion: conditions && coche ? conditions.version : null,
        platform: getPlatform(),
        redirection: getAuthRedirectUrl(),
        attribution: attributionPourEnvoi(),
        consentement: consentementPub(),
      });
      if (r.existant) {
        setEtat("saisie");
        setErreur("Cette adresse a déjà un compte SECOTO : touchez « Déjà client ? Me connecter » pour réserver.");
        return;
      }
      if (r.confirmation) { setEtat("confirmation"); return; }
      evenement("compte_cree", { role: "client", express: true }, { eventId: r.userId ? `compte-${r.userId}` : undefined });
      // La session est ouverte : l'app rattache le devis et ouvre le paiement.
      setEtat("ouverture");
    } catch (err) {
      setEtat("saisie");
      setErreur(humanizeError(err, "La réservation n’a pas pu démarrer. Réessayez dans un instant."));
    }
  }

  if (etat === "confirmation") {
    return (
      <div className="od-compte-cta" role="status">
        <strong className="od-compte-titre">Dernière étape : confirmez votre e-mail</strong>
        <p>Ouvrez le lien reçu à {email.trim().toLowerCase()} : votre prix est conservé et le paiement s’ouvre aussitôt.</p>
      </div>
    );
  }

  const liens = conditions ? conditionsLinks(["cgu", "confidentialite"], conditions.documents, conditions.version) : [];
  return (
    <form className="od-compte-cta" onSubmit={reserver} aria-label="Réserver ce transport">
      <strong className="od-compte-titre">Réservez ce prix en 1 minute</strong>
      <ul>
        <li>Pas de mot de passe à créer</li>
        <li>Le paiement s’ouvre juste après, au prix affiché</li>
        <li>Remboursé intégralement si aucun transporteur n’accepte</li>
      </ul>
      <label className="field">
        <span>Votre nom</span>
        <input value={nom} autoComplete="name" onChange={(e) => setNom(e.target.value)} placeholder="Prénom Nom" />
      </label>
      <label className="field">
        <span>Votre e-mail (confirmation de réservation)</span>
        <input type="email" inputMode="email" autoComplete="email" value={email}
          onChange={(e) => setEmail(e.target.value)} placeholder="prenom@gmail.com" />
      </label>
      {conditions && (
        <label className="payment-waiver-row">
          <input type="checkbox" checked={coche} onChange={(e) => setCoche(e.target.checked)} />
          <ConditionsSentence links={liens} onOpen={(url) => openExternal(url).catch(() => {})} />
        </label>
      )}
      {erreur && <p className="alert error" role="alert">{erreur}</p>}
      <button className="btn primary od-compte-btn" type="submit" disabled={etat !== "saisie"}>
        {etat === "envoi" ? "Réservation…" : etat === "ouverture" ? "Ouverture du paiement…" : "Réserver"}
      </button>
      <button className="linklike od-compte-connexion" type="button" onClick={() => onConnexion?.()}>
        Déjà client ? Me connecter
      </button>
      <small className="muted">Pour revenir plus tard depuis un autre appareil : « Mot de passe oublié » avec cet e-mail.</small>
    </form>
  );
}
