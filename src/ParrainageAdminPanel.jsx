import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { humanizeError } from "./lib/humanError";
import { STATUT_FILLEUL } from "./lib/parrainage";
import { formatDateTime } from "./lib/mappers";

// SECOTO 154 — Admin : tous les parrainages, primes transporteurs à verser.
async function charger() {
  const { data, error } = await supabase.rpc("secoto_admin_parrainages");
  if (error) throw error;
  return data || [];
}

export default function ParrainageAdminPanel() {
  const [liste, setListe] = useState(null);
  const [erreur, setErreur] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let vivant = true;
    charger().then((d) => { if (vivant) setListe(d); }).catch((e) => { if (vivant) setErreur(humanizeError(e)); });
    return () => { vivant = false; };
  }, []);
  async function primeVersee(id) {
    if (!window.confirm("Confirmer que la prime a bien été versée au parrain ?")) return;
    setBusy(true);
    try {
      const { error } = await supabase.rpc("secoto_admin_parrainage_prime_versee", { p_id: id });
      if (error) throw error;
      setListe(await charger());
    } catch (e) { setErreur(humanizeError(e)); } finally { setBusy(false); }
  }
  const aVerser = (liste || []).filter((p) => p.statut === "prime_a_verser");
  return (
    <div className="panel panel-full">
      <h2>Parrainage</h2>
      {erreur && <div className="alert error">{erreur}</div>}
      {!liste && !erreur && <p className="muted">Chargement…</p>}
      {liste && (
        <>
          <p className="muted">{liste.length} parrainage{liste.length > 1 ? "s" : ""} · {aVerser.length} prime{aVerser.length > 1 ? "s" : ""} transporteur à verser</p>
          <div className="cards">
            {liste.map((p) => (
              <article key={p.id} className="mission-card">
                <div className="card-top"><span className="od-pill">{p.type}</span><span className="muted">{formatDateTime(p.created_at)}</span></div>
                <p><strong>{p.parrain}</strong> → {p.filleul}</p>
                <p className="muted">{STATUT_FILLEUL[p.statut] || p.statut} · parrain {p.parrain_eur} €{p.filleul_eur ? ` · filleul ${p.filleul_eur} €` : ""}</p>
                {p.statut === "prime_a_verser" && (
                  <div className="actions-row">
                    {p.parrain_tel && <a className="btn ghost small" href={`tel:${p.parrain_tel}`}>Appeler {p.parrain_tel}</a>}
                    <button className="btn primary small" type="button" disabled={busy} onClick={() => primeVersee(p.id)}>Prime versée</button>
                  </div>
                )}
              </article>
            ))}
          </div>
        </>
      )}
    </div>
  );
}
