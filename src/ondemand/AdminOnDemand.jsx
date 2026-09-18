import { humanizeError } from "../lib/humanError";
import { useCallback, useEffect, useMemo, useState } from "react";
import { admin, formatCents, formatDateTime, ORDER_STATUS_LABEL, PAYMENT_STATE_LABEL, toCsv } from "../lib/onDemand";

const TABS = [
  { key: "orders", label: "Commandes" },
  { key: "quotes", label: "Devis à établir" },
  { key: "grids", label: "Barèmes & réglages" },
  { key: "partners", label: "Partenaires" },
  { key: "payouts", label: "Versements" },
  { key: "subscriptions", label: "Abonnements" },
  { key: "journal", label: "Journal & export" },
];

const FLAG_LABEL = {
  auto_pricing: "Prix automatique (devis calculés)",
  od_payments: "Paiement en ligne des commandes",
  subscriptions: "Abonnements professionnels",
  dispatch_notifications: "Diffusion automatique aux partenaires",
  live_tracking: "Suivi de position pendant la mission",
};

function download(content, name, type = "text/csv;charset=utf-8") {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const a = document.createElement("a");
  a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

export default function AdminOnDemand({ flags, onFlagsChange, transporters = [] }) {
  const [tab, setTab] = useState("orders");
  const [data, setData] = useState({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  const load = useCallback(async (which = tab) => {
    setError("");
    try {
      const map = {
        orders: () => admin.orders(),
        quotes: () => admin.quotes(),
        grids: () => admin.grids(),
        partners: () => admin.compliance(),
        payouts: () => admin.payouts("to_pay"),
        subscriptions: () => Promise.all([admin.eligibilityList(), admin.subscriptions()]).then(([applications, subscriptions]) => ({ applications, subscriptions })),
        journal: () => admin.audit(),
      };
      const result = await map[which]();
      setData((d) => ({ ...d, [which]: result }));
    } catch (e) {
      setError(humanizeError(e));
    }
  }, [tab]);

  useEffect(() => { queueMicrotask(() => load(tab)); }, [tab, load]);

  async function run(work, successMessage) {
    setBusy(true); setError(""); setMessage("");
    try {
      await work();
      if (successMessage) setMessage(successMessage);
      await load(tab);
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="panel panel-full">
      <h2>Transport à la demande</h2>
      <div className="tabs">
        {TABS.map((t) => (
          <button key={t.key} type="button" className={tab === t.key ? "active" : ""} onClick={() => setTab(t.key)}>{t.label}</button>
        ))}
      </div>
      {error && <div className="alert error" role="alert">{error}</div>}
      {message && <div className="alert success" role="status">{message}</div>}

      {tab === "orders" && <AdminOrders orders={data.orders} busy={busy} run={run} transporters={transporters} />}
      {tab === "quotes" && <AdminQuotes quotes={data.quotes} busy={busy} run={run} />}
      {tab === "grids" && <AdminGrids grids={data.grids} flags={flags} busy={busy} run={run} onFlagsChange={onFlagsChange} />}
      {tab === "partners" && <AdminPartners partners={data.partners} busy={busy} run={run} />}
      {tab === "payouts" && <AdminPayouts payouts={data.payouts} busy={busy} run={run} />}
      {tab === "subscriptions" && <AdminSubscriptions data={data.subscriptions} busy={busy} run={run} />}
      {tab === "journal" && <AdminJournal entries={data.journal} />}
    </div>
  );
}

function AdminOrders({ orders, busy, run, transporters }) {
  const [openId, setOpenId] = useState(null);
  const [pay, setPay] = useState("");
  const [note, setNote] = useState("");
  const [partner, setPartner] = useState("");
  // Pilotage en cours de mission : prix client, rémunération, date de prise en
  // charge. Le motif est obligatoire et le changement est tracé.
  const [cond, setCond] = useState({ client: "", pay: "", pickup: "", note: "" });
  if (!orders) return <p className="muted">Chargement…</p>;
  const live = orders.filter((o) => !["delivered", "cancelled"].includes(o.status));
  const archive = orders.filter((o) => ["delivered", "cancelled"].includes(o.status));
  const render = (o) => (
    <article className="mission-card" key={o.id}>
      <div className="card-top">
        <span className="badge">{o.public_ref}</span>
        <span className="status status-pending">{ORDER_STATUS_LABEL[o.status]}</span>
      </div>
      <h3>{o.pickup.city} → {o.delivery.city}</h3>
      <p>{o.vehicle?.model} · {o.mode} · {formatDateTime(o.pickup_at)} · {o.client_name}</p>
      <p>
        Client {formatCents(o.client_price_cents)} · partenaire {formatCents(o.partner_pay_cents)} · <strong>marge {formatCents(o.margin_cents)}</strong>
        {o.funding === "subscription" ? " · forfait" : ` · ${PAYMENT_STATE_LABEL[o.payment_status] || "—"}`}
      </p>
      <p className="muted">
        Tour {o.dispatch_round} · {o.offers?.sent || 0} proposition(s) en cours, {o.offers?.seen || 0} vue(s), {o.offers?.declined || 0} refus, {o.offers?.unanswered || 0} sans réponse
        {o.offers_expire_at ? ` · tour valable jusqu’à ${formatDateTime(o.offers_expire_at)}` : ""}
        {o.refund_pending ? " · remboursement/libération en cours" : ""}
        {o.dispute ? ` · contestation ${o.dispute}` : ""}
      </p>
      {openId === o.id ? (
        <div className="card-section">
          <div className="od-inline-form">
            <label className="field"><span>Rémunération partenaire (€)</span><input inputMode="decimal" value={pay} onChange={(e) => setPay(e.target.value)} /></label>
            <label className="field"><span>Motif (si dérogation de marge)</span><input value={note} onChange={(e) => setNote(e.target.value)} /></label>
            <button className="btn ghost small" type="button" disabled={busy}
              onClick={() => run(() => admin.setPartnerPay(o.id, Math.round(Number(pay.replace(",", ".")) * 100), Boolean(note), note || null), "Rémunération mise à jour.")}>Appliquer</button>
          </div>
          <div className="od-inline-form">
            <label className="field"><span>Attribuer à</span>
              <select value={partner} onChange={(e) => setPartner(e.target.value)}>
                <option value="">Choisir un partenaire…</option>
                {transporters.map((t) => <option key={t.id} value={t.id}>{t.companyName || t.fullName} ({t.transporterType})</option>)}
              </select>
            </label>
            <button className="btn ghost small" type="button" disabled={busy || !partner}
              onClick={() => run(() => admin.lockForPartner(o.id, partner), "Attribution demandée (capture du paiement en cours).")}>Attribuer</button>
          </div>
          <div className="od-inline-form">
            <label className="field"><span>Prix client (€)</span><input inputMode="decimal" value={cond.client} onChange={(e) => setCond({ ...cond, client: e.target.value })} /></label>
            <label className="field"><span>Rémunération transporteur (€)</span><input inputMode="decimal" value={cond.pay} onChange={(e) => setCond({ ...cond, pay: e.target.value })} /></label>
            <label className="field"><span>Prise en charge</span><input type="datetime-local" value={cond.pickup} onChange={(e) => setCond({ ...cond, pickup: e.target.value })} /></label>
            <label className="field"><span>Motif (obligatoire)</span><input value={cond.note} onChange={(e) => setCond({ ...cond, note: e.target.value })} /></label>
            <button className="btn ghost small" type="button" disabled={busy || cond.note.trim().length < 3}
              onClick={() => run(() => {
                const euros = (v) => (String(v).trim() ? Math.round(Number(String(v).replace(",", ".")) * 100) : undefined);
                const payload = {};
                if (euros(cond.client) !== undefined) payload.client_price_cents = euros(cond.client);
                if (euros(cond.pay) !== undefined) payload.partner_pay_cents = euros(cond.pay);
                if (cond.pickup) payload.pickup_at = new Date(cond.pickup).toISOString();
                return admin.updateConditions(o.id, payload, cond.note.trim());
              }, "Conditions mises à jour. Le client et le transporteur sont prévenus.")}>Modifier les conditions</button>
          </div>
          <p className="muted">
            Modifiable à tout moment, même en cours de mission. Si le prix change après encaissement,
            le complément ou le remboursement se traite à la main : rien n’est débité automatiquement.
          </p>
          <div className="actions-row">
            <button className="btn ghost small" type="button" disabled={busy} onClick={() => run(() => admin.rebroadcast(o.id), "Nouvelle diffusion lancée.")}>Rediffuser</button>
            {o.status === "partner_confirmed" && (
              <button className="btn ghost small" type="button" disabled={busy} onClick={() => run(() => admin.replacePartner(o.id, window.prompt("Motif du remplacement ?") || ""), "Partenaire remplacé.")}>Remplacer le partenaire</button>
            )}
            <button className="btn danger small" type="button" disabled={busy}
              onClick={() => run(() => admin.cancelOrder(o.id, window.prompt("Motif d’annulation ?") || "", window.confirm("Rembourser / libérer le paiement ? (Annuler = pas de remboursement)")), "Commande annulée.")}>Annuler</button>
            <button className="btn ghost small" type="button" onClick={() => setOpenId(null)}>Fermer</button>
          </div>
        </div>
      ) : (
        <div className="actions-row"><button className="btn ghost small" type="button" onClick={() => {
          setOpenId(o.id); setPay(String((o.partner_pay_cents / 100).toFixed(2))); setNote("");
          setCond({
            client: String((o.client_price_cents / 100).toFixed(2)),
            pay: String((o.partner_pay_cents / 100).toFixed(2)),
            pickup: new Date(new Date(o.pickup_at).getTime() - new Date(o.pickup_at).getTimezoneOffset() * 60000).toISOString().slice(0, 16),
            note: "",
          });
        }}>Piloter</button></div>
      )}
    </article>
  );
  return (
    <>
      {live.length === 0 && <p className="muted">Aucune commande en cours.</p>}
      <div className="cards">{live.map(render)}</div>
      {archive.length > 0 && <div className="applications-box"><h4>Historique</h4><div className="cards">{archive.slice(0, 20).map(render)}</div></div>}
    </>
  );
}

function AdminQuotes({ quotes, busy, run }) {
  const [form, setForm] = useState({});
  if (!quotes) return <p className="muted">Chargement…</p>;
  const pending = quotes.filter((q) => ["manual_review", "manual_priced"].includes(q.status));
  return (
    <>
      {pending.length === 0 && <p className="muted">Aucun devis à établir.</p>}
      <div className="cards">
        {pending.map((q) => {
          const f = form[q.id] || { client: "", partner: "", hours: 48, note: "", override: false };
          const set = (patch) => setForm({ ...form, [q.id]: { ...f, ...patch } });
          const margin = Number(f.client) - Number(f.partner);
          return (
            <article className="mission-card" key={q.id}>
              <div className="card-top"><span className="badge">{q.mode}</span><span className="od-pill is-warn">{q.manual_reason || q.status}</span></div>
              <h3>{q.pickup.city} → {q.delivery.city}</h3>
              <p>{q.vehicle?.model} · {q.vehicle?.class} · {q.vehicle?.rolling ? "roulant" : "NON roulant"} · {q.route?.distance_km ? `${q.route.distance_km} km` : "distance à estimer"}</p>
              <p className="muted">{q.client_name} · prise en charge {formatDateTime(q.pickup_at)} · créneau {q.schedule?.slot}</p>
              {q.vehicle?.notes && <p className="muted">« {q.vehicle.notes} »</p>}
              <div className="od-inline-form">
                <label className="field"><span>Prix client (€)</span><input inputMode="decimal" value={f.client} onChange={(e) => set({ client: e.target.value.replace(",", ".") })} /></label>
                <label className="field"><span>Rémunération partenaire (€)</span><input inputMode="decimal" value={f.partner} onChange={(e) => set({ partner: e.target.value.replace(",", ".") })} /></label>
                <label className="field"><span>Validité (h)</span><input type="number" min="1" max="720" value={f.hours} onChange={(e) => set({ hours: Number(e.target.value) })} /></label>
              </div>
              <p className="muted">Marge : {Number.isFinite(margin) ? `${margin.toFixed(2)} €` : "—"}{Number.isFinite(margin) && Number(f.client) > 0 ? ` (${((margin / Number(f.client)) * 100).toFixed(1)} %)` : ""}</p>
              <label className="od-checks"><input type="checkbox" checked={f.override} onChange={(e) => set({ override: e.target.checked })} /> Déroger au seuil de marge</label>
              <label className="field"><span>Note interne</span><input value={f.note} onChange={(e) => set({ note: e.target.value })} /></label>
              <div className="actions-row">
                <button className="btn primary small" type="button" disabled={busy || !f.client || !f.partner}
                  onClick={() => run(() => admin.priceQuote(q.id, Math.round(Number(f.client) * 100), Math.round(Number(f.partner) * 100), f.hours, f.note, f.override), "Devis transmis au client.")}>Envoyer le devis</button>
              </div>
            </article>
          );
        })}
      </div>
    </>
  );
}

function AdminGrids({ grids, flags, busy, run, onFlagsChange }) {
  const [draft, setDraft] = useState("");
  const [mode, setMode] = useState("convoyage");
  const [note, setNote] = useState("");
  const [sim, setSim] = useState({ km: 400, result: null });
  const active = useMemo(() => (grids || []).filter((g) => g.status === "active"), [grids]);
  return (
    <>
      <h3>Activation des fonctionnalités</h3>
      <div className="od-checks">
        {Object.entries(FLAG_LABEL).map(([key, label]) => (
          <label key={key}>
            <input type="checkbox" checked={Boolean(flags?.[key])} disabled={busy}
              onChange={(e) => run(async () => { const next = await admin.setFlag(key, e.target.checked); onFlagsChange?.(next); })} />
            {label}
          </label>
        ))}
      </div>
      <h3 style={{ marginTop: 18 }}>Barèmes</h3>
      {!grids && <p className="muted">Chargement…</p>}
      <div className="od-scroll">
        <table className="od-table">
          <thead><tr><th>Mode</th><th>Version</th><th>Statut</th><th>Origine</th><th>Paramètres</th><th /></tr></thead>
          <tbody>
            {(grids || []).map((g) => (
              <tr key={g.id}>
                <td>{g.mode}</td><td>v{g.version}</td>
                <td><span className={`od-pill ${g.status === "active" ? "is-ok" : ""}`}>{g.status}</span></td>
                <td>{g.source_note}</td>
                <td><details><summary>voir</summary><pre className="od-json">{JSON.stringify(g.params, null, 2)}</pre></details></td>
                <td>
                  {g.status !== "active" && <button className="btn ghost small" type="button" disabled={busy} onClick={() => run(() => admin.activateGrid(g.id), "Barème activé.")}>Activer</button>}
                  {g.status === "active" && <button className="btn ghost small" type="button" disabled={busy}
                    onClick={() => run(async () => { const r = await admin.simulate(g.id, Number(sim.km), { class: "voiture", category: "standard", rolling: true, constraints: [] }, 72); setSim((s) => ({ ...s, result: r })); })}>Simuler {sim.km} km</button>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {sim.result && (
        <div className="alert">
          {sim.result.manual_reason
            ? `Devis manuel : ${sim.result.manual_reason}`
            : `Client ${formatCents(sim.result.client_cents)} · partenaire ${formatCents(sim.result.partner_cents)} · marge ${formatCents(sim.result.margin_cents)} · encaissé ${formatCents(sim.result.collect_cents)}`}
        </div>
      )}
      <div className="od-inline-form">
        <label className="field"><span>Distance simulée (km)</span><input type="number" value={sim.km} onChange={(e) => setSim({ ...sim, km: e.target.value })} /></label>
      </div>
      <h4 style={{ marginTop: 16 }}>Nouvelle version</h4>
      <p className="muted">Une nouvelle version n’est jamais appliquée aux devis déjà émis : chaque devis conserve la version qui l’a produit.</p>
      <div className="od-inline-form">
        <label className="field"><span>Mode</span><select value={mode} onChange={(e) => setMode(e.target.value)}><option value="convoyage">convoyage</option><option value="plateau">plateau</option></select></label>
        <label className="field field-full"><span>Origine / justification</span><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Ex. révision gazole septembre 2026" /></label>
      </div>
      <label className="field"><span>Paramètres (JSON)</span>
        <textarea className="od-json" value={draft} placeholder={JSON.stringify(active[0]?.params || {}, null, 2)} onChange={(e) => setDraft(e.target.value)} />
      </label>
      <div className="actions-row">
        <button className="btn ghost small" type="button" onClick={() => setDraft(JSON.stringify(active.find((g) => g.mode === mode)?.params || {}, null, 2))}>Partir du barème actif</button>
        <button className="btn primary small" type="button" disabled={busy || !draft || note.length < 5}
          onClick={() => run(() => admin.createGrid(mode, JSON.parse(draft), note), "Nouvelle version créée (brouillon).")}>Créer la version</button>
      </div>
    </>
  );
}

function AdminPartners({ partners, busy, run }) {
  if (!partners) return <p className="muted">Chargement…</p>;
  return (
    <div className="od-scroll">
      <table className="od-table">
        <thead><tr><th>Partenaire</th><th>Type</th><th>Vérifié</th><th>Documents</th><th>Prochaine échéance</th><th>Disponible</th><th /></tr></thead>
        <tbody>
          {partners.map((p) => (
            <tr key={p.partner_id} className={p.documents_valid ? "" : "is-error"}>
              <td>{p.name}</td>
              <td>{p.transporter_type}</td>
              <td>{p.is_verified ? "oui" : "non"}</td>
              <td>{p.documents_valid ? "à jour" : `${p.expired.length} expiré(s)`}</td>
              <td>{p.next_expiry ? new Date(p.next_expiry).toLocaleDateString("fr-FR") : "—"}</td>
              <td>{p.available ? "oui" : "non"}{p.notify_offline ? " · push" : ""}</td>
              <td>
                {p.expired?.map((d) => (
                  <button key={d.id} className="btn ghost small" type="button" disabled={busy}
                    onClick={() => run(() => admin.setDocumentValidity(d.id, window.prompt(`Nouvelle validité pour ${d.type} (AAAA-MM-JJ)`) || null), "Échéance mise à jour.")}>{d.type}</button>
                ))}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AdminPayouts({ payouts, busy, run }) {
  if (!payouts) return <p className="muted">Chargement…</p>;
  if (!payouts.length) return <p className="muted">Aucun versement en attente.</p>;
  return (
    <div className="od-scroll">
      <table className="od-table">
        <thead><tr><th>Mission</th><th>Partenaire</th><th>Montant</th><th>Paiement client</th><th /></tr></thead>
        <tbody>
          {payouts.map((p) => (
            <tr key={p.id}>
              <td>{p.mission_ref}</td><td>{p.partner_name}</td><td>{formatCents(p.amount_cents)}</td><td>{PAYMENT_STATE_LABEL[p.client_payment_status] || "—"}</td>
              <td><button className="btn ghost small" type="button" disabled={busy}
                onClick={() => run(() => admin.markPayout(p.id, window.prompt("Référence du virement ?") || ""), "Versement marqué réglé.")}>Marquer réglé</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AdminSubscriptions({ data, busy, run }) {
  const [summary, setSummary] = useState(null);
  const [proposal, setProposal] = useState(null);
  if (!data) return <p className="muted">Chargement…</p>;
  return (
    <>
      <h3>Dossiers d’éligibilité</h3>
      {data.applications.length === 0 && <p className="muted">Aucun dossier.</p>}
      <div className="od-scroll">
        <table className="od-table">
          <thead><tr><th>Société</th><th>Statut</th><th>Lignes</th><th>Transmis le</th><th /></tr></thead>
          <tbody>
            {data.applications.map((a) => (
              <tr key={a.id}>
                <td>{a.business_name}{a.siren ? ` · ${a.siren}` : ""}</td><td>{a.status}</td><td>{a.rows}</td><td>{a.submitted_at ? formatDateTime(a.submitted_at) : "—"}</td>
                <td>
                  <button className="btn ghost small" type="button" onClick={async () => { const s = await admin.eligibilitySummary(a.id); setSummary(s); setProposal(defaultProposal(a.id, s)); }}>Étudier</button>
                  <button className="btn ghost small" type="button" disabled={busy}
                    onClick={() => run(() => admin.setApplicationStatus(a.id, "needs_correction", window.prompt("Que faut-il compléter ?") || ""), "Demande de complément envoyée.")}>Complément</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {summary && (
        <div className="applications-box">
          <h4>{summary.business?.name} — {summary.totals?.trips || 0} trajets analysés</h4>
          <p className="muted">{summary.disclaimer}</p>
          <p>
            {Math.round(summary.totals?.km || 0)} km · {Number(summary.totals?.amount_eur || 0).toLocaleString("fr-FR", { style: "currency", currency: "EUR" })} facturés ·
            moyenne {summary.totals?.avg_km} km · max {summary.totals?.max_km} km · {summary.totals?.avg_eur_per_km} €/km · {summary.totals?.warnings} ligne(s) douteuse(s)
          </p>
          <div className="od-bars">
            {(summary.by_distance || []).map((b) => (
              <div key={b.bucket}><span>{b.bucket} km</span><b style={{ width: `${Math.min(100, (b.trips / Math.max(1, summary.totals.trips)) * 100)}%` }} /><span>{b.trips}</span></div>
            ))}
          </div>
          <div className="od-bars" style={{ marginTop: 10 }}>
            {(summary.by_mode_vehicle || []).slice(0, 8).map((b, i) => (
              <div key={i}><span>{b.mode} · {b.vehicle}</span><b style={{ width: `${Math.min(100, (b.trips / Math.max(1, summary.totals.trips)) * 100)}%` }} /><span>{b.trips}</span></div>
            ))}
          </div>
          <p className="muted">Trajets fréquents : {(summary.top_routes || []).map((r) => `${r.from}→${r.to} (${r.trips})`).join(", ") || "—"}</p>
          {proposal && <ProposalForm proposal={proposal} setProposal={setProposal} busy={busy} run={run} />}
          <div className="actions-row"><button className="btn ghost small" type="button" onClick={() => { setSummary(null); setProposal(null); }}>Fermer l’étude</button></div>
        </div>
      )}

      <h3 style={{ marginTop: 18 }}>Abonnements</h3>
      {data.subscriptions.length === 0 && <p className="muted">Aucun abonnement.</p>}
      <div className="cards">
        {data.subscriptions.map((s) => (
          <article className="mission-card" key={s.id}>
            <div className="card-top"><span className="badge">{s.business_name}</span><span className={`od-pill ${s.status === "active" ? "is-ok" : "is-warn"}`}>{s.status}</span></div>
            <p>{formatCents(s.plan?.monthly_price_cents)} / mois · période jusqu’au {s.current_period_end ? formatDateTime(s.current_period_end) : "—"}{s.cancel_at_period_end ? " · résiliation demandée" : ""}</p>
            <p className="muted">Pire cas simulé : marge {s.plan?.worst_case?.worst_case_margin_eur} € ({s.plan?.worst_case?.worst_case_margin_pct} %)</p>
            {(s.usage?.categories || []).map((c) => <p key={c.category}>{c.category} : {c.consumed} consommés, {c.reserved} réservés / {c.included}</p>)}
            {(s.extensions || []).map((e) => (
              <div className="alert" key={e.id}>
                Extension {e.category} × {e.quantity}{e.extra_km ? ` + ${e.extra_km} km` : ""} — {e.status}
                {e.status === "requested" && (
                  <button className="btn ghost small" type="button" disabled={busy}
                    onClick={() => run(() => admin.priceExtension(e.id, Math.round(Number((window.prompt("Prix de l’extension en € ?") || "0").replace(",", ".")) * 100), 72), "Extension chiffrée.")}>Chiffrer</button>
                )}
              </div>
            ))}
          </article>
        ))}
      </div>
    </>
  );
}

function defaultProposal(applicationId, summary) {
  const q = summary.application?.questionnaire || {};
  return {
    application_id: applicationId,
    monthly_price_cents: 0,
    km_cap_total: Math.round((Number(summary.totals?.km) || 1000) / 3),
    max_km_per_trip: Math.max(100, Math.round(Number(summary.totals?.max_km) || 300)),
    zones: q.zones || [],
    modes: q.modes || ["convoyage"],
    lead_time_hours: 48,
    cancellation_notice_hours: 24,
    included_fees: "Convoyeur vérifié, états des lieux au départ et à la livraison, suivi dans l’application.",
    exclusions: "Carburant et péages refacturés au réel sur justificatifs validés.",
    carry_over_rule: "Les droits non utilisés ne sont pas reportés d’une période sur l’autre.",
    cancellation_rule: "Annulation plus de 24 h avant la prise en charge : droit restitué. Ensuite, le droit est consommé.",
    termination_rule: "Résiliable à chaque échéance mensuelle, sans frais, effet au terme de la période en cours.",
    effective_date: new Date().toISOString().slice(0, 10),
    valid_until: new Date(Date.now() + 14 * 86400000).toISOString().slice(0, 10),
    allowances: [{ category: "convoyage:voiture", quantity: Math.max(1, Math.round((Number(q.trips_per_month) || 4))), partner_cost_per_km_eur: 0.55, fees_per_trip_eur: 0, fixed_cost_per_trip_eur: 0 }],
  };
}

function ProposalForm({ proposal, setProposal, busy, run }) {
  const [saved, setSaved] = useState(null);
  const set = (patch) => setProposal({ ...proposal, ...patch });
  const setAllowance = (i, patch) => set({ allowances: proposal.allowances.map((a, idx) => (idx === i ? { ...a, ...patch } : a)) });
  return (
    <div className="card-section">
      <h4>Proposition</h4>
      <div className="form-grid">
        <label className="field"><span>Mensualité (€)</span><input inputMode="decimal" value={proposal.monthly_price_cents / 100 || ""} onChange={(e) => set({ monthly_price_cents: Math.round(Number(e.target.value.replace(",", ".")) * 100) || 0 })} /></label>
        <label className="field"><span>Plafond km / mois</span><input type="number" value={proposal.km_cap_total} onChange={(e) => set({ km_cap_total: Number(e.target.value) })} /></label>
        <label className="field"><span>Distance max / trajet</span><input type="number" value={proposal.max_km_per_trip} onChange={(e) => set({ max_km_per_trip: Number(e.target.value) })} /></label>
        <label className="field"><span>Zones (départements)</span><input value={proposal.zones.join(", ")} onChange={(e) => set({ zones: e.target.value.toUpperCase().split(/[^0-9A-Z]+/).filter(Boolean) })} /></label>
        <label className="field"><span>Modes</span><input value={proposal.modes.join(", ")} onChange={(e) => set({ modes: e.target.value.split(/[^a-z]+/).filter(Boolean) })} /></label>
        <label className="field"><span>Délai de prévenance (h)</span><input type="number" value={proposal.lead_time_hours} onChange={(e) => set({ lead_time_hours: Number(e.target.value) })} /></label>
        <label className="field"><span>Préavis d’annulation (h)</span><input type="number" value={proposal.cancellation_notice_hours} onChange={(e) => set({ cancellation_notice_hours: Number(e.target.value) })} /></label>
        <label className="field"><span>Date d’effet</span><input type="date" value={proposal.effective_date} onChange={(e) => set({ effective_date: e.target.value })} /></label>
        <label className="field"><span>Valable jusqu’au</span><input type="date" value={proposal.valid_until} onChange={(e) => set({ valid_until: e.target.value })} /></label>
      </div>
      <h5>Droits inclus (aucun forfait illimité)</h5>
      {proposal.allowances.map((a, i) => (
        <div className="od-inline-form" key={i}>
          <label className="field"><span>Catégorie</span><input value={a.category} onChange={(e) => setAllowance(i, { category: e.target.value })} /></label>
          <label className="field"><span>Transports / mois</span><input type="number" value={a.quantity} onChange={(e) => setAllowance(i, { quantity: Number(e.target.value) })} /></label>
          <label className="field"><span>Coût partenaire €/km</span><input inputMode="decimal" value={a.partner_cost_per_km_eur} onChange={(e) => setAllowance(i, { partner_cost_per_km_eur: Number(e.target.value.replace(",", ".")) })} /></label>
          <label className="field"><span>Frais / trajet (€)</span><input inputMode="decimal" value={a.fees_per_trip_eur} onChange={(e) => setAllowance(i, { fees_per_trip_eur: Number(e.target.value.replace(",", ".")) })} /></label>
          <button className="btn ghost small" type="button" onClick={() => set({ allowances: proposal.allowances.filter((_, idx) => idx !== i) })}>Retirer</button>
        </div>
      ))}
      <button className="btn ghost small" type="button" onClick={() => set({ allowances: [...proposal.allowances, { category: "plateau:voiture", quantity: 1, partner_cost_per_km_eur: 1.2, fees_per_trip_eur: 0, fixed_cost_per_trip_eur: 0 }] })}>Ajouter une catégorie</button>
      <div className="form-grid" style={{ marginTop: 12 }}>
        {["included_fees", "exclusions", "carry_over_rule", "cancellation_rule", "termination_rule"].map((k) => (
          <label className="field field-full" key={k}><span>{{ included_fees: "Frais inclus", exclusions: "Exclusions", carry_over_rule: "Report", cancellation_rule: "Annulation", termination_rule: "Résiliation" }[k]}</span>
            <textarea rows={2} value={proposal[k]} onChange={(e) => set({ [k]: e.target.value })} /></label>
        ))}
      </div>
      {saved?.worst_case && (
        <div className={`alert ${Number(saved.worst_case.worst_case_margin_pct) >= 10 ? "success" : "error"}`}>
          Simulation en utilisation complète (combinaison autorisée la plus coûteuse) : coût {saved.worst_case.worst_case_cost_eur} €,
          marge {saved.worst_case.worst_case_margin_eur} € ({saved.worst_case.worst_case_margin_pct} %), {saved.worst_case.km_used} km, {saved.worst_case.trips} transports.
        </div>
      )}
      <div className="actions-row">
        <button className="btn ghost small" type="button" disabled={busy}
          onClick={() => run(async () => { const r = await admin.saveProposal({ ...proposal, id: saved?.id }); setSaved(r); }, "Proposition enregistrée (brouillon).")}>Enregistrer et simuler</button>
        <button className="btn primary small" type="button" disabled={busy || !saved?.id}
          onClick={() => run(() => admin.sendProposal(saved.id), "Proposition envoyée au client.")}>Envoyer au client</button>
      </div>
    </div>
  );
}

function AdminJournal({ entries }) {
  const [range, setRange] = useState(() => ({ from: new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10), to: new Date().toISOString().slice(0, 10) }));
  const [busy, setBusy] = useState(false);
  return (
    <>
      <h3>Export comptable</h3>
      <div className="od-inline-form">
        <label className="field"><span>Du</span><input type="date" value={range.from} onChange={(e) => setRange({ ...range, from: e.target.value })} /></label>
        <label className="field"><span>Au</span><input type="date" value={range.to} onChange={(e) => setRange({ ...range, to: e.target.value })} /></label>
        <button className="btn primary small" type="button" disabled={busy} onClick={async () => {
          setBusy(true);
          try {
            const rows = await admin.accountingExport(range.from, range.to);
            download(toCsv(rows), `secoto-comptabilite-${range.from}_${range.to}.csv`);
          } finally { setBusy(false); }
        }}>Exporter en CSV</button>
      </div>
      <h3 style={{ marginTop: 18 }}>Journal des décisions</h3>
      {!entries && <p className="muted">Chargement…</p>}
      <div className="od-scroll">
        <table className="od-table">
          <thead><tr><th>Date</th><th>Action</th><th>Objet</th><th>Détail</th></tr></thead>
          <tbody>
            {(entries || []).map((e) => (
              <tr key={e.id}><td>{formatDateTime(e.created_at)}</td><td>{e.action}</td><td>{e.entity} {String(e.entity_id || "").slice(0, 8)}</td><td><code>{JSON.stringify(e.details).slice(0, 160)}</code></td></tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
