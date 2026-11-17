import { useEffect, useState } from "react";
import { admin, formatCents } from "../lib/onDemand";
import { humanizeError } from "../lib/humanError";
import { CLASSE_STATUT, OFFRE_APPEL as OFFRE, STATUTS_APPEL, telLien } from "../lib/appels";

// ============================================================================
// SECOTO 151 — « Transporteurs à appeler » (écran Piloter d'une commande).
// Transporteurs SECOTO du bon type, classés : basés au départ, puis à
// l'arrivée, puis ceux qui ont vu l'offre, puis par nombre de missions.
// Recherche Google (hors SECOTO) autour du départ, si la clé est configurée.
// Chaque appel se note en un clic : appelé, pas de réponse, intéressé, refus.
// ============================================================================

function LigneAppel({ t, onStatut, busy }) {
  return (
    <li className="od-appel">
      <div className="od-appel-tete">
        <strong>{t.nom || "Sans nom"}</strong>
        {t.proche && <span className="od-pill is-ok">Basé sur le trajet</span>}
        {t.appel && <span className={`od-pill ${CLASSE_STATUT[t.appel] || ""}`}>{STATUTS_APPEL.find((s) => s.cle === t.appel)?.libelle}</span>}
      </div>
      <div className="muted">
        {[t.ville || t.adresse, t.type && String(t.type).toUpperCase(), t.offre && (OFFRE[t.offre] || t.offre) + (t.vue ? " (vue)" : ""),
          t.missions != null && `${t.missions} mission${t.missions > 1 ? "s" : ""}`, t.payable === false && "paiement non configuré",
          t.note != null && t.avis != null && `Google ${t.note}/5 (${t.avis} avis)`].filter(Boolean).join(" · ")}
      </div>
      <div className="actions-row" style={{ flexWrap: "wrap" }}>
        <a className="btn small" href={telLien(t.telephone)}>Appeler {t.telephone}</a>
        {STATUTS_APPEL.map((s) => (
          <button key={s.cle} type="button" className="btn ghost small" disabled={busy} onClick={() => onStatut(t, s.cle)}>{s.libelle}</button>
        ))}
      </div>
    </li>
  );
}

export default function TransporteursAAppeler({ order }) {
  const [data, setData] = useState(null);
  const [google, setGoogle] = useState(null);
  const [erreur, setErreur] = useState("");
  const [busy, setBusy] = useState(false);

  async function charger() {
    try { setData(await admin.transporteursAAppeler(order.id)); setErreur(""); } catch (e) { setErreur(humanizeError(e)); }
  }
  useEffect(() => {
    let vivant = true;
    admin.transporteursAAppeler(order.id)
      .then((d) => { if (vivant) { setData(d); setErreur(""); } })
      .catch((e) => { if (vivant) setErreur(humanizeError(e)); });
    return () => { vivant = false; };
  }, [order.id]);

  async function statut(t, cle, source = "secoto") {
    setBusy(true);
    try {
      await admin.appelMaj(order.id, { cle: t.cle || t.id, source, nom: t.nom, telephone: t.telephone, statut: cle });
      await charger();
      if (source === "google") setGoogle((g) => g && g.map((x) => (x.cle === t.cle ? { ...x, appel: cle } : x)));
    } catch (e) { setErreur(humanizeError(e)); } finally { setBusy(false); }
  }

  async function chercherGoogle() {
    const c = data?.commande;
    if (!c?.lat || !c?.lng) { setErreur("Position du départ inconnue pour cette commande."); return; }
    setBusy(true);
    try {
      const r = await admin.placesTransporteurs(c.lat, c.lng, c.mode);
      const notes = new Map((data.appels_externes || []).map((a) => [a.cle, a.statut]));
      setGoogle((r?.transporteurs || []).map((t) => ({ ...t, appel: notes.get(t.cle) || null })));
      setErreur("");
    } catch (e) { setErreur(humanizeError(e)); } finally { setBusy(false); }
  }

  const liste = data?.transporteurs || [];
  return (
    <details className="od-appels" open>
      <summary><strong>Transporteurs à appeler</strong>{data && <span className="muted"> · {liste.length} chez SECOTO</span>}</summary>
      {erreur && <p className="od-pill is-warn">{erreur}</p>}
      {!data && !erreur && <p className="muted">Chargement…</p>}
      {data && (
        <>
          <p className="muted">
            {data.commande.depart} ({data.commande.dep_depart}) → {data.commande.arrivee} ({data.commande.dep_arrivee}) ·
            rémunération {formatCents(data.commande.remuneration_cents)}
          </p>
          <ul className="od-appels-liste">{liste.map((t) => <LigneAppel key={t.id} t={{ ...t, cle: t.id }} busy={busy} onStatut={(x, s) => statut(x, s)} />)}</ul>
          <div className="actions-row">
            <button type="button" className="btn ghost small" disabled={busy} onClick={chercherGoogle}>
              {google ? "Relancer la recherche Google" : "Chercher d’autres transporteurs autour du départ (Google)"}
            </button>
          </div>
          {google && (google.length === 0
            ? <p className="muted">Aucun nouveau transporteur trouvé autour du départ.</p>
            : <ul className="od-appels-liste">{google.map((t) => <LigneAppel key={t.cle} t={t} busy={busy} onStatut={(x, s) => statut(x, s, "google")} />)}</ul>)}
        </>
      )}
    </details>
  );
}
