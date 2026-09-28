import { useCallback, useEffect, useMemo, useState } from "react";
import { humanizeError } from "../lib/humanError";
import {
  carrierAcceptInvite, carrierAssignEmployee, carrierCreate, carrierInvite,
  carrierOverview, carrierRemoveMember, carrierSetRole,
} from "../lib/onDemand";

// Espace entreprise de transport.
//
// Un seul principe de conception : l'écran répond dans l'ordre aux questions
// que se pose un gérant en l'ouvrant.
//   1. Qu'est-ce qui attend une décision de ma part, maintenant ?
//   2. Qui est dans mon équipe ?
//   3. Combien SECOTO m'a rapporté ?
// Rien n'est caché derrière un onglet, aucune action ne demande deux clics.
//
// Un employé, lui, ne voit que ses missions. Aucun montant ne transite par
// cet écran pour lui — ni prix client, ni rémunération.

const euros = (v) =>
  Number(v || 0).toLocaleString("fr-FR", { style: "currency", currency: "EUR", maximumFractionDigits: 0 });

const jour = (d) =>
  d ? new Date(d).toLocaleDateString("fr-FR", { day: "2-digit", month: "short" }) : "—";

// Le lien d'invitation évite au convoyeur de recopier un code : il clique,
// il est dans l'entreprise.
const lienInvitation = (token) =>
  `${typeof window === "undefined" ? "" : window.location.origin}/?invitation=${encodeURIComponent(token)}`;

// Le convoyeur clique souvent le lien AVANT d'avoir un compte. Le jeton doit
// donc survivre a l'inscription, sinon il se retrouve devant un ecran vide
// sans savoir quoi faire — la friction qu'on a deja payee cher cote client.
const CLE_INVITATION = "secoto:carrier-invite";

export function memoriserInvitation() {
  try {
    const t = new URLSearchParams(window.location.search).get("invitation");
    if (t) localStorage.setItem(CLE_INVITATION, t);
    return Boolean(t || localStorage.getItem(CLE_INVITATION));
  } catch {
    return false;
  }
}

function invitationEnAttente() {
  try {
    return new URLSearchParams(window.location.search).get("invitation")
      || localStorage.getItem(CLE_INVITATION)
      || "";
  } catch {
    return "";
  }
}

function oublierInvitation() {
  try { localStorage.removeItem(CLE_INVITATION); } catch { /* stockage indisponible */ }
}

