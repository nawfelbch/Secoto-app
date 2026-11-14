import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabaseClient";
import { humanizeError } from "./lib/humanError";
import { etiquetteClient, filtrerClients, nomClient, TRIS } from "./lib/clientsPros";
import { euros } from "./lib/dirigeantUtil";
import { formatDateTime } from "./lib/mappers";
import { ORDER_STATUS_LABEL, OFFRE_LIBELLE, MODE_REGLEMENT_LIBELLE } from "./lib/orderCopy";
import { libelleSource } from "./lib/sourcesProvenance";

// ============================================================================
// SECOTO 147 — Onglet admin « Clients pros » : toutes les infos des comptes
// professionnels (identité, entreprise, provenance, devis, commandes, chiffre
// d'affaires, marge, Navette Pro, trajets, dernières commandes). Lecture seule.
// ============================================================================

const date = (v) => (v ? formatDateTime(v) : "—");

async function chargerClientsPros() {
  const { data, error } = await supabase.rpc("secoto_admin_clients_pros");
  if (error) throw error;
  return data || { total: {}, clients: [] };
}

function FicheClient({ c }) {
  const [ouvert, setOuvert] = useState(false);
  const etiquette = etiquetteClient(c);
  return (
    <article className="mission-card clientpro-carte">
      <div className="card-top">
        <span className={`od-pill ${etiquette.classe}`}>{etiquette.texte}</span>
        {c.navette > 0 && <span className="od-pill od-offre-pill is-pro">Navette Pro × {c.navette}</span>}
      </div>
      <h3>{nomClient(c)}</h3>
      {c.nom && nomClient(c) !== c.nom && <p className="muted">{c.nom}</p>}
      <div className="card-section">
        <p><strong>Téléphone :</strong> {c.telephone ? <a href={`tel:${c.telephone}`}>{c.telephone}</a> : "Non renseigné"}</p>
        <p><strong>E-mail :</strong> {c.email ? <a href={`mailto:${c.email}`}>{c.email}</a> : "Non renseigné"}</p>
        <p><strong>Ville :</strong> {c.ville || "Non renseignée"}</p>
        <p><strong>SIREN :</strong> {c.siren || "Non renseigné"}{c.raison_sociale ? ` · ${c.raison_sociale}` : ""}</p>
        <p><strong>Inscrit le :</strong> {date(c.inscrit_le)}{c.source ? ` · via ${libelleSource(c.source)}${c.campagne ? ` (${c.campagne})` : ""}` : ""}</p>
        <p><strong>Carte enregistrée :</strong> {c.carte_enregistree ? "oui" : "non"}</p>
      </div>
      <div className="kpi-grid clientpro-kpi">
        <div className="kpi-card"><span>Devis</span><strong>{c.devis}</strong><small>{c.devis_30j} sur 30 j</small></div>
        <div className="kpi-card"><span>Commandes</span><strong>{c.commandes}</strong><small>{c.livrees} livrées · {c.en_cours} en cours · {c.annulees} annulées</small></div>
        <div className="kpi-card"><span>Chiffre d’affaires</span><strong>{euros(c.ca_cents)}</strong><small>{c.vehicules} véhicule{c.vehicules > 1 ? "s" : ""}</small></div>
        <div className="kpi-card"><span>Marge</span><strong>{euros(c.marge_cents)}</strong><small>livré : {euros(c.ca_livre_cents)}</small></div>
      </div>
      <p className="muted">
        Dernier devis : {date(c.dernier_devis_at)} · Dernière commande : {date(c.derniere_commande_at)}
        {c.trajets?.length > 0 && <><br />Trajets fréquents : {c.trajets.join(" · ")}</>}
      </p>
      {c.commandes_recentes?.length > 0 && (
        <>
          <button type="button" className="btn ghost small" aria-expanded={ouvert} onClick={() => setOuvert((v) => !v)}>
            {ouvert ? "Masquer les commandes" : `Voir les ${c.commandes_recentes.length} dernières commandes`}
          </button>
          {ouvert && (
            <div className="clientpro-table-scroll">
              <table className="clientpro-table">
                <thead><tr><th>Réf.</th><th>Trajet</th><th>Offre</th><th>Statut</th><th>Prix</th><th>Marge</th><th>Créée le</th></tr></thead>
                <tbody>
                  {c.commandes_recentes.map((o) => (
                    <tr key={o.ref}>
                      <td>{o.ref}</td>
                      <td>{o.depart || "?"} → {o.arrivee || "?"}{o.vehicules > 1 ? ` · ${o.vehicules} véh.` : ""}</td>
                      <td>{OFFRE_LIBELLE[o.offre] || "—"}</td>
                      <td>{ORDER_STATUS_LABEL[o.statut] || o.statut}{o.reglement ? ` · ${MODE_REGLEMENT_LIBELLE[o.reglement] || o.reglement}` : ""}</td>
                      <td>{euros(o.prix_cents)}</td>
                      <td>{euros(o.marge_cents)}</td>
                      <td>{date(o.cree_le)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </article>
  );
}

export default function ClientsProsPanel() {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");
  const [recherche, setRecherche] = useState("");
  const [tri, setTri] = useState("activite");

  useEffect(() => {
    let vivant = true;
    chargerClientsPros()
      .then((d) => { if (vivant) { setData(d); setError(""); } })
      .catch((e) => { if (vivant) setError(humanizeError(e, "Les clients pros n’ont pas pu être chargés.")); });
    return () => { vivant = false; };
  }, []);

  const liste = useMemo(() => filtrerClients(data?.clients, recherche, tri), [data, recherche, tri]);
  const t = data?.total || {};

  return (
    <div className="panel panel-full">
      <h2>Clients pros <span className="badge">{t.comptes ?? "…"}</span></h2>
      {error && <div className="alert error" role="alert">{error}</div>}
      {!data && !error && <p className="muted">Chargement…</p>}
      {data && (
        <>
          <div className="kpi-grid dir-kpi">
            <div className="kpi-card"><span>Comptes pros</span><strong>{t.comptes || 0}</strong><small>{t.nouveaux_30j || 0} nouveaux sur 30 j</small></div>
            <div className="kpi-card"><span>Clients actifs</span><strong>{t.actifs || 0}</strong><small>au moins une commande</small></div>
            <div className="kpi-card"><span>Commandes</span><strong>{t.commandes || 0}</strong><small>{t.livrees || 0} livrées · {t.en_cours || 0} en cours · {t.navette || 0} Navette Pro</small></div>
            <div className="kpi-card dir-kpi-principal"><span>Marge pros</span><strong>{euros(t.marge_cents || 0)}</strong><small>CA {euros(t.ca_cents || 0)} · {t.devis_30j || 0} devis sur 30 j</small></div>
          </div>
          <div className="clientpro-outils">
            <input type="search" value={recherche} onChange={(e) => setRecherche(e.target.value)}
              placeholder="Rechercher : société, nom, e-mail, téléphone, ville, SIREN" aria-label="Rechercher un client pro" />
            <select value={tri} onChange={(e) => setTri(e.target.value)} aria-label="Trier">
              {TRIS.map((x) => <option key={x.cle} value={x.cle}>Trier : {x.libelle}</option>)}
            </select>
          </div>
          {liste.length === 0
            ? <p className="muted">{recherche ? "Aucun client pro ne correspond à cette recherche." : "Aucun client pro inscrit pour le moment."}</p>
            : <div className="cards">{liste.map((c) => <FicheClient key={c.id} c={c} />)}</div>}
        </>
      )}
    </div>
  );
}
