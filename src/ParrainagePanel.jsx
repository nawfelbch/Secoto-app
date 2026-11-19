import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { humanizeError } from "./lib/humanError";
import { STATUT_FILLEUL, codeEnAttente, normaliserCode, oublierCodeEnAttente, texteInvitation } from "./lib/parrainage";

// ============================================================================
// SECOTO 154 — Parrainage : mon code, mon lien, mon crédit, mes filleuls,
// et saisie d'un code reçu. Toutes les règles sont en base.
// ============================================================================

async function chargerMoi() {
  const { data, error } = await supabase.rpc("secoto_parrainage_moi");
  if (error) throw error;
  return data;
}

async function utiliserCode(code) {
  const { data, error } = await supabase.rpc("secoto_parrainage_utiliser", { p_code: code });
  if (error) throw error;
  return data;
}

// Code reçu par lien (?parrain=…) : envoyé une fois, dès que le compte est connecté.
export function ParrainageLienAuto({ accountId, onNotice }) {
  useEffect(() => {
    const code = codeEnAttente();
    if (!accountId || !code) return;
    let vivant = true;
    utiliserCode(code)
      .then((r) => { if (vivant && r?.ok && r.message) onNotice?.(r.message); })
      .catch(() => {})
      .finally(() => oublierCodeEnAttente());
    return () => { vivant = false; };
  }, [accountId, onNotice]);
  return null;
}

export default function ParrainagePanel() {
  const [moi, setMoi] = useState(null);
  const [erreur, setErreur] = useState("");
  const [info, setInfo] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let vivant = true;
    chargerMoi().then((d) => { if (vivant) setMoi(d); }).catch((e) => { if (vivant) setErreur(humanizeError(e)); });
    return () => { vivant = false; };
  }, []);

  async function partager() {
    const texte = texteInvitation(moi);
    try {
      if (navigator.share) { await navigator.share({ title: "SECOTO", text: texte }); return; }
      await navigator.clipboard.writeText(texte);
      setInfo("Message copié : collez-le dans un SMS, WhatsApp ou un e-mail.");
    } catch { /* partage annulé */ }
  }

  async function valider() {
    setBusy(true); setErreur(""); setInfo("");
    try {
      const r = await utiliserCode(normaliserCode(code));
      if (r?.ok) { setInfo(r.message || "Code enregistré."); setMoi(await chargerMoi()); setCode(""); }
      else setErreur(r?.raison || "Code refusé.");
    } catch (e) { setErreur(humanizeError(e)); } finally { setBusy(false); }
  }

  if (!moi && !erreur) return <div className="panel panel-full"><h2>Parrainage</h2><p className="muted">Chargement…</p></div>;
  if (moi && !moi.actif) return <div className="panel panel-full"><h2>Parrainage</h2><p className="muted">Le parrainage n’est pas ouvert pour le moment.</p></div>;
  const transporteur = moi?.type === "transporteur";
  return (
    <div className="panel panel-full parrainage">
      <h2>Parrainage</h2>
      {erreur && <div className="alert error">{erreur}</div>}
      {info && <div className="alert">{info}</div>}
      {moi && (
        <>
          <p>
            {transporteur
              ? <>Parrainez un transporteur : vous recevez <strong>{moi.parrain_eur} €</strong> quand il a livré ses {moi.missions_requises} premières missions SECOTO.</>
              : <>Votre filleul a <strong>{moi.filleul_eur} € de remise</strong> sur son premier transport, et vous recevez <strong>{moi.parrain_eur} € de crédit</strong> sur votre prochain transport quand le sien est livré.</>}
          </p>
          <div className="parrainage-code">
            <span className="muted">Votre code</span>
            <strong>{moi.code}</strong>
          </div>
          <div className="actions-row">
            <button className="btn primary" type="button" onClick={partager}>Inviter quelqu’un</button>
            <button className="btn ghost" type="button" onClick={() => navigator.clipboard?.writeText(moi.lien).then(() => setInfo("Lien copié."))}>Copier le lien</button>
          </div>
          {!transporteur && moi.credit_cents > 0 && (
            <p className="alert">Crédit parrainage disponible : <strong>{Math.round(moi.credit_cents / 100)} €</strong>, déduit automatiquement de votre prochain prix.</p>
          )}
          <h3>Mes filleuls</h3>
          {moi.filleuls?.length
            ? <ul className="parrainage-liste">{moi.filleuls.map((f, i) => <li key={i}><strong>{f.prenom}</strong> · {STATUT_FILLEUL[f.statut] || f.statut}</li>)}</ul>
            : <p className="muted">Aucun filleul pour l’instant.</p>}
          <h3>J’ai un code de parrainage</h3>
          {moi.parrain
            ? <p className="muted">Code de parrainage enregistré{moi.parrain.filleul_eur > 0 ? ` : ${moi.parrain.filleul_eur} € de remise ${moi.parrain.utilise ? "utilisée sur votre réservation" : "sur votre premier transport, déjà incluse dans les prix affichés"}` : ""}.</p>
            : (
              <div className="actions-row">
                <input className="input" value={code} maxLength={24} placeholder="Ex. MARIE-7K3" onChange={(e) => setCode(normaliserCode(e.target.value))} aria-label="Code de parrainage" />
                <button className="btn primary small" type="button" disabled={busy || code.length < 4} onClick={valider}>Valider</button>
              </div>
            )}
          <p className="muted parrainage-regles">
            Remise et crédit valables sur un transport réservé dans l’application, non remboursables en argent, non cumulables
            avec une autre remise (la plus avantageuse s’applique). Récompense après la première commande du filleul livrée et payée
            (pour un transporteur : après ses premières missions livrées). 10 filleuls maximum par an. Voir les conditions générales.
          </p>
        </>
      )}
    </div>
  );
}
