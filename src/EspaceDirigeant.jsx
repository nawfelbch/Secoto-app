import { useCallback, useEffect, useState } from "react";
import { humanizeError } from "./lib/humanError";
import { dirigeantLitiges, dirigeantTableau, dirigeantUrssaf } from "./lib/dirigeant";
import {
  MOIS, dateCourte, decaler, euros, eurosEntiers, periodeADeclarer, periodeEnCours, totauxAnnee,
} from "./lib/dirigeantUtil";
import AdminSavPanel from "./AdminSavPanel";

// ============================================================================
// SECOTO 087 — Espace dirigeant (visible uniquement par le dirigeant).
// Trois onglets : tableau de bord, déclaration URSSAF, litiges et SAV.
// Lecture seule : rien ici ne modifie une commande ou un paiement.
// ============================================================================

const ONGLETS = [
  { key: "tableau", label: "Tableau de bord" },
  { key: "urssaf", label: "Déclaration URSSAF" },
  { key: "litiges", label: "Litiges et SAV" },
];

function lireRythme() {
  try { return localStorage.getItem("secoto.dirigeant.rythme") === "trimestre" ? "trimestre" : "mois"; }
  catch { return "mois"; }
}
function ecrireRythme(r) {
  try { localStorage.setItem("secoto.dirigeant.rythme", r); } catch { /* stockage indisponible : sans effet */ }
}

export default function EspaceDirigeant() {
  const [onglet, setOnglet] = useState("tableau");
  return (
    <>
      <div className="panel panel-full dir-entete">
        <div>
          <h2>Espace dirigeant</h2>
          <p className="muted">Visible uniquement par vous. Les chiffres viennent des paiements enregistrés dans l’application.</p>
        </div>
        <div className="tabs" role="tablist">
          {ONGLETS.map((o) => (
            <button key={o.key} type="button" role="tab" aria-selected={onglet === o.key}
              className={onglet === o.key ? "active" : ""} onClick={() => setOnglet(o.key)}>{o.label}</button>
          ))}
        </div>
      </div>
      {onglet === "tableau" && <TableauDeBord />}
      {onglet === "urssaf" && <DeclarationUrssaf />}
      {onglet === "litiges" && <LitigesSav />}
    </>
  );
}

