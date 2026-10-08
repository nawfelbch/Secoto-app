import { contactLinks, phoneDisplay } from "./lib/contactLinks";
import { openExternal } from "./platform/runtime";

// ============================================================================
// SECOTO 084 — Mise en relation directe client <-> transporteur.
// ----------------------------------------------------------------------------
// Côté client : « Votre transporteur », son identité légale et des boutons
// Appeler / SMS / WhatsApp. Côté transporteur : les mêmes boutons vers le
// client. Boutons natifs : tel: et sms: ouvrent les applis du téléphone.
// ============================================================================

function ouvrir(url) {
  openExternal(url).catch(() => {});
}

export default function CarteContact({ titre, nom, details = [], phone, message = "", note = "" }) {
  const links = contactLinks(phone, message);
  return (
    <div className="carte-transporteur">
      <h4>{titre}</h4>
      {nom && <div className="ct-nom">{nom}</div>}
      {details.filter(Boolean).map((d) => <p className="ct-info" key={d}>{d}</p>)}
      {phone && <p className="ct-info">Téléphone : <strong>{phoneDisplay(phone)}</strong></p>}
      {links && (
        <div className="ct-actions">
          <button className="btn primary small" type="button" onClick={() => ouvrir(links.tel)}>Appeler</button>
          <button className="btn ghost small" type="button" onClick={() => ouvrir(links.sms)}>SMS</button>
          <button className="btn ghost small" type="button" onClick={() => ouvrir(links.whatsapp)}>WhatsApp</button>
        </div>
      )}
      {note && <p className="ct-info">{note}</p>}
    </div>
  );
}

export function CarteTransporteur({ contact, reference }) {
  if (!contact) return null;
  const nomLegal = contact.legal_name && contact.legal_name !== contact.name ? contact.legal_name : null;
  return (
    <CarteContact
      titre="Votre transporteur"
      nom={contact.name}
      details={[nomLegal, contact.siren ? `SIREN ${String(contact.siren).replace(/(\d{3})(?=\d)/g, "$1 ")}` : null]}
      phone={contact.phone}
      message={reference ? `Bonjour, je vous contacte pour le transport ${reference} réservé sur SECOTO.` : ""}
      note="C’est votre interlocuteur pour l’enlèvement, le trajet et la livraison. En cas de difficulté, le SAV SECOTO vous accompagne depuis l’application."
    />
  );
}
