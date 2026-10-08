import { useCallback, useEffect, useState } from "react";
import { humanizeError } from "./lib/humanError";
import { SAV_MOTIFS, SAV_STATUTS, savCourses, savCreate, savMyRequests } from "./lib/sav";

// ============================================================================
// SECOTO 084 — SAV SECOTO (côté client, après la première course).
// ----------------------------------------------------------------------------
// Pour l'enlèvement, le trajet et la livraison, l'interlocuteur du client est
// son transporteur. Le SAV intervient en cas de difficulté : le client écrit,
// SECOTO rappelle. Aucun numéro affiché. Un formulaire court, anti-friction.
// ============================================================================

function dateCourte(iso) {
  try { return new Date(iso).toLocaleDateString("fr-FR", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" }); }
  catch { return ""; }
}

export default function SavPanel() {
  const [courses, setCourses] = useState([]);
  const [demandes, setDemandes] = useState([]);
  const [course, setCourse] = useState("");
  const [motif, setMotif] = useState("");
  const [message, setMessage] = useState("");
  const [rappel, setRappel] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [envoye, setEnvoye] = useState(null);

  const appliquer = useCallback(([c, d]) => {
    setCourses(Array.isArray(c) ? c : []);
    setDemandes(Array.isArray(d) ? d : []);
    setCourse((prev) => prev || (Array.isArray(c) && c[0] ? `${c[0].kind}:${c[0].id}` : ""));
  }, []);
  const lire = () => Promise.all([savCourses().catch(() => []), savMyRequests().catch(() => [])]);
  const charger = () => lire().then(appliquer);
  useEffect(() => {
    let vivant = true;
    lire().then((r) => { if (vivant) appliquer(r); });
    return () => { vivant = false; };
  }, [appliquer]);

  async function envoyer(e) {
    e.preventDefault();
    setError("");
    if (!motif) { setError("Choisissez le motif de votre demande."); return; }
    if (message.trim().length < 5) { setError("Décrivez votre demande en quelques mots."); return; }
    setBusy(true);
    try {
      const [kind, id] = course ? course.split(":") : [null, null];
      const r = await savCreate({
        orderId: kind === "order" ? id : null,
        missionId: kind === "mission" ? id : null,
        motif, message: message.trim(), callbackPhone: rappel.trim() || null,
      });
      setEnvoye(r);
      setMotif(""); setMessage(""); setRappel("");
      charger();
    } catch (err) {
      setError(humanizeError(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="panel contact-panel">
      <h2>SAV SECOTO</h2>
      <p className="muted">
        Pour l’enlèvement, le trajet et la livraison, votre interlocuteur est votre transporteur : ses coordonnées
        sont dans votre commande. Un problème ? Le SAV SECOTO vous accompagne et intervient comme intermédiaire
        pour vous aider à trouver une solution avec lui.
      </p>

      {envoye && (
        <div className="alert success" role="status">
          Demande {envoye.public_ref} bien reçue. Le SAV SECOTO vous recontacte rapidement.
        </div>
      )}
      {error && <div className="alert error" role="alert">{error}</div>}

      <form className="form-grid" onSubmit={envoyer}>
        {courses.length > 0 && (
          <label className="field field-full">
            <span>Course concernée</span>
            <select value={course} onChange={(e) => setCourse(e.target.value)}>
              {courses.map((c) => <option key={`${c.kind}:${c.id}`} value={`${c.kind}:${c.id}`}>{c.label}</option>)}
              <option value="">Aucune course en particulier</option>
            </select>
          </label>
        )}
        <div className="field field-full">
          <span>Motif</span>
          <div className="sav-motifs" role="group" aria-label="Motif">
            {SAV_MOTIFS.map((m) => (
              <button key={m.key} type="button" aria-pressed={motif === m.key} onClick={() => setMotif(m.key)}>{m.label}</button>
            ))}
          </div>
        </div>
        <label className="field field-full">
          <span>Votre message</span>
          <textarea value={message} onChange={(e) => setMessage(e.target.value)} maxLength={4000}
            placeholder="Expliquez-nous la situation en quelques mots." />
        </label>
        <label className="field field-full">
          <span>Numéro pour vous rappeler (facultatif)</span>
          <input type="tel" inputMode="tel" autoComplete="tel" value={rappel} onChange={(e) => setRappel(e.target.value)} maxLength={30}
            placeholder="Sinon, celui de votre compte" />
        </label>
        <button className="btn primary field-full" type="submit" disabled={busy}>
          {busy ? "Envoi…" : "Envoyer ma demande au SAV"}
        </button>
      </form>

      {demandes.length > 0 && (
        <div className="card-section" style={{ marginTop: 16 }}>
          <h3>Mes demandes</h3>
          <ul className="sav-liste">
            {demandes.map((d) => (
              <li key={d.id}>
                <strong>{d.public_ref}</strong> · {SAV_STATUTS[d.status] || d.status} · {dateCourte(d.created_at)}
                {d.course_ref ? ` · ${d.course_ref}` : ""}
                <div className="muted">{d.message}</div>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
