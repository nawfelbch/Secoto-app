import { useCallback, useEffect, useState } from "react";
import { humanizeError } from "./lib/humanError";
import { SAV_MOTIFS, SAV_STATUTS, adminSavList, adminSavUpdate } from "./lib/sav";
import { contactLinks, phoneDisplay } from "./lib/contactLinks";
import { openExternal } from "./platform/runtime";

// SECOTO 084 — Demandes SAV des clients (administrateur) : rappeler, suivre, clore.
const MOTIF = Object.fromEntries(SAV_MOTIFS.map((m) => [m.key, m.label]));

export default function AdminSavPanel() {
  const [rows, setRows] = useState([]);
  const [filtre, setFiltre] = useState("actives");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(null);
  const [notes, setNotes] = useState({});

  const charger = useCallback(async () => {
    try { setRows(await adminSavList(null) || []); setError(""); } catch (e) { setError(humanizeError(e)); }
  }, []);
  useEffect(() => {
    let vivant = true;
    adminSavList(null).then((r) => { if (vivant) setRows(r || []); }).catch((e) => { if (vivant) setError(humanizeError(e)); });
    return () => { vivant = false; };
  }, []);

  async function statut(row, s) {
    setBusy(row.id);
    try { await adminSavUpdate(row.id, s, notes[row.id] || null); await charger(); }
    catch (e) { setError(humanizeError(e)); }
    finally { setBusy(null); }
  }

  const visibles = rows.filter((r) => (filtre === "actives" ? r.status !== "resolue" : true));
  return (
    <div className="panel panel-full">
      <h2>SAV clients</h2>
      <div className="actions-row">
        <button className={`btn small ${filtre === "actives" ? "primary" : "ghost"}`} type="button" onClick={() => setFiltre("actives")}>À traiter</button>
        <button className={`btn small ${filtre === "toutes" ? "primary" : "ghost"}`} type="button" onClick={() => setFiltre("toutes")}>Toutes</button>
        <button className="btn ghost small" type="button" onClick={charger}>Actualiser</button>
      </div>
      {error && <div className="alert error">{error}</div>}
      {visibles.length === 0 && <p className="muted">Aucune demande à traiter.</p>}
      <ul className="sav-liste">
        {visibles.map((r) => {
          const links = contactLinks(r.callback_phone);
          return (
            <li key={r.id}>
              <strong>{r.public_ref}</strong> · {MOTIF[r.motif] || r.motif} · {SAV_STATUTS[r.status]}
              {r.course_ref ? ` · ${r.course_ref}` : ""}
              <div>{r.client_name} · {r.client_email}{r.callback_phone ? ` · ${phoneDisplay(r.callback_phone)}` : ""}</div>
              <p>{r.message}</p>
              {r.admin_note && <p className="muted">Note : {r.admin_note}</p>}
              <input type="text" placeholder="Note interne (facultatif)" value={notes[r.id] || ""}
                onChange={(e) => setNotes({ ...notes, [r.id]: e.target.value })} />
              <div className="actions-row">
                {links && <button className="btn primary small" type="button" onClick={() => openExternal(links.tel).catch(() => {})}>Rappeler</button>}
                {r.status === "ouverte" && <button className="btn ghost small" type="button" disabled={busy === r.id} onClick={() => statut(r, "en_cours")}>En cours</button>}
                {r.status !== "resolue" && <button className="btn ghost small" type="button" disabled={busy === r.id} onClick={() => statut(r, "resolue")}>Marquer traitée</button>}
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