export default function EspaceEntreprise({ onChange }) {
  const [vue, setVue] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [info, setInfo] = useState("");
  const [nom, setNom] = useState("");
  const [siren, setSiren] = useState("");
  const [email, setEmail] = useState("");
  const [jeton, setJeton] = useState("");
  const [copie, setCopie] = useState("");

  const charger = useCallback(async () => {
    try {
      setVue(await carrierOverview());
      setError("");
    } catch (e) {
      setError(humanizeError(e));
    }
  }, []);

  useEffect(() => { queueMicrotask(charger); }, [charger]);

  // Invitation reçue par lien : le champ est déjà rempli, il ne reste qu'à
  // confirmer. C'est la friction qu'on supprime en priorité.
  useEffect(() => { setJeton(invitationEnAttente()); }, []);

  async function agir(action, message) {
    setBusy(true);
    setError("");
    setInfo("");
    try {
      const r = await action();
      await charger();
      onChange?.();
      if (message) setInfo(message);
      return r;
    } catch (e) {
      setError(humanizeError(e));
      return null;
    } finally {
      setBusy(false);
    }
  }

  const company = vue?.company || null;
  const gerant = company?.role === "owner";
  const membres = vue?.members || [];
  const suggestions = vue?.suggestions || [];
  const missions = vue?.missions || [];
  const compta = vue?.comptabilite || null;

  // Ce qui attend une décision : les missions de l'entreprise sans exécutant
  // désigné. C'est la seule chose qui bloque réellement une livraison.
  const aDesigner = useMemo(
    () => missions.filter((m) => !m.employee_id && !["completed", "cancelled"].includes(m.status)),
    [missions],
  );

  if (!vue) return <div className="panel panel-full"><h2>Mon entreprise</h2><p className="muted">Chargement…</p></div>;

  // ---------------------------------------------------------------------
  // Aucune entreprise : deux chemins, pas un de plus.
  // ---------------------------------------------------------------------
  if (!company) {
    return (
      <div className="panel panel-full">
        <h2>Mon entreprise</h2>
        <p className="muted">
          Si vous employez des convoyeurs, créez votre entreprise : vous acceptez les missions,
          vous désignez qui les exécute, et <strong>SECOTO ne verse qu’à vous</strong>.
          Si vous travaillez seul, vous n’avez rien à faire ici.
        </p>
        {error && <div className="alert error">{error}</div>}
        {info && <div className="alert">{info}</div>}
        {jeton && (
          <div className="alert">
            Une invitation vous attend. Cliquez sur <strong>Rejoindre</strong>, plus bas : rien d’autre à faire.
          </div>
        )}

        <div className="form-grid">
          <label className="field"><span>Nom de l’entreprise *</span>
            <input value={nom} maxLength={160} placeholder="Ex. Bad Motors" onChange={(e) => setNom(e.target.value)} />
          </label>
          <label className="field"><span>SIREN</span>
            <input value={siren} inputMode="numeric" placeholder="Facultatif" onChange={(e) => setSiren(e.target.value)} />
          </label>
        </div>
        <div className="actions-row">
          <button className="btn primary" type="button" disabled={busy || nom.trim().length < 2}
            onClick={() => agir(() => carrierCreate(nom.trim(), siren.trim()), "Entreprise créée.")}>
            Créer mon entreprise
          </button>
        </div>

        <hr />
        <h3>J’ai reçu une invitation</h3>
        <p className="muted">Votre employeur vous a envoyé un lien. Collez-le ici si vous ne l’avez pas ouvert directement.</p>
        <div className="actions-row">
          <input value={jeton} placeholder="Lien ou code d’invitation" onChange={(e) => setJeton(e.target.value)} />
          <button className="btn primary" type="button" disabled={busy || jeton.trim().length < 6}
            onClick={async () => {
              const ok = await agir(
                () => carrierAcceptInvite(jeton.trim().split("invitation=").pop().trim()),
                "Vous faites partie de l’entreprise.",
              );
              if (ok) { oublierInvitation(); setJeton(""); }
            }}>
            Rejoindre
          </button>
        </div>
      </div>
    );
  }

  // ---------------------------------------------------------------------
  // Employé : ses missions, aucun montant.
  // ---------------------------------------------------------------------
  if (!gerant) {
    return (
      <div className="panel panel-full">
        <h2>{company.name}</h2>
        <p className="muted">
          Vous êtes convoyeur chez {company.name}. Votre employeur accepte les missions et vous désigne ;
          vous pouvez lui en suggérer depuis l’onglet « Disponibles ».
        </p>
        {error && <div className="alert error">{error}</div>}
        <h3>Mes missions</h3>
        {(vue.missions || []).length === 0
          ? <p className="muted">Aucune mission ne vous est confiée pour l’instant.</p>
          : (
            <ul className="od-lines">
              {(vue.missions || []).map((m) => (
                <li key={m.id}>
                  <span><strong>{m.from_city} → {m.to_city}</strong> · {m.vehicle}</span>
                  <span>{jour(m.mission_date)}</span>
                </li>
              ))}
            </ul>
          )}
      </div>
    );
  }

  // ---------------------------------------------------------------------
  // Gérant : décisions d'abord, équipe ensuite, argent enfin.
  // ---------------------------------------------------------------------
  return (
    <div className="panel panel-full">
      <h2>{company.name}</h2>
      {error && <div className="alert error">{error}</div>}
      {info && <div className="alert">{info}</div>}

      {/* 1. Ce qui attend une décision */}
      {(suggestions.length > 0 || aDesigner.length > 0) && (
        <>
          <h3>À décider maintenant</h3>

          {suggestions.map((s) => (
            <div className="alert" key={`${s.mission_id}-${s.employee_id}`}>
              <strong>{s.employee_name}</strong> propose {s.from_city} → {s.to_city} du {jour(s.mission_date)}.
              {s.note ? <> « {s.note} »</> : null}
              <div className="actions-row">
                <button className="btn primary small" type="button" disabled={busy}
                  onClick={() => agir(
                    () => carrierAssignEmployee(s.mission_id, s.employee_id),
                    `${s.employee_name} est désigné sur cette mission.`,
                  )}>
                  Confier à {s.employee_name}
                </button>
              </div>
            </div>
          ))}

          {aDesigner.map((m) => (
            <div className="alert" key={m.id}>
              <strong>{m.from_city} → {m.to_city}</strong> du {jour(m.mission_date)} : aucun convoyeur désigné.
              <div className="actions-row">
                <select defaultValue="" disabled={busy}
                  onChange={(e) => e.target.value && agir(
                    () => carrierAssignEmployee(m.id, e.target.value),
                    "Convoyeur désigné.",
                  )}>
                  <option value="">Désigner un convoyeur…</option>
                  {membres.map((x) => (
                    <option key={x.account_id} value={x.account_id}>
                      {x.name}{x.missions_en_cours ? ` (${x.missions_en_cours} en cours)` : ""}
                    </option>
                  ))}
                </select>
              </div>
            </div>
          ))}
        </>
      )}

      {/* 2. L'équipe */}
      <h3>Mon équipe</h3>
      <p className="muted">
        Un convoyeur voit ses missions et peut vous en suggérer. Il ne voit aucun montant,
        et <strong>aucun paiement ne peut lui être versé</strong> : SECOTO ne verse qu’à l’entreprise.
      </p>

      <ul className="od-lines">
        {membres.map((x) => (
          <li key={x.account_id}>
            <span>
              <strong>{x.name}</strong> · {x.role === "owner" ? "Gérant" : "Convoyeur"}
              {x.account_id === company.payout_account_id ? " · reçoit les versements" : ""}
              {x.missions_en_cours ? ` · ${x.missions_en_cours} mission(s) en cours` : ""}
            </span>
            <span className="actions-row">
              <button className="btn ghost small" type="button" disabled={busy}
                onClick={() => agir(
                  () => carrierSetRole(x.account_id, x.role === "owner" ? "member" : "owner"),
                  x.role === "owner" ? "Passé convoyeur." : "Passé gérant.",
                )}>
                {x.role === "owner" ? "Passer convoyeur" : "Passer gérant"}
              </button>
              {x.role !== "owner" && (
                <button className="btn ghost small" type="button" disabled={busy}
                  onClick={() => agir(() => carrierRemoveMember(x.account_id), "Convoyeur retiré.")}>
                  Retirer
                </button>
              )}
            </span>
          </li>
        ))}
      </ul>

      <h3>Inviter un convoyeur</h3>
      <div className="actions-row">
        <input type="email" value={email} placeholder="son.email@exemple.fr" onChange={(e) => setEmail(e.target.value)} />
        <button className="btn primary small" type="button" disabled={busy || !email.includes("@")}
          onClick={async () => {
            const r = await agir(() => carrierInvite(email.trim()));
            if (r?.token) {
              setEmail("");
              setInfo("Invitation créée : envoyez-lui le lien ci-dessous.");
            }
          }}>
          Créer l’invitation
        </button>
      </div>

      {(vue.invitations || []).length > 0 && (
        <ul className="od-lines">
          {(vue.invitations || []).map((i) => (
            <li key={i.id}>
              <span>{i.email}</span>
              <span className="actions-row">
                <button className="btn ghost small" type="button"
                  onClick={async () => {
                    try {
                      await navigator.clipboard.writeText(lienInvitation(i.token));
                      setCopie(i.id);
                    } catch { setCopie(""); setError("Copie impossible : sélectionnez le lien à la main."); }
                  }}>
                  {copie === i.id ? "Lien copié" : "Copier le lien"}
                </button>
                <a className="btn ghost small" href={`sms:?&body=${encodeURIComponent(
                  `Rejoignez ${company.name} sur SECOTO : ${lienInvitation(i.token)}`)}`}>
                  Envoyer par SMS
                </a>
              </span>
            </li>
          ))}
        </ul>
      )}

      {/* 3. L'argent */}
      <h3>Ce que SECOTO vous a apporté</h3>
      {compta && (
        <div className="od-two">
          <div>
            <strong>{euros(compta.verse_total_eur)}</strong>
            <p className="muted">versés, sur {compta.missions_livrees || 0} mission(s) livrée(s)</p>
          </div>
          <div>
            <strong>{euros(compta.en_attente_eur)}</strong>
            <p className="muted">à venir sur les missions en cours</p>
          </div>
        </div>
      )}
      <p className="muted">
        Chaque paiement est déclenché sous 48 h après la livraison, sur le compte de versement de l’entreprise.
      </p>

      <h3>Missions de l’entreprise</h3>
      {missions.length === 0
        ? <p className="muted">Aucune mission pour l’instant.</p>
        : (
          <ul className="od-lines">
            {missions.slice(0, 30).map((m) => (
              <li key={m.id}>
                <span>
                  <strong>{m.from_city} → {m.to_city}</strong> · {m.vehicle} · {jour(m.mission_date)}
                  {m.employee_id
                    ? ` · ${membres.find((x) => x.account_id === m.employee_id)?.name || "convoyeur désigné"}`
                    : " · à désigner"}
                </span>
                <span>{euros(m.carrier_pay)}</span>
              </li>
            ))}
          </ul>
        )}
    </div>
  );
}
