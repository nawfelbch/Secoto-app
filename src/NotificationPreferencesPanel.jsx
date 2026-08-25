import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { pushSupported } from "./push";
import { humanizeError } from "./lib/humanError";

// ============================================================================
// SECOTO — Préférences de notification, par compte et donc par rôle.
// ----------------------------------------------------------------------------
// Les événements de paiement et d'annulation ne sont volontairement PAS
// désactivables : ce sont des obligations d'information contractuelle. Couper
// le push ne supprime jamais la trace : la cloche dans l'application reste le
// canal de repli, et l'e-mail double les événements critiques.
// ============================================================================

const DEFAULTS = {
  push_enabled: true,
  email_enabled: true,
  mute_missions: false,
  mute_documents: false,
  mute_frais: false,
  cash_sound_enabled: true,
};

// Le son de caisse ne concerne que les rôles qui gagnent de l'argent sur un
// événement : le transporteur et l'administration. Un client n'a rien à
// encaisser, l'option ne lui est donc même pas affichée.
const CASH_SOUND_ROLES = new Set(["transporter", "admin"]);

const CASH_SOUND_DETAIL = {
  transporter: "Nouvelle course disponible, mission attribuée et paiement reçu.",
  admin: "Paiement encaissé et nouvelle demande.",
};

export default function NotificationPreferencesPanel({ account, onEnablePush, pushState }) {
  const [prefs, setPrefs] = useState(DEFAULTS);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  useEffect(() => {
    let alive = true;
    supabase
      .from("notification_preferences")
      .select("push_enabled,email_enabled,mute_missions,mute_documents,mute_frais,cash_sound_enabled")
      .eq("account_id", account.id)
      .maybeSingle()
      .then(({ data }) => { if (alive && data) setPrefs({ ...DEFAULTS, ...data }); });
    return () => { alive = false; };
  }, [account.id]);

  async function save(next) {
    setBusy(true); setError(""); setNotice("");
    try {
      const { error: rpcError } = await supabase.rpc("secoto_update_notification_preferences", {
        p_push_enabled: next.push_enabled,
        p_email_enabled: next.email_enabled,
        p_mute_missions: next.mute_missions,
        p_mute_documents: next.mute_documents,
        p_mute_frais: next.mute_frais,
        p_cash_sound_enabled: next.cash_sound_enabled,
      });
      if (rpcError) throw rpcError;
      setPrefs(next);
      setNotice("Préférences enregistrées.");
    } catch (e) {
      setError(humanizeError(e, "Enregistrement impossible."));
    } finally {
      setBusy(false);
    }
  }

  function toggle(key) {
    save({ ...prefs, [key]: !prefs[key] });
  }

  return (
    <div className="panel panel-full">
      <h2>Notifications</h2>

      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      {pushSupported() && pushState !== "enabled" && (
        <div className="card-section">
          <p>
            Les notifications ne sont pas encore activées sur cet appareil. Sans
            elles, vous ne serez prévenu qu’en ouvrant l’application.
          </p>
          <button className="btn primary small" type="button" onClick={onEnablePush} disabled={busy}>
            Activer sur cet appareil
          </button>
        </div>
      )}

      <div className="card-section">
        <label className="field">
          <span className="payment-waiver-row">
            <input
              type="checkbox"
              checked={prefs.push_enabled}
              onChange={() => toggle("push_enabled")}
              disabled={busy}
            />
            <span>Recevoir les notifications sur mon téléphone</span>
          </span>
        </label>
        <label className="field">
          <span className="payment-waiver-row">
            <input
              type="checkbox"
              checked={prefs.email_enabled}
              onChange={() => toggle("email_enabled")}
              disabled={busy}
            />
            <span>Recevoir les confirmations importantes par e-mail</span>
          </span>
        </label>
      </div>

      {CASH_SOUND_ROLES.has(account.role) && (
        <div className="card-section">
          <h3>Son des notifications</h3>
          <label className="field">
            <span className="payment-waiver-row">
              <input
                type="checkbox"
                checked={prefs.cash_sound_enabled}
                onChange={() => toggle("cash_sound_enabled")}
                disabled={busy}
              />
              <span>
                Son de caisse enregistreuse sur les notifications qui rapportent
                <br />
                <span className="muted">{CASH_SOUND_DETAIL[account.role]}</span>
              </span>
            </span>
          </label>
          <p className="muted">
            Décoché, ces notifications reprennent le son standard de votre
            téléphone. Toutes les autres notifications SECOTO gardent toujours
            le son standard. Sur Android, le changement s’applique à la
            prochaine notification reçue.
          </p>
        </div>
      )}

      <div className="card-section">
        <h3>Ce que je ne souhaite pas recevoir</h3>
        <label className="field">
          <span className="payment-waiver-row">
            <input
              type="checkbox"
              checked={prefs.mute_missions}
              onChange={() => toggle("mute_missions")}
              disabled={busy}
            />
            <span>Avancement des missions (nouvelle course, suivi, livraison)</span>
          </span>
        </label>
        <label className="field">
          <span className="payment-waiver-row">
            <input
              type="checkbox"
              checked={prefs.mute_documents}
              onChange={() => toggle("mute_documents")}
              disabled={busy}
            />
            <span>Documents (devis, bon de mission, facture)</span>
          </span>
        </label>
        <label className="field">
          <span className="payment-waiver-row">
            <input
              type="checkbox"
              checked={prefs.mute_frais}
              onChange={() => toggle("mute_frais")}
              disabled={busy}
            />
            <span>Frais réels</span>
          </span>
        </label>
        <p className="muted">
          Les notifications de paiement et d’annulation restent toujours actives :
          elles vous informent d’un engagement contractuel.
        </p>
      </div>
    </div>
  );
}
