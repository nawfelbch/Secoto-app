import { useId, useState } from "react";
import { aideContact, contactValide } from "../lib/contactDevis";

// SECOTO 090 — Dernière étape avant le prix, pour un visiteur sans compte.
// Une seule case : le téléphone (préféré), ou l'e-mail d'un geste. Le prix
// s'affiche juste après, à l'écran : on le dit, pour rassurer.
export default function ContactAvantPrix({ value, onChange, onSubmit }) {
  const id = useId();
  const [mode, setMode] = useState(() => (!value?.phone && value?.email ? "email" : "telephone"));
  const [touche, setTouche] = useState(false);
  const aide = touche ? aideContact(value, mode) : "";
  const pret = Boolean(contactValide(value));

  function basculer() {
    setMode((m) => (m === "telephone" ? "email" : "telephone"));
    setTouche(false);
  }

  return (
    <form
      className="contact-prix"
      noValidate
      onSubmit={(e) => { e.preventDefault(); setTouche(true); if (pret) onSubmit?.(); }}
    >
      <p className="contact-prix-etape">Dernière étape</p>
      <h3 className="contact-prix-titre">Votre prix s’affiche juste après</h3>
      <p className="muted contact-prix-sous">
        {mode === "telephone"
          ? "Facultatif : laissez votre numéro pour recevoir votre prix et être rappelé si besoin."
          : "Facultatif : laissez votre e-mail pour recevoir votre prix et un rappel avant qu’il expire."}
      </p>

      {mode === "telephone" ? (
        <label className="field contact-prix-champ" htmlFor={`${id}-tel`}>
          <span>Numéro de téléphone</span>
          <input
            id={`${id}-tel`}
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            enterKeyHint="go"
            placeholder="06 12 34 56 78"
            value={value?.phone || ""}
            aria-invalid={Boolean(aide)}
            onChange={(e) => onChange({ ...value, phone: e.target.value })}
            onBlur={() => setTouche(true)}
          />
        </label>
      ) : (
        <label className="field contact-prix-champ" htmlFor={`${id}-mail`}>
          <span>Adresse e-mail</span>
          <input
            id={`${id}-mail`}
            type="email"
            inputMode="email"
            autoComplete="email"
            autoCapitalize="none"
            enterKeyHint="go"
            placeholder="vous@exemple.fr"
            value={value?.email || ""}
            aria-invalid={Boolean(aide)}
            onChange={(e) => onChange({ ...value, email: e.target.value })}
            onBlur={() => setTouche(true)}
          />
        </label>
      )}
      {aide && <small className="contact-prix-aide" role="status">{aide}</small>}

      <button type="button" className="contact-prix-bascule" onClick={basculer}>
        {mode === "telephone" ? "Je préfère laisser mon e-mail" : "Je préfère laisser mon numéro"}
      </button>

      <ul className="contact-prix-rassurance">
        <li>Votre prix s’affiche immédiatement à l’écran</li>
        <li>Aucun compte à créer, aucun paiement à cette étape</li>
        <li>Utilisé uniquement pour cette demande : ni démarchage, ni revente</li>
      </ul>
      <p className="muted contact-prix-legal">
        Vos coordonnées servent à vous recontacter au sujet de cette demande.{" "}
        <a href="/politique-confidentialite.html" target="_blank" rel="noopener noreferrer">Confidentialité</a>
      </p>
      {/* Touche « Entrée » du clavier : envoie le formulaire. */}
      <button type="submit" hidden aria-hidden="true" tabIndex={-1} />
    </form>
  );
}
