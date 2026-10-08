import { useCallback, useEffect, useState } from "react";
import { humanizeError } from "../lib/humanError";
import { carrierAcceptBillingMandate, carrierDirectStatus, connectOnboarding } from "../lib/onDemand";

// ============================================================================
// SECOTO 074 — Paiement direct (transporteurs plateau).
// ----------------------------------------------------------------------------
// Le client paie directement le transporteur ; SECOTO ne garde que sa
// commission, prélevée automatiquement par Stripe. Une seule démarche :
//   1. informations légales + mandat de facturation (case jamais pré-cochée) ;
//   2. activation chez Stripe (lien hébergé par Stripe, ouvert une fois).
// Ensuite le transporteur ne revoit plus Stripe : il accepte des missions et
// Stripe lui verse automatiquement ce qu'il encaisse.
// ============================================================================

const MANDAT_VERSION = "2026-10-08";

const MANDAT_TEXTE = [
  "En activant le paiement direct, vous donnez mandat à SECOTO (SIREN 951 857 531) d’établir et d’émettre, en votre nom et pour votre compte, les factures des transports que vous réalisez pour les clients mis en relation par l’application.",
  "Chaque facture porte la mention « Facture établie par SECOTO au nom et pour le compte de » votre entreprise, avec vos informations ci-dessous et une numérotation propre à votre entreprise. Vous garantissez l’exactitude de ces informations et les tenez à jour.",
  "Vous restez seul redevable de la TVA éventuellement due sur vos prestations et de vos obligations déclaratives.",
  "Une copie de chaque facture est disponible dans l’application dès son émission ; vous disposez de 7 jours pour la contester.",
  "Les frais de mise en relation de SECOTO sont prélevés automatiquement sur chaque paiement du client ; SECOTO vous adresse la facture correspondante.",
  "Vous pouvez révoquer ce mandat à tout moment auprès de SECOTO : les missions réglées par l’application sont alors suspendues.",
];

const VIDE = { legalName: "", siren: "", address: "", vatRegime: "franchise", vatNumber: "" };

export default function PaiementDirectPanel() {
  const [etat, setEtat] = useState(null);
  const [form, setForm] = useState(VIDE);
  const [accord, setAccord] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const charger = useCallback(async () => {
    try {
      const s = await carrierDirectStatus();
      setEtat(s);
      if (s?.billing?.legal_name) {
        setForm({
          legalName: s.billing.legal_name || "", siren: s.billing.siren || "", address: s.billing.address || "",
          vatRegime: s.billing.vat_regime || "franchise", vatNumber: s.billing.vat_number || "",
        });
      }
      setError("");
    } catch (e) {
      setError(humanizeError(e));
    }
  }, []);

  useEffect(() => { queueMicrotask(charger); }, [charger]);

  const champ = (cle) => (e) => setForm((f) => ({ ...f, [cle]: e.target.value }));

  async function accepterMandat(e) {
    e.preventDefault();
    if (!accord) { setError("Cochez la case pour accepter le mandat de facturation."); return; }
    setBusy(true); setError(""); setNotice("");
    try {
      await carrierAcceptBillingMandate({ version: MANDAT_VERSION, ...form });
      await charger();
      setNotice("Mandat enregistré. Dernière étape : activez le paiement direct chez Stripe.");
    } catch (err) {
      setError(humanizeError(err));
    } finally {
      setBusy(false);
    }
  }

  async function activer() {
    setBusy(true); setError(""); setNotice("");
    try {
      // Pas encore de compte Stripe : on le crée d'abord (lien hébergé par Stripe).
      const r = await connectOnboarding(etat?.stripe_account ? "direct" : "link");
      if (r?.url) { window.location.assign(r.url); return; }
      await charger();
      setNotice("Paiement direct activé : vous pouvez accepter les missions plateau.");
    } catch (err) {
      setError(humanizeError(err));
    } finally {
      setBusy(false);
    }
  }

  if (!etat) {
    return <div className="panel panel-full"><h2>Paiement direct</h2>{error ? <div className="alert error">{error}</div> : <p className="muted">Chargement…</p>}</div>;
  }

  const mandatOk = Boolean(etat.mandate_accepted_at);
  return (
    <div className="panel panel-full">
      <h2>Paiement direct des missions plateau</h2>
      <p className="muted">
        Pour les missions plateau, le client vous paie directement : l’argent arrive sur votre compte Stripe,
        jamais chez SECOTO. SECOTO ne garde que ses frais de mise en relation, prélevés automatiquement.
        Stripe vous verse automatiquement ce que vous encaissez.
      </p>
      {error && <div className="alert error" role="alert">{error}</div>}
      {notice && <div className="alert success" role="status">{notice}</div>}

      {etat.ready ? (
        <p><span className="od-pill is-ok">Actif</span> Vous pouvez accepter les missions plateau.</p>
      ) : (
        <ol className="od-milestones">
          <li className={mandatOk ? "is-done" : ""}>Informations de facturation et mandat</li>
          <li className={etat.card_payments ? "is-done" : ""}>Activation chez Stripe</li>
        </ol>
      )}

      {!mandatOk && (
        <form className="form-grid" onSubmit={accepterMandat}>
          <label className="field"><span>Nom de votre entreprise *</span>
            <input value={form.legalName} maxLength={200} onChange={champ("legalName")} required />
          </label>
          <label className="field"><span>SIREN *</span>
            <input value={form.siren} inputMode="numeric" maxLength={11} placeholder="9 chiffres" onChange={champ("siren")} required />
          </label>
          <label className="field"><span>Adresse de l’entreprise *</span>
            <input value={form.address} maxLength={400} onChange={champ("address")} required />
          </label>
          <label className="field"><span>TVA *</span>
            <select value={form.vatRegime} onChange={champ("vatRegime")}>
              <option value="franchise">Franchise en base (TVA non applicable, art. 293 B du CGI)</option>
              <option value="assujetti">Assujetti à la TVA</option>
            </select>
          </label>
          {form.vatRegime === "assujetti" && (
            <label className="field"><span>Numéro de TVA intracommunautaire *</span>
              <input value={form.vatNumber} maxLength={20} placeholder="FR…" onChange={champ("vatNumber")} required />
            </label>
          )}
          <details className="applications-box">
            <summary>Lire le mandat de facturation</summary>
            {MANDAT_TEXTE.map((t) => <p key={t} className="muted">{t}</p>)}
          </details>
          <label className="payment-waiver-row">
            <input type="checkbox" checked={accord} onChange={(e) => setAccord(e.target.checked)} />
            <span>J’accepte le mandat de facturation : SECOTO émet en mon nom les factures de mes transports réservés via l’application et prélève ses frais sur chaque paiement.</span>
          </label>
          <div className="actions-row">
            <button className="btn primary" type="submit" disabled={busy}>{busy ? "Enregistrement…" : "Enregistrer et continuer"}</button>
          </div>
        </form>
      )}

      {mandatOk && !etat.ready && (
        <div className="actions-row">
          <button className="btn primary" type="button" disabled={busy} onClick={activer}>
            {busy ? "Ouverture…" : etat.stripe_account ? "Activer le paiement direct" : "Créer mon compte de paiement"}
          </button>
          <button className="btn ghost small" type="button" disabled={busy} onClick={charger}>Actualiser</button>
        </div>
      )}
    </div>
  );
}
