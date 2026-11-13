import { useCallback, useEffect, useRef, useState } from "react";
import { humanizeError } from "../lib/humanError";
import { chatEnvoyer, chatMessages, chatNonLusPartage, chatSignaler } from "../lib/chatMission";
import { CHAT_MAX, auteurChat, heureChat, texteAEnvoyer, titreChat } from "../lib/chatUtil";

// ============================================================================
// SECOTO 142 — chat en direct client ↔ transporteur, par mission.
// ----------------------------------------------------------------------------
// Fermé par défaut (pastille du nombre de messages non lus). Ouvert, le fil
// se rafraîchit toutes les 8 secondes. Chaque message reçu peut être signalé
// (l'admin est prévenu). L'écriture se ferme 7 jours après la livraison.
// ============================================================================

const RAFRAICHISSEMENT_MS = 8000;

export default function ChatMission({ missionId, roleAttendu = "client" }) {
  const [ouvert, setOuvert] = useState(false);
  const [fil, setFil] = useState(null);
  const [nonLus, setNonLus] = useState(0);
  const [texte, setTexte] = useState("");
  const [busy, setBusy] = useState(false);
  const [erreur, setErreur] = useState("");
  const [signales, setSignales] = useState({});
  const basRef = useRef(null);

  useEffect(() => {
    if (!missionId || ouvert) return undefined;
    let vivant = true;
    chatNonLusPartage().then((m) => { if (vivant) setNonLus(Number(m?.[missionId] || 0)); });
    return () => { vivant = false; };
  }, [missionId, ouvert]);

  const charger = useCallback(async () => {
    try {
      const data = await chatMessages(missionId);
      setFil(data);
      setNonLus(0);
    } catch (e) {
      setErreur(humanizeError(e, "La conversation n’a pas pu être chargée."));
    }
  }, [missionId]);

  useEffect(() => {
    if (!ouvert || !missionId) return undefined;
    const premier = setTimeout(charger, 0);
    const t = setInterval(() => { if (document.visibilityState !== "hidden") charger(); }, RAFRAICHISSEMENT_MS);
    return () => { clearTimeout(premier); clearInterval(t); };
  }, [ouvert, missionId, charger]);

  const nbMessages = fil?.messages?.length || 0;
  useEffect(() => {
    if (ouvert && nbMessages) basRef.current?.scrollIntoView?.({ block: "nearest" });
  }, [ouvert, nbMessages]);

  async function envoyer(e) {
    e.preventDefault();
    const propre = texteAEnvoyer(texte);
    if (!propre || busy) return;
    setBusy(true); setErreur("");
    try {
      await chatEnvoyer(missionId, propre);
      setTexte("");
      await charger();
    } catch (err) {
      setErreur(humanizeError(err, "Le message n’a pas pu être envoyé."));
    } finally {
      setBusy(false);
    }
  }

  async function signaler(id) {
    if (!window.confirm("Signaler ce message à SECOTO ?")) return;
    try {
      await chatSignaler(id);
      setSignales((s) => ({ ...s, [id]: true }));
    } catch (err) {
      setErreur(humanizeError(err, "Le signalement n’a pas pu être envoyé."));
    }
  }

  if (!missionId) return null;
  const role = fil?.role || roleAttendu;

  return (
    <div className="chat-mission">
      <button type="button" className="btn chat-toggle" aria-expanded={ouvert} onClick={() => setOuvert((v) => !v)}>
        💬 {titreChat(role)}
        {!ouvert && nonLus > 0 && <span className="chat-badge" aria-label={`${nonLus} message(s) non lu(s)`}>{nonLus}</span>}
      </button>
      {ouvert && (
        <div className="chat-panel">
          <div className="chat-fil" role="log" aria-live="polite">
            {!fil && <p className="muted">Chargement…</p>}
            {fil && nbMessages === 0 && (
              <p className="muted">Aucun message pour l’instant. Écrivez ici pour convenir de l’heure, de l’accès ou des clés.</p>
            )}
            {(fil?.messages || []).map((m) => (
              <div key={m.id} className={`chat-msg${m.moi ? " is-moi" : ""}${m.auteur_role === "admin" ? " is-admin" : ""}`}>
                <div className="chat-meta">{auteurChat(m, role)} · {heureChat(m.cree_le)}</div>
                <div className="chat-texte">{m.texte}</div>
                {!m.moi && role !== "admin" && (
                  m.signale || signales[m.id]
                    ? <div className="chat-signale">Signalé à SECOTO</div>
                    : <button type="button" className="chat-signaler" onClick={() => signaler(m.id)}>Signaler</button>
                )}
                {role === "admin" && m.signale && <div className="chat-signale">⚠️ Message signalé</div>}
              </div>
            ))}
            <div ref={basRef} />
          </div>
          {fil?.ouvert === false ? (
            <p className="muted">Cette conversation est fermée (plus de 7 jours après la livraison).</p>
          ) : (
            <form className="chat-form" onSubmit={envoyer}>
              <textarea
                value={texte}
                maxLength={CHAT_MAX}
                rows={2}
                placeholder="Votre message…"
                onChange={(e) => setTexte(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); envoyer(e); } }}
              />
              <button type="submit" className="btn primary" disabled={busy || !texteAEnvoyer(texte)}>{busy ? "Envoi…" : "Envoyer"}</button>
            </form>
          )}
          {erreur && <p className="alert error" role="alert">{erreur}</p>}
          <p className="chat-note">Restez courtois. Les échanges sont conservés et peuvent être consultés par SECOTO en cas de litige.</p>
        </div>
      )}
    </div>
  );
}
