import { useCallback, useEffect, useState } from "react";
import { humanizeError } from "../lib/humanError";
import { OFFRE_LIBELLE, admin, formatCents } from "../lib/onDemand";

// ============================================================================
// SECOTO 099 — Espace admin : trois offres (réglages et mesure).
// ----------------------------------------------------------------------------
// Coefficients, fenêtres, tranches Éco et seuil modifiables sans redéploiement.
// La base valide chaque valeur (bornes) avant d'enregistrer. La mesure
// s'appuie uniquement sur les commandes réelles (hors commandes de test).
// ============================================================================

const nombre = (v) => {
  const n = Number(String(v ?? "").replace(",", "."));
  return Number.isFinite(n) ? n : null;
};

function Champ({ label, value, onChange, suffix, step = "1" }) {
  return (
    <label className="field">
      <span>{label}</span>
      <span style={{ display: "flex", gap: 6, alignItems: "center" }}>
        <input inputMode="decimal" type="number" step={step} value={value ?? ""} onChange={(e) => onChange(e.target.value)} />
        {suffix && <small className="muted">{suffix}</small>}
      </span>
    </label>
  );
}

export default function AdminOffres({ flags, onFlagsChange }) {
  const [etat, setEtat] = useState(null);
  const [form, setForm] = useState(null);
  const [stats, setStats] = useState(null);
  const [jours, setJours] = useState(30);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  const load = useCallback(async () => {
    try {
      const [e, s] = await Promise.all([admin.troisOffres(), admin.offresStats(jours)]);
      setEtat(e);
      setForm(JSON.parse(JSON.stringify(e.reglages || {})));
      setStats(s);
      setError("");
    } catch (err) { setError(humanizeError(err)); }
  }, [jours]);
  useEffect(() => { queueMicrotask(load); }, [load]);

  if (error && !form) return <div className="alert error">{error}</div>;
  if (!form) return <p className="muted">Chargement…</p>;

  const set = (path, v) => setForm((f) => {
    const next = JSON.parse(JSON.stringify(f));
    let o = next;
    for (let i = 0; i < path.length - 1; i += 1) { o[path[i]] = o[path[i]] ?? {}; o = o[path[i]]; }
    o[path[path.length - 1]] = v;
    return next;
  });
  const tranches = form.eco?.tranches || [];

  async function enregistrer() {
    setBusy(true); setError(""); setMessage("");
    try {
      const payload = {
        ...form,
        seuil_transporteurs: nombre(form.seuil_transporteurs),
        attente_validation_min: nombre(form.attente_validation_min),
        standard: { ...form.standard, fenetre_h: nombre(form.standard?.fenetre_h) },
        express: { ...form.express, coef: nombre(form.express?.coef), fenetre_h: nombre(form.express?.fenetre_h) },
        eco: {
          ...form.eco,
          fenetre_h: nombre(form.eco?.fenetre_h),
          tranches: tranches.map((t, i) => ({
            max_km: i === tranches.length - 1 ? null : nombre(t.max_km),
            transporteur_eur: nombre(t.transporteur_eur),
            marge_pct: nombre(t.marge_pct),
          })),
        },
      };
      await admin.setTroisOffres(payload);
      setMessage("Réglages enregistrés : ils s’appliquent aux prochains devis.");
      await load();
    } catch (err) { setError(humanizeError(err)); } finally { setBusy(false); }
  }

  const actif = Boolean(flags?.trois_offres ?? etat?.actif);
  return (
    <div className="panel panel-full">
      <h3>Trois offres : Express, Standard, Éco</h3>
      <p className="muted">
        Transport sur plateau d’un véhicule. Éteint : une seule offre, comme aujourd’hui. Allumé : jusqu’à trois offres, carte
        enregistrée à la réservation et débit seulement quand un transporteur confirme.
      </p>
      <label className="od-checks">
        <input type="checkbox" checked={actif} disabled={busy} onChange={async (e) => {
          setBusy(true); setError("");
          try { await admin.setFlag("trois_offres", e.target.checked); await onFlagsChange?.(); await load(); }
          catch (err) { setError(humanizeError(err)); } finally { setBusy(false); }
        }} /> Offres activées
      </label>
      {error && <div className="alert error" role="alert">{error}</div>}
      {message && <div className="alert success">{message}</div>}

      <div className="form-grid" style={{ marginTop: 12 }}>
        <Champ label="Transporteurs minimum par offre" value={form.seuil_transporteurs} onChange={(v) => set(["seuil_transporteurs"], v)} />
        <Champ label="Délai de validation bancaire (3D Secure)" value={form.attente_validation_min} onChange={(v) => set(["attente_validation_min"], v)} suffix="min" />
        <Champ label="Express : coefficient (client et transporteur)" value={form.express?.coef} onChange={(v) => set(["express", "coef"], v)} step="0.01" suffix="× Standard" />
        <Champ label="Express : fenêtre" value={form.express?.fenetre_h} onChange={(v) => set(["express", "fenetre_h"], v)} suffix="h" />
        <Champ label="Standard : fenêtre" value={form.standard?.fenetre_h} onChange={(v) => set(["standard", "fenetre_h"], v)} suffix="h" />
        <Champ label="Éco : fenêtre" value={form.eco?.fenetre_h} onChange={(v) => set(["eco", "fenetre_h"], v)} suffix="h" />
      </div>

      <h4 style={{ marginTop: 16 }}>Éco : barème fixe par véhicule (porte-voitures PL, voitures roulantes)</h4>
      <div className="od-table-wrap">
        <table className="od-table">
          <thead><tr><th>Distance jusqu’à</th><th>Rémunération transporteur</th><th>Marge SECOTO</th><th>Prix client</th></tr></thead>
          <tbody>
            {tranches.map((t, i) => {
              const pay = nombre(t.transporteur_eur);
              const marge = nombre(t.marge_pct);
              const client = pay != null && marge != null ? Math.round(pay * (1 + marge / 100) * 100) : null;
              const derniere = i === tranches.length - 1;
              return (
                <tr key={i}>
                  <td>{derniere ? "au-delà" : <input type="number" value={t.max_km ?? ""} onChange={(e) => set(["eco", "tranches", i, "max_km"], e.target.value)} style={{ width: 90 }} />}{!derniere && " km"}</td>
                  <td><input type="number" value={t.transporteur_eur ?? ""} onChange={(e) => set(["eco", "tranches", i, "transporteur_eur"], e.target.value)} style={{ width: 90 }} /> €</td>
                  <td><input type="number" value={t.marge_pct ?? ""} onChange={(e) => set(["eco", "tranches", i, "marge_pct"], e.target.value)} style={{ width: 70 }} /> %</td>
                  <td>{client != null ? formatCents(client) : "—"}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className="actions-row"><button className="btn primary" type="button" disabled={busy} onClick={enregistrer}>{busy ? "Enregistrement…" : "Enregistrer les réglages"}</button></div>

      <h4 style={{ marginTop: 22 }}>Mesure par offre</h4>
      <label className="field" style={{ maxWidth: 220 }}><span>Période</span>
        <select value={jours} onChange={(e) => setJours(Number(e.target.value))}>
          {[7, 30, 90, 365].map((j) => <option key={j} value={j}>{j} derniers jours</option>)}
        </select>
      </label>
      <div className="od-table-wrap">
        <table className="od-table">
          <thead><tr><th>Offre</th><th>Affichée</th><th>Choisie</th><th>Acceptée</th><th>Taux d’acceptation</th><th>Délai réel moyen</th><th>Fenêtre expirée</th><th>Commission</th></tr></thead>
          <tbody>
            {(stats?.offres || []).map((s) => (
              <tr key={s.cle}>
                <td><strong>{OFFRE_LIBELLE[s.cle]}</strong></td>
                <td>{s.affichees}</td>
                <td>{s.choisies}</td>
                <td>{s.acceptees}</td>
                <td>{s.taux_acceptation != null ? `${String(s.taux_acceptation).replace(".", ",")} %` : "—"}</td>
                <td>{s.delai_moyen_h != null ? `${String(s.delai_moyen_h).replace(".", ",")} h` : "—"}</td>
                <td>{s.fenetre_expiree}{s.taux_expiration != null ? ` (${String(s.taux_expiration).replace(".", ",")} %)` : ""}</td>
                <td>{formatCents(s.commission_cents)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted">Le délai moyen de confirmation ne sera affiché aux clients qu’à partir de 20 missions acceptées par offre.</p>
    </div>
  );
}
