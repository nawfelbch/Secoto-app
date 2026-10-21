// SECOTO 110 — Où les visiteurs abandonnent-ils le formulaire de devis ?
// Visites anonymes (sans compte), par jour et par provenance.
import { useEffect, useState } from "react";
import { supabase } from "../supabaseClient";

const COLONNES = [
  ["arrivee", "Arrivée"], ["trajet", "Trajet"], ["vehicule", "Véhicule"], ["mode", "Mode"],
  ["dates", "Dates"], ["contact", "Contact"], ["prix", "Prix"], ["reserver", "Réserver"],
];
const SOURCES = { ads: "Google Ads", naturel: "Google naturel", direct: "Direct", autre: "Autre" };

/** Taux de passage de la colonne précédente à celle-ci (null si rien avant). */
function tauxPassage(etapes, i) {
  if (i === 0) return null;
  // 112 : le contact est facultatif ; le prix se compare aux visiteurs arrivés aux dates.
  const precedente = COLONNES[i][0] === "prix" ? "dates" : COLONNES[i - 1][0];
  const avant = Number(etapes?.[precedente] || 0);
  const ici = Number(etapes?.[COLONNES[i][0]] || 0);
  return avant > 0 ? Math.round((ici / avant) * 100) : null;
}

export default function EntonnoirPanel() {
  const [lignes, setLignes] = useState(null);
  const [erreur, setErreur] = useState("");
  useEffect(() => {
    supabase.rpc("secoto_admin_entonnoir", { p_jours: 7 })
      .then(({ data, error }) => { if (error) setErreur("Entonnoir indisponible (SQL 110 à coller dans Supabase ?)"); else setLignes(data || []); })
      .catch(() => setErreur("Entonnoir indisponible."));
  }, []);
  if (erreur) return <p className="muted">{erreur}</p>;
  if (!lignes) return <p className="muted">Chargement…</p>;
  if (!lignes.length) return <p className="muted">Pas encore de visite comptée. Les chiffres apparaissent dès les premières visites.</p>;
  return (
    <div className="table-wrap" style={{ overflowX: "auto" }}>
      <table className="entonnoir">
        <thead>
          <tr><th>Jour</th><th>Provenance</th>{COLONNES.map(([, l]) => <th key={l}>{l}</th>)}</tr>
        </thead>
        <tbody>
          {lignes.map((r) => (
            <tr key={`${r.jour}-${r.source}`}>
              <td>{new Date(`${r.jour}T12:00:00`).toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit" })}</td>
              <td>{SOURCES[r.source] || r.source}</td>
              {COLONNES.map(([cle], i) => {
                const t = tauxPassage(r.etapes, i);
                return (
                  <td key={cle}>
                    <strong>{Number(r.etapes?.[cle] || 0)}</strong>
                    {t != null && <small className={t < 50 ? "entonnoir-fuite" : "muted"}> {t} %</small>}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
      <p className="muted">Visites sans compte. Le pourcentage indique la part des visiteurs de l’étape précédente qui ont atteint celle-ci (pour « Prix » : par rapport à « Dates », car le contact est facultatif ; « Contact » = coordonnées laissées) ; en rouge, plus de la moitié abandonne.{lignes.some((r) => r.etapes?.erreur_prix) ? " Des erreurs de calcul de prix ont été comptées : prévenez votre développeur." : ""}</p>
    </div>
  );
}