// ---------------------------------------------------------------- Tableau ---
function TableauDeBord() {
  const [annee, setAnnee] = useState(null);
  const [data, setData] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let vivant = true;
    dirigeantTableau(annee)
      .then((d) => { if (vivant) { setData(d); setError(""); } })
      .catch((e) => { if (vivant) setError(humanizeError(e)); });
    return () => { vivant = false; };
  }, [annee]);

  if (error) return <div className="panel panel-full"><div className="alert error" role="alert">{error}</div></div>;
  if (!data) return <div className="panel panel-full"><p className="muted">Chargement des chiffres…</p></div>;

  const t = totauxAnnee(data.mois);
  const moisCourant = new Date().getFullYear() === data.annee ? new Date().getMonth() + 1 : 12;
  // Du premier mois d'activité jusqu'au mois en cours : pas de mois vides avant le lancement.
  const premier = (data.mois || []).find((m) => Number(m.operations) > 0)?.mois ?? moisCourant;
  const mois = (data.mois || []).filter((m) => (m.mois >= premier && m.mois <= moisCourant) || Number(m.operations) > 0).reverse();
  const maxCommission = Math.max(1, ...mois.map((m) => Math.abs(Number(m.commission_cents || 0))));

  return (
    <>
      <div className="panel panel-full">
        <div className="dir-ligne-titre">
          <h2>Année {data.annee}</h2>
          {(data.annees || []).length > 1 && (
            <label className="dir-select">
              <span className="sr-only">Année</span>
              <select value={data.annee} onChange={(e) => setAnnee(Number(e.target.value))}>
                {data.annees.map((a) => <option key={a} value={a}>{a}</option>)}
              </select>
            </label>
          )}
        </div>
        <div className="kpi-grid dir-kpi">
          <div className="kpi-card dir-kpi-principal"><span>Commission SECOTO</span><strong>{euros(t.commission)}</strong></div>
          <div className="kpi-card"><span>Encaissé auprès des clients</span><strong>{euros(t.encaisse)}</strong></div>
          <div className="kpi-card"><span>Part des transporteurs</span><strong>{euros(t.reverse)}</strong></div>
          <div className="kpi-card"><span>Remboursé</span><strong>{euros(t.rembourse)}</strong></div>
        </div>
      </div>

      <div className="panel panel-full">
        <h2>Mois par mois</h2>
        {mois.length === 0 && <p className="muted">Aucune opération cette année.</p>}
        <ul className="dir-mois">
          {mois.map((m) => {
            const c = Number(m.commission_cents || 0);
            return (
              <li key={m.mois}>
                <div className="dir-mois-tete">
                  <strong>{MOIS[m.mois - 1].charAt(0).toUpperCase() + MOIS[m.mois - 1].slice(1)}</strong>
                  <span className={`dir-montant${c < 0 ? " is-negatif" : ""}`}>{euros(c)}</span>
                </div>
                <div className="dir-barre" aria-hidden="true"><span style={{ width: `${Math.round((Math.abs(c) / maxCommission) * 100)}%` }} /></div>
                <div className="dir-mois-detail">
                  <span>Encaissé {euros(m.encaisse_cents)}</span>
                  <span>Transporteurs {euros(m.reverse_cents)}</span>
                  <span>Remboursé {euros(m.rembourse_cents)}</span>
                  <span>{m.operations} opération{Number(m.operations) > 1 ? "s" : ""}</span>
                </div>
              </li>
            );
          })}
        </ul>
      </div>

      <div className="panel panel-full">
        <h2>À surveiller</h2>
        <div className="kpi-grid dir-kpi">
          <div className="kpi-card"><span>En attente de paiement client</span><strong>{data.en_attente?.nombre || 0}</strong><small>{euros(data.en_attente?.montant_cents || 0)}</small></div>
          <div className="kpi-card"><span>Commissions en espèces à encaisser</span><strong>{data.commissions_especes_dues?.nombre || 0}</strong><small>{euros(data.commissions_especes_dues?.montant_cents || 0)}</small></div>
          <div className="kpi-card"><span>Versements transporteurs à faire</span><strong>{data.versements_a_faire?.nombre || 0}</strong><small>{euros(data.versements_a_faire?.montant_cents || 0)}</small></div>
        </div>
        {(data.en_attente?.liste || []).length > 0 && (
          <>
            <h3 className="dir-sous-titre">En attente de paiement</h3>
            <ul className="dir-liste">
              {data.en_attente.liste.slice(0, 10).map((x) => (
                <li key={x.reference}>
                  <div><strong>{x.reference}</strong> · {x.trajet || "—"}</div>
                  <div className="muted">{x.client || "—"} · depuis le {dateCourte(x.depuis)}</div>
                  <span className="dir-montant">{euros(x.montant_cents)}</span>
                </li>
              ))}
            </ul>
          </>
        )}
        {(data.commissions_especes_dues?.liste || []).length > 0 && (
          <>
            <h3 className="dir-sous-titre">Commissions en espèces à encaisser</h3>
            <ul className="dir-liste">
              {data.commissions_especes_dues.liste.map((x) => (
                <li key={x.reference}>
                  <div><strong>{x.reference}</strong> · {x.trajet || "—"}</div>
                  <div className="muted">{x.transporteur || "Transporteur"} · livrée le {dateCourte(x.depuis)}</div>
                  <span className="dir-montant">{euros(x.montant_cents)}</span>
                </li>
              ))}
            </ul>
          </>
        )}
      </div>
    </>
  );
}

