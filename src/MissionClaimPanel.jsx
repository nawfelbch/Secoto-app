import { useState } from "react";
import { normalizeClaimCode } from "./lib/missionClaims";

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

function clientMessage(claim) {
  return [
    "Bonjour,",
    "",
    `Votre transport SECOTO ${claim.publicRef} est enregistré.`,
    "",
    "Ouvrez ce lien pour créer votre compte ou vous connecter. Le transport sera ajouté automatiquement à votre espace :",
    claim.url,
    "",
    `Code de secours : ${claim.accessCode}`,
    "",
    "Vous n’aurez normalement aucun code à saisir.",
  ].join("\n");
}

export function AdminClaimSharePanel({ claim, onClose }) {
  const [notice, setNotice] = useState("");
  if (!claim) return null;

  async function share() {
    const text = clientMessage(claim);

    if (navigator.share) {
      try {
        await navigator.share({
          title: `Suivi SECOTO ${claim.publicRef}`,
          text,
        });
        return;
      } catch (error) {
        if (error?.name === "AbortError") return;
      }
    }

    await copyText(text);
    setNotice("Message complet copié.");
  }

  return (
    <div className="claim-share-panel panel" role="status">
      <div className="card-top">
        <div>
          <p className="eyebrow">Accès client sécurisé</p>
          <h2>{claim.publicRef}</h2>
        </div>
        <button className="btn ghost small" type="button" onClick={onClose}>
          Fermer
        </button>
      </div>

      <p className="muted">
        Envoyez le message au client. Le lien le conduit directement à la connexion
        et rattache automatiquement ce transport après identification.
      </p>

      <div className="claim-code-display">
        <span>Code de secours</span>
        <strong>{claim.accessCode}</strong>
        <small>À utiliser uniquement si le lien ne s’ouvre pas correctement.</small>
      </div>

      <div className="actions-row">
        <button className="btn primary" type="button" onClick={share}>
          Envoyer au client
        </button>
        <button
          className="btn ghost"
          type="button"
          onClick={async () => {
            await copyText(clientMessage(claim));
            setNotice("Message complet copié.");
          }}
        >
          Copier le message
        </button>
      </div>

      {notice && <div className="alert success">{notice}</div>}
    </div>
  );
}

export function ClientClaimRecoveryPanel({
  open,
  automatic = false,
  busy = false,
  error = "",
  initialCode = "",
  onSubmitCode,
  onClose,
}) {
  const [code, setCode] = useState(normalizeClaimCode(initialCode));


  if (!open) return null;

  function submit(event) {
    event.preventDefault();
    const normalized = normalizeClaimCode(code);
    if (normalized.replace(/-/g, "").length !== 10) return;
    onSubmitCode?.(normalized);
  }

  return (
    <div className="claim-client-panel" id="secoto-claim-panel">
      <div className="card-top">
        <div>
          <p className="eyebrow">Suivi SECOTO</p>
          <h3>Retrouver mon transport</h3>
        </div>
        {onClose && !busy && (
          <button className="btn ghost small" type="button" onClick={onClose}>
            Fermer
          </button>
        )}
      </div>

      {automatic && !error ? (
        <div className="claim-auto-progress">
          <strong>{busy ? "Ajout de votre transport…" : "Connexion sécurisée détectée"}</strong>
          <p className="muted">
            SECOTO rattache automatiquement la commande à votre compte.
          </p>
        </div>
      ) : (
        <>
          <p className="muted">
            Saisissez le code de secours présent dans le message envoyé par SECOTO.
          </p>
          <form className="claim-form" onSubmit={submit}>
            <input
              className="claim-code-input"
              type="text"
              inputMode="text"
              value={code}
              onChange={(event) => setCode(normalizeClaimCode(event.target.value))}
              placeholder="ABCD-1234-EF"
              autoComplete="one-time-code"
              autoCapitalize="characters"
              aria-label="Code SECOTO"
            />
            <button
              className="btn primary"
              type="submit"
              disabled={busy || code.replace(/-/g, "").length !== 10}
            >
              {busy ? "Vérification…" : "Ajouter mon transport"}
            </button>
          </form>
        </>
      )}

      {error && <div className="alert error">{error}</div>}
    </div>
  );
}