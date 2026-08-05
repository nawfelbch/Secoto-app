import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabaseClient";

function firstRow(data) {
  return Array.isArray(data) ? data[0] : data;
}

async function copyText(value) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }
  const area = document.createElement("textarea");
  area.value = value;
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();
  document.execCommand("copy");
  area.remove();
}

export function AdminClaimSharePanel({ claim, onClose }) {
  const [notice, setNotice] = useState("");
  if (!claim) return null;

  async function share() {
    const text = `Bonjour, votre transport ${claim.publicRef} est enregistré sur SECOTO. Créez votre compte ou connectez-vous avec ce lien sécurisé pour suivre la mission :`;
    if (navigator.share) {
      try {
        await navigator.share({ title: "Suivi SECOTO", text, url: claim.url });
        return;
      } catch (error) {
        if (error?.name === "AbortError") return;
      }
    }
    await copyText(`${text}\n${claim.url}`);
    setNotice("Message et lien copiés.");
  }

  return (
    <div className="claim-share-panel panel">
      <div className="card-top">
        <div>
          <p className="eyebrow">Lien client sécurisé</p>
          <h2>{claim.publicRef}</h2>
        </div>
        <button className="btn ghost small" type="button" onClick={onClose}>Fermer</button>
      </div>
      <p className="muted">Le lien est à usage unique et expire dans 30 jours. Un nouveau lien invalide automatiquement le précédent.</p>
      <input className="claim-link-input" value={claim.url} readOnly aria-label="Lien sécurisé client" />
      <div className="actions-row">
        <button className="btn primary" type="button" onClick={share}>Partager au client</button>
        <button className="btn ghost" type="button" onClick={async () => { await copyText(claim.url); setNotice("Lien copié."); }}>Copier le lien</button>
      </div>
      {notice && <div className="alert success">{notice}</div>}
    </div>
  );
}

export default function MissionClaimPanel({ onClaimed }) {
  const initialToken = useMemo(() => {
    if (typeof window === "undefined") return "";
    return new URLSearchParams(window.location.search).get("claim") || "";
  }, []);
  const [token, setToken] = useState(initialToken);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  useEffect(() => {
    if (!initialToken) return;
    document.getElementById("secoto-claim-panel")?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, [initialToken]);

  async function claimMission(event) {
    event.preventDefault();
    setError("");
    setNotice("");
    const cleanToken = token.trim();
    if (cleanToken.length < 32) {
      setError("Le code sécurisé est incomplet.");
      return;
    }
    setBusy(true);
    try {
      const { data, error: claimError } = await supabase.rpc("secoto_claim_mission", { p_token: cleanToken });
      if (claimError) throw claimError;
      const row = firstRow(data);
      setNotice(`Le transport ${row?.public_ref || "SECOTO"} est maintenant rattaché à votre compte.`);
      setToken("");
      const url = new URL(window.location.href);
      url.searchParams.delete("claim");
      window.history.replaceState({}, "", `${url.pathname}${url.search}${url.hash}`);
      await onClaimed?.(row);
    } catch (claimError) {
      setError(claimError.message || "Rattachement impossible.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="claim-client-panel" id="secoto-claim-panel">
      <h3>Rattacher un transport commandé par téléphone</h3>
      <p className="muted">Ouvrez le lien envoyé par SECOTO ou collez ici le code sécurisé reçu avec votre référence de course.</p>
      <form className="claim-form" onSubmit={claimMission}>
        <input
          type="text"
          value={token}
          onChange={(event) => setToken(event.target.value)}
          placeholder="Code sécurisé de rattachement"
          autoComplete="off"
          aria-label="Code sécurisé de rattachement"
        />
        <button className="btn primary" type="submit" disabled={busy || !token.trim()}>
          {busy ? "Rattachement…" : "Ajouter ce transport à mon compte"}
        </button>
      </form>
      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}
    </div>
  );
}