import { useState } from "react";
import { humanizeError } from "./lib/humanError";
import { CLASS_LABEL, exampleTrip, formatEuros, parseEuros, sameAsDefaults, saveCarrierRates } from "./lib/carrierRates";

// ============================================================================
// SECOTO 085 — Barème du transporteur.
// ----------------------------------------------------------------------------
// Pré-rempli avec le barème de départ SECOTO. Le transporteur fixe librement
// son prix : il le valide d'un clic ou le modifie, à l'inscription puis à tout
// moment. Il reçoit les missions dont la rémunération correspond à son barème
// (à 5 % près), en même temps que les autres transporteurs concernés.
// ============================================================================

const deux = (n) => (n === null || n === undefined || n === "" ? "" : Number(n).toFixed(2).replace(".", ","));
const toForm = (rates) => Object.fromEntries(Object.entries(rates || {}).map(([k, r]) => [k, {
  eur_per_km: deux(r.eur_per_km),
  minimum_eur: deux(r.minimum_eur),
  non_rolling_eur: deux(r.non_rolling_eur),
}]));

export default function BaremeTransporteur({ status, onSaved, gate = false }) {
  const [form, setForm] = useState(() => toForm(status?.rates));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [ok, setOk] = useState("");
  const classes = Object.keys(status?.rates || {});
  const inchange = sameAsDefaults(form, status?.defaults);

  const set = (k, f, v) => { setOk(""); setForm({ ...form, [k]: { ...form[k], [f]: v } }); };

  async function enregistrer() {
    setError(""); setOk("");
    const payload = {};
    for (const k of classes) {
      const r = form[k] || {};
      const v = { eur_per_km: parseEuros(r.eur_per_km), minimum_eur: parseEuros(r.minimum_eur), non_rolling_eur: parseEuros(r.non_rolling_eur) };
      if (Object.values(v).some((n) => !Number.isFinite(n) || n < 0)) {
        setError(`${CLASS_LABEL[k] || k} : renseignez des montants valides.`);
        return;
      }
      payload[k] = v;
    }
    setBusy(true);
    try {
      const s = await saveCarrierRates(payload);
      setOk("Votre barème est enregistré.");
      onSaved?.(s);
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="panel panel-full" role={gate ? "dialog" : undefined} aria-modal={gate || undefined} aria-labelledby="bareme-titre">
      <h2 id="bareme-titre">{gate ? "Votre barème" : "Mon barème"}</h2>
      <p className="muted">
        Voici le barème de départ proposé par SECOTO. Vous fixez librement votre prix : gardez-le ou modifiez-le,
        quand vous voulez. Vous recevez, en même temps que les autres transporteurs concernés, les missions dont la
        rémunération correspond à votre barème (à {status?.tolerance_pct ?? 5} % près).
      </p>
      {error && <div className="alert error" role="alert">{error}</div>}
      {ok && <div className="alert success" role="status">{ok}</div>}
      <p className="muted" style={{ fontSize: "0.82rem" }}>
        Pour chaque type de véhicule : votre prix au kilomètre, votre minimum par course (petits trajets) et votre
        supplément si le véhicule ne roule pas (treuil).
      </p>
      <div className="bareme-grille">
        {classes.map((k) => {
          const ex = exampleTrip({ eur_per_km: form[k]?.eur_per_km, minimum_eur: form[k]?.minimum_eur });
          return (
            <div className="bareme-ligne" key={k}>
              <strong>{CLASS_LABEL[k] || k}</strong>
              <label><span>€ / km</span><input inputMode="decimal" value={form[k]?.eur_per_km ?? ""} onChange={(e) => set(k, "eur_per_km", e.target.value)} /></label>
              <label><span>Minimum (€)</span><input inputMode="decimal" value={form[k]?.minimum_eur ?? ""} onChange={(e) => set(k, "minimum_eur", e.target.value)} /></label>
              <label><span>Non roulant (€)</span><input inputMode="decimal" value={form[k]?.non_rolling_eur ?? ""} onChange={(e) => set(k, "non_rolling_eur", e.target.value)} /></label>
              {ex !== null && <p className="bareme-exemple">Exemple : 300 km = {formatEuros(ex)} pour vous.</p>}
            </div>
          );
        })}
      </div>
      <div className="actions-row" style={{ marginTop: 14 }}>
        <button className="btn primary" type="button" disabled={busy} onClick={enregistrer}>
          {busy ? "Enregistrement…" : inchange ? "Valider ce barème" : "Enregistrer mon barème"}
        </button>
        {!inchange && (
          <button className="btn ghost" type="button" disabled={busy} onClick={() => setForm(toForm(status?.defaults))}>
            Revenir au barème de départ
          </button>
        )}
      </div>
      {status?.confirmed_at && !gate && (
        <p className="muted">Dernière validation : {new Date(status.confirmed_at).toLocaleString("fr-FR")}.</p>
      )}
    </div>
  );
}
