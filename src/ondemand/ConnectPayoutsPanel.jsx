import { useCallback, useEffect, useState } from "react";
import { humanizeError } from "../lib/humanError";
import { connectOnboarding } from "../lib/onDemand";

// Paiements SECOTO : le transporteur confie son identité et son IBAN à Stripe,
// jamais à SECOTO. SECOTO déclenche ensuite chaque paiement sous 48 h après la
// livraison ; le virement vers sa banque suit le calendrier de son compte.
const LIBELLES = {
  none: { texte: "Non configuré", classe: "is-warn" },
  incomplete: { texte: "Inscription à terminer", classe: "is-warn" },
  pending: { texte: "Vérification en cours chez Stripe", classe: "is-warn" },
  restricted: { texte: "Informations à compléter", classe: "is-bad" },
  active: { texte: "Actif", classe: "is-ok" },
};

export default function ConnectPayoutsPanel() {
  const [etat, setEtat] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const charger = useCallback(async () => {
    try {
      setEtat(await connectOnboarding("status"));
      setError("");
    } catch (e) {
      setError(humanizeError(e));
    }
  }, []);

  useEffect(() => { queueMicrotask(charger); }, [charger]);

  async function ouvrir(action) {
    setBusy(true);
    setError("");
    try {
      const { url } = await connectOnboarding(action);
      if (url) window.location.assign(url);
    } catch (e) {
      setError(humanizeError(e));
      setBusy(false);
    }
  }

  const libelle = LIBELLES[etat?.status] || LIBELLES.none;
  const actif = etat?.status === "active";
  const aUnCompte = etat && etat.status !== "none";

  return (
    <div className="panel panel-full">
      <h2>Paiements SECOTO</h2>
      <p className="muted">
        Vos paiements sont déclenchés sous 48 h après chaque livraison, directement sur votre compte de versement.
        Votre identité et votre IBAN sont confiés à Stripe, notre prestataire de paiement : SECOTO ne les voit jamais.
      </p>
      {error && <div className="alert error">{error}</div>}
      <p>État : <span className={`od-pill ${libelle.classe}`}>{etat ? libelle.texte : "Chargement…"}</span></p>
      {etat?.status === "restricted" && (
        <p className="muted">Stripe a besoin d’informations complémentaires avant de pouvoir vous verser vos paiements.</p>
      )}
      <div className="actions-row">
        {!actif && (
          <button className="btn primary small" type="button" disabled={busy || !etat} onClick={() => ouvrir("link")}>
            {aUnCompte ? "Terminer mon inscription" : "Configurer mes versements"}
          </button>
        )}
        {aUnCompte && (
          <button className="btn ghost small" type="button" disabled={busy} onClick={() => ouvrir("dashboard")}>
            Ouvrir mon espace Stripe
          </button>
        )}
        <button className="btn ghost small" type="button" disabled={busy} onClick={charger}>Actualiser</button>
      </div>
    </div>
  );
}
