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

function LigneAppel({ t, onStatut, busy, onInviter }) {
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
        {onInviter && (
          <button type="button" className="btn ghost small" disabled={busy || t.invite} onClick={() => onInviter(t)}>
            {t.invite ? "Invitation envoyée" : "Inviter par SMS"}
          </button>
        )}
      </div>
    </li>
  );
}

// 152 : utilisable pour une commande de l'app (order) ou une mission manuelle (mission).
export default function TransporteursAAppeler({ order, mission }) {
  const id = mission ? mission.id : order.id;
  const lire = () => (mission ? admin.transporteursAAppelerMission(id) : admin.transporteursAAppeler(id));
  const noter = (t) => (mission ? admin.appelMissionMaj(id, t) : admin.appelMaj(id, t));
  const [data, setData] = useState(null);
  const [google, setGoogle] = useState(null);
  const [erreur, setErreur] = useState("");
  const [busy, setBusy] = useState(false);
  // Mission manuelle : liste repliée, chargée seulement à l'ouverture (une carte par mission publiée).
  const [ouvert, setOuvert] = useState(!mission);

  async function charger() {
    try { setData(await lire()); setErreur(""); } catch (e) { setErreur(humanizeError(e)); }
  }
  useEffect(() => {
    if (!ouvert) return undefined;
    let vivant = true;
    lire()
      .then((d) => { if (vivant) { setData(d); setErreur(""); } })
      .catch((e) => { if (vivant) setErreur(humanizeError(e)); });
    return () => { vivant = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, ouvert]);

  async function statut(t, cle, source = "secoto") {
    setBusy(true);
    try {
      await noter({ cle: t.cle || t.id, source, nom: t.nom, telephone: t.telephone, statut: cle });
      await charger();
      if (source === "google") setGoogle((g) => g && g.map((x) => (x.cle === t.cle ? { ...x, appel: cle } : x)));
    } catch (e) { setErreur(humanizeError(e)); } finally { setBusy(false); }
  }

  async function chercherGoogle() {
    const c = data?.commande;
    if ((!c?.lat || !c?.lng) && !c?.adresse_depart) { setErreur("Position du départ inconnue."); return; }
    setBusy(true);
    try {
      const r = await admin.placesTransporteurs(c.lat ?? null, c.lng ?? null, c.mode, c.adresse_depart || null);
      const notes = new Map((data.appels_externes || []).map((a) => [a.cle, a.statut]));
      setGoogle((r?.transporteurs || []).map((t) => ({ ...t, appel: notes.get(t.cle) || null })));
      setErreur("");
    } catch (e) { setErreur(humanizeError(e)); } finally { setBusy(false); }
  }

  // Prospect hors SECOTO : un seul SMS d'invitation à s'inscrire (refusé par la base si déjà inscrit ou déjà invité).
  async function inviter(t) {
    setBusy(true);
    try {
      const r = await admin.inviterTransporteurSms(t.telephone, t.nom);
      if (r?.envoye || r?.raison === "Déjà invité par SMS.") setGoogle((g) => g && g.map((x) => (x.cle === t.cle ? { ...x, invite: true } : x)));
      setErreur(r?.envoye ? "" : r?.raison || "");
    } catch (e) { setErreur(humanizeError(e)); } finally { setBusy(false); }
  }

  const liste = data?.transporteurs || [];
  return (
    <details className="od-appels" open={ouvert} onToggle={(e) => setOuvert(e.currentTarget.open)}>
      <summary><strong>Transporteurs à appeler</strong>{data && <span className="muted"> · {liste.length} chez SECOTO</span>}</summary>
      {erreur && <p className="od-pill is-warn">{erreur}</p>}
      {ouvert && !data && !erreur && <p className="muted">Chargement…</p>}
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
            : <ul className="od-appels-liste">{google.map((t) => <LigneAppel key={t.cle} t={t} busy={busy} onStatut={(x, s) => statut(x, s, "google")} onInviter={inviter} />)}</ul>)}
        </>
      )}
    </details>
  );
}
