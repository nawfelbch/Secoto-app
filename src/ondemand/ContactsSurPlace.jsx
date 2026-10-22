// SECOTO 115 — Contacts à l'enlèvement et à la livraison, saisis par le client
// après la réservation. Professionnel : un nom (garage, société) suffit.
// Particulier : téléphone obligatoire. Le transporteur attribué les reçoit.
import { useState } from "react";
import { humanizeError } from "../lib/humanError";
import { enregistrerContactsSurPlace } from "../lib/onDemand";
import { telephoneLisible, telephonePropre } from "../lib/contactDevis";

const vide = { nom: "", telephone: "" };
const versForm = (c) => (c ? { nom: c.nom || "", telephone: telephoneLisible(c.telephone || "") } : { ...vide });
const resume = (c) => [c?.nom, c?.telephone ? telephoneLisible(c.telephone) : null].filter(Boolean).join(" · ") || "à préciser";

export default function ContactsSurPlace({ order, onChange }) {
  const pro = order.client_pro === true;
  const renseignes = Boolean(order.contact_enlevement && order.contact_livraison);
  const [ouvert, setOuvert] = useState(!renseignes);
  const [enl, setEnl] = useState(() => versForm(order.contact_enlevement));
  const [liv, setLiv] = useState(() => versForm(order.contact_livraison));
  const [busy, setBusy] = useState(false);
  const [erreur, setErreur] = useState("");

  const valide = (c) => {
    const telOk = !c.telephone.trim() || Boolean(telephonePropre(c.telephone));
    return telOk && (pro ? Boolean(c.nom.trim() || c.telephone.trim()) : Boolean(telephonePropre(c.telephone)));
  };

  async function enregistrer(e) {
    e.preventDefault();
    setBusy(true); setErreur("");
    try {
      const o = await enregistrerContactsSurPlace(order.id, enl, liv);
      onChange?.(o);
      setOuvert(false);
    } catch (err) {
      setErreur(humanizeError(err, "Les contacts n’ont pas pu être enregistrés."));
    } finally {
      setBusy(false);
    }
  }

  if (!ouvert) {
    return (
      <div className="od-contacts">
        <p><strong>Contact à l’enlèvement :</strong> {resume(order.contact_enlevement)}</p>
        <p><strong>Contact à la livraison :</strong> {resume(order.contact_livraison)}</p>
        <button className="linklike" type="button" onClick={() => setOuvert(true)}>Modifier les contacts</button>
      </div>
    );
  }

  const champ = (lieu, c, set) => (
    <fieldset className="od-contacts-lieu">
      <legend>{lieu}</legend>
      <label className="field"><span>{pro ? "Nom (garage, société…) *" : "Nom (facultatif)"}</span>
        <input value={c.nom} maxLength={120} autoComplete="organization" onChange={(e) => set({ ...c, nom: e.target.value })} placeholder={pro ? "Ex : Garage Dupont" : "Ex : Marie Martin"} />
      </label>
      <label className="field"><span>{pro ? "Téléphone (facultatif)" : "Téléphone *"}</span>
        <input type="tel" inputMode="tel" autoComplete="tel" value={c.telephone} onChange={(e) => set({ ...c, telephone: e.target.value })} placeholder="06 12 34 56 78" />
      </label>
    </fieldset>
  );

  return (
    <form className="od-contacts applications-box" onSubmit={enregistrer} noValidate>
      <h4>Contacts sur place</h4>
      <p className="muted">Qui le transporteur doit-il appeler à l’enlèvement et à la livraison ? Il les reçoit dès qu’il accepte la course.</p>
      {champ("À l’enlèvement", enl, setEnl)}
      {champ("À la livraison", liv, setLiv)}
      {erreur && <div className="alert error">{erreur}</div>}
      <div className="actions-row">
        <button className="btn primary small" type="submit" disabled={busy || !valide(enl) || !valide(liv)}>{busy ? "Enregistrement…" : "Enregistrer les contacts"}</button>
        {renseignes && <button className="btn ghost small" type="button" disabled={busy} onClick={() => setOuvert(false)}>Annuler</button>}
      </div>
    </form>
  );
}
