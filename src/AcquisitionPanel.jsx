import { useEffect, useState } from "react";
import { humanizeError } from "./lib/humanError";
import { acquisition, reseau } from "./lib/acquisition";
import { derniersJours, euros } from "./lib/dirigeantUtil";

// ============================================================================
// SECOTO 088 — Acquisition (administrateur) : d'où viennent les clients, et
// l'état du réseau de transporteurs par département. Lecture seule.
// Les missions et commandes de test, et les comptes internes SECOTO, sont exclus.
// ============================================================================

const PERIODES = [7, 30, 90];

export default function AcquisitionPanel() {
  const [jours, setJours] = useState(30);
  const [data, setData] = useState(null);
  const [net, setNet] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let vivant = true;
    const { debut, fin } = derniersJours(jours);
    acquisition(debut, fin)
      .then((d) => { if (vivant) { setData(d); setError(""); } })
      .catch((e) => { if (vivant) setError(humanizeError(e)); });
    return () => { vivant = false; };
  }, [jours]);

  useEffect(() => {
    let vivant = true;
    reseau().then((r) => { if (vivant) setNet(r); }).catch(() => {});
    return () => { vivant = false; };
  }, []);

  const t = data?.total || {};
  const lignes = data?.lignes || [];
  return (
    <>
      <div className="panel panel-full">
        <div className="dir-ligne-titre">
          <h2>Acquisition</h2>
          <div className="acq-periodes" role="group" aria-label="Période">
            {PERIODES.map((p) => (
              <button key={p} type="button" className={jours === p ? "active" : ""} onClick={() => { setData(null); setJours(p); }}>{p} jours</button>
            ))}
          </div>
        </div>
        {error && <div className="alert error" role="alert">{error}</div>}
        {!data && !error && <p className="muted">Chargement…</p>}
        {data && (
          <>
            <div className="kpi-grid dir-kpi">
              <div className="kpi-card"><span>Prix affichés</span><strong>{t.prix_affiches || 0}</strong></div>
              <div className="kpi-card"><span>Comptes créés</span><strong>{t.comptes_crees || 0}</strong></div>
              <div className="kpi-card"><span>Commandes payées</span><strong>{t.commandes_payees || 0}</strong></div>
              <div className="kpi-card dir-kpi-principal"><span>Commission</span><strong>{euros(t.commission_cents || 0)}</strong></div>
            </div>
            <h3 className="dir-sous-titre">Par source et campagne</h3>
            {lignes.length === 0 && <p className="muted">Aucune donnée sur cette période.</p>}
            <ul className="acq-liste">
              {lignes.map((l) => (
                <li key={`${l.source}|${l.campagne}`}>
                  <div className="acq-tete">
                    <strong>{l.source}</strong>
                    <span className="muted">{l.campagne === "—" ? "sans campagne" : l.campagne}</span>
                  </div>
                  <div className="acq-chiffres">
                    <span>Prix affichés<b>{l.prix_affiches}</b></span>
                    <span>Comptes<b>{l.comptes_crees}</b></span>
                    <span>Commandes<b>{l.commandes_payees}</b></span>
                    <span>Commission<b>{euros(l.commission_cents)}</b></span>
                  </div>
                </li>
              ))}
            </ul>
            <p className="muted dir-note">
              « (direct) » regroupe les visites sans lien de campagne : bouche-à-oreille, Leboncoin, recherche naturelle, appli. Pour suivre une campagne, ajoutez utm_source et utm_campaign à son lien.
            </p>
          </>
        )}
      </div>

      <div className="panel panel-full">
        <h2>Réseau de transporteurs</h2>
        {!net && <p className="muted">Chargement…</p>}
        {net && (
          <>
            <div className="kpi-grid dir-kpi">
              <div className="kpi-card"><span>Transporteurs vérifiés</span><strong>{net.resume?.transporteurs || 0}</strong></div>
              <div className="kpi-card"><span>Disponibles</span><strong>{net.resume?.disponibles || 0}</strong></div>
              <div className="kpi-card"><span>Prennent la moto</span><strong>{net.resume?.moto || 0}</strong></div>
              <div className="kpi-card"><span>Couverture confirmée</span><strong>{net.resume?.couverture_confirmee || 0}</strong></div>
            </div>
            <h3 className="dir-sous-titre">Par département de prise en charge</h3>
            <div className="acq-deps">
              {(net.departements || []).map((d) => (
                <span key={d.departement}><strong>{d.departement}</strong> · {d.transporteurs} transp.{d.moto ? ` · ${d.moto} moto` : ""}</span>
              ))}
            </div>
            <p className="muted dir-note">Comptes internes SECOTO exclus. Un chauffeur salarié compte avec son entreprise.</p>
          </>
        )}
      </div>
    </>
  );
}
