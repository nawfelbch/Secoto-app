import { useState } from "react";
import { supabase } from "./supabaseClient";
import { humanizeError } from "./lib/humanError";
import { passwordChanged } from "./lib/onDemand";

// Un compte créé par un gérant arrive avec un mot de passe que son employeur
// connaît. Tant qu'il n'est pas remplacé, l'application ne montre que cet
// écran : c'est la seule façon de garantir qu'un mot de passe transmis par SMS
// ne reste pas actif.
//
// Un seul champ, une seule action. Rien à lire, rien à choisir d'autre.
export default function MotDePasseProvisoire({ account, onChanged }) {
  const [motDePasse, setMotDePasse] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const tropCourt = motDePasse.length > 0 && motDePasse.length < 8;

  async function valider() {
    setBusy(true);
    setError("");
    try {
      const { error: authErr } = await supabase.auth.updateUser({ password: motDePasse });
      if (authErr) throw authErr;
      await passwordChanged();
      onChanged?.();
    } catch (e) {
      setError(humanizeError(e));
      setBusy(false);
    }
  }

  return (
    <main className="app-shell">
      <div className="layout">
      <div className="panel panel-full">
        <h2>Choisissez votre mot de passe</h2>
        <p className="muted">
          Bonjour {account?.fullName || ""}. Votre compte a été créé par votre employeur
          avec un mot de passe provisoire. Choisissez le vôtre : lui ne le connaîtra pas.
        </p>
        {error && <div className="alert error">{error}</div>}
        <label className="field"><span>Nouveau mot de passe *</span>
          <input
            type="password"
            autoComplete="new-password"
            value={motDePasse}
            onChange={(e) => setMotDePasse(e.target.value)}
            placeholder="8 caractères minimum"
          />
          {tropCourt && <small className="muted">Encore {8 - motDePasse.length} caractère(s).</small>}
        </label>
        <div className="actions-row">
          <button
            className="btn primary"
            type="button"
            disabled={busy || motDePasse.length < 8}
            onClick={valider}
          >
            {busy ? "Enregistrement…" : "Valider et continuer"}
          </button>
        </div>
      </div>
    </div>
    </main>
  );
}