// ----------------------------------------------------------------- URSSAF ---
function DeclarationUrssaf() {
  const [rythme, setRythme] = useState(lireRythme);
  const [periode, setPeriode] = useState(() => periodeADeclarer(lireRythme()));
  const [data, setData] = useState(null);
  const [error, setError] = useState("");
  const [copie, setCopie] = useState(false);

  useEffect(() => {
    let vivant = true;
    dirigeantUrssaf(periode.debut, periode.fin)
      .then((d) => { if (vivant) { setData(d); setError(""); setCopie(false); } })
      .catch((e) => { if (vivant) setError(humanizeError(e)); });
    return () => { vivant = false; };
  }, [periode]);

  function changerRythme(r) {
    ecrireRythme(r);
    setRythme(r);
    setData(null);
    setPeriode(periodeADeclarer(r));
  }
  function deplacer(sens) { setData(null); setPeriode((p) => decaler(p, sens)); }
  async function copier() {
    try { await navigator.clipboard.writeText(String(data.a_declarer_euros)); setCopie(true); }
    catch { setCopie(false); }
  }

  const enCours = periodeEnCours(periode);
  const lignes = data?.lignes || [];
  return (
    <>
      <div className="panel panel-full">
        <div className="dir-ligne-titre">
          <h2>Déclaration URSSAF</h2>
          <div className="dir-bascule" role="group" aria-label="Rythme de déclaration">
            <button type="button" className={rythme === "mois" ? "active" : ""} onClick={() => changerRythme("mois")}>Mensuelle</button>
            <button type="button" className={rythme === "trimestre" ? "active" : ""} onClick={() => changerRythme("trimestre")}>Trimestrielle</button>
          </div>
        </div>

        <div className="dir-periode">
          <button type="button" className="btn ghost small" onClick={() => deplacer(-1)} aria-label="Période précédente">‹</button>
          <div>
            <strong>{periode.label}</strong>
            {periode.detail && <span className="muted"> · {periode.detail}</span>}
          </div>
          <button type="button" className="btn ghost small" onClick={() => deplacer(1)} aria-label="Période suivante">›</button>
        </div>

        {error && <div className="alert error" role="alert">{error}</div>}
        {!data && !error && <p className="muted">Calcul en cours…</p>}
        {data && (
          <div className="dir-declaration">
            <span>Commission à déclarer</span>
            <strong>{eurosEntiers(data.a_declarer_euros)}</strong>
            <small className="muted">Montant exact : {euros(data.commission_cents)}, arrondi à l’euro.</small>
            <button type="button" className="btn primary" onClick={copier}>{copie ? "Montant copié" : "Copier le montant"}</button>
          </div>
        )}
        {enCours && <div className="alert info" role="status">Cette période n’est pas terminée : le montant peut encore évoluer.</div>}
        <p className="muted dir-note">
          Seule la commission SECOTO est comptée : la part des transporteurs et les remboursements sont déduits. Une course est comptée le jour où le client a payé.
          Une commission réglée hors application n’apparaît que si elle est marquée « réglée » sur la mission.
        </p>
      </div>

      {data && (
        <div className="panel panel-full">
          <h2>Détail ({lignes.length} opération{lignes.length > 1 ? "s" : ""})</h2>
          {lignes.length === 0 && <p className="muted">Aucune commission sur cette période.</p>}
          <ul className="dir-liste">
            {lignes.map((l, i) => (
              <li key={`${l.reference}-${i}`}>
                <div><strong>{l.reference}</strong> · {l.trajet || l.libelle}</div>
                <div className="muted">{dateCourte(l.jour)} · {l.client || "—"} · {l.libelle}</div>
                <div className="muted dir-calcul">
                  Encaissé {euros(l.encaisse_cents)}
                  {Number(l.reverse_cents) > 0 && <> · transporteur {euros(l.reverse_cents)}</>}
                  {Number(l.rembourse_cents) > 0 && <> · remboursé {euros(l.rembourse_cents)}</>}
                </div>
                <span className={`dir-montant${Number(l.commission_cents) < 0 ? " is-negatif" : ""}`}>{euros(l.commission_cents)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  );
}

// ------------------------------------------------------------ Litiges/SAV ---
const STATUT_CONTESTATION = { open: "En cours", closed: "Close" };

function LitigesSav() {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");
  const charger = useCallback(() => dirigeantLitiges().then(setData).catch((e) => setError(humanizeError(e))), []);
  useEffect(() => {
    let vivant = true;
    dirigeantLitiges().then((d) => { if (vivant) setData(d); }).catch((e) => { if (vivant) setError(humanizeError(e)); });
    return () => { vivant = false; };
  }, []);

  const ouvertes = (data?.contestations || []).filter((c) => c.statut === "open").length;
  return (
    <>
      <div className="panel panel-full">
        <div className="dir-ligne-titre">
          <h2>Litiges</h2>
          <button type="button" className="btn ghost small" onClick={charger}>Actualiser</button>
        </div>
        {error && <div className="alert error" role="alert">{error}</div>}
        {!data && !error && <p className="muted">Chargement…</p>}
        {data && (
          <>
            <div className="kpi-grid dir-kpi">
              <div className={`kpi-card${ouvertes ? " dir-kpi-alerte" : ""}`}><span>Contestations bancaires en cours</span><strong>{ouvertes}</strong></div>
              <div className={`kpi-card${data.sav?.dommages_ouverts ? " dir-kpi-alerte" : ""}`}><span>Dommages signalés à traiter</span><strong>{data.sav?.dommages_ouverts || 0}</strong></div>
              <div className="kpi-card"><span>Demandes SAV à traiter</span><strong>{Number(data.sav?.ouvertes || 0) + Number(data.sav?.en_cours || 0)}</strong></div>
              <div className="kpi-card"><span>Demandes SAV traitées</span><strong>{data.sav?.resolues || 0}</strong></div>
            </div>
            <h3 className="dir-sous-titre">Contestations bancaires</h3>
            {(data.contestations || []).length === 0 && <p className="muted">Aucune contestation. Un client qui conteste un paiement auprès de sa banque apparaîtra ici.</p>}
            <ul className="dir-liste">
              {(data.contestations || []).map((c, i) => (
                <li key={`${c.reference}-${i}`}>
                  <div><strong>{c.reference}</strong> · {c.client || "—"}</div>
                  <div className="muted">{STATUT_CONTESTATION[c.statut] || c.statut} · depuis le {dateCourte(c.depuis)} · à suivre dans Stripe, rubrique Litiges</div>
                  <span className="dir-montant">{euros(c.montant_cents)}</span>
                </li>
              ))}
            </ul>
          </>
        )}
      </div>
      <AdminSavPanel />
    </>
  );
}
